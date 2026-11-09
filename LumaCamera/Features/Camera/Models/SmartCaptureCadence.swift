import Foundation

/// 智拍分析轮询节奏。分析本身已有 in-flight 门控；这里只降低无主体、弹窗和低电量时的空转。
enum SmartCaptureCadence {
    static func interval(hasVisibleGuide: Bool, analysisAllowed: Bool,
                         lowPower: Bool, thermalSerious: Bool) -> TimeInterval {
        if !analysisAllowed { return 0.25 }
        if lowPower || thermalSerious { return hasVisibleGuide ? 0.10 : 0.20 }
        return hasVisibleGuide ? 1.0 / 15.0 : 1.0 / 8.0
    }
}
