import CoreGraphics

/// Fit the entire image above the bottom five controls without changing its crop ratio.
/// Long ratios still include the pixels beneath the top toolbar.
enum CameraPreviewLayout {
    /// HDR 标识固定在 4:3 取景框顶部下方的位置，长画幅只改变水平锚点。
    static let hdrBadgeTopInset: CGFloat = 8

    static func frame(in container: CGSize, ratio: FrameRatio, openGatePortraitRatio: CGFloat? = nil,
                      landscape: Bool = false) -> CGRect {
        let portraitAspect = ratio == .openGate ? max(0.01, openGatePortraitRatio ?? ratio.portraitRatio) : ratio.portraitRatio
        let aspect = landscape ? 1 / portraitAspect : portraitAspect
        let top: CGFloat = ratio == .standard || ratio == .square
            || (!landscape && ratio == .openGate && aspect > 9.0 / 16.0) ? 62 : 0
        let bottom = max(top + 1, container.height - CameraControlLayout.shutterBottom - 78 - 12)
        let availableHeight = bottom - top
        let width = max(1, min(container.width, availableHeight * aspect))
        let height = width / aspect
        let y = landscape ? top + (availableHeight - height) / 2 : top
        return CGRect(x: (container.width - width) / 2, y: y, width: width, height: height)
    }

    /// 4:3 预览时 HDR 标识的绝对顶部位置，供所有画幅共用。
    static func hdrBadgeTop(in container: CGSize, openGatePortraitRatio: CGFloat? = nil,
                            landscape: Bool = false) -> CGFloat {
        frame(in: container, ratio: .standard, openGatePortraitRatio: openGatePortraitRatio,
              landscape: landscape).minY + hdrBadgeTopInset
    }
}
