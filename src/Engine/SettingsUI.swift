import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Preferências guardadas DENTRO do próprio .app (atributos estendidos do pacote).
// Apagou o app, apagou a configuração: nada vai para ~/Library.

enum Prefs {
    private static var path: String { Bundle.main.bundlePath }
    static func get(_ key: String) -> String? {
        let name = "local.rp60." + key
        let len = getxattr(path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(path, name, &buf, len, 0, 0) == len else { return nil }
        return String(bytes: buf, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        let name = "local.rp60." + key
        let d = Array(value.utf8)
        _ = setxattr(path, name, d, d.count, 0, 0)
    }
}

// MARK: - Visual

enum Theme {
    static let pink = Color(red: 1.0, green: 0.33, blue: 0.56)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let violet = Color(red: 0.56, green: 0.33, blue: 1.0)
    static let accent = LinearGradient(colors: [pink, orange], startPoint: .leading, endPoint: .trailing)
    static let icon = LinearGradient(colors: [pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension FGMode {
    var symbol: String {
        switch self {
        case .off: return "pause.circle"
        case .fast60: return "bolt.fill"
        case .sharp60: return "eye.fill"
        case .fluid120: return "wind"
        }
    }
    var label: String {
        switch self {
        case .off: return "Desligado"
        case .fast60: return "60 fps · Menor atraso"
        case .sharp60: return "60 fps · Máxima nitidez"
        case .fluid120: return "120 fps · Máxima fluidez"
        }
    }
    var subtitle: String {
        switch self {
        case .off: return "Só upscaling, sem frames gerados"
        case .fast60: return "Dobra os quadros · controle mais responsivo"
        case .sharp60: return "Dobra os quadros · IA em 1080p, mais pesada"
        case .fluid120: return "Quadruplica os quadros · usa os 120 Hz da tela"
        }
    }
    var typicalDelay: String {
        switch self {
        case .off: return "+0 ms"
        case .fast60: return "≈ +32 ms"
        case .sharp60: return "≈ +49 ms"
        case .fluid120: return "≈ +49 ms"
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var mode: FGMode { didSet { onMode?(mode) } }
    @Published var metalFX: Bool { didSet { onMetalFX?(metalFX) } }
    @Published var showHUD: Bool { didSet { onHUD?(showHUD) } }

    @Published var connected = false
    @Published var status = "Procurando a janela do PS Remote Play…"
    @Published var sourceFPS = 0
    @Published var outputFPS = 0
    @Published var delayMs = 0
    @Published var detail = ""

    var onMode: ((FGMode) -> Void)?
    var onMetalFX: ((Bool) -> Void)?
    var onHUD: ((Bool) -> Void)?
    var onRecalibrate: (() -> Void)?
    var onPlay: (() -> Void)?
    var onQuit: (() -> Void)?

    init(mode: FGMode, metalFX: Bool, showHUD: Bool) {
        self.mode = mode
        self.metalFX = metalFX
        self.showHUD = showHUD
    }
}

struct ModeRow: View {
    let mode: FGMode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.08)))
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label).font(.system(size: 13, weight: .semibold))
                    Text(mode.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(mode.typicalDelay)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.pink.opacity(0.16) : Color.white.opacity(hover ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.06)), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Cabeçalho
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.icon)
                    .frame(width: 40, height: 40)
                    .overlay(Text("60").font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("RemotePlay 60").font(.system(size: 17, weight: .bold))
                    HStack(spacing: 6) {
                        Circle().fill(m.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(m.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }

            // Medidor ao vivo
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("JOGO").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).tracking(1.2)
                    Text("\(m.sourceFPS)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                }
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text("NA TELA").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).tracking(1.2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(m.outputFPS)").font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.accent)
                        Text("fps").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("ATRASO EXTRA").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).tracking(1.2)
                    Text("+\(m.delayMs) ms").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.28)))

            // Modos
            VStack(alignment: .leading, spacing: 8) {
                Text("GERAÇÃO DE FRAMES POR IA").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(1.2)
                ForEach([FGMode.fluid120, .fast60, .sharp60, .off], id: \.rawValue) { md in
                    ModeRow(mode: md, selected: m.mode == md) { m.mode = md }
                }
            }

            // Opções
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $m.metalFX) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Upscaling MetalFX").font(.system(size: 13, weight: .medium))
                        Text("Amplia o 1080p para a resolução da tela com mais nitidez").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $m.showHUD) {
                    Text("Mostrar contador de FPS sobre o jogo").font(.system(size: 13, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.pink)

            if !m.detail.isEmpty {
                Text(m.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(2)
            }

            // Ações
            HStack(spacing: 10) {
                Button { m.onPlay?() } label: {
                    Label("Voltar ao jogo", systemImage: "gamecontroller.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Button("Recalibrar área") { m.onRecalibrate?() }
                Spacer()
                Button("Sair") { m.onQuit?() }
            }
            .controlSize(.regular)

            Text("⌃⌥F mostra/esconde este painel · ícone no Dock também abre")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Janela do painel: vidro escuro, sem barra de título visível, acima do overlay do jogo.
final class SettingsWindow: NSWindow {
    init(model: SettingsModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        let host = NSHostingView(rootView: SettingsView(m: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
        setContentSize(host.fittingSize)
        center()
    }
}

// MARK: - Ícone desenhado em código (sem arquivos extras)

func makeAppIcon(size: CGFloat = 512) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    drawAppIcon(size: size)
    img.unlockFocus()
    return img
}

/// Gera um .iconset (PNGs em todos os tamanhos) para o build de release.
func exportIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawAppIcon(size: CGFloat(px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}

private func drawAppIcon(size: CGFloat) {
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.33, blue: 0.56, alpha: 1),
                        NSColor(srgbRed: 0.56, green: 0.33, blue: 1.0, alpha: 1)])?.draw(in: path, angle: -55)
    // brilho
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: rect.height * 0.45),
                               xRadius: rect.width * 0.225, yRadius: rect.width * 0.225), angle: -90)
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let big: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.40, weight: .black),
        .foregroundColor: NSColor.white,
        .paragraphStyle: p,
    ]
    let small: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.09, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .paragraphStyle: p,
        .kern: size * 0.012,
    ]
    let s = NSAttributedString(string: "60", attributes: big)
    let h = s.size().height
    s.draw(in: NSRect(x: rect.minX, y: rect.midY - h * 0.42, width: rect.width, height: h))
    NSAttributedString(string: "FPS · IA", attributes: small)
        .draw(in: NSRect(x: rect.minX, y: rect.minY + rect.height * 0.14, width: rect.width, height: size * 0.12))
}

// MARK: - Atalho global ⌃⌥F (Carbon: não precisa de permissão de Acessibilidade)

private var hotKeyRef: EventHotKeyRef?
private var hotKeyAction: (() -> Void)?

func registerHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x5250_3630), id: 1)  // 'RP60'
    RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
}
