import SwiftUI
import Photos
import PhotosUI

struct LivePhotoPlaybackSource {
    var assetID: String?
    var resources: [PhotoResource] = []
}

@MainActor final class LivePhotoPlayback: ObservableObject {
    @Published private(set) var photo: PHLivePhoto?
    @Published private(set) var holding = false
    @Published private(set) var loading = false
    private var generation = UUID()
    private var cancelRequest: (() -> Void)?
    private var staged: PhotoLibraryStagedResources?
    private var stagingTask: Task<Void, Never>?

    func press(_ pressed: Bool, source: LivePhotoPlaybackSource, size: CGSize) {
        holding = pressed
        guard pressed else { cancelLoading(); return }
        guard photo == nil, !loading else { return }
        loading = true
        let token = UUID(); generation = token
        let target = CGSize(width: min(1200, max(1, size.width * 2)), height: min(1600, max(1, size.height * 2)))
        if let id = source.assetID, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
            let request = PHImageManager.default().requestLivePhoto(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] photo, info in
                Task { @MainActor in self?.received(photo, info: info ?? [:], token: token) }
            }
            cancelRequest = { PHImageManager.default().cancelImageRequest(request) }
        } else if source.resources.contains(where: \.pairedVideo) {
            stagingTask = Task { [weak self] in
                do {
                    let files = try await Task.detached(priority: .userInitiated) { try PhotoLibraryStagedResources(source.resources) }.value
                    guard let self, self.generation == token, self.holding, !Task.isCancelled else { files.cleanup(); return }
                    self.staged = files
                    let request = PHLivePhoto.request(withResourceFileURLs: files.entries.map(\.url), placeholderImage: nil, targetSize: target, contentMode: .aspectFit) { [weak self] photo, info in
                        Task { @MainActor in self?.received(photo, info: info, token: token) }
                    }
                    self.cancelRequest = { PHLivePhoto.cancelRequest(withRequestID: request) }
                } catch { self?.received(nil, info: [:], token: token) }
            }
        } else { loading = false }
    }
    private func received(_ result: PHLivePhoto?, info: [AnyHashable: Any], token: UUID) {
        guard generation == token, holding else { return }
        if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true || (info[PHImageResultIsDegradedKey] as? Bool) == true { return }
        photo = result; loading = false
        cancelRequest = nil
        // PHLivePhoto can lazily read its movie during playback; retain local files with the cached photo.
    }
    private func cancelLoading() {
        generation = UUID(); loading = false
        stagingTask?.cancel(); stagingTask = nil
        cancelRequest?(); cancelRequest = nil
        if photo == nil { staged = nil }
    }
    func cancel() { holding = false; cancelLoading(); photo = nil; staged = nil }
    deinit { stagingTask?.cancel(); cancelRequest?() }
}

/// Full playback starts after UIKit attaches the video view to a window. Starting
/// inside makeUIView can run before its rendering surface exists and leave only the still transition.
final class HoldLivePhotoView: PHLivePhotoView, PHLivePhotoViewDelegate {
    private(set) var wantsPlayback = false
    private(set) var fullPlaybackBeginCount = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = .clear; contentMode = .scaleAspectFit; isMuted = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func playWhenAttached() {
        wantsPlayback = true
        if window != nil, livePhoto != nil { startPlayback(with: .full) }
    }
    func endHold() { wantsPlayback = false; stopPlayback() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsPlayback, livePhoto != nil { startPlayback(with: .full) }
        else if window == nil { stopPlayback() }
    }
    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        if playbackStyle == .full { fullPlaybackBeginCount += 1 }
    }
}

struct LivePhotoPlaybackView: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> HoldLivePhotoView {
        let view = HoldLivePhotoView()
        view.livePhoto = photo; view.playWhenAttached()
        return view
    }
    func updateUIView(_ view: HoldLivePhotoView, context: Context) {
        if view.livePhoto !== photo { view.livePhoto = photo; view.playWhenAttached() }
    }
    static func dismantleUIView(_ view: HoldLivePhotoView, coordinator: ()) { view.endHold(); view.livePhoto = nil }
}
