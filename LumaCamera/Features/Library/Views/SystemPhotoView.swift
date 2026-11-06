import SwiftUI

struct SystemPhotoView: View {
    @ObservedObject var model: GalleryViewModel
    @StateObject private var detail: PhotoDetailViewModel
    let photo: LibraryPhoto
    var pagingBusy = false
    let onCamera: () -> Void
    var pageMotion: PhotoPageAnimation?
    var onPageFinished: (() -> Void)?
    var onDeletePrepared: (() -> Void)?
    var onDeleted: (() -> Void)?
    var onImageDisplayed: ((UIImage?) -> Void)?
    var onSwipe: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var share = false
    @State private var info = false
    @State private var editor: PhotoEditSession?
    init(model: GalleryViewModel, photo: LibraryPhoto, initialImage: UIImage? = nil, pagingBusy: Bool = false, onCamera: @escaping () -> Void, onSwipe: ((Int) -> Void)? = nil, pageMotion: PhotoPageAnimation? = nil, onPageFinished: (() -> Void)? = nil, onImageDisplayed: ((UIImage?) -> Void)? = nil, onDeletePrepared: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        self.model = model; self.photo = photo; self.onCamera = onCamera; self.onSwipe = onSwipe; self.pagingBusy = pagingBusy
        self.pageMotion = pageMotion; self.onPageFinished = onPageFinished; self.onImageDisplayed = onImageDisplayed
        self.onDeletePrepared = onDeletePrepared; self.onDeleted = onDeleted
        _detail = StateObject(wrappedValue: PhotoDetailViewModel(photo: photo, gallery: model, initialImage: initialImage))
    }
    var body: some View {
        PhotoViewerLayout(image: detail.image, date: photo.date, location: photo.location ?? detail.details?.location, isRAW: photo.isRAW, isLive: photo.isLive, hasFilter: detail.hasFilter, isNightComposite: photo.isNightComposite, liveSource: photo.isLive ? LivePhotoPlaybackSource(assetID: photo.id) : nil, busy: detail.busy, pagingBusy: pagingBusy, destructiveBusy: model.library.deleting || model.library.editing, shareBusy: detail.preparingShare, infoVisible: info, details: detail.details, detailsLoading: detail.detailsLoading,
                          onBack: { dismiss() }, onCamera: onCamera,
                          onShare: { detail.prepareShare { share = $0 } },
                          onInfo: { info.toggle(); if info { detail.loadDetails() } },
                          onEdit: { detail.prepareEditor { editor = $0 } },
                          onDelete: { onDeletePrepared?(); model.delete(photo) { deleted in if deleted { if let onDeleted { onDeleted() } else { dismiss() } } } },
                          onSwipe: share || editor != nil ? nil : onSwipe, pageMotion: pageMotion, onPageFinished: onPageFinished)
            .onAppear { onImageDisplayed?(detail.image) }
            .onChange(of: detail.image) { _, image in onImageDisplayed?(image) }
            .task {
                detail.load()
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--preview-photo-info") { detail.loadDetails(); info = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-editor") { detail.prepareEditor { editor = $0 } }
                #endif
            }.onDisappear { detail.cancelLoading() }
            .sheet(isPresented: $share) { if let image = detail.image { ShareSheet(image: image, resources: detail.resources) } }
            .sheet(item: $editor) { session in PhotoEditorView(session: session, library: model.library) { detail.edited($0); if info { detail.loadDetails() } } }
            .alert("光屿相机", isPresented: Binding(get: { detail.message != nil }, set: { if !$0 { detail.message = nil } })) {
                Button("好", role: .cancel) { detail.message = nil }
            } message: { Text(detail.message ?? "") }
    }

}
