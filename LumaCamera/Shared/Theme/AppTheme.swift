import SwiftUI
import UIKit

enum AppTheme {
    static let accentUIColor = UIColor(red: 201.0 / 255, green: 101.0 / 255, blue: 28.0 / 255, alpha: 1)
    static let accent = Color(uiColor: accentUIColor)
    static var popupAnimation: Animation {
        .easeInOut(duration: UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.22)
    }
    /// Text and icons drawn on the accent fill.
    static let accentForeground = Color(white: 0.06)
    static var frameAnimation: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.28) }
    static let cameraPopupMaterialOpacity = 0.66
    static let popupColor = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let popupOpacity = 0.86
    /// Dim only button content so the glass background stays legible while disabled.
    static let disabledControlOpacity = 0.46
    static var popupBackground: Color { popupColor.opacity(popupOpacity) }
}

/// A background fitted to the glyphs, leaving the parent layout and hit area in place.
private struct PreviewAccentLabel: ViewModifier {
    let active: Bool
    let inactive: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? AppTheme.accent : inactive)
            .background {
                if active {
                    Capsule()
                        .fill(.black.opacity(reduceTransparency ? 1 : 0.80))
                        .padding(.horizontal, -4)
                        .padding(.vertical, -2)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func previewAccentLabel(active: Bool = true, inactive: Color = .white) -> some View {
        modifier(PreviewAccentLabel(active: active, inactive: inactive))
    }
}
