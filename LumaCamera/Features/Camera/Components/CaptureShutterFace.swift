import SwiftUI

struct CaptureShutterFace: View {
    enum Kind {
        case photo, video

        var fill: Color { self == .photo ? .white : .red }
        var stopColor: Color { self == .photo ? .red : .white }
        var loadingColor: Color { self == .photo ? .white : .black }
    }

    enum Center: Equatable {
        case none, countdown, stop, loading
    }

    let kind: Kind
    let center: Center
    var ready = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            // Keep the halo separate from the colored glass lens and center symbol.
            Circle().fill(Color.clear)
                .frame(width: 76, height: 76)
                .modifier(GlassSurface(radius: 38))
                .allowsHitTesting(false)
            Circle().stroke(.white.opacity(0.85), lineWidth: 3)
                .frame(width: 76, height: 76)
            glassLens
                .frame(width: 66, height: 66)
                .allowsHitTesting(false)
            if center != .none {
                RoundedRectangle(cornerRadius: 7)
                    .fill(center == .countdown ? .black : kind.stopColor)
                    .frame(width: 26, height: 26)
                    .overlay {
                        if center == .loading {
                            loadingIndicator
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.16), value: center)
    }

    private var faceColor: Color {
        ready || kind == .video ? kind.fill : .gray
    }

    private var glassLens: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                Circle().fill(faceColor.opacity(0.92))
                    .glassEffect(.clear.tint(faceColor.opacity(0.12)).interactive(), in: Circle())
            } else {
                Circle().fill(faceColor)
                    .overlay {
                        Circle().fill(LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
        }
        .overlay {
            Circle().fill(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.32),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.06), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            Circle().strokeBorder(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.90), location: 0),
                    .init(color: .white.opacity(0.18), location: 0.40),
                    .init(color: .black.opacity(0.12), location: 0.65),
                    .init(color: .white.opacity(0.48), location: 1)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
        }
    }

    @ViewBuilder private var loadingIndicator: some View {
        Group {
            if reduceMotion {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kind.loadingColor)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(kind.loadingColor)
            }
        }
        .frame(width: 18, height: 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
