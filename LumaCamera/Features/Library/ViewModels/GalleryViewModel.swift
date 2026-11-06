import Combine
import UIKit

@MainActor
final class GalleryViewModel: ObservableObject {
    @Published private(set) var photos: [LibraryPhoto] = []
    let unavailablePhotos = PassthroughSubject<Set<String>, Never>()
    @Published private(set) var latestThumbnail: UIImage?
    private var thumbnailResolved = false
    private var synchronizedCaptureID: String?
    private var thumbnailGeneration = UUID()
    private var thumbnailRequest: PhotoImageRequest?

    var albumButtonImage: UIImage? {
        if let capture = library.lastPhoto {
            if !library.photoSaved { return capture }
            if let id = library.savedPhotoID, synchronizedCaptureID != id { return capture }
        }
        return latestThumbnail ?? (thumbnailResolved ? nil : library.lastPhoto)
    }
    @Published private(set) var access: PhotoLibraryAccess?
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private(set) var deletingID: String?
    @Published private(set) var selecting = false
    @Published private(set) var selectedIDs = Set<String>()
    private var loadWaiters: [() -> Void] = []
    func endSelection() { selecting = false; selectedIDs = [] }
    func beginSelection() { guard !library.isBusy, !library.captureInProgress else { return }; selecting = true }
    func toggleSelection(_ id: String) {
        guard selecting, !library.isBusy else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    func selectAll(_ ids: [String]) {
        guard selecting, !library.isBusy else { return }
        let visible = Set(ids)
        if selectedIDs == visible { selectedIDs = [] } else { selectedIDs = visible }
    }
    func deleteSelected() {
        guard selecting, !selectedIDs.isEmpty, deletingID == nil, !library.isBusy, !library.captureInProgress else { return }
        let ids = selectedIDs
        deletingID = "batch"
        library.deleteSystemPhotos(ids: Array(ids)) { [weak self] result in
            guard let self else { return }
            self.deletingID = nil
            switch result {
            case .success:
                self.photos.removeAll { ids.contains($0.id) }
                self.endSelection(); self.refreshThumbnail()
            case .failure(let error):
                if !PhotoLibraryError.isUserCancelled(error) {
                    self.message = "未完成删除：\(error.localizedDescription)"
                }
            }
        }
    }
    private func finishLoading() {
        loading = false
        selectedIDs.formIntersection(Set(photos.map(\.id)).union(library.savedPhotoID.map { [$0] } ?? []))
        let callbacks = loadWaiters; loadWaiters = []
        callbacks.forEach { $0() }
    }
    @Published var message: String?

    let browser: PhotoBrowserService
    let library: PhotoLibraryViewModel
    private var generation = UUID()
    private let pageSize = 60
    private var subscriptions = Set<AnyCancellable>()
    private var savedRefreshTask: Task<Void, Never>?
    private var awaitingSavedIDs = Set<String>()

    init(browser: PhotoBrowserService, library: PhotoLibraryViewModel) {
        self.browser = browser
        self.library = library
        browser.onLibraryChange = { [weak self] in self?.refresh(); self?.refreshThumbnail() }
        library.didSavePhoto.sink { [weak self] assetID in
            // Save completion is authoritative even if the Photos observer notification
            // was missed. Defer until the save transaction has published all state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let granted = self.browser.existingAccess ?? self.access
                guard let granted, granted != .denied else { return }
                self.awaitingSavedIDs.insert(assetID)
                self.refresh()
                self.refreshThumbnail()
                self.retryUnindexedSaves()
            }
        }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    deinit { thumbnailRequest?.cancel(); savedRefreshTask?.cancel() }

    /// Photos commit and broad-query indexing can arrive at different times. Retry only
    /// while committed IDs remain absent; coalesce burst saves and never fabricate rows.
    private func retryUnindexedSaves() {
        savedRefreshTask?.cancel()
        savedRefreshTask = Task { [weak self] in
            for delay in [0.2, 0.6, 1.2] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                self.awaitingSavedIDs.subtract(self.photos.map(\.id))
                guard !self.awaitingSavedIDs.isEmpty else { return }
                guard let access = self.browser.existingAccess ?? self.access, access != .denied else { return }
                self.refresh()
            }
            self?.awaitingSavedIDs.removeAll()
        }
    }

