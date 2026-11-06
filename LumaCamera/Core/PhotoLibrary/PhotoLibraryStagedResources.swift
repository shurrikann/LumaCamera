import Photos
import UniformTypeIdentifiers

/// Photos validates paired movies asynchronously. File URLs and type hints remove
/// ambiguity and outlive the changes block; failed saves retain their original data for retry.
// Entries are built once during init; later access only reads them or removes the directory.
final class PhotoLibraryStagedResources: @unchecked Sendable {
    struct Entry {
        let filename: String
        let kind: PHAssetResourceType
        let typeIdentifier: String?
        let url: URL
    }
    let directory: URL
    private(set) var entries: [Entry] = []
    init(_ resources: [PhotoResource]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoKit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (index, resource) in resources.enumerated() {
                let filename = (resource.filename as NSString).lastPathComponent
                let url = directory.appendingPathComponent("\(index)-" + filename)
                try resource.data.write(to: url, options: .atomic)
                let type = resource.pairedVideo ? UTType.quickTimeMovie : UTType(filenameExtension: (filename as NSString).pathExtension)
                entries.append(Entry(filename: filename, kind: resource.pairedVideo ? .pairedVideo : resource.alternate ? .alternatePhoto : .photo,
                                     typeIdentifier: type?.identifier, url: url))
            }
        } catch { cleanup(); throw error }
    }
    /// Call only inside the Photos changes block, retaining this object through completion.
    func add(to request: PHAssetCreationRequest) {
        for entry in entries {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = entry.filename
            options.uniformTypeIdentifier = entry.typeIdentifier
            options.shouldMoveFile = false
            request.addResource(with: entry.kind, fileURL: entry.url, options: options)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { cleanup() }
}
