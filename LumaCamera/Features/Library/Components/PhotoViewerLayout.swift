import SwiftUI

struct LibraryCameraButton: View {
    let action: () -> Void
    var body: some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: "camera.fill").rotatingCaptureContent().font(.system(size: 25)).foregroundStyle(.black)
                .frame(width: 60, height: 60).background(AppTheme.accent, in: Circle())
        }.accessibilityLabel("返回相机")
    }
}
struct PhotoViewerLayout: View {
    let image: UIImage?
    let date: Date?
    var location: PhotoLocation? = nil
    var isRAW = false
    var isLive = false
    var hasFilter = false
    var isNightComposite = false
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
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { PhotoPageViewport(image: image, isRAW: isRAW, isLive: isLive, hasFilter: hasFilter, isNightComposite: isNightComposite, liveSource: busy || pagingBusy || infoVisible ? nil : liveSource, onSwipe: busy || pagingBusy || infoVisible ? nil : onSwipe, motion: pageMotion, onFinished: onPageFinished).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity) }
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
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: infoVisible)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                action("arrow.left", label: "返回相册", disabled: destructiveBusy, action: onBack)
                Spacer(minLength: 8)
                if date != nil || location?.isValid == true {
                    VStack(spacing: 3) {
                        if let date { Text(date.formatted(date: .numeric, time: .standard)).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.7) }
                        if let location, location.isValid { PhotoLocationTitle(location: location) }
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 12).padding(.vertical, 7).modifier(PopupSurface(radius: 24))
                }
                Spacer(minLength: 8)
                Color.clear.frame(width: 48, height: 48)
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                action(shareBusy ? "hourglass" : "square.and.arrow.up", label: "分享", disabled: busy || image == nil, action: onShare)
                Spacer(minLength: 0)
                action("info.circle", label: infoVisible ? "收起图片详情" : "图片详情", disabled: busy, action: onInfo)
                Spacer(minLength: 0)
                LibraryCameraButton(action: onCamera).disabled(destructiveBusy)
                Spacer(minLength: 0)
                action("slider.horizontal.3", label: "图片编辑", disabled: busy || image == nil, action: onEdit)
                Spacer(minLength: 0)
                action("trash", label: "删除", disabled: busy, action: onDelete)
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
                .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
        .toolbar(.hidden, for: .navigationBar)
    }
    private func action(_ icon: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: icon).rotatingCaptureContent().font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(disabled ? AppTheme.disabledControlOpacity : 1))
                .frame(width: 48, height: 48).modifier(PopupSurface(radius: 24))
        }.disabled(disabled)
            .allowsHitTesting(!pagingBusy || label == "返回相册").accessibilityLabel(label)
    }
}
