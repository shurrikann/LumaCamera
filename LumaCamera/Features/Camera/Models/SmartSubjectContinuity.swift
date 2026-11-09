import Foundation

/// 智拍白点的身份迟滞：同一主体持续更新；新主体必须连续稳定一段时间才允许替换，
/// 短暂丢失时保留旧点，但标记为未验证，不能触发自动取景或对焦。
struct SmartSubjectContinuity {
    private var published: SmartCompositionGuide?
    private var publishedLastSeen: TimeInterval?
    private var candidateID: UUID?
    private var candidateSince: TimeInterval?

    let switchDwell: TimeInterval
    let holdDuration: TimeInterval

    init(switchDwell: TimeInterval = 0.60, holdDuration: TimeInterval = 0.65) {
        self.switchDwell = switchDwell
        self.holdDuration = holdDuration
    }

    mutating func reset() {
        published = nil
        publishedLastSeen = nil
        candidateID = nil
        candidateSince = nil
    }

    mutating func update(_ guide: SmartCompositionGuide?, at now: TimeInterval) -> SmartCompositionGuide? {
        guard let guide else {
            guard let value = published, let seen = publishedLastSeen,
                  now - seen <= holdDuration else {
                reset()
                return nil
            }
            var held = value
            held.trackingVerified = false
            return held
        }

        if let value = published, value.subjectID == guide.subjectID {
            published = guide
            publishedLastSeen = now
            candidateID = nil
            candidateSince = nil
            return guide
        }

        guard published != nil else {
            // 首个点也必须先通过纹理/对象验证，不能在错误目标上先点亮。
            guard guide.trackingVerified else { return nil }
            published = guide
            publishedLastSeen = now
            candidateID = nil
            candidateSince = nil
            return guide
        }

        if candidateID != guide.subjectID {
            candidateID = guide.subjectID
            candidateSince = now
        }
        let stable = candidateSince.map { now - $0 >= switchDwell } ?? false
        if stable, guide.trackingVerified {
            published = guide
            publishedLastSeen = now
            candidateID = nil
            candidateSince = nil
            return guide
        }

        guard let value = published, let seen = publishedLastSeen,
              now - seen <= holdDuration else {
            // 旧点已超过保留时间，新点又未确认：宁可暂时不显示，也不跳到未验证目标。
            reset()
            return nil
        }
        var held = value
        held.trackingVerified = false
        return held
    }
}
