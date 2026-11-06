import Photos
import Foundation

extension SystemPhotoLibraryService: PhotoFileExportService {
    func exportPhoto(id: String, directory: URL, completion: @escaping (Result<URL, Error>) -> Void) -> PhotoImageRequest {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // Preserve the original resource for both stills and videos in batch sharing.
        let resource = asset.mediaType == .video
            ? (resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video }))
            : (resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }))
        guard let resource else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        let filename = (resource.originalFilename as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            completion(.failure(PhotoDetailError.unavailable)); return PhotoImageRequest(cancel: {})
        }
        let writer: PhotoExportFileWriter
        do { writer = try PhotoExportFileWriter(url: directory.appendingPathComponent(filename)) }
        catch { completion(.failure(error)); return PhotoImageRequest(cancel: {}) }
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        let requestID = manager.requestData(for: resource, options: options, dataReceivedHandler: { writer.append($0) }) { error in
            let result = writer.finish(error: error)
            DispatchQueue.main.async { completion(result) }
        }
        return PhotoImageRequest { writer.cancel(); manager.cancelDataRequest(requestID) }
    }
}
