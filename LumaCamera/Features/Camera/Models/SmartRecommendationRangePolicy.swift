import Foundation

/// 推荐范围偏好，不控制镜头/对焦，也不把lensPosition换算成米。
/// 当前平台SDK约定0为最近焦端、1为最远焦端；不同镜头的实际距离不一致。
struct SmartRecommendationRangePolicy {
    private(set) var allowsRecommendations = false
    private var deviceID: String?
    private var lastSample = -Double.infinity
    private var pending: Bool?
    private var pendingSince: Double?

    mutating func reset() { self = Self() }
    mutating func update(position:Double?,adjusting:Bool,macro:Bool,deviceID:String?,sampleTime:Double?) -> Bool {
        if self.deviceID != deviceID { reset(); self.deviceID = deviceID }
        if macro {
            allowsRecommendations = false; pending = nil; pendingSince = nil
            return false
        }
        guard let deviceID, !deviceID.isEmpty, let sampleTime, sampleTime.isFinite,
              sampleTime > lastSample else { return allowsRecommendations }
        lastSample = sampleTime
        guard !adjusting, let position, position.isFinite, (0...1).contains(position) else {
            pending = nil; pendingSince = nil; return allowsRecommendations
        }
        // 近端排除与恢复分开，灰区保留状态；至少两个真实新读数且跨度0.25秒。
        let desired: Bool?
        if position <= 0.35 { desired = false }
        else if position >= 0.50 { desired = true }
        else { desired = nil }
        guard let desired, desired != allowsRecommendations else {
            pending = nil; pendingSince = nil; return allowsRecommendations
        }
        if pending != desired { pending = desired; pendingSince = sampleTime; return allowsRecommendations }
        if sampleTime-(pendingSince ?? sampleTime) >= 0.25 {
            allowsRecommendations = desired; pending = nil; pendingSince = nil
        }
        return allowsRecommendations
    }
}
