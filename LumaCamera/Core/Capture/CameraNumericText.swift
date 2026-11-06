import Foundation

/// Hardware can briefly return indefinite times while camera inputs are switching.
enum CameraNumericText {
    static func integer(_ value: Double, positive: Bool = true) -> String {
        guard value.isFinite, !positive || value > 0,
              let integer = Int(exactly: value.rounded(.towardZero)) else { return "—" }
        return String(integer)
    }
    static func shutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denominator = (1 / seconds).rounded()
        guard denominator.isFinite, let value = Int(exactly: denominator), value > 0 else { return "—" }
        return "1/\(value)"
    }
}

/// Familiar photographic shutter stops used by the manual exposure control.
/// Values remain logarithmic so equal EV changes occupy equal distances on the ruler.
enum CameraShutterStops {
    private static let denominators: [Double] = [
        51_200, 40_000, 32_000, 25_600, 20_000, 16_000, 12_800, 10_000,
        8_000, 6_400, 5_000, 4_000, 3_200, 2_500, 2_000, 1_600, 1_250,
        1_000, 800, 640, 500, 400, 320, 250, 200, 160, 125, 100, 80,
        60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3, 2, 1
    ]

    static func log2Durations(in range: ClosedRange<Double>) -> [Double] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return [] }
        let standardStops = standardLog2Durations(in: range)
        let candidates = (standardStops + [range.lowerBound, range.upperBound])
            .filter { $0.isFinite && range.contains($0) }
            .sorted()
        return candidates.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.000_001 }) ?? true {
                result.append(value)
            }
        }
    }

    static func standardLog2Durations(in range: ClosedRange<Double>) -> [Double] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return [] }
        return denominators.map { log2(1.0 / $0) }.filter(range.contains)
    }

    static func snappedLog2Duration(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return value }
        let boundedValue = min(max(value, range.lowerBound), range.upperBound)
        // A narrow hardware range may contain no standard photographic stop.
        // In that case preserve continuous adjustment instead of snapping to an
        // artificial endpoint tick.
        let stops = standardLog2Durations(in: range)
        guard !stops.isEmpty else { return boundedValue }
        return stops.min(by: { abs($0 - boundedValue) < abs($1 - boundedValue) }) ?? boundedValue
    }
}
