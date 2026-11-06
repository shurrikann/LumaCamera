import Foundation

/// One pulse per crossed ruler tick; major ticks take priority and jitter is suppressed.
struct CameraRulerDetents {
    enum Feedback: Equatable { case tick, major }
    private var previous: Double?
    private var lastTick: Int?
    mutating func reset(at value: Double, range: ClosedRange<Double>, reversed: Bool) {
        previous = position(value, range: range, reversed: reversed); lastTick = nil
    }
    mutating func reset(atTick index: Int) { previous = Double(index); lastTick = nil }
    mutating func move(to value: Double, range: ClosedRange<Double>, reversed: Bool) -> Feedback? {
        guard let next = position(value, range: range, reversed: reversed) else { return nil }
        return move(toPosition: next)
    }
    mutating func move(toTick index: Int) -> Feedback? { move(toPosition: Double(index)) }

    private mutating func move(toPosition next: Double) -> Feedback? {
        guard let old = previous else { previous = next; return nil }
        previous = next
        guard old != next else { return nil }
        if let lastTick, abs(old - Double(lastTick)) > 0.4 { self.lastTick = nil }
        let lower = next < old ? Int(ceil(next)) : Int(floor(old)) + 1
        let upper = next < old ? Int(ceil(old)) - 1 : Int(floor(next))
        guard lower <= upper else { return nil }
        let crossed = (lower...upper).filter { $0 != lastTick }
        guard !crossed.isEmpty else { return nil }
        let major = crossed.filter { $0 % 5 == 0 }
        let chosen = (next > old ? major.last : major.first) ?? (next > old ? crossed.last! : crossed.first!)
        lastTick = chosen
        return chosen % 5 == 0 ? .major : .tick
    }
    private func position(_ value: Double, range: ClosedRange<Double>, reversed: Bool) -> Double? {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite, range.upperBound > range.lowerBound else { return nil }
        return CameraRulerMapping.fraction(value: value, range: range, reversed: reversed) * 100
    }
}

/// Produces the real value represented by each visible manual-parameter tick.
/// 手动参数刻度逐格对应实际数值，拖动时不再先连续映射再事后吸附。
enum CameraRulerTickValues {
    static func values(for parameter: CameraParameter, in range: ClosedRange<Double>) -> [Double] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return [] }
        if parameter == .shutter {
            let standardStops = CameraShutterStops.standardLog2Durations(in: range)
            // Keep a continuous ruler when the device exposes a narrow interval
            // that contains fewer than two familiar shutter detents.
            guard standardStops.count >= 2 else { return [] }
            let candidates = (standardStops + [range.lowerBound, range.upperBound]).sorted()
            return candidates.reduce(into: []) { result, value in
                if result.last.map({ abs($0 - value) > 0.000_001 }) ?? true { result.append(value) }
            }
        }
        let candidates: [Double]
        switch parameter {
        case .shutter: return []
        case .iso:
            candidates = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                          1_000, 1_250, 1_600, 2_000, 2_500, 3_200, 4_000, 5_000, 6_400, 8_000, 10_000,
                          12_800, 16_000, 20_000, 25_600, 32_000, 40_000, 51_200, 64_000, 80_000, 102_400]
        case .ev:
            candidates = stride(from: range.lowerBound, through: range.upperBound, by: 0.1).map { ($0 * 10).rounded() / 10 }
        case .focus:
            candidates = stride(from: range.lowerBound, through: range.upperBound, by: 0.01).map { ($0 * 100).rounded() / 100 }
        case .wb:
            candidates = stride(from: range.lowerBound, through: range.upperBound, by: 100).map { ($0 / 100).rounded() * 100 }
        case .tint:
            candidates = stride(from: range.lowerBound, through: range.upperBound, by: 1).map { $0.rounded() }
        }
        let sorted = ([range.lowerBound, range.upperBound] + candidates)
            .filter { $0.isFinite && range.contains($0) }
            .sorted()
        return sorted.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.000_001 }) ?? true { result.append(value) }
        }
    }

    static func nearestIndex(to value: Double, in values: [Double]) -> Int? {
        guard value.isFinite, !values.isEmpty else { return nil }
        return values.indices.min(by: { abs(values[$0] - value) < abs(values[$1] - value) })
    }
}

extension CameraRulerMapping {
    /// Keeps adjacent real ticks easy to reach while preserving context for dense scales.
    static func scale(tickCount: Int) -> CGFloat {
        guard tickCount > 1 else { return 3 }
        return min(3, max(0.28, CGFloat(tickCount - 1) * 0.03))
    }

    static func draggedTickIndex(originIndex: Int, translation: CGFloat, width: CGFloat,
                                 tickCount: Int, scale: CGFloat) -> Int {
        guard width.isFinite, width > 0, translation.isFinite, tickCount > 1,
              scale.isFinite, scale > 0 else { return originIndex }
        let tickDelta = Int((-translation / (width * scale) * CGFloat(tickCount - 1)).rounded())
        return min(max(originIndex + tickDelta, 0), tickCount - 1)
    }
}
