import Foundation

/// 夜景M挡的应用调节范围，并非Apple给出的Night mode规格；始终与镜头真实范围相交。
enum NightManualExposurePolicy {
    /// 手动ISO×快门不是环境测光；用系统实际曝光相对目标的偏差消除人为过曝/欠曝的影响。
    static func meteringBias(userBias: Double, customExposure: Bool, offsetEV: Double?) -> Double? {
        guard userBias.isFinite else { return nil }
        guard customExposure else { return userBias }
        guard let offsetEV, offsetEV.isFinite else { return nil }
        return userBias+offsetEV
    }
    static func isoRange(hardware: ClosedRange<Double>) -> ClosedRange<Double> {
        intersection(100...3200,hardware:hardware) ?? hardware
    }
    static func shutterRange(hardware: ClosedRange<Double>) -> ClosedRange<Double> {
        intersection(log2(1.0/30)...0,hardware:hardware) ?? hardware
    }
    private static func intersection(_ requested: ClosedRange<Double>,hardware: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lower = max(requested.lowerBound,hardware.lowerBound), upper = min(requested.upperBound,hardware.upperBound)
        return lower<=upper ? lower...upper : nil
    }
}
