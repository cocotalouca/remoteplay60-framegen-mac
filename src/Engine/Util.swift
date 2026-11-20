import Foundation
import QuartzCore
import CoreVideo

private let timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return t
}()

/// Converte mach_absolute_time para segundos (mesmo domínio de CACurrentMediaTime / CADisplayLink).
func machSeconds(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}

func rpLog(_ s: String) {
    let line = String(format: "[%.3f] ", CACurrentMediaTime()) + s + "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

let debugMode = ProcessInfo.processInfo.environment["RP60_DEBUG"] != nil

/// Um frame pronto para exibir, com o horário (host time, segundos) em que deve aparecer.
final class Frame {
    var buffer: CVPixelBuffer
    let time: Double
    let interpolated: Bool
    /// Frames reais em resolução cheia (antes/depois), usados para devolver o detalhe
    /// às áreas paradas quando a IA rodou em resolução menor.
    let refA: CVPixelBuffer?
    let refB: CVPixelBuffer?
    init(buffer: CVPixelBuffer, time: Double, interpolated: Bool, refA: CVPixelBuffer? = nil, refB: CVPixelBuffer? = nil) {
        self.buffer = buffer
        self.time = time
        self.interpolated = interpolated
        self.refA = refA
        self.refB = refB
    }
}

/// Fila de exibição ordenada por horário. O display link pega o frame mais recente já "vencido".
final class FrameQueue {
    private let lock = NSLock()
    private var items: [Frame] = []
    private var lastShown: Double = -.infinity

    @discardableResult
    func push(_ f: Frame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if f.time <= lastShown { return false }  // chegou tarde: um frame mais novo já foi exibido
        let idx = items.firstIndex { $0.time > f.time } ?? items.count
        items.insert(f, at: idx)
        if items.count > 12 { items.removeFirst(items.count - 12) }
        return true
    }

    func pop(due t: Double) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let i = items.lastIndex(where: { $0.time <= t }) else { return nil }
        let f = items[i]
        items.removeFirst(i + 1)
        lastShown = f.time
        return f
    }

    /// Troca o buffer de um frame real ainda não exibido (versão refinada do mesmo frame do jogo).
    func upgrade(time: Double, buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let f = items.first(where: { !$0.interpolated && $0.time == time }) { f.buffer = buffer }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
        lastShown = -.infinity
    }
}
