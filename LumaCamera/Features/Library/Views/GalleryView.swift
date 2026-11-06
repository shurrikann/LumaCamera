import SwiftUI
import Photos
import PhotosUI

enum GalleryRoute: Hashable { case asset(LibraryPhoto), capture }

struct GalleryView: View {
    @ObservedObject var model: GalleryViewModel
    @ObservedObject var library: PhotoLibraryViewModel
    let isDemo: Bool
    var openLatestCapture = false
    var openVideoID: String? = nil
    let onCamera: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [GalleryRoute] = []
    @State private var previewOpened = false
    @State private var recentOnly = false
    @StateObject private var batchShare: BatchPhotoShareModel
    @StateObject private var mediaOrientation: CaptureControlOrientation
    init(model: GalleryViewModel, library: PhotoLibraryViewModel, isDemo: Bool, openLatestCapture: Bool = false, openVideoID: String? = nil, batchShare: BatchPhotoShareModel? = nil, mediaOrientation: CaptureControlOrientation? = nil, onCamera: @escaping () -> Void) {
        self.model = model; self.library = library; self.isDemo = isDemo; self.openLatestCapture = openLatestCapture; self.openVideoID = openVideoID; self.onCamera = onCamera
        _batchShare = StateObject(wrappedValue: batchShare ?? BatchPhotoShareModel())
        _mediaOrientation = StateObject(wrappedValue: mediaOrientation ?? CaptureControlOrientation())
    }
    private var displayedPhotos: [LibraryPhoto] {
        recentOnly ? model.photos.filter { $0.id == library.savedPhotoID } : model.photos
    }
    private var showCurrentCapture: Bool {
        library.lastPhoto != nil && !library.photoSaved && !displayedPhotos.contains(where: { $0.id == library.savedPhotoID })
    }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if model.selecting { model.endSelection() } else { model.beginSelection() }
                    } label: { Text(model.selecting ? "取消" : "选择").rotatingCaptureContent() }.disabled(library.isBusy || library.captureInProgress || batchShare.preparing)
                    Spacer()
                    Menu {
                        Button("所有内容") { model.endSelection(); recentOnly = false }
                        Button("本次拍摄") { model.endSelection(); recentOnly = true }
                    } label: {
                        GalleryScopeLabel(recentOnly: recentOnly).environment(\.isEnabled, true)
                    }
                    .disabled(model.selecting || library.isBusy || batchShare.preparing)
                    Spacer()
                    if model.selecting {
                        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.selectAll(displayedPhotos.map(\.id)) } label: { Text("全选").rotatingCaptureContent() }
                            .accessibilityLabel("全选已加载照片").disabled(library.isBusy || batchShare.preparing)
                    }
                }.padding(.horizontal, 16).padding(.top, 8)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.access == .limited {
                            HStack {
                                Text("仅显示获准访问的照片").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("选择更多") { presentLimitedPicker() }.font(.caption)
                            }.padding(.horizontal, 12)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            if showCurrentCapture, let image = library.lastPhoto {
                                NavigationLink(value: GalleryRoute.capture) {
                                    GeometryReader { geometry in
                                        LibraryMediaThumbnail(image: image).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                            .overlay(alignment: .bottomTrailing) {
                                                VStack(alignment: .trailing, spacing: 4) {
                                                    if library.saving { ProgressView().padding(4) }
                                                    else if !library.photoSaved { Text("未保存").font(.system(size: 9)).padding(4).background(AppTheme.popupBackground) }
                                                    if library.hasRAWResource { rawBadge }
                                                    if library.hasLiveResource { formatBadge("LIVE") }
                                                }.padding(5)
                                            }
                                    }.aspectRatio(1, contentMode: .fit)
                                        .clipped().contentShape(Rectangle())
                                }.buttonStyle(GalleryStableActionStyle()).disabled(model.selecting).accessibilityLabel("刚刚拍摄的照片")
                            }
                            ForEach(displayedPhotos) { photo in
                                if model.selecting {
                                    Button { model.toggleSelection(photo.id) } label: { photoTile(photo).overlay(alignment: .topTrailing) { selectionBadge(photo.id) } }
                                        .buttonStyle(GalleryStableActionStyle()).disabled(library.isBusy || batchShare.preparing).accessibilityLabel("选择照片")
                                        .accessibilityValue(model.selectedIDs.contains(photo.id) ? "已选择" : "未选择")
                                } else {
                                    NavigationLink(value: GalleryRoute.asset(photo)) { photoTile(photo) }
                                        .buttonStyle(GalleryStableActionStyle()).accessibilityLabel(photo.isVideo ? "播放视频" : photo.isRAW ? "查看 RAW 照片" : "查看照片")
                                }
                            }
                        }.padding(.horizontal, 3)
                        if model.access == .denied {
                            ContentUnavailableView {
                                Label("允许访问系统相册", systemImage: "photo.on.rectangle")
                            } description: { Text("请在系统设置中允许访问照片，以浏览、编辑和删除。") } actions: {
                                Button("前往设置") { openSettings() }.buttonStyle(.borderedProminent)
                            }
                        } else if !model.loading && displayedPhotos.isEmpty && !showCurrentCapture {
                            ContentUnavailableView("暂无照片或视频", systemImage: "photo", description: Text("拍摄后会自动保存到系统相册。"))
                        }
                        if model.hasMore && !model.loading && !recentOnly {
                            Button("加载更多") { model.loadMore() }
                                .task { await Task.yield(); if !Task.isCancelled { model.loadMore() } }.padding()
                        }
                        if model.loading { ProgressView().padding(20) }
                    }
                }.refreshable { model.refresh() }
                GalleryActionBar(selecting: model.selecting, selectedCount: model.selectedIDs.count,
                                 preparing: batchShare.preparing, completedCount: batchShare.completedCount, totalCount: batchShare.totalCount,
                                 libraryBusy: library.isBusy, captureInProgress: library.captureInProgress,
                                 destructiveBusy: library.deleting || library.editing,
                                 onShare: {
                    guard let service = model.browser as? PhotoFileExportService else { model.message = "暂时无法分享这些照片。"; return }
                    batchShare.prepare(photos: displayedPhotos.filter { model.selectedIDs.contains($0.id) }, service: service)
                }, onCamera: onCamera, onDelete: { model.deleteSelected() }, onCancelShare: { batchShare.cancelPreparation() })

            }
            .navigationDestination(for: GalleryRoute.self) { route in
                PhotoPagingView(model: model, library: library, initial: route, photos: displayedPhotos,
                                isDemo: isDemo, canLoadMore: !recentOnly, onCamera: onCamera)
            }
            .task {
                openRequestedVideoIfAvailable()
                if !previewOpened && openLatestCapture && library.lastPhoto != nil {
                    previewOpened = true; path = [.capture]
                }
            }
            .onChange(of: model.photos) { _, photos in
                openRequestedVideoIfAvailable()
                #if DEBUG && targetEnvironment(simulator)
                let arguments = ProcessInfo.processInfo.arguments
                if !previewOpened, (arguments.contains("--preview-photo") || arguments.contains("--preview-editor") || arguments.contains("--preview-photo-info")), let first = photos.first {
                    previewOpened = true; path = [.asset(first)]
                }
                #endif
            }
            .overlay {
                if openVideoID != nil && !previewOpened && model.loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.popupColor.ignoresSafeArea())
                }
            }
            .background(AppTheme.popupColor.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: scenePhase) { if scenePhase == .active { model.refresh() } }
            .sheet(item: $batchShare.prepared) { FileShareSheet(session: $0).presentationBackground(AppTheme.popupColor).preferredColorScheme(.dark) }
            .onDisappear { batchShare.cancelPreparation() }
            .alert("光屿相机", isPresented: Binding(get: { model.message != nil || library.message != nil || batchShare.message != nil }, set: { if !$0 { model.message = nil; library.message = nil; batchShare.message = nil } })) {
                Button("好", role: .cancel) { model.message = nil; library.message = nil; batchShare.message = nil }
            } message: { Text(batchShare.message ?? model.message ?? library.message ?? "") }
        }.buttonStyle(GalleryStableActionStyle()).tint(AppTheme.accent).preferredColorScheme(.dark)
            .interactiveDismissDisabled(library.deleting || library.editing || batchShare.preparing)
            // Controls and editor stay portrait; photo canvases use libraryMediaAngle.
            .environment(\.captureControlAngle, 0)
            // Observe inside the presented library, rather than capturing camera environment angles.
            .environment(\.libraryMediaAngle, mediaOrientation.degrees)
            .environment(\.videoPlaybackAngle, mediaOrientation.degrees)
            .onAppear { mediaOrientation.resetForMediaPresentation(UIDevice.current.orientation) }
    }
    private func openRequestedVideoIfAvailable() {
        guard !previewOpened, let openVideoID,
              let video = model.photos.first(where: { $0.id == openVideoID && $0.isVideo }) else { return }
        previewOpened = true
        path = [.asset(video)]
    }
    private func photoTile(_ photo: LibraryPhoto) -> some View {
        GeometryReader { geometry in
            LibraryImageView(photo: photo, browser: model.browser, size: CGSize(width: 360, height: 360), onUnavailable: { model.removeIfConfirmedMissing(id: photo.id) })
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.aspectRatio(1, contentMode: .fit).clipped().contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) { if photo.hasFilter && !photo.isVideo { PhotoFilterBadge().padding(5) } }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 5) {
                    if photo.isVideo {
                        formatBadge(videoDurationText(photo.duration))
                        if photo.hasFilter { PhotoFilterBadge() }
                        if let logLabel = photo.logLabel { formatBadge(logLabel) }
                    } else {
                        if photo.isRAW { rawBadge }
                        if photo.isLive { formatBadge("LIVE") }
                        if photo.isNightComposite { PhotoNightBadge() }
                    }
                }.padding(5)
            }
    }
    private func selectionBadge(_ id: String) -> some View {
        Image(systemName: model.selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22)).foregroundStyle(model.selectedIDs.contains(id) ? AppTheme.accent : .white)
            .shadow(color: .black, radius: 2).padding(7).allowsHitTesting(false)
    }
    private var rawBadge: some View { formatBadge("RAW") }
    private func videoDurationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
    private func formatBadge(_ title: String) -> some View {
        Text(title).rotatingCaptureContent().font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .allowsHitTesting(false)
    }

    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in Task { @MainActor in model.refresh() } }
    }
}
