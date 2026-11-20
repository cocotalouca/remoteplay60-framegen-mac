import AppKit
import ScreenCaptureKit
import VideoToolbox

let remotePlayBundleID = "com.playstation.RemotePlay"

private var controller: AppController?

@_cdecl("rp60_main")
public func rp60_main() {
    setvbuf(stdout, nil, _IOLBF, 0)
    if let dir = ProcessInfo.processInfo.environment["RP60_EXPORT_ICONSET"] {
        exportIconset(to: dir)
        exit(0)
    }
    let app = NSApplication.shared
    let c = AppController()
    controller = c
    app.delegate = c
    app.setActivationPolicy(.regular)
    app.run()
}

/// Janela transparente para cliques/teclado, que nunca rouba o foco do PS Remote Play.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Plaquinha de FPS desenhada sobre o jogo.
final class HUDPill: NSView {
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ attributed: NSAttributedString) {
        label.attributedStringValue = attributed
        label.sizeToFit()
        let s = NSSize(width: label.frame.width + 20, height: label.frame.height + 10)
        label.setFrameOrigin(NSPoint(x: 10, y: 5))
        guard let sv = superview else { return }
        frame = NSRect(x: 14, y: sv.bounds.height - s.height - 14, width: s.width, height: s.height)
    }
}

final class AppController: NSObject, NSApplicationDelegate, PipelineDelegate {
    private var model: SettingsModel!
    private var settingsWindow: SettingsWindow?

    private var renderer: Renderer!
    private let frameQueue = FrameQueue()
    private var panel: OverlayPanel?
    private var overlayView: OverlayView?
    private var hud: HUDPill?

    private var pipeline: Pipeline?
    private var rpWindowID: CGWindowID = 0
    private var rpFrame = CGRect.zero        // coordenadas globais, origem no topo-esquerdo (pontos)
    private var videoRect: CGRect?           // relativo à janela do Remote Play
    private var windowOnscreen = false
    private var pendingSize: CGSize?
    private var pendingSince = 0.0
    private var acquiring = false
    private var lastAcquire = -10.0

    private var mode: FGMode = .fluid120
    private var hudOn = true

    private var pollTimer: Timer?
    private var statsTimer: Timer?

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeAppIcon()
        buildMainMenu()

        // Preferências (gravadas no próprio .app)
        if let env = ProcessInfo.processInfo.environment["RP60_MODE"], let m = Int(env).flatMap(FGMode.init(rawValue:)) {
            mode = m
        } else if let s = Prefs.get("mode"), let m = Int(s).flatMap(FGMode.init(rawValue:)) {
            mode = m
        }
        hudOn = Prefs.get("hud") != "0"
        let fxOn = Prefs.get("metalfx") != "0"

        guard let r = Renderer() else {
            fatalAlert("Não foi possível inicializar o Metal.")
            return
        }
        renderer = r
        renderer.useMetalFX = fxOn

        model = SettingsModel(mode: mode, metalFX: fxOn, showHUD: hudOn)
        model.onMode = { [weak self] m in self?.setMode(m) }
        model.onMetalFX = { [weak self] on in
            self?.renderer.useMetalFX = on
            Prefs.set("metalfx", on ? "1" : "0")
        }
        model.onHUD = { [weak self] on in
            self?.hudOn = on
            self?.hud?.isHidden = !on
            Prefs.set("hud", on ? "1" : "0")
        }
        model.onRecalibrate = { [weak self] in self?.restartPipeline() }
        model.onPlay = { [weak self] in self?.backToGame() }
        model.onQuit = { NSApp.terminate(nil) }

