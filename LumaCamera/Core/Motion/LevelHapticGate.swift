import Foundation

/// Hysteresis, a short stable hold and cooldown prevent chatter around the level threshold.
struct LevelHapticGate {
    private var wasLevel: Bool?
    private var candidateSince: Double?
    private var lastFeedback = -Double.infinity
    mutating func update(roll: Double, time: Double, enabled: Bool) -> Bool {
        guard enabled, roll.isFinite, time.isFinite else { wasLevel = nil; candidateSince = nil; return false }
        let angle = abs(roll)
        if wasLevel == nil { wasLevel = angle < 0.025; return false }
        if wasLevel == true {
            if angle > 0.05 { wasLevel = false }
            return false
        }
        guard angle < 0.025 else { candidateSince = nil; return false }
        if candidateSince == nil { candidateSince = time }
        guard time - (candidateSince ?? time) >= 0.2 else { return false }
        wasLevel = true; candidateSince = nil
        guard time - lastFeedback >= 1 else { return false }
        lastFeedback = time
        return true
    }
}
