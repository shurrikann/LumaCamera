import AVKit
import Photos
import SwiftUI
import UIKit

/// A system Photos video keeps its own player lifetime, separate from still-image editing.
struct SystemVideoView: View {
    @ObservedObject var model: GalleryViewModel
    let photo: LibraryPhoto
    let onCamera: () -> Void
    var onSwipe: ((Int) -> Void)?
    var onSwipeWithSnapshot: ((Int, UIImage?) -> Void)?
    var pageMotion: PhotoPageAnimation?
    var onPageFinished: (() -> Void)?
    var onDeletePrepared: (() -> Void)?
    var onDeleted: (() -> Void)?
    #if DEBUG
    var playbackAssetForTesting: AVAsset?
    var onLayoutForTesting: (([String: CGRect]) -> Void)?
    var infoVisibleForTesting: Bool?
    var playingForTesting: Bool?
    var onPlaybackVisibilityForTesting: ((Bool) -> Void)?
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.videoPlaybackAngle) private var playbackAngle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var message: String?
    @State private var loading = true
    @State private var shareBusy = false
    @State private var shareSession: PreparedPhotoShare?
    @State private var shareRequest: PhotoImageRequest?
    @State private var loadedAsset: AVAsset?
    @State private var details: PhotoDetails?
    @State private var detailsBusy = false
    @State private var detailsVisible = false
    @State private var detailsTask: Task<Void, Never>?
    @State private var active = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var scrubbing = false
    @State private var volume: Double = 0
    @State private var lastAudibleVolume: Double = 1
    @State private var editorPresented = false
    @State private var pageProgress: CGFloat = 0
    @State private var pageSwipeCapturing = false

    var body: some View {
        GeometryReader { geometry in
            detail(bottomInset: geometry.safeAreaInsets.bottom)
        }
    }

    private func detail(bottomInset: CGFloat) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mediaCanvas(bottomInset: bottomInset).ignoresSafeArea()
        }
        .overlay {
            if detailsVisible {
                Color.black.opacity(0.08).contentShape(Rectangle())
                    .onTapGesture { closeDetails() }.accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            topBar.opacity(isPlaying ? 0 : 1).allowsHitTesting(!isPlaying).accessibilityHidden(isPlaying)
                .animation(popupAnimation, value: isPlaying)
        }
        .overlay(alignment: .bottom) {
            bottomBar
                .frame(width: 300)
                .background {
                    Color.clear.frame(height: 50)
                        .modifier(PreviewSurface(radius: 25, opacity: AppTheme.popupOpacity, interactive: false))
                }
                .padding(.bottom, 12)
                .opacity(isPlaying ? 0 : 1)
                .allowsHitTesting(!isPlaying).accessibilityHidden(isPlaying)
                .animation(popupAnimation, value: isPlaying)
        }
        .overlayPreferenceValue(VideoPopupAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if detailsVisible, let anchor = anchors[.info] {
                    VideoAnchoredPopup(
                        anchor: geometry[anchor], container: geometry.size,
                        width: 520, height: min(540, geometry.size.height * 0.72),
                        scrollsWhenCompact: false
                    ) {
                        PhotoInfoPanel(details: details, loading: detailsBusy, isVideo: true) {
                            closeDetails()
                        }
                        .videoDetailFrame("infoPanel")
                    }
                    .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(!editorPresented)
        .accessibilityHidden(editorPresented)
        .overlay {
            if editorPresented, let loadedAsset {
                VideoEditorView(asset: loadedAsset, photo: photo, library: model.library) {
                    withAnimation(popupAnimation) { editorPresented = false }
                }
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .coordinateSpace(name: "videoDetail")
        .onPreferenceChange(VideoDetailFrameKey.self) { frames in
            #if DEBUG
            onLayoutForTesting?(frames)
            #endif
        }
        .onAppear { active = true; load(); if pageMotion == nil { onPageFinished?() } }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                detailsTask?.cancel()
                closeDetails()
            }
            #if DEBUG
            onPlaybackVisibilityForTesting?(playing)
            #endif
        }
        #if DEBUG
        .task(id: playingForTesting) {
            if let playingForTesting, let player,
               (player.timeControlStatus != .paused) != playingForTesting { togglePlayback() }
        }
        .task(id: infoVisibleForTesting) {
            guard let infoVisibleForTesting else { return }
            if infoVisibleForTesting {
                if !detailsVisible { showDetails() }
            } else {
                closeDetails()
            }
        }
        #endif
        .task(id: pageMotion?.id) {
            guard pageMotion != nil else { return }
            pageProgress = 0
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : GalleryPageTransition.duration), completionCriteria: .removed) {
                pageProgress = 1
            } completion: { onPageFinished?() }
        }
        .task {
            while !Task.isCancelled {
                syncPlayback()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onDisappear {
            active = false
            player?.pause()
            detailsTask?.cancel()
            shareRequest?.cancel()
            if requestID != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(requestID) }
        }
        // 系统分享面板使用标准 sheet 动画；自定义 presentationBackground 会让
        // UIActivityViewController 的呈现看起来是瞬切，不叠加自定义背景。
        .sheet(item: $shareSession) { FileShareSheet(session: $0) }
        .alert("光屿相机", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func mediaCanvas(bottomInset: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack {
                if let pageMotion, let outgoing = pageMotion.outgoing {
                    LibraryMediaCanvas(angle: playbackAngle) { size in
                        Image(uiImage: outgoing).resizable().scaledToFit()
                            .frame(width: size.width, height: size.height)
                    }
                        .offset(x: GalleryPageTransition.horizontalOffset(direction: pageMotion.direction, extent: geometry.size.width, progress: pageProgress, incoming: false, reduceMotion: reduceMotion))
                        .opacity(GalleryPageTransition.opacity(progress: pageProgress, incoming: false, reduceMotion: reduceMotion))
                        .accessibilityIdentifier("VideoPagingOutgoingImage")
                        .allowsHitTesting(false)
                }
                mediaCanvasContent(geometry.size, bottomInset: bottomInset)
                    .offset(x: pageMotion.map { GalleryPageTransition.horizontalOffset(direction: $0.direction, extent: geometry.size.width, progress: pageProgress, incoming: true, reduceMotion: reduceMotion) } ?? 0)
                    .opacity(pageMotion.map { _ in GalleryPageTransition.opacity(progress: pageProgress, incoming: true, reduceMotion: reduceMotion) } ?? 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipped().videoDetailFrame("media")
        .contentShape(Rectangle())
        .onTapGesture { handleMediaTap() }
        .overlay {
            GeometryReader { geometry in
                LibraryMediaCanvas(angle: playbackAngle) { size in
                    VStack {
                        Spacer(minLength: 0)
                        playbackBar(width: max(1, size.width * 2 / 3))
                            .videoDetailFrame("playback")
                            .frame(height: 72)
                            .background {
                                Color.clear.frame(height: 50)
                                    .modifier(PreviewSurface(radius: 25, opacity: AppTheme.popupOpacity, interactive: false))
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, abs(sin(playbackAngle * .pi / 180)) > 0.5 ? 16 : bottomInset + 12)
                    }
                }
            }
            .opacity(isPlaying ? 1 : 0)
            .allowsHitTesting(isPlaying && player != nil).accessibilityHidden(!isPlaying)
            .animation(popupAnimation, value: isPlaying)
        }
        .overlay {
            if !isPlaying {
                Button { handleMediaTap() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .offset(x: 1)
                        .frame(width: 52, height: 52)
                        .modifier(PreviewSurface(radius: 26, opacity: AppTheme.popupOpacity, interactive: false))
                }
                .rotationEffect(.degrees(playbackAngle))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: playbackAngle)
                .buttonStyle(GalleryStableActionStyle())
                .disabled(player == nil || editorPresented || shareBusy)
                .accessibilityLabel("播放视频")
                .videoDetailFrame("centerPlay")
                .transition(.opacity)
            }
        }
        .animation(popupAnimation, value: isPlaying)
    }

    private func handleMediaTap() {
        if detailsVisible { closeDetails(); return }
        guard !editorPresented, !shareBusy else { return }
        togglePlayback()
    }

    @ViewBuilder private func mediaCanvasContent(_ viewport: CGSize, bottomInset: CGFloat) -> some View {
            let size = LibraryMediaRotation.canvasSize(viewport, angle: playbackAngle)
            let dockWidth = min(340, max(1, size.width - 24))
            ZStack(alignment: .bottom) {
                if let player {
                    PlayerLayerView(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
                            guard !detailsVisible, !editorPresented, !shareBusy, !pageSwipeCapturing else { return }
                            let translation = LibraryMediaRotation.screenTranslation(drag.translation, angle: playbackAngle)
                            if let step = GalleryPhotoPaging.swipeStep(horizontal: translation.width,
                                                                        vertical: translation.height) {
                                if onSwipeWithSnapshot != nil { capturePageSnapshotAndSwipe(step) }
                                else { onSwipe?(step) }
                            }
                        })
                } else if loading { ProgressView().tint(AppTheme.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 5) {
                        viewerTextBadge(videoDurationText(photo.duration))
                        if photo.hasFilter { PhotoFilterBadge() }
                        if let logLabel = photo.logLabel { viewerTextBadge(logLabel) }
                        if photo.isAstroCapture { PhotoAstroBadge() }
                    }
                    .allowsHitTesting(false).videoDetailFrame("badges")
                    .opacity(isPlaying ? 0 : 1).accessibilityHidden(isPlaying)
                    .animation(popupAnimation, value: isPlaying)
                }
                .frame(width: dockWidth)
                .padding(.bottom, abs(sin(playbackAngle * .pi / 180)) > 0.5 ? 16 : bottomInset + 96)
            }
            .frame(width: size.width, height: size.height)
            // rotationEffect does not change layout dimensions: swap them explicitly at 90°.
            .rotationEffect(.degrees(playbackAngle))
            .position(x: viewport.width / 2, y: viewport.height / 2)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: playbackAngle)
    }

    private func capturePageSnapshotAndSwipe(_ step: Int) {
        guard let onSwipeWithSnapshot else { onSwipe?(step); return }
        guard let loadedAsset, let player else { onSwipeWithSnapshot(step, nil); return }
        pageSwipeCapturing = true
        let generator = AVAssetImageGenerator(asset: loadedAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let time = player.currentTime()
        Task { @MainActor in
            let snapshot: UIImage?
            do {
                let frame = try await generator.image(at: time).image
                snapshot = UIImage(cgImage: frame)
            } catch {
                snapshot = nil
            }
            pageSwipeCapturing = false
            onSwipeWithSnapshot(step, snapshot)
        }
    }

    private var topBar: some View {
        HStack {
            viewerAction("chevron.left", label: "返回相册") { dismiss() }.videoDetailFrame("back")
            Spacer(minLength: 8)
            if photo.date != nil || photo.location?.isValid == true {
                VStack(spacing: 3) {
                    if let date = photo.date {
                        Text(date.formatted(date: .numeric, time: .standard))
                            .font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    if let location = photo.location, location.isValid {
                        PhotoLocationTitle(location: location)
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .modifier(PreviewSurface(radius: 24, opacity: AppTheme.popupOpacity, interactive: false))
                .videoDetailFrame("title")
            }
            Spacer(minLength: 8)
            Color.clear.frame(width: 48, height: 48)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var bottomBar: some View {
            HStack(spacing: 0) {
            viewerAction(shareBusy ? "hourglass" : "square.and.arrow.up", label: "分享视频", disabled: shareBusy) { prepareShare() }
                .frame(maxWidth: .infinity)
            viewerAction(detailsBusy ? "hourglass" : "info.circle",
                         label: detailsVisible ? "收起视频详情" : "视频详情",
                         disabled: loadedAsset == nil || detailsBusy, anchor: .info) { showDetails() }
                .frame(maxWidth: .infinity)
            LibraryCameraButton(action: onCamera).disabled(model.library.deleting || model.library.editing)
                .frame(maxWidth: .infinity)
            viewerAction("slider.horizontal.3", label: "编辑视频", disabled: loadedAsset == nil || loading) {
                player?.pause()
                detailsTask?.cancel()
                withAnimation(popupAnimation) {
                    detailsVisible = false
                    editorPresented = true
                }
            }
                .frame(maxWidth: .infinity)
            viewerAction("trash", label: "删除视频", disabled: model.library.deleting) { deleteVideo() }
                .frame(maxWidth: .infinity)
            }
            .videoDetailFrame("actions")
            .padding(.horizontal, 6)
            .frame(height: 72)
    }

    private func deleteVideo() {
        onDeletePrepared?()
        model.delete(photo) { deleted in
            if deleted { if let onDeleted { onDeleted() } else { dismiss() } }
        }
    }

    private func viewerAction(_ icon: String, label: String, disabled: Bool = false, anchor: VideoPopupAnchor? = nil, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            let content = Image(systemName: icon).font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(disabled ? AppTheme.disabledControlOpacity : 1))
                .frame(width: 48, height: 48)
                .background {
                    if icon == "chevron.left" {
                        Color.clear.modifier(PreviewSurface(radius: 24, opacity: AppTheme.popupOpacity, interactive: false))
                    }
                }
            if let anchor {
                content.videoPopupAnchor(anchor).videoDetailFrame("info")
            } else {
                content
            }
        }.buttonStyle(GalleryStableActionStyle()).disabled(disabled).accessibilityLabel(label)
    }

    private func viewerTextBadge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    private func videoDurationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    private func load() {
        #if DEBUG
        if let playbackAssetForTesting {
            loadedAsset = playbackAssetForTesting
            player = AVPlayer(playerItem: AVPlayerItem(asset: playbackAssetForTesting))
            loading = false
            return
        }
        #endif
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else {
            loading = false; message = "视频已不在系统相册中。"; return
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { asset, _, info in
            DispatchQueue.main.async {
                guard active else { return }
                loading = false
                if let asset {
                    loadedAsset = asset
                    duration = 0
                    let created = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    created.volume = Float(volume)
                    player = created
                }
                else { message = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "无法载入视频。" }
            }
        }
    }

    private func playbackBar(width: CGFloat) -> some View {
        let compact = width < 300
        return HStack(spacing: compact ? 5 : 9) {
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: compact ? 26 : 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }.accessibilityLabel(isPlaying ? "暂停视频" : "播放视频")

            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: 3)
                    Capsule().fill(AppTheme.accent).frame(width: max(3, width * progress), height: 3)
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .offset(x: max(0, min(width - 9, width * progress - 4.5)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = true
                        currentTime = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        guard duration > 0 else { return }
                        scrubbing = false
                        seek(to: currentTime)
                    })
                .accessibilityElement()
                .accessibilityLabel("播放进度")
                .accessibilityValue(timeText(currentTime) + " / " + timeText(duration))
                .accessibilityAdjustableAction { direction in
                    guard duration > 0 else { return }
                    let step = max(1, duration / 20)
                    let target = direction == .increment ? min(duration, currentTime + step) : max(0, currentTime - step)
                    currentTime = target
                    seek(to: target)
                }
            }.frame(minWidth: 28).frame(height: 20)

            Text(timeText(currentTime) + " / " + timeText(duration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78)).lineLimit(1).minimumScaleFactor(0.7)

            Button { toggleMute() } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: compact ? 22 : 24, height: 26)
            }.accessibilityLabel(volume > 0.001 ? "静音" : "取消静音")

            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: 3)
                    Capsule().fill(AppTheme.accent).frame(width: max(2, width * volume), height: 3)
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .offset(x: max(0, min(width - 7, width * volume - 3.5)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in setVolume(min(max(value.location.x / width, 0), 1)) })
                .accessibilityElement()
                .accessibilityLabel("音量")
                .accessibilityValue("\(Int(volume * 100))%")
                .accessibilityAdjustableAction { direction in
                    let step = 0.1
                    setVolume(direction == .increment ? min(1, volume + step) : max(0, volume - step))
                }
            }.frame(width: compact ? 32 : 42, height: 20)
        }
        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 7)
        .frame(width: width, height: 50)
    }

    private var volumeIcon: String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.fill" }
        if volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        if clamped > 0 { lastAudibleVolume = clamped }
        player?.volume = Float(clamped)
    }

    private func toggleMute() {
        if volume > 0.001 { lastAudibleVolume = volume; setVolume(0) }
        else { setVolume(max(0.2, lastAudibleVolume)) }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus != .paused { player.pause() }
        else {
            if duration > 0, currentTime >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        }
        syncPlayback()
    }

    private func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func syncPlayback() {
        guard let player else { return }
        isPlaying = player.timeControlStatus != .paused
        if !scrubbing {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { currentTime = seconds }
        }
        if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 { duration = seconds }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private var popupAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.1 : 0.18)
    }

    private func closeDetails() {
        withAnimation(popupAnimation) { detailsVisible = false }
    }

    private func showDetails() {
        if detailsVisible { withAnimation(popupAnimation) { detailsVisible = false }; return }
        if details != nil { withAnimation(popupAnimation) { detailsVisible = true }; return }
        guard let asset = loadedAsset, !detailsBusy else { return }
        let resource = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject
            .flatMap { PHAssetResource.assetResources(for: $0).first { $0.type == .video || $0.type == .fullSizeVideo } }
        detailsBusy = true
        detailsTask = Task { @MainActor in
            defer { detailsBusy = false }
            do {
                let value = try await VideoDetailsReader.read(asset, filename: resource?.originalFilename, date: photo.date,
                                                              location: photo.location,
                                                              badges: VideoCaptureBadgeStore.shared.badges(assetID: photo.id))
                guard !Task.isCancelled, active else { return }
                details = value
                withAnimation(popupAnimation) { detailsVisible = true }
            } catch {
                if !Task.isCancelled, active { message = "无法读取视频详情：\(error.localizedDescription)" }
            }
        }
    }

    private func prepareShare() {
        guard !shareBusy, let exporter = model.browser as? PhotoFileExportService else { return }
        shareBusy = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoShare-" + UUID().uuidString)
        shareRequest = exporter.exportPhoto(id: photo.id, directory: folder) { result in
            shareBusy = false
            shareRequest = nil
            switch result {
            case .success(let url): shareSession = PreparedPhotoShare(directory: folder, urls: [url])
            case .failure(let error): message = "分享视频失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct VideoDetailFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    @ViewBuilder func videoDetailFrame(_ name: String) -> some View {
        #if DEBUG
        background(GeometryReader { geometry in
            Color.clear.preference(key: VideoDetailFrameKey.self, value: [name: geometry.frame(in: .named("videoDetail"))])
        })
        #else
        self
        #endif
    }
}


private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
