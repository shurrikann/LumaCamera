import UIKit
import Combine

/// Keep interface geometry portrait; rotate only opt-in control contents.
@MainActor
final class CaptureControlOrientation: ObservableObject {
    @Published private(set) var degrees = 0.0
    private var observer: AnyCancellable?
    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        update(UIDevice.current.orientation)
        observer = NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update(UIDevice.current.orientation) }
        #if DEBUG && targetEnvironment(simulator)
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-control-rotation=") }),
           let value = Double(arg.dropFirst("--preview-control-rotation=".count)), [0,90,-90,180].contains(value) { degrees = value }
        #endif
    }
    func update(_ orientation: UIDeviceOrientation) {
        guard let next = Self.angle(for: orientation) else { return }
        // Use the nearest equivalent angle; crossing upside-down never spins through 270°.
        degrees += Self.shortestDelta(from: degrees, to: next)
    }
    /// A newly opened media viewer must not inherit the camera's last sideways pose while flat.
    func resetForMediaPresentation(_ orientation: UIDeviceOrientation) {
        degrees = Self.angle(for: orientation) ?? 0
    }
    static func angle(for orientation: UIDeviceOrientation) -> Double? {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portraitUpsideDown: return 180
        default: return nil // Preserve direction while flat, rather than oscillating.
        }
    }
    static func shortestDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}
