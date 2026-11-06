import SwiftUI

/// One material recipe for rounded panels, flat filter panels and the zoom wheel.
struct PopupGlassBackground<S: InsettableShape>: View {
    let shape: S
    var materialOpacity = AppTheme.cameraPopupMaterialOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                // Keep the dark glass identity without relying on backdrop blur.
                shape.fill(AppTheme.popupColor.opacity(0.96))
                    .overlay(shape.fill(Color(white: 0.17).opacity(0.55)))
            } else if #available(iOS 26.0, *) {
                shape.fill(Color.clear)
                    .glassEffect(.regular, in: shape)
                    // Keep the app's warm blue/orange palette subtle while letting
                    // the system material provide the refraction and depth.
                    .overlay(shape.fill(AppTheme.popupColor.opacity(0.12 * materialOpacity)))
                    .overlay(shape.fill(LinearGradient(colors: [AppTheme.accent.opacity(0.055), .clear],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
            } else {
                ZStack {
                    // A dark body keeps every popup black-gray over bright previews.
                    shape.fill(AppTheme.popupColor.opacity(0.22))
                    shape.fill(.ultraThinMaterial)
                        .opacity(materialOpacity)
                        .environment(\.colorScheme, .dark)
                    // Thickness: the upper face catches light, the lower face falls into shadow.
                    shape.fill(LinearGradient(stops: [
                        .init(color: Color(white: 0.56).opacity(0.17), location: 0),
                        .init(color: .clear, location: 0.36),
                        .init(color: .black.opacity(0.20), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    // Broad diagonal sheen from the lit top-left corner.
                    shape.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.13), location: 0),
                        .init(color: .white.opacity(0.035), location: 0.16),
                        .init(color: .clear, location: 0.42)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    // A soft bloom adds the rounded highlight of a thick glass face.
                    shape.fill(EllipticalGradient(colors: [
                        .white.opacity(0.16),
                        .white.opacity(0.045),
                        .clear
                    ], center: UnitPoint(x: 0.18, y: -0.04),
                       startRadiusFraction: 0,
                       endRadiusFraction: 0.52))
                    // Fine frosted grain breaks up the flat material.
                    GlassTexture.grain
                        .resizable(resizingMode: .tile)
                        .blendMode(.softLight)
                        .opacity(0.06)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
            }
        }
        .overlay { rim }
        .shadow(color: .black.opacity(0.34), radius: 22, x: 0, y: 9)
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
    }

    /// Bright contact edge plus a darker inner lip give the sheet real thickness.
    private var rim: some View {
        ZStack {
            shape.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(0.58), location: 0),
                .init(color: .white.opacity(0.18), location: 0.34),
                .init(color: .white.opacity(0.06), location: 0.7),
                .init(color: .white.opacity(0.32), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            shape.inset(by: 1).stroke(LinearGradient(colors: [
                .clear,
                .black.opacity(0.30)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }
}
