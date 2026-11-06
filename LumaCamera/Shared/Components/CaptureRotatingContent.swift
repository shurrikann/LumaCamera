import SwiftUI

private struct CaptureControlAngleKey: EnvironmentKey { static let defaultValue = 0.0 }
// Independent of captureControlAngle, which the portrait-only gallery resets to zero.
private struct VideoPlaybackAngleKey: EnvironmentKey { static let defaultValue = 0.0 }
private struct LibraryMediaAngleKey: EnvironmentKey { static let defaultValue = 0.0 }
extension EnvironmentValues {
    var libraryMediaAngle: Double {
        get { self[LibraryMediaAngleKey.self] }
        set { self[LibraryMediaAngleKey.self] = newValue }
    }
    var videoPlaybackAngle: Double {
        get { self[VideoPlaybackAngleKey.self] }
        set { self[VideoPlaybackAngleKey.self] = newValue }
    }
    var captureControlAngle: Double {
        get { self[CaptureControlAngleKey.self] }
        set { self[CaptureControlAngleKey.self] = newValue }
    }
    var captureControlsLandscape: Bool { abs(sin(captureControlAngle * .pi / 180)) > 0.5 }
}
private struct CaptureRotatingContent: ViewModifier {
    @Environment(\.captureControlAngle) private var angle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: angle)
            .transaction { $0.disablesAnimations = false }
    }
}
extension View {
    func rotatingCaptureContent() -> some View { modifier(CaptureRotatingContent()) }
}

