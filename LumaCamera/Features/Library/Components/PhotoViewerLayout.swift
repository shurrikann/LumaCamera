import SwiftUI

struct LibraryCameraButton: View {
    let action: () -> Void
    var body: some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: "camera.fill").font(.system(size: 25)).foregroundStyle(.black)
                .frame(width: 60, height: 60)
                .background(AppTheme.accent, in: Circle())
                .modifier(CaptureAlbumGlassSurface(interactive: false))
        }.buttonStyle(GalleryStableActionStyle()).accessibilityLabel("返回相机")
    }
}
struct PhotoViewerLayout: View {
    let image: UIImage?
    let date: Date?
    var location: PhotoLocation? = nil
    var isRAW = false
    var isLive = false
    var hasFilter = false
    var isAstroCapture = false
    var liveSource: LivePhotoPlaybackSource? = nil
    var busy = false
    var pagingBusy = false
    var destructiveBusy = false
    var shareBusy = false
    var infoVisible = false
    var details: PhotoDetails? = nil
    var detailsLoading = false
    let onBack: () -> Void
    let onCamera: () -> Void
    let onShare: () -> Void
    let onInfo: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onSwipe: ((Int) -> Void)? = nil
    var pageMotion: PhotoPageAnimation? = nil
    var onPageFinished: (() -> Void)? = nil
    #if DEBUG
    var onActionFrameForTesting: ((String, CGRect) -> Void)? = nil
    #endif
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            viewer(topOverlayInset: geometry.safeAreaInsets.top + 60)
        }
    }

    private func viewer(topOverlayInset: CGFloat) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { PhotoPageViewport(image: image, topOverlayInset: topOverlayInset, isRAW: isRAW, isLive: isLive, hasFilter: hasFilter, isAstroCapture: isAstroCapture, liveSource: busy || pagingBusy || infoVisible ? nil : liveSource, onSwipe: busy || pagingBusy || infoVisible ? nil : onSwipe, motion: pageMotion, onFinished: onPageFinished).frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea().transition(.opacity) }
            else { ProgressView().tint(AppTheme.accent) }

        }
        // 下一张照片异步到达时只淡入媒体画布，工具按钮不移动或闪烁。
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.18), value: image != nil)
        .overlay {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    if infoVisible {
                        Color.black.opacity(0.08).contentShape(Rectangle())
                            .onTapGesture { onInfo() }.accessibilityHidden(true)
                            .transition(.opacity)
                        PhotoInfoPanel(details: details, loading: detailsLoading, onClose: onInfo)
                            .frame(height: landscape ? min(340, geometry.size.width - 28) : min(540, geometry.size.height * 0.72))
                            .orientedPopup()
                            .padding(.horizontal, 8).padding(.bottom, 6)
                            .transition(.opacity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: infoVisible)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                action("arrow.left", label: "返回相册", disabled: destructiveBusy, action: onBack)
                Spacer(minLength: 8)
                if date != nil || location?.isValid == true {
                    VStack(spacing: 3) {
                        if let date { Text(date.formatted(date: .numeric, time: .standard)).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.7) }
                        if let location, location.isValid { PhotoLocationTitle(location: location) }
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .modifier(PreviewSurface(radius: 24, opacity: AppTheme.popupOpacity, interactive: false))
                }
                Spacer(minLength: 8)
                Color.clear.frame(width: 48, height: 48)
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                action("square.and.arrow.up", label: "分享", disabled: busy || image == nil, loading: shareBusy, surface: false, action: onShare)
                    .frame(maxWidth: .infinity)
                action("info.circle", label: infoVisible ? "收起图片详情" : "图片详情", disabled: busy, surface: false, action: onInfo)
                    .frame(maxWidth: .infinity)
                LibraryCameraButton(action: onCamera).disabled(destructiveBusy)
                    .frame(maxWidth: .infinity)
                action("slider.horizontal.3", label: "图片编辑", disabled: busy || image == nil, surface: false, action: onEdit)
                    .frame(maxWidth: .infinity)
                action("trash", label: "删除", disabled: busy, surface: false, action: onDelete)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6)
            .frame(width: 300, height: 72)
            .background {
                Color.clear.frame(height: 50)
                    .modifier(PreviewSurface(radius: 25, opacity: AppTheme.popupOpacity, interactive: false))
            }
            .padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
    private func action(_ icon: String, label: String, disabled: Bool, loading: Bool = false, surface: Bool = true, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: icon).font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(disabled && !loading ? AppTheme.disabledControlOpacity : 1))
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    onActionFrameForTesting?(label, $0)
                }
                #endif
                .frame(width: 48, height: 48)
                .background {
                    if surface { Color.clear.modifier(PreviewSurface(radius: 24, opacity: AppTheme.popupOpacity, interactive: false)) }
                }
                .overlay {
                    if loading { GalleryActivityRing(tint: .white).allowsHitTesting(false) }
                }
        }.buttonStyle(GalleryStableActionStyle()).disabled(disabled)
            .allowsHitTesting(!pagingBusy || label == "返回相册").accessibilityLabel(label)
    }
}
