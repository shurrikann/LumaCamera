import Foundation

/// Matches the dial's twelve logarithmic ticks per stop. Coalesces fast movement
/// into one pulse and suppresses repeated pulses from jitter around a tick.
struct ZoomDialDetents {
    enum Feedback: Equatable { case tick, anchor }
    private var previous: Double?
    private var lastTick: Int?
    private static let anchors: Set<Int> = [-12, 0, 12, 24, 36]

    mutating func reset(at zoom: CGFloat) {
        previous = Self.position(zoom)
        lastTick = nil
    }

    mutating func move(to zoom: CGFloat) -> Feedback? {
        guard let position = Self.position(zoom) else { return nil }
        guard let old = previous else { previous = position; return nil }
        previous = position
        guard old != position else { return nil }
        if let tick = lastTick, abs(old - Double(tick)) > 0.4 { lastTick = nil }
        let first = Int(floor(min(old, position))) + 1
        let last = Int(floor(max(old, position)))
        // Include a tick reached exactly when moving down, but exclude the starting tick.
        let lower = position < old ? Int(ceil(position)) : first
        let upper = position < old ? Int(ceil(old)) - 1 : last
        guard lower <= upper else { return nil }
        let crossed = (lower...upper).filter { $0 != lastTick }
        guard !crossed.isEmpty else { return nil }
        let anchors = crossed.filter { Self.anchors.contains($0) }
        let selected = (position > old ? anchors.last : anchors.first)
            ?? (position > old ? crossed.last! : crossed.first!)
        lastTick = selected
        return Self.anchors.contains(selected) ? .anchor : .tick
    }

    private static func position(_ zoom: CGFloat) -> Double? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        return log2(Double(zoom)) * 12
    }
}
