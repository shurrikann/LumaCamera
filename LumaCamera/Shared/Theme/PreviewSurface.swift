import SwiftUI

/// Keeps preview details visible beneath controls, independent of system material opacity.
struct PreviewSurface: ViewModifier {
    let radius: CGFloat
    var opacity: Double = 0.28
    var curve: RoundedCornerStyle = .continuous
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: curve)
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                content
                    .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.24), lineWidth: 0.65).allowsHitTesting(false))
            } else {
                content.background {
                    shape.fill(AppTheme.popupColor.opacity(reduceTransparency ? 0.96 : opacity))
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(shape.stroke(.white.opacity(0.26), lineWidth: 0.6))
                }
            }
        }
    }
}
