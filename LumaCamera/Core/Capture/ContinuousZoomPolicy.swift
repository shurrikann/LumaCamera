import Foundation
import CoreImage
import UIKit

enum ContinuousZoomPolicy {
    static func range(_ cameras: [LensZoomCapabilities]) -> ClosedRange<CGFloat> {
        let valid = cameras.filter { $0.baseZoom > 0 && $0.maximum >= $0.minimum }
        guard let low = valid.map({ $0.baseZoom * $0.minimum }).min(),
              let high = valid.map({ $0.baseZoom * $0.maximum }).max() else { return 1...1 }
        return low...max(low, min(high, 40))
    }
    static func draggedValue(origin: CGFloat, translation: CGFloat, width: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard origin.isFinite, translation.isFinite else { return range.lowerBound }
        let value = origin * pow(2, -translation / max(width, 1) * 3)
        return min(max(value, range.lowerBound), range.upperBound)
    }
    /// AVFoundation's rate is in powers of two per second, not factor units/sec.
    static func animatedRampRate(current: CGFloat, target: CGFloat) -> Float {
        guard current.isFinite, target.isFinite, current > 0, target > 0 else { return 4 }
        return Float(min(96, max(4, abs(log2(target/current))/0.08)))
    }
    static func demoFrame(_ source: CIImage, zoom: CGFloat) -> CIImage {
        let factor = min(max(zoom, 1), 5)
        let rect = CGRect(x: source.extent.midX - source.extent.width / factor / 2,
                          y: source.extent.midY - source.extent.height / factor / 2,
                          width: source.extent.width / factor, height: source.extent.height / factor)
        return source.cropped(to: rect)
    }
}


/// Feeds the same direct zoom route as the wheel on a fixed display-clock timeline.
@MainActor final class FocalZoomAnimation {
    static let duration: TimeInterval = 0.5
    @MainActor private final class Target: NSObject {
        weak var owner: FocalZoomAnimation?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private var link: CADisplayLink?
    private let target = Target()
    private var began: CFTimeInterval = 0
    private var origin: CGFloat = 1
    private var destination: CGFloat = 1
    private var update: ((CGFloat) -> Void)?
    private(set) var isRunning = false
    private(set) var elapsed: TimeInterval = 0
    func start(from: CGFloat, to: CGFloat, update: @escaping (CGFloat) -> Void) {
        cancel()
        guard from.isFinite, to.isFinite, from > 0, to > 0 else { return }
        origin = from; destination = to; self.update = update
        began = CACurrentMediaTime(); elapsed = 0; isRunning = true
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    private func tick(_ link: CADisplayLink) {
        elapsed = max(0, link.targetTimestamp-began)
        let t = min(1, elapsed/Self.duration)
        let eased = t*t*(3-2*t)
        let value = origin * pow(destination/origin, eased)
        update?(t >= 1 ? destination : value)
        if t >= 1 { cancel() }
    }
    func cancel() {
        link?.invalidate(); link = nil; update = nil; isRunning = false
    }
    deinit { link?.invalidate() }
}
