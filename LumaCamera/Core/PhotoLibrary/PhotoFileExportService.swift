import Foundation

/// Streams one image resource to disk. Completion is delivered on the main queue.
protocol PhotoFileExportService {
    func exportPhoto(id: String, directory: URL, completion: @escaping (Result<URL, Error>) -> Void) -> PhotoImageRequest
}

/// Serializes PhotoKit data callbacks, disk errors and cancellation without retaining a whole RAW in RAM.
final class PhotoExportFileWriter {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failure: Error?
    private var cancelled = false
    let url: URL
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, failure == nil else { return }
        do { try handle?.write(contentsOf: data) } catch { failure = error }
    }
    func finish(error: Error?) -> Result<URL, Error> {
        lock.lock(); defer { lock.unlock() }
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        if cancelled { try? FileManager.default.removeItem(at: url); return .failure(CancellationError()) }
        if let error = failure ?? error { try? FileManager.default.removeItem(at: url); return .failure(error) }
        return .success(url)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
