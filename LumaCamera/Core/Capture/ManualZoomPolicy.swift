import CoreGraphics

/// A selected preset owns its physical camera throughout continuous manual zoom.
enum ManualZoomPolicy {
    static func range(anchor: CGFloat, physicalBase: CGFloat, minimum: CGFloat, maximum: CGFloat) -> ClosedRange<CGFloat> {
        guard anchor.isFinite, physicalBase.isFinite, minimum.isFinite, maximum.isFinite,
              anchor > 0, physicalBase > 0, minimum > 0, maximum >= minimum else { return 1...1 }
        let low = max(anchor, physicalBase * minimum)
        return low...max(low, min(anchor * 5, physicalBase * maximum, 40))
    }
}
