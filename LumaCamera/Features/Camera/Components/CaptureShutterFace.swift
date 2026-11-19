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

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.85), lineWidth: 3)
                .frame(width: 76, height: 76)
            Circle().fill(ready || kind == .video ? kind.fill : .gray)
                .frame(width: 66, height: 66)
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