    /// Only a single small image is requested; opening the camera never prompts for Photos access.
    func refreshThumbnail() {
        let generation = UUID()
        thumbnailGeneration = generation
        thumbnailRequest?.cancel(); thumbnailRequest = nil
        guard let access = browser.existingAccess, access != .denied else {
            latestThumbnail = nil; thumbnailResolved = false
            return
        }
        reconcileSavedCapture()
        // Existing access is already granted; this registers the Photos change observer without a prompt.
        browser.authorize { [weak self] access in
            guard let self, self.thumbnailGeneration == generation else { return }
            guard access != .denied else {
                self.latestThumbnail = nil; self.thumbnailResolved = false
                return
            }
            self.browser.fetchPhotos(offset: 0, limit: 1) { [weak self] page in
                guard let self, self.thumbnailGeneration == generation else { return }
                self.thumbnailResolved = true
                guard let photo = page.photos.first else { self.latestThumbnail = nil; return }
                self.thumbnailRequest = self.browser.requestImage(id: photo.id, size: CGSize(width: 160, height: 160)) { [weak self] image, _ in
                    guard let self, self.thumbnailGeneration == generation else { return }
                    if let image {
                        self.latestThumbnail = image
                        self.library.releaseSavedCaptureCacheIfAccessible()
                        if let savedID = self.library.savedPhotoID {
                            let isNewer = photo.date.map { date in self.library.lastPhotoDate.map { date >= $0 } ?? false } ?? false
                            if photo.id == savedID || isNewer {
                                self.synchronizedCaptureID = savedID
                            }
                        }
                    }
                }
            }
        }
    }

    /// External camera/import changes may happen while our scene is suspended.
    /// Requery an opened library on foreground entry without prompting from the camera screen.
    func refreshAfterForeground() {
        refreshThumbnail()
        if let granted = browser.existingAccess, granted != .denied { refresh() }
        else if access != nil { refresh() }
    }

    func refresh() {
        let request = UUID()
        generation = request
        loading = true
        var missing = Set<String>()
        let previousIDs = Set(photos.map(\.id))
        if !previousIDs.isEmpty {
            browser.availablePhotoIDs(Array(previousIDs)) { [weak self] available in
                guard let self, self.generation == request, let available else { return }
                missing = previousIDs.subtracting(available)
                if !missing.isEmpty {
                    self.unavailablePhotos.send(missing)
                    self.photos.removeAll { missing.contains($0.id) }
                    self.selectedIDs.subtract(missing)
                    if let id = self.library.savedPhotoID, missing.contains(id) { self.removeIfConfirmedMissing(id: id) }
                }
            }
        }
        browser.authorize { [weak self] access in
            guard let self, self.generation == request else { return }
            self.access = access
            guard access != .denied else {
                self.photos = []; self.hasMore = false; self.finishLoading()
                return
            }
            self.browser.fetchPhotos(offset: 0, limit: max(self.pageSize, self.photos.count)) { [weak self] page in
                guard let self, self.generation == request else { return }
                let visible = page.photos.filter { !missing.contains($0.id) }
                if self.photos != visible { self.photos = visible }
                self.hasMore = page.hasMore
                self.finishLoading()
                self.reconcileSavedCapture()
            }
        }
    }

    private func reconcileSavedCapture() {
        guard library.photoSaved, let id = library.savedPhotoID else { return }
        removeIfConfirmedMissing(id: id)
    }
    func removeIfConfirmedMissing(id: String) {
        let token = generation
        browser.photoAvailability(id: id) { [weak self] availability in
            guard let self, self.generation == token, availability == .missing else { return }
            self.unavailablePhotos.send([id])
            self.photos.removeAll { $0.id == id }
            self.selectedIDs.remove(id)
            if self.library.savedPhotoID == id {
                self.latestThumbnail = nil; self.thumbnailResolved = true; self.synchronizedCaptureID = nil
            }
            self.library.clearExternallyDeletedPhoto(assetID: id)
            self.refreshThumbnail()
        }
    }

    func loadMore(completion: (() -> Void)? = nil) {
        if let completion { loadWaiters.append(completion) }
        guard !loading else { return }
        guard hasMore else { finishLoading(); return }
        loading = true
        let request = generation
        let offset = photos.count
        browser.fetchPhotos(offset: offset, limit: pageSize) { [weak self] page in
            guard let self, self.generation == request else { return }
            let existing = Set(self.photos.map(\.id))
            self.photos.append(contentsOf: page.photos.filter { !existing.contains($0.id) })
            self.hasMore = page.hasMore
            self.finishLoading()
        }
    }

    func delete(_ photo: LibraryPhoto, completion: @escaping (Bool) -> Void) {
        guard deletingID == nil, !library.isBusy, !library.captureInProgress else { return }
        deletingID = photo.id
        library.deleteSystemPhoto(id: photo.id) { [weak self] result in
            guard let self else { return }
            self.deletingID = nil
            switch result {
            case .success:
                self.photos.removeAll { $0.id == photo.id }
                self.refreshThumbnail()
                completion(true)
            case .failure(let error):
                if !PhotoLibraryError.isUserCancelled(error) {
                    self.message = "未完成删除：\(error.localizedDescription)"
                }
                completion(false)
            }
        }
    }
}
