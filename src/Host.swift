// Executável mínimo do app. Ele só carrega o motor (RP60Engine.dylib) e chama rp60_main().
// Fica separado para que a permissão de Gravação de Tela não se perca a cada recompilação do motor.
import Foundation

let bundleURL = Bundle.main.bundleURL
let candidates = [
    bundleURL.appendingPathComponent("Contents/Frameworks/RP60Engine.dylib").path,
    bundleURL.deletingLastPathComponent().appendingPathComponent("build/RP60Engine.dylib").path,
]
guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
    fputs("RP60: motor RP60Engine.dylib não encontrado\n", stderr)
    exit(1)
}
guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
    fputs("RP60: dlopen falhou: \(String(cString: dlerror()))\n", stderr)
    exit(1)
}
guard let sym = dlsym(handle, "rp60_main") else {
    fputs("RP60: símbolo rp60_main ausente\n", stderr)
    exit(1)
}
typealias EntryFn = @convention(c) () -> Void
unsafeBitCast(sym, to: EntryFn.self)()
