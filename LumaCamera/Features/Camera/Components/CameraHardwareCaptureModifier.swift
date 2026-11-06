import SwiftUI
import AVKit

/// Uses the system capture interaction rather than intercepting volume or touch events.
struct CameraHardwareCaptureModifier: ViewModifier {
    let enabled: Bool
    let silent: Bool
    let action: (AVCaptureEvent) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.onCameraCaptureEvent(isEnabled: enabled, defaultSoundDisabled: silent, action: action)
        } else {
            content.onCameraCaptureEvent(isEnabled: enabled, action: action)
        }
    }
}
