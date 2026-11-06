import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(red: 231.0 / 255.0, green: 102.0 / 255.0, blue: 43.0 / 255.0)
    static var popupAnimation: Animation {
        .easeInOut(duration: UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.22)
    }
    static let manualParameterColor = accent
    /// Text and icons drawn on the accent fill.
    static let accentForeground = Color(red: 0.06, green: 0.06, blue: 0.06)
    static var frameAnimation: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.28) }
    static let cameraPopupMaterialOpacity = 0.66
    static let popupColor = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let popupOpacity = 0.86
    /// Dim only button content so the glass background stays legible while disabled.
    static let disabledControlOpacity = 0.46
    static var popupBackground: Color { popupColor.opacity(popupOpacity) }
}
