import SwiftUI

/// Rotate the complete card, including its glass, rather than separate labels.
/// The caller retains its screen anchor; oversized card content remains scrollable.
private struct OrientedPopup: ViewModifier {
    var maximumWidth: CGFloat
    @Environment(\.captureControlAngle) private var angle
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var naturalHeight: CGFloat = 240
    @State private var renderedLandscape: Bool?
    @State private var cardOpacity: Double = 1
    @State private var cardScale: CGFloat = 1
    @State private var cardTilt: Double = 0
    @State private var orientationToken = UUID()

    func body(content: Content) -> some View {
        Group {
            if renderedLandscape ?? landscape {
                landscapePopup(content)
            } else {
                content
            }
        }
        .opacity(cardOpacity)
        .scaleEffect(cardScale)
        .rotationEffect(.degrees(cardTilt))
        .allowsHitTesting(cardOpacity > 0.99)
        .onAppear {
            if renderedLandscape == nil { renderedLandscape = landscape }
        }
        .onChange(of: landscape) { _, next in
            transitionOrientation(to: next)
        }
    }

    /// Fade the old layout out, swap to the new layout while it is invisible,
    /// then fade the new card in. This keeps the reflow from looking like a snap.
    private func transitionOrientation(to next: Bool) {
        let token = UUID()
        orientationToken = token
        let outDuration = reduceMotion ? 0.08 : 0.14
        let inDuration = reduceMotion ? 0.10 : 0.20

        guard (renderedLandscape ?? !next) != next else {
            withAnimation(.easeOut(duration: inDuration)) {
                cardOpacity = 1
                cardScale = 1
                cardTilt = 0
            }
            return
        }

        withAnimation(.easeIn(duration: outDuration)) {
            cardOpacity = 0
            cardScale = 0.95
            cardTilt = next ? -10 : 10
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int((outDuration + 0.01) * 1000)))
            guard orientationToken == token else { return }
            renderedLandscape = next
            cardScale = 0.97
            cardTilt = next ? 5 : -5
            withAnimation(.easeOut(duration: inDuration)) {
                cardOpacity = 1
                cardScale = 1
                cardTilt = 0
            }
        }
    }

    private func landscapePopup(_ content: Content) -> some View {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow
        let size = window?.bounds.size ?? CGSize(width: 390, height: 844)
        let width = min(maximumWidth, max(240, size.height - 220))
        let height = min(max(1, naturalHeight), max(120, size.width - 28))
        return ScrollView(.vertical) {
            content.environment(\.captureControlAngle, 0).frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs(naturalHeight - $0) > 0.5 { naturalHeight = $0 } }
        }.scrollBounceBehavior(.basedOnSize)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .rotationEffect(.degrees(angle))
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.26), value: angle)
            .frame(width: height, height: width)
    }
}
extension View {
    func orientedPopup(maximumWidth: CGFloat = 500) -> some View { modifier(OrientedPopup(maximumWidth: maximumWidth)) }
}

/// A presented settings sheet owns its own bounded rectangle; fit the rotated form
/// inside that rectangle, without rotating the camera or gallery underneath it.
private struct RotatingSheetContent: ViewModifier {
    @Environment(\.captureControlAngle) private var angle
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content.environment(\.captureControlAngle, 0)
                .frame(width: landscape ? geometry.size.height : geometry.size.width,
                       height: landscape ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(angle))
                .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.26), value: angle)
                .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.26), value: landscape)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
extension View {
    func rotatingSheetContent() -> some View { modifier(RotatingSheetContent()) }
}
