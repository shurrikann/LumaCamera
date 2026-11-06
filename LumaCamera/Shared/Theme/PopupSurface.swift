import SwiftUI

/// Shared background for application panels; in-preview controls keep their lighter surface.
struct PopupSurface: ViewModifier {
    let radius: CGFloat
    var glass = false
    var materialOpacity = 1.0
    var bottomRadius: CGFloat? = nil

    func body(content: Content) -> some View {
        if glass {
            if let bottomRadius {
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: radius,
                    bottomLeadingRadius: bottomRadius,
                    bottomTrailingRadius: bottomRadius,
                    topTrailingRadius: radius,
                    style: .continuous)
                content.background { PopupGlassBackground(shape: shape, materialOpacity: materialOpacity) }
            } else {
                content.background { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), materialOpacity: materialOpacity) }
            }
        } else {
            content.modifier(PreviewSurface(radius: radius, opacity: AppTheme.popupOpacity))
        }
    }
}
