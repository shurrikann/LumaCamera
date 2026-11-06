import SwiftUI

struct PhotoPageAnimation: Identifiable {
    let id = UUID()
    let outgoing: UIImage?
    let direction: Int
    var outgoingRAW = false
    var outgoingLive = false
    var outgoingFilter = false
    var outgoingNight = false
}

/// Only the bounded image viewport moves; viewer controls remain outside it.
struct PhotoPageViewport: View {
    let image: UIImage
    var isRAW = false
    var isLive = false
    var hasFilter = false
    var isNightComposite = false
    var liveSource: LivePhotoPlaybackSource? = nil
    @StateObject private var playback = LivePhotoPlayback()
    var onSwipe: ((Int) -> Void)?
    var motion: PhotoPageAnimation?
    var onFinished: (() -> Void)?
    @State private var progress: CGFloat = 0
    @Environment(\.libraryMediaAngle) private var photoAngle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let motion, let outgoing = motion.outgoing {
                    LibraryMediaCanvas(angle: photoAngle) { size in
                        Image(uiImage: outgoing).resizable().scaledToFit().allowedDynamicRange(.high)
                            .frame(width: size.width, height: size.height)
                            .overlay { if motion.outgoingRAW || motion.outgoingLive || motion.outgoingFilter || motion.outgoingNight { badge(in: size, image: outgoing, raw: motion.outgoingRAW, live: motion.outgoingLive, filter: motion.outgoingFilter, night: motion.outgoingNight) } }
                    }
                        .offset(x: GalleryPageTransition.horizontalOffset(direction: motion.direction, extent: geometry.size.width, progress: progress, incoming: false, reduceMotion: reduceMotion))
                        .opacity(GalleryPageTransition.opacity(progress: progress, incoming: false, reduceMotion: reduceMotion))
                        .accessibilityIdentifier("PhotoPagingOutgoingImage")
                        .allowsHitTesting(false)
                }
                LibraryMediaCanvas(angle: photoAngle) { size in
                    ZoomablePhotoView(image: image, onSwipe: onSwipe, onLivePress: liveSource.map { source in
                        { holding in playback.press(holding, source: source, size: size) }
                    }, pagingAngle: photoAngle)
                    .overlay {
                        if playback.holding, let live = playback.photo { LivePhotoPlaybackView(photo: live).allowsHitTesting(false) }
                        else if playback.loading { ProgressView().tint(.white).allowsHitTesting(false) }
                    }
                    .overlay { if isRAW || isLive || hasFilter || isNightComposite { badge(in: size, image: image, raw: isRAW, live: isLive, filter: hasFilter, night: isNightComposite) } }
                }
                    .offset(x: motion.map { GalleryPageTransition.horizontalOffset(direction: $0.direction, extent: geometry.size.width, progress: progress, incoming: true, reduceMotion: reduceMotion) } ?? 0)
                    .opacity(motion.map { _ in GalleryPageTransition.opacity(progress: progress, incoming: true, reduceMotion: reduceMotion) } ?? 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .overlay(alignment: .top) {
            if isLive && !playback.holding {
                Text("长按播放 Live").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.4), in: Capsule()).padding(.top, 12).allowsHitTesting(false)
            }
        }
        .onDisappear { playback.cancel() }
        .onChange(of: image) { _, _ in playback.cancel() }
        .onChange(of: photoAngle) { _, _ in playback.cancel() }
        .task(id: motion?.id) {
            guard motion != nil else { return }
            progress = 0
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : GalleryPageTransition.duration), completionCriteria: .removed) {
                progress = 1
            } completion: { onFinished?() }
        }
    }
    private func badge(in viewport: CGSize, image: UIImage, raw: Bool, live: Bool, filter: Bool, night: Bool) -> some View {
        let fit = PhotoRAWBadgeLayout.fit(image: image.size, viewport: viewport)
        return Color.clear.frame(width: fit.width, height: fit.height)
            .overlay(alignment: .bottomLeading) { if filter { PhotoFilterBadge().padding(10) } }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 5) {
                    if raw || live {
                        Text([raw ? "RAW" : nil, live ? "LIVE" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityLabel(live ? "Live 实况照片" : "RAW 格式照片")
                    }
                    if night { PhotoNightBadge() }
                }.padding(10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }
}
enum PhotoRAWBadgeLayout {
    static func fit(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