        registerHotKey { [weak self] in self?.toggleSettings() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        if !VTSupport.interpolationSupported {
            rpLog("Interpolação de frames não suportada neste Mac; rodando só com upscaling.")
        }

        if !CGPreflightScreenCaptureAccess() {
            rpLog("Sem permissão de Gravação de Tela; solicitando.")
            if !CGRequestScreenCaptureAccess() {
                permissionAlert()
                return
            }
        }

        launchRemotePlayIfNeeded()

        let pt = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pt, forMode: .common)
        pollTimer = pt
        let stt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.updateStats() }
        RunLoop.main.add(stt, forMode: .common)
        statsTimer = stt
        poll()
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func appTerminated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == remotePlayBundleID else { return }
        rpLog("PS Remote Play fechado; encerrando.")
        NSApp.terminate(nil)
    }

    @objc private func appActivated(_ n: Notification) {
        updateOverlayVisibility()
    }

    private func launchRemotePlayIfNeeded() {
        if NSRunningApplication.runningApplications(withBundleIdentifier: remotePlayBundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: remotePlayBundleID) {
            rpLog("Abrindo o PS Remote Play…")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Menu principal e painel

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let show = NSMenuItem(title: "Mostrar painel", action: #selector(showSettingsAction), keyEquivalent: ",")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Sair do RemotePlay 60", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func showSettingsAction() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func toggleSettings() {
        if let w = settingsWindow, w.isVisible, NSApp.isActive {
            backToGame()
        } else {
            showSettings()
        }
    }

    /// Esconde o painel e devolve o foco ao Remote Play (o controle só funciona com ele em primeiro plano).
    private func backToGame() {
        settingsWindow?.orderOut(nil)
        if let rp = NSRunningApplication.runningApplications(withBundleIdentifier: remotePlayBundleID).first {
            rp.activate()
        }
    }

    private func setMode(_ m: FGMode) {
        guard m != mode else { return }
        mode = m
        Prefs.set("mode", String(m.rawValue))
        pipeline?.setMode(m)
        frameQueue.reset()
        rpLog("Modo: \(m.title)")
    }

    // MARK: - Acompanhamento da janela do Remote Play

    private func poll() {
        let now = CACurrentMediaTime()
        if rpWindowID == 0 {
            acquireIfNeeded()
            updateOverlayVisibility()
            return
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], rpWindowID) as? [[String: Any]],
              let info = list.first,
              let bd = info[kCGWindowBounds as String],
              let b = CGRect(dictionaryRepresentation: bd as! CFDictionary) else {
            rpLog("Janela do Remote Play sumiu.")
            stopPipeline()
            return
        }
        windowOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if b.size != rpFrame.size {
            // Redimensionando (ou entrando em tela cheia): espera estabilizar e recalibra
            if pendingSize != b.size {
                pendingSize = b.size
                pendingSince = now
                hideOverlay()
                return
            }
            if now - pendingSince > 0.6 {
                rpLog("Janela mudou de tamanho para \(Int(b.width))x\(Int(b.height)); recalibrando.")
                pendingSize = nil
                restartPipeline()
            }
            return
        }
        pendingSize = nil
        if b.origin != rpFrame.origin {
            rpFrame = b
            positionOverlay()
        }
        updateOverlayVisibility()
    }

    private func acquireIfNeeded() {
        let now = CACurrentMediaTime()
        guard !acquiring, now - lastAcquire > 1.0 else { return }
        acquiring = true
        lastAcquire = now
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                self.acquiring = false
                guard let content else {
                    rpLog("Não consegui listar janelas: \(String(describing: error))")
                    self.model.connected = false
                    self.model.status = "Sem permissão de Gravação de Tela"
                    return
                }
                // Só a janela do stream (vídeo 16:9 + barra de título). A janela inicial do Remote Play
                // (864x432, proporção 2:1) e diálogos ficam de fora.
                let wins = content.windows.filter {
                    guard $0.owningApplication?.bundleIdentifier == remotePlayBundleID, $0.windowLayer == 0,
                          $0.frame.width >= 480, $0.frame.height >= 270 else { return false }
                    let aspect = $0.frame.width / max(1, $0.frame.height - 28)
                    return aspect >= 1.45 && aspect <= 1.95
                }
                guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    self.model.connected = false
                    self.model.status = "Aguardando o stream do PS Remote Play…"
                    return
                }
                self.startPipeline(w)
            }
        }
    }

    private func startPipeline(_ w: SCWindow) {
        stopPipeline()
        rpWindowID = w.windowID
        rpFrame = w.frame
        videoRect = nil
        windowOnscreen = true
        let p = Pipeline(window: w, out: frameQueue)
        p.delegate = self
        pipeline = p
        model.status = "Calibrando a área do vídeo…"
        p.start(fixedRect: nil, mode: mode, displayHz: Double(NSScreen.main?.maximumFramesPerSecond ?? 60)) { [weak self] err in
            guard let self, let err else { return }
            rpLog("Falha ao iniciar captura: \(err)")
            self.model.status = "Falha na captura: \(err.localizedDescription)"
            self.stopPipeline()
        }
        if debugMode {
            let dir = Bundle.main.bundleURL.deletingLastPathComponent()
            p.saveSnapshot(to: dir.appendingPathComponent("diagnostico-janela.png"))
        }
    }

    private func stopPipeline() {
        pipeline?.stop()
        pipeline = nil
        rpWindowID = 0
        videoRect = nil
        frameQueue.reset()
        hideOverlay()
    }

    private func restartPipeline() {
        stopPipeline()
        lastAcquire = -10
        acquireIfNeeded()
    }

    // MARK: - PipelineDelegate

    func pipelineCalibrated(_ p: Pipeline, videoRect r: CGRect) {
        guard p === pipeline else { return }
        videoRect = r
        frameQueue.reset()
        positionOverlay()
        updateOverlayVisibility()
    }

    func pipelineStopped(_ p: Pipeline, error: Error?) {
        guard p === pipeline else { return }
        stopPipeline()
    }

    // MARK: - Overlay

    private func positionOverlay() {
        guard let vr = videoRect else { return }
        let g = CGRect(x: rpFrame.minX + vr.minX, y: rpFrame.minY + vr.minY, width: vr.width, height: vr.height)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: g.minX, y: primaryH - g.maxY, width: g.width, height: g.height)
        if panel == nil { makePanel(rect) }
        panel?.setFrame(rect, display: false)
    }

    private func makePanel(_ rect: NSRect) {
        let p = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.sharingType = .none
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        let v = OverlayView(frame: container.bounds, renderer: renderer, queue: frameQueue)
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)

        let pill = HUDPill(frame: NSRect(x: 14, y: rect.height - 40, width: 10, height: 10))
        pill.autoresizingMask = [.minYMargin]
        pill.isHidden = !hudOn
        container.addSubview(pill)

        p.contentView = container
        panel = p
        overlayView = v
        hud = pill
    }

    private func hideOverlay() {
        panel?.orderOut(nil)
        overlayView?.paused = true
    }

    private func updateOverlayVisibility() {
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let front = frontID == remotePlayBundleID || frontID == Bundle.main.bundleIdentifier
        let visible = videoRect != nil && windowOnscreen && front && pendingSize == nil && pipeline != nil
        guard let p = panel else { return }
        if visible {
            if !p.isVisible {
                frameQueue.reset()
                p.orderFrontRegardless()
            }
            overlayView?.paused = false
        } else if p.isVisible {
            hideOverlay()
        }
    }

    // MARK: - Estatísticas

    private func updateStats() {
        guard let p = pipeline else {
            model.sourceFPS = 0
            model.outputFPS = 0
            model.delayMs = 0
            return
        }
        let s = p.takeStats()
        let counts = overlayView?.takeCounts() ?? (total: 0, interp: 0)
        if s.calibrating {
            model.connected = false
            model.status = "Calibrando a área do vídeo… (mexa a câmera)"
            if debugMode { rpLog("calibrando: capturados=\(s.captured)") }
            return
        }
        let visible = panel?.isVisible ?? false
        let outFPS = visible ? counts.total : 0
        model.connected = true
        model.sourceFPS = s.unique
        model.outputFPS = outFPS
        model.delayMs = Int(s.delayMs.rounded())
        if mode == .off {
            model.status = "Conectado · geração de frames desligada"
        } else if !s.fgReady {
            model.status = "Carregando a IA…"
        } else {
            model.status = visible ? "Ativo sobre o PS Remote Play" : "Pronto · clique no jogo para ver"
        }
        let fx = renderer.metalFXActive ? "MetalFX" : "bilinear"
        let inS = renderer.lastInputSize, outS = renderer.lastOutputSize
        model.detail = String(format: "IA %d×%d em %.1f ms · %d×%d → %d×%d %@",
                              Int(s.interpSize.width), Int(s.interpSize.height), s.vtMs,
                              Int(inS.width), Int(inS.height), Int(outS.width), Int(outS.height), fx)

        if hudOn, let hud {
            let a = NSMutableAttributedString()
            let white: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)]
            let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white.withAlphaComponent(0.65), .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
            let pink: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(srgbRed: 1, green: 0.45, blue: 0.62, alpha: 1), .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy)]
            a.append(NSAttributedString(string: "\(s.unique)", attributes: white))
            a.append(NSAttributedString(string: " → ", attributes: dim))
            a.append(NSAttributedString(string: "\(outFPS) fps", attributes: pink))
            a.append(NSAttributedString(string: "  ·  +\(Int(s.delayMs.rounded())) ms", attributes: dim))
            hud.set(a)
        }

        rpLog("\(mode.short) cap=\(s.captured) jogo=\(s.unique) refin=\(s.refines) rep=\(s.dups) gerados=\(s.interp) exib=\(counts.total) (gerados exib=\(counts.interp)) late=\(s.late) fail=\(s.failed) vt=\(String(format: "%.1f", s.vtMs))ms lat=\(String(format: "%.1f", s.latMs))ms atraso=\(String(format: "%.0f", s.delayMs))ms \(fx) \(Int(inS.width))x\(Int(inS.height))→\(Int(outS.width))x\(Int(outS.height)) visível=\(visible)")
    }

    // MARK: - Alertas

    private func permissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Permita a Gravação de Tela"
        a.informativeText = "O RemotePlay 60 precisa ler a imagem da janela do PS Remote Play para gerar os frames extras.\n\nEm Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema, ative \"RemotePlay60\" e abra o app de novo."
        a.addButton(withTitle: "Abrir Ajustes")
        a.addButton(withTitle: "Sair")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    private func fatalAlert(_ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "RemotePlay 60"
        a.informativeText = msg
        a.runModal()
        NSApp.terminate(nil)
    }
}

enum VTSupport {
    static var interpolationSupported: Bool {
        VTLowLatencyFrameInterpolationConfiguration.isSupported
    }
}
