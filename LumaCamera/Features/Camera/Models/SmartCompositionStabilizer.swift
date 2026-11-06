import CoreGraphics
import Foundation

/// 跟踪点直接跟随物体；只对提示/阶段切换使用迟滞，不更改相机状态。
struct SmartCompositionStabilizer {
    private var published: SmartCompositionGuide?
    private var smoothedTarget: CGPoint?
    private var pendingKey: String?
    private var pendingSince: TimeInterval?
    private var lastSeen: TimeInterval?
    private let smoothing = 0.5
    private let stageDwell: TimeInterval = 0.8
    private let directionDwell: TimeInterval = 0.45
    private let missingGrace: TimeInterval = 0.18

    mutating func reset() {
        published = nil
        smoothedTarget = nil
        pendingKey = nil
        pendingSince = nil
        lastSeen = nil
    }

    mutating func update(_ raw: SmartCompositionGuide?, at now: TimeInterval) -> SmartCompositionGuide? {
        guard let raw else {
            if let lastSeen, now - lastSeen > missingGrace {
                reset()
                return nil
            }
            return published.map { value in
                var held = value; held.trackingVerified = false; return held
            }
        }
        lastSeen = now
        // 已经由纹理确认的坐标直接跟随视频；再次低通会让点落在物体的旧位置。
        let subject = raw.subject
        let target = smooth(raw.target, previous: &smoothedTarget)
        guard let published else {
            let first = guide(raw, subject: subject, target: target)
            self.published = first
            return first
        }

        let candidate = guide(raw, subject: subject, target: target)
        let key = "\(candidate.stage.rawValue)|\(candidate.direction.rawValue)|\(candidate.text)"
        let required: TimeInterval = candidate.stage != published.stage ? stageDwell : directionDwell
        if key != pendingKey {
            pendingKey = key
            pendingSince = now
        }
        if candidate.stage == published.stage, candidate.direction == published.direction, candidate.text == published.text {
            // Same instruction: keep points live without waiting.
            self.published = candidate
            pendingKey = nil
            pendingSince = nil
            return candidate
        }
        if let pendingSince, now - pendingSince >= required {
            self.published = candidate
            pendingKey = nil
            self.pendingSince = nil
            return candidate
        }
        // Hold the previous stage/direction while the new one stabilizes.
        // Crucially, keep the old target: while aligning, the crosshair must
        // stay at the preview centre, not jump to the incoming thirds target.
        var held = guide(published, subject: subject, target: published.target)
        held.trackingVerified = raw.trackingVerified
        self.published = held
        return held
    }

    private func smooth(_ point: CGPoint, previous: inout CGPoint?) -> CGPoint {
        guard let value = previous else { previous = point; return point }
        let next = CGPoint(x: value.x + (point.x - value.x) * smoothing,
                           y: value.y + (point.y - value.y) * smoothing)
        previous = next
        return next
    }

    private func guide(_ base: SmartCompositionGuide, subject: CGPoint, target: CGPoint) -> SmartCompositionGuide {
        SmartCompositionGuide(stage: base.stage, direction: base.direction,
                              subject: subject, target: target, text: base.text,
                              subjectRect: base.subjectRect, subjectKind:base.subjectKind,subjectID:base.subjectID,imageAspect:base.imageAspect,
                              trackingVerified: base.trackingVerified,preserveSceneContext:base.preserveSceneContext)
    }
}
