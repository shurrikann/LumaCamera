import CoreGraphics

/// Positions belong to the camera screen, independent of the current image crop.
enum CameraControlLayout {
    static let buttonRowSideInset: CGFloat = 20
    static let parameterSideInset = buttonRowSideInset
    static let parameterGlassHeight: CGFloat = 46
    static let parameterBottom: CGFloat = 132
    static let compositionBottom: CGFloat = 224
    static let zoomBottom: CGFloat = 216
    static let shutterBottom: CGFloat = 28
    static let toolbarHeight: CGFloat = 49
    static let toolbarTopInset: CGFloat = 2
    static let toolbarContentInset: CGFloat = 5
    static let recordingTimerTopInset: CGFloat = 5
    static let upperButtonGap: CGFloat = 14
    /// Extra touch target around the small A/M, tools, and shooting-mode buttons.
    static let buttonHitExpansion: CGFloat = 8

    static func upperButtonOffset(diameter: CGFloat) -> CGFloat {
        -diameter - upperButtonGap
    }

}
