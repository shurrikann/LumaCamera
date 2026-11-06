import SwiftUI

/// Page state changes immediately; only its photo viewport receives the animation.
struct PhotoPagingView: View {
    @ObservedObject var model: GalleryViewModel
    @ObservedObject var library: PhotoLibraryViewModel
    @StateObject private var loader: PhotoPageLoader
    @State private var selected: GalleryRoute
    @State private var seed: UIImage?
    @State private var displayedImage: UIImage?
    @State private var motion: PhotoPageAnimation?
    @State private var transitioning = false
    @State private var deletionNavigation = PhotoDeletionNavigation()
    @State private var captureAssetID: String?
    @State private var deletionFallback: GalleryRoute?
    @State private var deletionBoundaryID: String?
    @State private var deletionWasRAW = false
    @State private var deletionWasLive = false
    @State private var deletionWasNight = false
    @State private var deletionHadFilter = false
    @State private var handledUnavailableID: String?
    @State private var deferredUnavailableIDs = Set<String>()
    @Environment(\.dismiss) private var dismiss
    let photos: [LibraryPhoto]
    let isDemo: Bool
    let canLoadMore: Bool
    let onCamera: () -> Void
    init(model: GalleryViewModel, library: PhotoLibraryViewModel, initial: GalleryRoute, photos: [LibraryPhoto], isDemo: Bool, canLoadMore: Bool, onCamera: @escaping () -> Void) {
        self.model = model; self.library = library; self.photos = photos
        self.isDemo = isDemo; self.canLoadMore = canLoadMore; self.onCamera = onCamera
        _captureAssetID = State(initialValue: library.savedPhotoID)
        _selected = State(initialValue: initial)
        _loader = StateObject(wrappedValue: PhotoPageLoader(browser: model.browser))
    }
    var body: some View {
        page(selected)
            .id(selected)
            .allowsHitTesting(!transitioning)
            .background(AppTheme.popupColor.ignoresSafeArea())
            .onDisappear { loader.cancel() }
            .onReceive(model.unavailablePhotos) { ids in
                if library.editing { deferredUnavailableIDs.formUnion(ids) }
                else { handleUnavailablePhotos(ids) }
            }
            .onChange(of: library.savedPhotoID) { _, id in
                if selected == .capture, let id { captureAssetID = id }
            }
            .onChange(of: library.editing) { _, editing in
                if !editing, !deferredUnavailableIDs.isEmpty {
                    let ids = deferredUnavailableIDs; deferredUnavailableIDs = []
                    handleUnavailablePhotos(ids)
                }
            }
            .alert("光屿相机", isPresented: Binding(get: { loader.message != nil }, set: { if !$0 { loader.message = nil } })) {
                Button("好", role: .cancel) { loader.message = nil }
            } message: { Text(loader.message ?? "") }
    }
    @ViewBuilder private func page(_ route: GalleryRoute) -> some View {
        let displayed: (UIImage?) -> Void = { image in if selected == route, let image { displayedImage = image } }
        let finished: () -> Void = { if selected == route { transitioning = false; motion = nil } }
        switch route {
        case .asset(let photo):
            if photo.isVideo {
                SystemVideoView(model: model, photo: photo, onCamera: onCamera,
                                onSwipeWithSnapshot: { step, image in move(step, outgoing: image) }, pageMotion: motion,
                                onPageFinished: finished, onDeletePrepared: prepareDeletion,
                                onDeleted: { deletedPhoto(from: route) })
            } else {
            SystemPhotoView(model: model, photo: photo, initialImage: seed, pagingBusy: loader.loading, onCamera: onCamera, onSwipe: { step in move(step) },
                            pageMotion: motion, onPageFinished: finished, onImageDisplayed: displayed,
                            onDeletePrepared: prepareDeletion, onDeleted: { deletedPhoto(from: route) })
            }
        case .capture:
            PhotoReview(model: library, isDemo: isDemo, browser: model.browser, onCamera: onCamera, onSwipe: { step in move(step) }, pagingBusy: loader.loading,
                        pageMotion: motion, onPageFinished: finished, onImageDisplayed: displayed,
                            onDeletePrepared: prepareDeletion, onDeleted: { deletedPhoto(from: route) })
        }
    }
    private func handleUnavailablePhotos(_ ids: Set<String>) {
        guard !library.deleting, deletionNavigation.token == nil else { return } // Local deletion already owns navigation.
        let id: String?
        switch selected { case .asset(let photo): id = photo.id; case .capture: id = captureAssetID ?? library.savedPhotoID }
        guard let id, ids.contains(id), handledUnavailableID != id else { return }
        handledUnavailableID = id
        deletionWasRAW = selectedIsRAW; deletionWasLive = selectedIsLive; deletionWasNight = selectedIsNightComposite; deletionHadFilter = selectedHasFilter
        let remainingOrder = photos.filter { $0.id == id || !ids.contains($0.id) }
        deletionFallback = GalleryPhotoPaging.afterDeleting(selected, photos: remainingOrder,
            hasCapture: library.lastPhoto != nil && !library.photoSaved, captureID: captureAssetID ?? library.savedPhotoID)
        deletionBoundaryID = remainingOrder.last(where: { $0.id != id })?.id
        // The availability event precedes the array/cache mutation; navigate afterwards.
        let origin = selected
        DispatchQueue.main.async { deletedPhoto(from: origin) }
    }

