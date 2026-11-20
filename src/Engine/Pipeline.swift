import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

protocol PipelineDelegate: AnyObject {
    func pipelineCalibrated(_ p: Pipeline, videoRect: CGRect)
    func pipelineStopped(_ p: Pipeline, error: Error?)
}

/// Modos de geração de frames.
enum FGMode: Int, CaseIterable {
    case off = 0        // só upscaling
    case fast60 = 1     // 2x, IA em 720p + detalhe 1080p: menor atraso
    case sharp60 = 2    // 2x, IA em 1080p: máxima nitidez
    case fluid120 = 3   // 4x (3 frames gerados), IA em 720p + detalhe 1080p: 120 fps

    var title: String {
        switch self {
        case .off: return "Desligado (só upscaling)"
        case .fast60: return "60 fps · menor atraso"
        case .sharp60: return "60 fps · máxima nitidez"
        case .fluid120: return "120 fps · máxima fluidez"
        }
    }
    var short: String {
        switch self {
        case .off: return "FG off"
        case .fast60: return "FG 60 rápido"
        case .sharp60: return "FG 60 nítido"
        case .fluid120: return "FG 120"
        }
    }
    var lowRes: Bool { self == .fast60 || self == .fluid120 }
    var multiplier: Int { self == .fluid120 ? 4 : 2 }
}

struct PipelineStats {
    var captured = 0
    var unique = 0
    var dups = 0
    var refines = 0
    var interp = 0
    var late = 0
    var failed = 0
    var latMs = 0.0
    var vtMs = 0.0
    var delayMs = 0.0
    var sourceFPS = 0.0
    var capSize = CGSize.zero
    var interpSize = CGSize.zero
    var fgReady = false
    var calibrating = true
}

