import SwiftUI

/// The library keeps portrait controls while its media follows the device.
enum LibraryMediaRotation {
    static func screenTranslation(_ translation: CGSize, angle: Double) -> CGSize {
        let radians = angle * .pi / 180
        return CGSize(width: translation.width * cos(radians) - translation.height * sin(radians),
                      height: translation.width * sin(radians) + translation.height * cos(radians))
    }
    static func canvasSize(_ viewport: CGSize, angle: Double) -> CGSize {
        abs(sin(angle * .pi / 180)) > 0.5
            ? CGSize(width: viewport.height, height: viewport.width) : viewport
    }

    /// A swipe belongs to the screen's horizontal axis, including inside a rotated canvas.
    static func pageStep(direction: UISwipeGestureRecognizer.Direction, angle: Double) -> Int? {
        let vector: CGPoint
        switch direction {
        case .left: vector = CGPoint(x: -1, y: 0)
        case .right: vector = CGPoint(x: 1, y: 0)
        case .up: vector = CGPoint(x: 0, y: -1)
        case .down: vector = CGPoint(x: 0, y: 1)
        default: return nil
        }
        let x = screenTranslation(CGSize(width: vector.x, height: vector.y), angle: angle).width
        guard abs(x) > 0.5 else { return nil }
        return x < 0 ? 1 : -1
    }
}

struct LibraryMediaCanvas<Content: View>: View {
    let angle: Double
    @ViewBuilder var content: (CGSize) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = LibraryMediaRotation.canvasSize(geometry.size, angle: angle)
            content(size)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(angle))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: angle)
        }.clipped()
    }
}

/// Fill the fixed thumbnail slot; original aspect-fit media belongs to detail pages.
struct LibraryMediaThumbnail: View {
    let image: UIImage
    @Environment(\.libraryMediaAngle) private var angle
    var body: some View {
        LibraryMediaCanvas(angle: angle) { size in
            Image(uiImage: image).resizable().scaledToFill().allowedDynamicRange(.high)
                .frame(width: size.width, height: size.height).clipped()
        }
    }
}

/// Read the installed camera environment at the thumbnail, including isolated control hosts.
struct CaptureAlbumThumbnail: View {
    let image: UIImage
    @Environment(\.captureControlAngle) private var angle
    var body: some View {
        LibraryMediaThumbnail(image: image).environment(\.libraryMediaAngle, angle)
    }
}


/// A clear lens keeps the album photo visible beneath the reflective surface.
struct CaptureAlbumGlassSurface: ViewModifier {
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        lens(content)
            .overlay {
                Circle().fill(LinearGradient(
                    colors: [.white.opacity(0.10), .clear, .black.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle().strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.65), .white.opacity(0.10), .white.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder private func lens(_ content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(interactive ? .clear.interactive() : .clear, in: Circle())
        } else {
            content.background(Circle().fill(Color(white: 0.12)))
        }
    }
}
