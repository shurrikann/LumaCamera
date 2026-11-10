import Foundation

/// Caps only preview publication under power/thermal pressure. Capture and
/// recording frame rates stay untouched, so the delivered file keeps its spec.
enum PreviewPowerPolicy {
    static let constrainedRate = 30

    static func cappedRate(_ requested: Int?,
                           lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Int {
        let rate = min(60, max(1, requested ?? 30))
        guard lowPower || thermal == .serious || thermal == .critical else { return rate }
        return min(rate, constrainedRate)
    }
}
