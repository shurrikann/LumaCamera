import CoreGraphics

/// Fit the entire image above the bottom five controls without changing its crop ratio.
/// Long ratios still include the pixels beneath the top toolbar.
enum CameraPreviewLayout {
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
}