    private var selectedIsRAW: Bool {
        switch selected { case .asset(let photo): return photo.isRAW; case .capture: return library.hasRAWResource }
    }
    private var selectedIsLive: Bool {
        switch selected { case .asset(let photo): return photo.isLive; case .capture: return library.hasLiveResource }
    }
    private var selectedIsNightComposite: Bool {
        switch selected { case .asset(let photo): return photo.isNightComposite; case .capture: return library.hasNightCompositeResource }
    }
    private var selectedHasFilter: Bool {
        switch selected { case .asset(let photo): return PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID: photo.id); case .capture: return library.hasFilterResource }
    }
    private func prepareDeletion() {
        deletionFallback = GalleryPhotoPaging.afterDeleting(selected, photos: photos, hasCapture: library.lastPhoto != nil && !library.photoSaved, captureID: captureAssetID ?? library.savedPhotoID)
        deletionWasRAW = selectedIsRAW
        deletionWasLive = selectedIsLive
        deletionWasNight = selectedIsNightComposite
        deletionHadFilter = selectedHasFilter
        let deletedID: String?
        switch selected { case .asset(let p): deletedID = p.id; case .capture: deletedID = captureAssetID ?? library.savedPhotoID }
        deletionBoundaryID = photos.last(where: { $0.id != deletedID })?.id
    }
    private func deletedPhoto(from origin: GalleryRoute) {
        guard let token = deletionNavigation.begin(from: origin, current: selected) else { return }
        guard let next = deletionFallback else {
            guard canLoadMore, model.hasMore || model.loading else { dismiss(); return }
            loadDeletionSuccessor(token: token)
            return
        }
        deletionFallback = nil
        prepareSelection(next, direction: 1, afterDeletion: true, deletionToken: token)
    }
    private func loadDeletionSuccessor(token: UUID) {
        guard deletionNavigation.matches(token, current: selected) else { return }
        // Wait for a running refresh, then continue the same deletion exactly once.
        let count = model.photos.count
        let wasLoading = model.loading
        model.loadMore {
            guard deletionNavigation.matches(token, current: selected) else { return }
            let next: LibraryPhoto?
            if let boundary = deletionBoundaryID, let index = model.photos.firstIndex(where: { $0.id == boundary }) {
                next = model.photos.dropFirst(index + 1).first
            } else if deletionBoundaryID == nil { next = model.photos.first }
            else { next = nil }
            if let next { prepareSelection(.asset(next), direction: 1, afterDeletion: true, deletionToken: token) }
            else if model.hasMore && (wasLoading || model.photos.count > count) { loadDeletionSuccessor(token: token) }
            else { dismiss() }
        }
    }
    private func move(_ step: Int, outgoing: UIImage? = nil) {
        guard !transitioning, !loader.loading, !library.isBusy else { return }
        guard let next = GalleryPhotoPaging.neighbor(of: selected, step: step, photos: photos,
                                                    hasCapture: library.lastPhoto != nil && !library.photoSaved, captureID: captureAssetID ?? library.savedPhotoID) else {
            if step == 1 && canLoadMore { model.loadMore() }; return
        }
        prepareSelection(next, direction: step, outgoing: outgoing)
    }
    private func prepareSelection(_ next: GalleryRoute, direction: Int, outgoing: UIImage? = nil,
                                  afterDeletion: Bool = false, deletionToken: UUID? = nil) {
        // A video page owns its own AVAsset/player loader. Asking the photo image
        // loader for a still poster can fail and leave the current photo selected,
        // making every later swipe appear unresponsive.
        if !GalleryPhotoPaging.requiresImagePreload(next, afterDeletion: afterDeletion) {
            loader.cancel()
            let previousImage = outgoing ?? displayedImage
            motion = PhotoPageAnimation(outgoing: previousImage, direction: direction,
                outgoingRAW: afterDeletion ? deletionWasRAW : selectedIsRAW,
                outgoingLive: afterDeletion ? deletionWasLive : selectedIsLive,
                outgoingFilter: afterDeletion ? deletionHadFilter : selectedHasFilter,
                outgoingNight: afterDeletion ? deletionWasNight : selectedIsNightComposite)
            seed = nil
            displayedImage = nil
            // 已删除照片不能因下一张仍在下载而占住详情，也不能锁住返回操作。
            if afterDeletion, GalleryPhotoPaging.requiresImagePreload(next) { motion = nil }
            transitioning = motion != nil
            selected = next
            // 无预加载分支同样必须结束删除事务，否则下一次删除虽成功却无法切页。
            if let deletionToken { deletionNavigation.finish(deletionToken) }
            return
        }
        let origin = selected
        loader.prepare(next, capture: library.lastPhoto, onFailure: { if afterDeletion { dismiss() } }) { image in
            guard selected == origin else { return }
            if let deletionToken, !deletionNavigation.matches(deletionToken, current: selected) { return }
            motion = PhotoPageAnimation(outgoing: outgoing ?? displayedImage, direction: direction,
                outgoingRAW: afterDeletion ? deletionWasRAW : selectedIsRAW,
                outgoingLive: afterDeletion ? deletionWasLive : selectedIsLive,
                outgoingFilter: afterDeletion ? deletionHadFilter : selectedHasFilter,
                outgoingNight: afterDeletion ? deletionWasNight : selectedIsNightComposite)
            transitioning = true
            seed = image; selected = next
            if let deletionToken { deletionNavigation.finish(deletionToken) }
            if case .asset(let photo) = next, canLoadMore,
               let index = model.photos.firstIndex(where: { $0.id == photo.id }), index >= model.photos.count - 3 { model.loadMore() }
        }
    }
}
