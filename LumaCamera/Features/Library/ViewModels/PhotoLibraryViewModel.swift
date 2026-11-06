import Combine
import UIKit

/// Current capture only; system Photos access is isolated behind PhotoLibraryService.
@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    @Published private(set) var lastPhoto: UIImage?
    @Published private(set) var lastPhotoDate: Date?
    /// Session-only: each new capture may open automatically once.
    @Published private(set) var captureAwaitingReview = false
    /// A saved video can open once after recording; this in-memory token is consumed by the gallery entry.
    @Published private(set) var videoAwaitingReviewID: String?
    func consumeCaptureReview() -> Bool {
        guard captureAwaitingReview, lastPhoto != nil else { return false }
        captureAwaitingReview = false
        return true
    }
    func consumeVideoReview() -> String? {
        defer { videoAwaitingReviewID = nil }
        return videoAwaitingReviewID
    }
    @Published private(set) var saving = false
    @Published private(set) var deleting = false
    @Published private(set) var editing = false
    /// Every committed save, including burst jobs older than the current capture.
    let didSavePhoto = PassthroughSubject<String, Never>()
    @Published private(set) var photoSaved = false
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var videoSaving = false
    @Published private(set) var failedVideos: [URL] = []
    private var pendingVideoBadges: [URL: VideoCaptureBadges] = [:]
    private var pendingVideoReviewFlags: [URL: Bool] = [:]
    @Published private(set) var failedSaveCount = 0
    private struct SaveJob {
        let id: UUID
        let image: UIImage
        let photo: CapturedPhoto?
        let showSuccess: Bool
        var bytes: Int { ((photo?.resources.reduce(0) { $0 + $1.data.count } ?? 0) + (photo?.unfilteredOriginal?.data.count ?? 0)) + (image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
    }
    private var saveQueue: [SaveJob] = []
    private var activeSave: SaveJob?
    private var failedSaves: [SaveJob] = []
    var canAcceptNewCapture: Bool {
        !deleting && !editing && pendingSaveCount + failedSaveCount < 4 &&
        (saveQueue + failedSaves + (activeSave.map { [$0] } ?? [])).reduce(0, { $0 + $1.bytes }) < 128 * 1024 * 1024
    }
    @Published var captureInProgress = false
    @Published var message: String?

    var isBusy: Bool { saving || videoSaving || deleting || editing }
    var savedPhotoID: String? { savedAssetID }
    private let service: PhotoLibraryService
    private var editedFilterApplied: Bool?
    private var savedRAW = false
    private var savedLive = false
    private var savedInfoRows: [PhotoInfoRow]?
    /// Full-resolution encoded resources belong to Photos after a successful save.
    var hasReleasedCaptureResources: Bool { photoSaved && capturedPhoto?.resources.isEmpty != false }
    private var capturedPhoto: CapturedPhoto?
    private var photoID = UUID()
    private var savedAssetID: String?

    init(service: PhotoLibraryService) { self.service = service }

    #if DEBUG
    /// 仅诊断只读相册：下一用例不继承上一用例临时保存失败。正式用户照片仍保留重试队列。
    func resetDiagnosticStateForTesting() {
        guard service is DiagnosticReadOnlyPhotoService else { return }
        saveQueue.removeAll(); failedSaves.removeAll(); activeSave = nil
        failedVideos.removeAll(); pendingVideoBadges.removeAll(); pendingVideoReviewFlags.removeAll()
        videoSaving = false; captureInProgress = false; deleting = false; editing = false
        updateSaveCounts(); setCurrentPhoto(nil)
    }
    #endif

    func saveVideo(at url: URL, badges: VideoCaptureBadges? = nil, opensReview: Bool = true,
                   completion: ((Result<String, Error>) -> Void)? = nil) {
        guard !videoSaving else { completion?(.failure(PhotoLibraryError.busy)); return }
        if let badges { pendingVideoBadges[url] = badges }
        pendingVideoReviewFlags[url] = opensReview
        videoSaving = true
        service.saveVideo(at: url) { [weak self] result in
            guard let self else { return }
            self.videoSaving = false
            switch result {
            case .success(let id):
                try? FileManager.default.removeItem(at: url)
                self.failedVideos.removeAll { $0 == url }
                if let badges = self.pendingVideoBadges.removeValue(forKey: url) { VideoCaptureBadgeStore.shared.save(badges, assetID: id) }
                self.pendingVideoReviewFlags.removeValue(forKey: url)
                if opensReview {
                    self.captureAwaitingReview = false
                    self.videoAwaitingReviewID = id
                }
                self.didSavePhoto.send(id)
                completion?(.success(id))
            case .failure(let error):
                if !self.failedVideos.contains(url) { self.failedVideos.append(url) }
                self.message = "视频保存失败：\(error.localizedDescription)"
                completion?(.failure(error))
            }
        }
    }

    func saveLivePhoto(stillImage: Data, movieURL: URL, location: PhotoLocation?, creationDate: Date?, completion: @escaping (Result<String, Error>) -> Void) {
        guard !videoSaving else { completion(.failure(PhotoLibraryError.busy)); return }
        videoSaving = true
        service.saveLivePhoto(stillImage: stillImage, movieURL: movieURL, location: location, creationDate: creationDate) { [weak self] result in
            guard let self else { return }
            self.videoSaving = false
            if case .success(let id) = result { self.didSavePhoto.send(id) }
            completion(result)
        }
    }

    func retryFailedVideo() {
        guard !videoSaving, let url = failedVideos.first else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            saveVideo(at: url, badges: pendingVideoBadges[url], opensReview: pendingVideoReviewFlags[url] ?? true)
        }
        else {
            failedVideos.removeFirst()
            message = "上次未保存的视频文件已不可用。"
        }
    }

    func acceptPhoto(_ image: UIImage?) {
        guard !isBusy else { return }
        setCurrentPhoto(image)
    }

    private func setCurrentPhoto(_ image: UIImage?) {
        videoAwaitingReviewID = nil
        photoID = UUID()
        savedAssetID = nil
        photoSaved = false
        lastPhoto = image
        captureAwaitingReview = image != nil
        lastPhotoDate = image == nil ? nil : Date()
        message = nil
        capturedPhoto = nil
        editedFilterApplied = nil
        savedRAW = false; savedLive = false; savedInfoRows = nil
    }

    func acceptCapture(_ photo: CapturedPhoto?, automaticallySave: Bool = false) {
        guard !deleting, !editing else { return }
        setCurrentPhoto(photo?.preview)
        capturedPhoto = photo
        if let date = photo?.diagnostics?.parameters?.capturedAt { lastPhotoDate = date }
        if automaticallySave, photo != nil { enqueueCurrentPhoto(showSuccessMessage: false) }
        if !failedSaves.isEmpty { message = "有 \(failedSaves.count) 张照片未保存，可重试保存。" }
    }
    var hasFilterResource: Bool { editedFilterApplied ?? (captureParameters?.filterID.map { $0 != FilmStyle.original.rawValue && (captureParameters?.filterIntensity ?? 0) > 0 } ?? false) }
    var hasLiveResource: Bool { savedLive || shareResources.contains(where: \.pairedVideo) }
    var hasRAWResource: Bool { savedRAW || shareResources.contains { PhotoResourceKind.isRAW(typeIdentifier: nil, filename: $0.filename) } }
    var shareResources: [PhotoResource] { capturedPhoto?.resources ?? [] }
    var captureLocation: PhotoLocation? { capturedPhoto?.location ?? captureParameters?.location }
    var hasNightCompositeResource: Bool { capturedPhoto?.diagnostics?.isNightComposite ?? false }
    var captureParameters: PhotoCaptureParameters? { capturedPhoto?.diagnostics?.currentParameters }
    var captureInfoRows: [PhotoInfoRow] {
        savedInfoRows ?? PhotoCaptureDiagnostics.merged(PhotoCaptureDiagnostics.resourceRows(shareResources), with: capturedPhoto?.diagnostics?.detailRows ?? [])
    }

    func savePhoto(showSuccessMessage: Bool = true) {
        guard !isBusy, !captureInProgress else { return }
        if !failedSaves.isEmpty { retryFailedSaves() }
        if !photoSaved { enqueueCurrentPhoto(showSuccessMessage: showSuccessMessage) }
    }

    private func enqueueCurrentPhoto(showSuccessMessage: Bool) {
        guard let image = lastPhoto, !photoSaved,
              activeSave?.id != photoID, !saveQueue.contains(where: { $0.id == photoID }),
              !failedSaves.contains(where: { $0.id == photoID }) else { return }
        message = nil
        saveQueue.append(SaveJob(id: photoID, image: image, photo: capturedPhoto, showSuccess: showSuccessMessage))
        updateSaveCounts()
        startNextSave()
    }

    func retryFailedSaves() {
        guard !deleting, !editing, !failedSaves.isEmpty else { return }
        message = nil
        saveQueue.append(contentsOf: failedSaves)
        failedSaves.removeAll()
        updateSaveCounts()
        startNextSave()
    }

    private func updateSaveCounts() {
        pendingSaveCount = saveQueue.count + (activeSave == nil ? 0 : 1)
        failedSaveCount = failedSaves.count
        saving = pendingSaveCount > 0
    }

    private func startNextSave() {
        guard activeSave == nil, !saveQueue.isEmpty else { updateSaveCounts(); return }
        let job = saveQueue.removeFirst()
        activeSave = job
        updateSaveCounts()
        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self, self.activeSave?.id == job.id else { return }
            self.activeSave = nil
            switch result {
            case .success(let assetID):
                if self.photoID == job.id {
                    // Publish the identity before the saved flag, so thumbnail readers cannot
                    // briefly select a previous asset when automatic saving completes.
                    self.savedAssetID = assetID
                    if self.service.canReloadSavedPhoto(id: assetID) { self.releaseSavedCaptureResources() }
                    self.photoSaved = true
                    if job.showSuccess { self.message = "照片已保存到系统相册。" }
                }
                self.didSavePhoto.send(assetID)
            case .failure(let error):
                self.failedSaves.append(job)
                self.message = "保存失败：\(error.localizedDescription)；\(self.failedSaves.count) 张照片未保存，可重试保存。"
            }
            self.updateSaveCounts()
            self.startNextSave()
        }
        if let photo = job.photo { service.saveCapture(photo, completion: completion) }
        else { service.save(job.image, completion: completion) }
    }

    func releaseSavedCaptureCacheIfAccessible() {
        guard photoSaved, !hasReleasedCaptureResources, let id = savedAssetID, service.canReloadSavedPhoto(id: id) else { return }
        releaseSavedCaptureResources()
    }

    private func releaseSavedCaptureResources() {
        savedRAW = hasRAWResource
        savedLive = hasLiveResource
        savedInfoRows = captureInfoRows
        guard let image = lastPhoto else { return }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let thumbnail: UIImage
        if longest > 240 {
            let scale = 240 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        } else { thumbnail = image }
        capturedPhoto = CapturedPhoto(preview: thumbnail, resources: [], diagnostics: capturedPhoto?.diagnostics, location: capturedPhoto?.location)
        lastPhoto = thumbnail
    }

    func beginEditing() -> Bool {
        guard !isBusy, !captureInProgress else { return false }
        editing = true
        return true
    }
    func endEditing() { editing = false }
    func updateSavedPreview(assetID: String, result: PhotoEditResult) {
        guard savedAssetID == assetID else { return }
        editedFilterApplied = result.filterApplied
        lastPhoto = result.preview
        capturedPhoto = CapturedPhoto(preview: result.preview, resources: [result.resource], diagnostics: PhotoCaptureDiagnosticsStore.shared.load(assetID: assetID) ?? capturedPhoto?.diagnostics, location: capturedPhoto?.location)
        savedInfoRows = nil
        if service.canReloadSavedPhoto(id: assetID) { releaseSavedCaptureResources() }
    }
    func replaceUnsavedPhoto(_ result: PhotoEditResult) {
        guard !photoSaved, !isBusy, !captureInProgress else { return }
        let rawResources = shareResources.filter { $0.filename.lowercased().hasSuffix(".dng") }
            .map { PhotoResource(data: $0.data, filename: $0.filename, alternate: true) }
        let diagnostics = capturedPhoto?.diagnostics
        let captureDate = lastPhotoDate
        let awaitingReview = captureAwaitingReview
        acceptCapture(CapturedPhoto(preview: result.preview, resources: [result.resource] + rawResources, diagnostics: diagnostics, location: capturedPhoto?.location))
        editedFilterApplied = result.filterApplied
        lastPhotoDate = captureDate
        captureAwaitingReview = awaitingReview
    }

    func deletePhoto(completion: ((Bool) -> Void)? = nil) {
        guard lastPhoto != nil, !isBusy, !captureInProgress else { completion?(false); return }
        let id = photoID
        if !photoSaved { clearPhoto(expectedID: id); completion?(true); return }
        guard let assetID = savedAssetID else {
            message = PhotoLibraryError.missingIdentifier.localizedDescription; completion?(false); return
        }
        deleting = true
        service.delete(assetID: assetID) { [weak self] result in
            guard let self else { return }
            self.deleting = false
            guard self.photoID == id else { completion?(false); return }
            switch result {
            case .success: self.clearPhoto(expectedID: id); completion?(true)
            case .failure(let error):
                if !PhotoLibraryError.isUserCancelled(error) {
                    self.message = "未完成删除：\(error.localizedDescription)"
                }
                completion?(false)
            }
        }
    }

    /// Deletes any selected system photo while retaining the current capture on failure.
    func deleteSystemPhoto(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        deleteSystemPhotos(ids: [id], completion: completion)
    }

    func deleteSystemPhotos(ids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isBusy, !captureInProgress else { return }
        let ids = Set(ids)
        guard !ids.isEmpty else { completion(.success(())); return }
        deleting = true
        service.delete(assetIDs: Array(ids)) { [weak self] result in
            guard let self else { return }
            self.deleting = false
            if case .success = result, let savedID = self.savedAssetID, ids.contains(savedID) {
                self.clearPhoto(expectedID: self.photoID)
            }
            completion(result)
        }
    }

    func clearExternallyDeletedPhoto(assetID: String) {
        guard photoSaved, savedAssetID == assetID else { return }
        clearPhoto(expectedID: photoID)
    }

    private func clearPhoto(expectedID: UUID) {
        guard photoID == expectedID else { return }
        failedSaves.removeAll { $0.id == expectedID }
        updateSaveCounts()
        savedAssetID = nil
        photoSaved = false
        lastPhoto = nil
        captureAwaitingReview = false
        videoAwaitingReviewID = nil
        lastPhotoDate = nil
        capturedPhoto = nil
        editedFilterApplied = nil
        savedRAW = false; savedLive = false; savedInfoRows = nil
        photoID = UUID()
    }
}
