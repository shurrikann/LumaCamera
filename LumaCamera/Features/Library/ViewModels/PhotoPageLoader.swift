import Combine
import UIKit

/// Load the destination before replacing the visible page; stale callbacks cannot turn it.
@MainActor
final class PhotoPageLoader: ObservableObject {
    @Published private(set) var loading = false
    @Published var message: String?
    private var request: PhotoImageRequest?
    private var generation = UUID()
    private let browser: PhotoBrowserService
    init(browser: PhotoBrowserService) { self.browser = browser }
    func prepare(_ route: GalleryRoute, capture: UIImage?, onFailure: (() -> Void)? = nil, completion: @escaping (UIImage) -> Void) {
        cancel()
        loading = true; message = nil
        let token = generation
        let received: (UIImage?, Error?) -> Void = { [weak self] image, error in
            // Browser services may return synchronously or deliver more than one quality level.
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.loading else { return }
                self.loading = false
                if let image { completion(image) }
                else { self.message = error?.localizedDescription ?? "无法载入照片，请重试。"; onFailure?() }
            }
        }
        switch route {
        case .capture: received(capture, nil)
        case .asset(let photo): request = browser.requestImage(id: photo.id, size: CGSize(width: 2400, height: 2400), completion: received)
        }
    }
    func cancel() { generation = UUID(); request?.cancel(); request = nil; loading = false }
}