/// Captura a janela do PS Remote Play (ScreenCaptureKit), separa os frames realmente novos do jogo,
/// gera frames intermediários com o interpolador de IA da Apple (VideoToolbox) e agenda tudo na FrameQueue.
final class Pipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    let window: SCWindow
    let filter: SCContentFilter
    let windowSize: CGSize           // pontos
    let pixelScale: CGFloat
    weak var delegate: PipelineDelegate?

    private let out: FrameQueue
    private let q = DispatchQueue(label: "rp60.pipeline", qos: .userInteractive)
    private let setupQ = DispatchQueue(label: "rp60.setup", qos: .userInitiated)
    private var stream: SCStream?

    // Estado (somente na fila q)
    private enum Phase { case calibrating, running }
    private var phase: Phase = .calibrating
    private var capW = 0, capH = 0
    private var mode: FGMode = .fluid120
    private var displayHz = 120.0
    private var stopped = false

    private var copySession: VTPixelTransferSession?
    private var scaleSession: VTPixelTransferSession?
    private var fullPool: CVPixelBufferPool?
    private var lowPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private var procKey = ""
    private var interpW = 0, interpH = 0
    private var processor: VTFrameProcessor?
    private var procReady = false
    private var procGen = 0
    private var busy = false

    // Linha do tempo
    private var lastCap: [UInt8] = []
    private var lastGameRaw = 0.0
    private var lastGameN16 = 0
    private var lastGameDue = 0.0
    private var prevFull: CVPixelBuffer?
    private var prevLow: CVPixelBuffer?
    private var prevT = 0.0
    private var lastRaw = 0.0
    private var deltaEMA = 1.0 / 30.0
    private var smoothedT = 0.0
    private var latencySamples: [Double] = []   // displayTime -> frames gerados prontos
    private var needSamples: [Double] = []      // folga que cada par realmente precisou (pronto - instante do 1º frame gerado)
    private var vtSamples: [Double] = []

    // Calibração
    private var calStart = 0.0
    private var calFrames = 0
    private var calGrid: [UInt8] = []
    private var calGW = 0, calGH = 0
    private var rowHits: [Int] = []
    private var colHits: [Int] = []
    private var calPrimed = false

    // Estatísticas
    private var st = PipelineStats()
    private var loggedFirstFrame = false

    init(window: SCWindow, out: FrameQueue) {
        self.window = window
        self.filter = SCContentFilter(desktopIndependentWindow: window)
        self.windowSize = window.frame.size
        self.pixelScale = CGFloat(filter.pointPixelScale)
        self.out = out
        super.init()
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &copySession)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &scaleSession)
        if let s = scaleSession {
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
    }

    // MARK: - Controle

    func start(fixedRect: CGRect?, mode: FGMode, displayHz: Double, completion: @escaping (Error?) -> Void) {
        let cfg: SCStreamConfiguration
        let w: Int, h: Int
        if let r = fixedRect {
            (cfg, w, h) = makeConfig(rect: r, maxW: 1920, maxH: 1080, maxPixels: 1920 * 1080)
        } else {
            (cfg, w, h) = makeConfig(rect: CGRect(origin: .zero, size: windowSize), maxW: 1280, maxH: 800, maxPixels: 1280 * 800)
        }
        q.sync {
            self.mode = mode
            self.displayHz = displayHz
            self.capW = w
            self.capH = h
            self.phase = fixedRect == nil ? .calibrating : .running
            self.st.calibrating = fixedRect == nil
            self.calStart = CACurrentMediaTime()
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        } catch {
            completion(error)
            return
        }
        stream = s
        rpLog("Captura: janela \(Int(windowSize.width))x\(Int(windowSize.height)) pt, escala \(pixelScale), saída \(w)x\(h), \(fixedRect == nil ? "calibrando" : "área fixa")")
        s.startCapture { err in
            DispatchQueue.main.async { completion(err) }
        }
        if let r = fixedRect {
            DispatchQueue.main.async { self.delegate?.pipelineCalibrated(self, videoRect: r) }
        }
    }

    func stop() {
        q.sync { stopped = true }
        stream?.stopCapture { _ in }
        stream = nil
        let p = q.sync { () -> VTFrameProcessor? in
            let p = processor
            processor = nil
            procReady = false
            procGen += 1
            prevFull = nil
            prevLow = nil
            return p
        }
        if let p { setupQ.async { p.endSession() } }
    }

    func setMode(_ m: FGMode) {
        q.async {
            self.mode = m
            self.latencySamples.removeAll()
            self.needSamples.removeAll()
            self.prevFull = nil
            self.prevLow = nil
        }
    }

    func takeStats() -> PipelineStats {
        q.sync {
            var s = st
            func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) * 1000 }
            s.latMs = avg(latencySamples)
            s.vtMs = avg(vtSamples)
            s.delayMs = currentDelay() * 1000
            s.sourceFPS = 1.0 / deltaEMA
            s.capSize = CGSize(width: capW, height: capH)
            s.interpSize = CGSize(width: interpW, height: interpH)
            s.fgReady = procReady && mode != .off
            s.calibrating = phase == .calibrating
            st = PipelineStats()
            st.calibrating = s.calibrating
            return s
        }
    }

    // MARK: - Configuração da captura

    private func makeConfig(rect: CGRect, maxW: Int, maxH: Int, maxPixels: Int) -> (SCStreamConfiguration, Int, Int) {
        let pxW = Double(rect.width * pixelScale), pxH = Double(rect.height * pixelScale)
        var s = min(1.0, Double(maxW) / pxW, Double(maxH) / pxH)
        s = min(s, (Double(maxPixels) / (pxW * pxH)).squareRoot())
        let w = max(16, Int(pxW * s) & ~1)
        let h = max(16, Int(pxH * s) & ~1)
        let c = SCStreamConfiguration()
        c.sourceRect = rect
        c.width = w
        c.height = h
        c.scalesToFit = true
        c.preservesAspectRatio = false
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.colorSpaceName = CGColorSpace.sRGB
        c.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        c.queueDepth = 5
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        c.captureResolution = .best
        return (c, w, h)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        rpLog("Captura parou: \(error)")
        DispatchQueue.main.async { self.delegate?.pipelineStopped(self, error: error) }
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = sb.imageBuffer else { return }
        let raw = (info[.displayTime] as? UInt64).map(machSeconds) ?? CACurrentMediaTime()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w == capW, h == capH else { return }  // frame de configuração antiga
        st.captured += 1
        if !loggedFirstFrame {
            loggedFirstFrame = true
            rpLog("Primeiro frame: \(w)x\(h) atraso da captura \(String(format: "%.1f", (CACurrentMediaTime() - raw) * 1000)) ms")
        }
        switch phase {
        case .calibrating: calibrate(pb, now: raw)
        case .running: process(pb, raw: raw)
        }
    }

    // MARK: - Calibração: descobre onde está o vídeo (16:9) dentro da janela pelo que se mexe

    private func calibrate(_ pb: CVPixelBuffer, now: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let baseRaw = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let base = baseRaw.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let step = 2
        let gw = w / step, gh = h / step
        if calGW != gw || calGH != gh {
            calGW = gw; calGH = gh
            calGrid = [UInt8](repeating: 0, count: gw * gh)
            rowHits = [Int](repeating: 0, count: gh)
            colHits = [Int](repeating: 0, count: gw)
            calPrimed = false
            calFrames = 0
        }
        var tmpRow = [Int](repeating: 0, count: gh)
        var tmpCol = [Int](repeating: 0, count: gw)
        var changed = 0
        calGrid.withUnsafeMutableBufferPointer { g in
            for gy in 0..<gh {
                let row = base + gy * step * bpr
                let gi = gy * gw
                for gx in 0..<gw {
                    let v = row[gx * step]
                    let d = Int(v) - Int(g[gi + gx])
                    if d > 10 || d < -10 {
                        tmpRow[gy] += 1
                        tmpCol[gx] += 1
                        changed += 1
                    }
                    g[gi + gx] = v
                }
            }
        }
        if !calPrimed { calPrimed = true; return }
        let elapsed = now - calStart
        if changed < max(8, gw * gh / 3000) {  // frame repetido
            if elapsed > 6 { finishCalibration(detectVideoRect() ?? fallbackRect()) }
            return
        }
        calFrames += 1
        for i in 0..<gh { rowHits[i] += tmpRow[i] }
        for i in 0..<gw { colHits[i] += tmpCol[i] }

        guard elapsed > 1.0, calFrames >= 10 else {
            if elapsed > 6 { finishCalibration(fallbackRect()) }
            return
        }
        if let r = detectVideoRect() {
            finishCalibration(r)
        } else if elapsed > 6 {
            finishCalibration(fallbackRect())
        }
    }

    private func detectVideoRect() -> CGRect? {
        let thr = 2
        guard let r0 = rowHits.firstIndex(where: { $0 >= thr }), let r1 = rowHits.lastIndex(where: { $0 >= thr }),
              let c0 = colHits.firstIndex(where: { $0 >= thr }), let c1 = colHits.lastIndex(where: { $0 >= thr }) else { return nil }
        let W = Double(windowSize.width), H = Double(windowSize.height)
        let sy = H / Double(calGH), sx = W / Double(calGW)
        let y0d = Double(r0) * sy, y1d = Double(r1 + 1) * sy
        let x0d = Double(c0) * sx, x1d = Double(c1 + 1) * sx
        let detW = x1d - x0d, detH = y1d - y0d
        rpLog(String(format: "Calibração: movimento em x %.0f–%.0f, y %.0f–%.0f (janela %.0fx%.0f pt)", x0d, x1d, y0d, y1d, W, H))
        guard detW > 0.25 * W, detH > 0.25 * H else { return nil }
        let aspect = 16.0 / 9.0
        var w: Double, h: Double
        if W / H <= 1.80 {
            // Janela mais "alta" que 16:9: o vídeo ocupa a largura toda (faixas pretas em cima/embaixo)
            w = W; h = W / aspect
        } else {
            // Janela mais larga: o vídeo ocupa a altura útil (faixas nas laterais)
            h = min(H, max(detH, detW / aspect)); w = h * aspect
        }
        if h > H { h = H; w = h * aspect }
        if w > W { w = W; h = w / aspect }
        let cy = (y0d + y1d) / 2
        var y0 = cy - h / 2
        if H - y1d < 0.01 * H { y0 = H - h }  // movimento encosta embaixo: vídeo alinhado embaixo
        y0 = min(max(0, y0), H - h)
        let x0 = min(max(0, (W - w) / 2), W - w)
        return snap(CGRect(x: x0, y: y0, width: w, height: h))
    }

    private func fallbackRect() -> CGRect {
        let W = Double(windowSize.width), H = Double(windowSize.height)
        // Barra de título de 28 pt (0 em tela cheia); vídeo 16:9 centralizado no resto
        let titlebar = H >= (NSScreen.main?.frame.height ?? 0) - 1 ? 0.0 : 28.0
        let content = H - titlebar
        var w = W, h = W * 9 / 16
        if h > content { h = content; w = h * 16 / 9 }
        rpLog("Calibração: pouco movimento, usando estimativa geométrica")
        return snap(CGRect(x: (W - w) / 2, y: titlebar + (content - h) / 2, width: w, height: h))
    }

    private func snap(_ r: CGRect) -> CGRect {
        let s = Double(pixelScale)
        func f(_ v: Double) -> Double { (v * s).rounded() / s }
        return CGRect(x: f(r.minX), y: f(r.minY), width: f(r.width), height: f(r.height))
    }

    private func finishCalibration(_ r: CGRect) {
        let (cfg, w, h) = makeConfig(rect: r, maxW: 1920, maxH: 1080, maxPixels: 1920 * 1080)
        rpLog(String(format: "Área do vídeo: x %.1f y %.1f %.1fx%.1f pt -> captura %dx%d", r.minX, r.minY, r.width, r.height, w, h))
        phase = .running
        capW = w
        capH = h
        st.calibrating = false
        lastCap.removeAll()
        stream?.updateConfiguration(cfg) { err in
            if let err { rpLog("updateConfiguration erro: \(err)") }
        }
        DispatchQueue.main.async { self.delegate?.pipelineCalibrated(self, videoRect: r) }
    }

    // MARK: - Interpolador

    private func ensureProcessor(w: Int, h: Int) {
        let key = "\(w)x\(h)-\(mode.rawValue)"
        if key == procKey { return }
        procKey = key
        procReady = false
        procGen += 1
        if let old = processor { setupQ.async { old.endSession() } }
        processor = nil
        prevFull = nil
        prevLow = nil
        latencySamples.removeAll()
        needSamples.removeAll()
        vtSamples.removeAll()

        fullPool = makePool(w: w, h: h, attrs: [:])
        guard mode != .off else { interpW = 0; interpH = 0; return }
        var iw = w, ih = h
        if mode.lowRes {
            let s = min(1.0, 1280.0 / Double(w), 720.0 / Double(h))
            iw = Int(Double(w) * s) & ~1
            ih = Int(Double(h) * s) & ~1
        }
        interpW = iw; interpH = ih
        let n = mode.multiplier == 4 ? 2 : 1
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: iw, frameHeight: ih, numberOfInterpolatedFrames: n) else {
            rpLog("Interpolador não aceita \(iw)x\(ih)")
            return
        }
        if mode.lowRes {
            lowPool = makePool(w: iw, h: ih, attrs: cfg.sourcePixelBufferAttributes)
        } else {
            fullPool = makePool(w: w, h: h, attrs: cfg.sourcePixelBufferAttributes)
            lowPool = nil
        }
        dstPool = makePool(w: iw, h: ih, attrs: cfg.destinationPixelBufferAttributes)
        let gen = procGen
        let modeName = mode.title
        setupQ.async {
            let p = VTFrameProcessor()
            let t0 = CACurrentMediaTime()
            do {
                try p.startSession(configuration: cfg)
            } catch {
                rpLog("Falha ao iniciar interpolador: \(error)")
                return
            }
            rpLog(String(format: "IA pronta: %@ (%dx%d) em %.0f ms", modeName, iw, ih, (CACurrentMediaTime() - t0) * 1000))
            self.q.async {
                if gen == self.procGen && !self.stopped {
                    self.processor = p
                    self.procReady = true
                } else {
                    self.setupQ.async { p.endSession() }
                }
            }
        }
    }

    private func makePool(w: Int, h: Int, attrs: [String: Any]) -> CVPixelBufferPool? {
        var a = attrs
        a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        a[kCVPixelBufferWidthKey as String] = w
        a[kCVPixelBufferHeightKey as String] = h
        a[kCVPixelBufferMetalCompatibilityKey as String] = true
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, a as CFDictionary, &pool)
        return pool
    }

    private func transfer(_ src: CVPixelBuffer, pool: CVPixelBufferPool?, session: VTPixelTransferSession?) -> CVPixelBuffer? {
        guard let pool, let session else { return nil }
        var o: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &o)
        guard let dst = o, VTPixelTransferSessionTransferImage(session, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    // MARK: - Detecção de frames novos

    /// Amostra a luminância numa grade direto do buffer da captura (sem copiar).
    private func lumaSamples(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let b = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let base = b.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let step = 6
        var out = [UInt8]()
        out.reserveCapacity((w / step + 1) * (h / step + 1))
        var y = step / 2
        while y < h {
            let row = base + y * bpr
            var x = step / 2
            while x < w { out.append(row[x]); x += step }
            y += step
        }
        return out
    }

    /// (amostras com |d|>2, amostras com |d|>16)
    private func diffStats(_ a: [UInt8], _ b: [UInt8]) -> (Int, Int) {
        var n2 = 0, n16 = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count {
                    var d = Int(pa[i]) - Int(pb[i])
                    if d < 0 { d = -d }
                    if d > 2 { n2 += 1; if d > 16 { n16 += 1 } }
                }
            }
        }
        return (n2, n16)
    }

    private func currentDelay() -> Double {
        guard mode != .off, procReady else { return 0 }
        if needSamples.count >= 8 {
            let s = needSamples.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * 0.8))] + 0.001
        }
        let lat = mode.lowRes ? 0.014 : 0.018
        return (1 - minPhase()) * deltaEMA + lat + 0.003
    }

    private func phases() -> [Float] {
        if mode.multiplier == 4 && deltaEMA * displayHz >= 3.0 { return [0.25, 0.5, 0.75] }
        return [0.5]
    }

    private func minPhase() -> Double { Double(phases().first ?? 0.5) }

    // MARK: - Execução

    private func process(_ pb: CVPixelBuffer, raw: Double) {
        // 1) Classifica: repetição exata (Remote Play redesenhando a 120 Hz), "refinamento" do codec
        //    (o stream a 60 fps manda cada frame do jogo a 30 fps duas vezes) ou frame novo do jogo.
        let samples = lumaSamples(pb)
        guard lastCap.count == samples.count else { lastCap = samples; return }
        let (n2, n16) = diffStats(samples, lastCap)
        lastCap = samples
        if n2 < 4 { st.dups += 1; return }
        let isRefine = (raw - lastGameRaw) < 0.022 && n16 * 6 < lastGameN16

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        ensureProcessor(w: w, h: h)
        guard let full = transfer(pb, pool: fullPool, session: copySession) else { return }
        let fg = mode != .off && procReady
        let low: CVPixelBuffer? = (fg && mode.lowRes) ? transfer(full, pool: lowPool, session: scaleSession) : nil

        if isRefine {
            // Mesmo frame do jogo com melhor qualidade de compressão: troca o que ainda não foi exibido
            st.refines += 1
            out.upgrade(time: lastGameDue, buffer: full)
            prevFull = full
            if low != nil { prevLow = low }
            return
        }
        lastGameRaw = raw
        lastGameN16 = n16
        st.unique += 1

        // 2) Linha do tempo suavizada dos frames do jogo
        if lastRaw > 0 {
            let d = raw - lastRaw
            if d > 0.007 && d < 0.1 { deltaEMA = deltaEMA * 0.9 + d * 0.1 }
        }
        lastRaw = raw
        var t = raw
        if smoothedT > 0 {
            let pred = smoothedT + deltaEMA
            let err = raw - pred
            if abs(err) < deltaEMA * 0.45 { t = pred + err * 0.3 }
        }
        smoothedT = t

        let delay = currentDelay()
        let due = fg ? t + delay : raw
        out.push(Frame(buffer: full, time: due, interpolated: false))
        lastGameDue = due

        // 3) Gera os frames intermediários entre o anterior e este
        let gap = t - prevT
        let srcI = mode.lowRes ? low : full
        let prvI = mode.lowRes ? prevLow : prevFull
        if fg, let srcI, let prvI, let refA = prevFull, let proc = processor, let dpool = dstPool,
           !busy, gap > 0.007, gap < 0.075 {
            let ph = phases()
            var dsts: [CVPixelBuffer] = []
            for _ in ph {
                var o: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, dpool, &o)
                if let o { dsts.append(o) }
            }
            let tPrev = prevT
            let pts = { (s: Double) in CMTime(seconds: s, preferredTimescale: 1_000_000) }
            let dFrames = zip(dsts, ph).compactMap { VTFrameProcessorFrame(buffer: $0.0, presentationTimeStamp: pts(tPrev + Double($0.1) * gap)) }
            if dsts.count == ph.count, dFrames.count == ph.count,
               let src = VTFrameProcessorFrame(buffer: srcI, presentationTimeStamp: pts(t)),
               let prv = VTFrameProcessorFrame(buffer: prvI, presentationTimeStamp: pts(tPrev)),
               let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: src, previousFrame: prv, interpolationPhase: ph, destinationFrames: dFrames) {
                busy = true
                let gen = procGen
                let lowRes = mode.lowRes
                let refB = full
                let call = CACurrentMediaTime()
                let outQ = out
                proc.process(parameters: params) { [weak self] _, err in
                    let ready = CACurrentMediaTime()
                    var pushed = 0
                    if err == nil {
                        // Publica direto daqui (a fila é thread-safe) para não esperar a fila de captura
                        for (i, d) in dsts.enumerated() {
                            let f = Frame(buffer: d, time: tPrev + Double(ph[i]) * gap + delay, interpolated: true,
                                          refA: lowRes ? refA : nil, refB: lowRes ? refB : nil)
                            if outQ.push(f) { pushed += 1 }
                        }
                    }
                    guard let self else { return }
                    self.q.async {
                        self.busy = false
                        guard gen == self.procGen else { return }
                        if let err {
                            self.st.failed += 1
                            if self.st.failed < 3 { rpLog("Interpolação falhou: \(err)") }
                            return
                        }
                        self.st.interp += pushed
                        self.latencySamples.append(ready - raw)
                        if self.latencySamples.count > 40 { self.latencySamples.removeFirst() }
                        self.vtSamples.append(ready - call)
                        if self.vtSamples.count > 40 { self.vtSamples.removeFirst() }
                        let need = ready - (tPrev + Double(ph[0]) * gap)
                        self.needSamples.append(need)
                        if self.needSamples.count > 60 { self.needSamples.removeFirst() }
                        if need > delay { self.st.late += 1 }
                    }
                }
            }
        }
        prevFull = full
        prevLow = low
        prevT = t
    }

    // MARK: - Diagnóstico

    func saveSnapshot(to url: URL) {
        let c = SCStreamConfiguration()
        c.width = Int(windowSize.width * pixelScale)
        c.height = Int(windowSize.height * pixelScale)
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: c) { img, err in
            guard let img else { rpLog("Snapshot falhou: \(String(describing: err))"); return }
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, img, nil)
            CGImageDestinationFinalize(d)
            rpLog("Snapshot salvo em \(url.path) (\(img.width)x\(img.height))")
        }
    }
}
