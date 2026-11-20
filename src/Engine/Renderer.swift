import AppKit
import Metal
import MetalFX
import CoreVideo
import QuartzCore

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
// YCbCr 4:2:0 BT.709 (video range) -> RGB
static half4 toRGB(float Y, float2 C) {
    Y = (Y - 0.0627451) * 1.1643836;
    float Cb = (C.x - 0.5019608) * 1.1383929;
    float Cr = (C.y - 0.5019608) * 1.1383929;
    float3 rgb = float3(Y + 1.5748 * Cr,
                        Y - 0.1873243 * Cb - 0.4681243 * Cr,
                        Y + 1.8556 * Cb);
    return half4(half3(saturate(rgb)), 1.0h);
}
fragment half4 fyuv(VOut in [[stage_in]],
                    texture2d<float> ty [[texture(0)]],
                    texture2d<float> tc [[texture(1)]],
                    sampler s [[sampler(0)]]) {
    return toRGB(ty.sample(s, in.uv).r, tc.sample(s, in.uv).rg);
}
// Frame gerado pela IA em 720p: onde a cena está parada (A ~ B e a IA concorda), devolve o detalhe
// de alta frequência dos frames reais em 1080p. Onde há movimento, fica a imagem da IA.
static float lowpass(texture2d<float> t, sampler s, float2 uv, float2 o) {
    return 0.25 * (t.sample(s, uv + float2(-o.x, -o.y)).r + t.sample(s, uv + float2(o.x, -o.y)).r +
                   t.sample(s, uv + float2(-o.x,  o.y)).r + t.sample(s, uv + float2(o.x,  o.y)).r);
}
fragment half4 finterp(VOut in [[stage_in]],
                       texture2d<float> iy [[texture(0)]],
                       texture2d<float> ic [[texture(1)]],
                       texture2d<float> ay [[texture(2)]],
                       texture2d<float> by [[texture(3)]],
                       sampler s [[sampler(0)]],
                       constant float2 &texel [[buffer(0)]]) {
    float2 uv = in.uv;
    float Yi = iy.sample(s, uv).r;
    float Ya = ay.sample(s, uv).r;
    float Yb = by.sample(s, uv).r;
    float2 o = texel * 0.75;
    float La = lowpass(ay, s, uv, o);
    float Lb = lowpass(by, s, uv, o);
    float detail = 0.5 * (Ya + Yb) - 0.5 * (La + Lb);
    float still = 1.0 - smoothstep(0.012, 0.045, abs(La - Lb));
    float agree = 1.0 - smoothstep(0.015, 0.05, abs(Yi - 0.5 * (La + Lb)));
    return toRGB(Yi + detail * still * agree, ic.sample(s, uv).rg);
}
"""

/// Converte o frame YUV em RGB e desenha na camada. Com MetalFX ligado, faz upscaling espacial
/// (1920x1080 -> resolução nativa da tela) em vez de um simples bilinear.
final class Renderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let pipeline: MTLRenderPipelineState
    private let pipelineInterp: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    var useMetalFX = true
    private(set) var metalFXActive = false

    private var rgbTex: MTLTexture?
    private var outTex: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = [0, 0, 0, 0]
    private var scalerFailedKey = [0, 0, 0, 0]

    private(set) var lastInputSize = CGSize.zero
    private(set) var lastOutputSize = CGSize.zero

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let cq = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = cq
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain")
            d.fragmentFunction = lib.makeFunction(name: "fyuv")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
            d.fragmentFunction = lib.makeFunction(name: "finterp")
            pipelineInterp = try dev.makeRenderPipelineState(descriptor: d)
        } catch {
            rpLog("Erro compilando shaders: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)!
    }

    func configure(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &tex)
        return tex
    }

    private func ensureScaler(inW: Int, inH: Int, outW: Int, outH: Int) -> MTLFXSpatialScaler? {
        let key = [inW, inH, outW, outH]
        if key == scalerKey, let s = scaler { return s }
        if key == scalerFailedKey { return nil }
        scaler = nil
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { scalerFailedKey = key; return nil }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = inW
        d.inputHeight = inH
        d.outputWidth = outW
        d.outputHeight = outH
        d.colorTextureFormat = .bgra8Unorm
        d.outputTextureFormat = .bgra8Unorm
        d.colorProcessingMode = .perceptual
        guard let s = d.makeSpatialScaler(device: device) else {
            rpLog("MetalFX: não suportado para \(inW)x\(inH) -> \(outW)x\(outH); usando bilinear")
            scalerFailedKey = key
            return nil
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: inW, height: inH, mipmapped: false)
        td.usage = s.colorTextureUsage.union([.renderTarget, .shaderRead])
        td.storageMode = .private
        rgbTex = device.makeTexture(descriptor: td)
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
        od.usage = s.outputTextureUsage.union([.shaderRead])
        od.storageMode = .private
        outTex = device.makeTexture(descriptor: od)
        scaler = s
        scalerKey = key
        rpLog("MetalFX: upscaling \(inW)x\(inH) -> \(outW)x\(outH)")
        return s
    }

    @discardableResult
    func draw(_ frame: Frame, layer: CAMetalLayer) -> Bool {
        let pb = frame.buffer
        guard let yRef = planeTexture(pb, plane: 0, format: .r8Unorm),
              let cRef = planeTexture(pb, plane: 1, format: .rg8Unorm),
              let yTex = CVMetalTextureGetTexture(yRef),
              let cTex = CVMetalTextureGetTexture(cRef) else { return false }

        // Frame da IA em resolução menor + referências em resolução cheia?
        var aRef: CVMetalTexture?, bRef: CVMetalTexture?
        var aTex: MTLTexture?, bTex: MTLTexture?
        var inW = CVPixelBufferGetWidth(pb), inH = CVPixelBufferGetHeight(pb)
        if let ra = frame.refA, let rb = frame.refB, CVPixelBufferGetWidth(ra) != inW {
            aRef = planeTexture(ra, plane: 0, format: .r8Unorm)
            bRef = planeTexture(rb, plane: 0, format: .r8Unorm)
            if let aRef, let bRef {
                aTex = CVMetalTextureGetTexture(aRef)
                bTex = CVMetalTextureGetTexture(bRef)
                inW = CVPixelBufferGetWidth(ra)
                inH = CVPixelBufferGetHeight(ra)
            }
        }
        guard let drawable = layer.nextDrawable(), let cb = commandQueue.makeCommandBuffer() else { return false }

        let target = drawable.texture
        let outW = target.width, outH = target.height
        lastInputSize = CGSize(width: inW, height: inH)
        lastOutputSize = CGSize(width: outW, height: outH)

        func colorPass(into tex: MTLTexture) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            if let aTex, let bTex {
                enc.setRenderPipelineState(pipelineInterp)
                enc.setFragmentTexture(aTex, index: 2)
                enc.setFragmentTexture(bTex, index: 3)
                var texel = SIMD2<Float>(1 / Float(aTex.width), 1 / Float(aTex.height))
                enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            } else {
                enc.setRenderPipelineState(pipeline)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        var usedFX = false
        if useMetalFX, outW > inW || outH > inH, outW >= inW, outH >= inH,
           let s = ensureScaler(inW: inW, inH: inH, outW: outW, outH: outH),
           let rgb = rgbTex, let out = outTex {
            colorPass(into: rgb)
            s.colorTexture = rgb
            s.outputTexture = out
            s.inputContentWidth = inW
            s.inputContentHeight = inH
            s.encode(commandBuffer: cb)
            if let bl = cb.makeBlitCommandEncoder() {
                bl.copy(from: out, to: target)
                bl.endEncoding()
            }
            usedFX = true
        } else {
            colorPass(into: target)
        }
        metalFXActive = usedFX
        cb.present(drawable)
        cb.addCompletedHandler { _ in
            _ = yRef; _ = cRef; _ = aRef; _ = bRef; _ = frame  // mantém os buffers vivos até a GPU terminar
        }
        cb.commit()
        return true
    }
}

/// View da camada Metal + display link (120 Hz no ProMotion) que puxa frames da fila no horário certo.
final class OverlayView: NSView {
    let metalLayer = CAMetalLayer()
    private let renderer: Renderer
    private let queue: FrameQueue
    private var link: CADisplayLink?
    private let countLock = NSLock()
    private var displayed = 0
    private var displayedInterp = 0

    init(frame: NSRect, renderer: Renderer, queue: FrameQueue) {
        self.renderer = renderer
        self.queue = queue
        super.init(frame: frame)
        renderer.configure(layer: metalLayer)
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let s = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != s { metalLayer.drawableSize = s }
    }

    var paused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    @objc private func step(_ l: CADisplayLink) {
        guard let f = queue.pop(due: l.targetTimestamp + 0.001) else { return }
        if renderer.draw(f, layer: metalLayer) {
            countLock.lock()
            displayed += 1
            if f.interpolated { displayedInterp += 1 }
            countLock.unlock()
        }
    }

    func takeCounts() -> (total: Int, interp: Int) {
        countLock.lock(); defer { countLock.unlock() }
        let r = (displayed, displayedInterp)
        displayed = 0
        displayedInterp = 0
        return r
    }
}
