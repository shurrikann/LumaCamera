import UIKit

struct LibraryPhoto: Identifiable, Hashable {
    let id: String
    let date: Date?
    var isRAW = false
    var location: PhotoLocation? = nil
    var isLive = false
    var isNightComposite = false
    var hasFilter = false
    var isVideo = false
    var duration: TimeInterval? = nil
    var logLabel: String? = nil
    var videoBadges: VideoCaptureBadges? = nil
}

enum PhotoAssetAvailability { case available, missing, unknown }

enum PhotoLibraryAccess { case full, limited, denied }
struct PhotoPage {
    let photos: [LibraryPhoto]
    let hasMore: Bool
}

final class PhotoImageRequest {
    private let cancellation: () -> Void
    private let lock = NSLock()
    private var cancelled = false
    init(cancel: @escaping () -> Void) { cancellation = cancel }
    func cancel() {
        lock.lock()
        let shouldCancel = !cancelled
        cancelled = true
        lock.unlock()
        if shouldCancel { cancellation() }
    }
}

/// Metadata is paginated; images are requested only for visible thumbnails or an opened photo.
/// All completion and change callbacks are delivered on the main queue.
protocol PhotoBrowserService: AnyObject {
    var onLibraryChange: (() -> Void)? { get set }
    /// Read current permission without presenting an authorization prompt.
    var existingAccess: PhotoLibraryAccess? { get }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void)
    func availablePhotoIDs(_ ids: [String], completion: @escaping (Set<String>?) -> Void)
    func photoAvailability(id: String, completion: @escaping (PhotoAssetAvailability) -> Void)
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void)
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest
}

extension PhotoBrowserService {
    func availablePhotoIDs(_ ids: [String], completion: @escaping (Set<String>?) -> Void) { completion(nil) }
    var existingAccess: PhotoLibraryAccess? { nil }
    func photoAvailability(id: String, completion: @escaping (PhotoAssetAvailability) -> Void) { completion(.unknown) }
}
