import SwiftUI

struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var previewOverlay = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if previewOverlay {
            content.modifier(PreviewSurface(radius: radius))
        } else if #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .glassEffect(.regular.interactive(), in: shape)
                .overlay(shape.stroke(.white.opacity(0.24), lineWidth: 0.65).allowsHitTesting(false))
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content.background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color(red: 0.30, green: 0.30, blue: 0.30).opacity(0.52)))
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.07), .white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            }.shadow(color: Color(red: 0.02, green: 0.02, blue: 0.02).opacity(0.30), radius: 8, y: 4)
        }
    }
}

