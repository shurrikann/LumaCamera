import Combine
import UIKit

@MainActor
final class PhotoDetailViewModel: ObservableObject {
    @Published private(set) var hasFilter: Bool
    @Published private(set) var image: UIImage?
    @Published private(set) var loading = false
    @Published private(set) var preparingShare = false
    @Published private(set) var preparingEdit = false
    @Published private(set) var details: PhotoDetails?
    @Published private(set) var detailsLoading = false
    @Published private(set) var resources: [PhotoResource] = []
    @Published var message: String?
    let photo: LibraryPhoto
    let gallery: GalleryViewModel
    private var imageRequest: PhotoImageRequest?
    private var requests: [PhotoImageRequest] = []
    private var generation = UUID()
    var busy: Bool { preparingShare || preparingEdit || gallery.library.isBusy }
    init(photo: LibraryPhoto, gallery: GalleryViewModel, initialImage: UIImage? = nil) { self.photo = photo; self.hasFilter = photo.hasFilter; self.gallery = gallery; self.image = initialImage }
    func load() {
        imageRequest?.cancel(); requests.forEach { $0.cancel() }; requests = []
        let token = UUID(); generation = token; loading = true
        preparingShare = false; preparingEdit = false; detailsLoading = false
        imageRequest = gallery.browser.requestImage(id: photo.id, size: CGSize(width: 2400, height: 2400)) { [weak self] image, error in
            guard let self, self.generation == token else { return }
            if let image { self.image = image; self.loading = false }
            else if let error { self.loading = false; self.message = error.localizedDescription }
            else { self.loading = false }
        }
    }
    func loadDetails() {
        guard !detailsLoading else { return }
        guard let service = gallery.browser as? PhotoDetailService else { message = PhotoDetailError.unavailable.localizedDescription; return }
        details = nil; detailsLoading = true
        let token = generation
        requests.append(service.details(id: photo.id) { [weak self] result in
            guard let self, self.generation == token else { return }; self.detailsLoading = false
            switch result { case .success(let details): self.details = details; case .failure(let error): self.message = error.localizedDescription }
        })
    }
    func prepareShare(completion: @escaping (Bool) -> Void) {
        guard !busy, let service = gallery.browser as? PhotoDetailService else { return }
        preparingShare = true
        let token = generation
        requests.append(service.shareResources(id: photo.id) { [weak self] result in
            guard let self, self.generation == token else { return }; self.preparingShare = false
            switch result {
            case .success(let resources): self.resources = resources; completion(true)
            case .failure(let error): self.message = error.localizedDescription; completion(false)
            }
        })
    }
    func prepareEditor(completion: @escaping (PhotoEditSession) -> Void) {
        guard !busy, let service = gallery.browser as? PhotoDetailService else { return }
        preparingEdit = true
        let token = generation
        requests.append(service.openEditor(id: photo.id) { [weak self] result in
            guard let self, self.generation == token else { return }; self.preparingEdit = false
            switch result { case .success(let session): completion(session); case .failure(let error): self.message = error.localizedDescription }
        })
    }
    func edited(_ result: PhotoEditResult) {
        if result.copiedAssetID != nil { gallery.refresh(); return }
        hasFilter = result.filterApplied ?? hasFilter
        image = result.preview
        details = nil
        gallery.library.updateSavedPreview(assetID: photo.id, result: result)
        gallery.refresh()
        load()
    }
    func cancelLoading() {
        generation = UUID(); imageRequest?.cancel(); requests.forEach { $0.cancel() }; requests = []
    }
}
