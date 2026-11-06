import UIKit

/// Completions are delivered on the main queue. The identifier belongs to the system Photos library.
protocol PhotoLibraryService {
    func canReloadSavedPhoto(id: String) -> Bool
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void)
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void)
    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void)
    func saveLivePhoto(stillImage: Data, movieURL: URL, location: PhotoLocation?, creationDate: Date?, completion: @escaping (Result<String, Error>) -> Void)
    func delete(assetIDs: [String], completion: @escaping (Result<Void, Error>) -> Void)
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension PhotoLibraryService {
    func canReloadSavedPhoto(id: String) -> Bool { true }
    func delete(assetIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        let ids = Array(Set(assetIDs))
        if ids.isEmpty { completion(.success(())) }
        else if ids.count == 1 { delete(assetID: ids[0], completion: completion) }
        else { completion(.failure(PhotoLibraryError.batchDeletionUnsupported)) }
    }

    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) { save(photo.preview, completion: completion) }
    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(PhotoLibraryError.videoUnsupported))
    }
    func saveLivePhoto(stillImage: Data, movieURL: URL, location: PhotoLocation?, creationDate: Date?, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(PhotoLibraryError.videoUnsupported))
    }
}

enum PhotoLibraryError: LocalizedError {
    case batchDeletionUnsupported, videoUnsupported, writeDenied, readDenied, inaccessible, missingIdentifier, busy

    /// PhotoKit uses this error when the user declines its system deletion confirmation.
    /// Apple defines PHPhotosErrorUserCancelled as 3072 in PHError.h.
    static func isUserCancelled(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == "PHPhotosErrorDomain" && value.code == 3072
    }

    var errorDescription: String? {
        switch self {
        case .batchDeletionUnsupported: return "当前相册服务不支持批量删除。"
        case .videoUnsupported: return "当前相册服务不支持保存视频。"
        case .writeDenied: return "未获得相册写入权限。可在系统设置中允许，或使用分享导出照片。"
        case .readDenied: return "删除已保存的照片需要相册访问权限。请在系统设置中允许访问，或在系统相册中删除。"
        case .inaccessible: return "当前权限无法访问这张照片。请允许访问这张照片后重试，或在系统相册中删除。"
        case .missingIdentifier: return "无法定位这张已保存的照片，请在系统相册中删除。"
        case .busy: return "相册正在处理其他操作，请稍后再试。"
        }
    }
}
