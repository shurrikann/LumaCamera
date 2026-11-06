import CoreImage

/// Compiled with the app; no runtime compilation of deprecated Core Image language.
enum MetalImageKernels {
    private static let library: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            NSLog("Missing Core Image Metal library"); return nil
        }
        return try? Data(contentsOf: url)
    }()
    static func color(_ name: String) -> CIColorKernel? {
        guard let library else { return nil }
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: library) }
        catch { NSLog("Metal color kernel %@: %@", name, error.localizedDescription); return nil }
    }
    static func general(_ name: String) -> CIKernel? {
        guard let library else { return nil }
        do { return try CIKernel(functionName: name, fromMetalLibraryData: library) }
        catch { NSLog("Metal image kernel %@: %@", name, error.localizedDescription); return nil }
    }
}
