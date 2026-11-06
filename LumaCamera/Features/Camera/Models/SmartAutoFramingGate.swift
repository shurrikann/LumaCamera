import CoreGraphics
import Foundation

/// 每轮稳定对齐取景一次；圈外恢复引导，拍照成功由模型显式开启下一轮。
struct SmartAutoFramingGate {
    private(set) var completed = false
    private(set) var alignmentConfirmed = false
    private var alignedSince: TimeInterval?
    private var missingSince: TimeInterval?
    private var anchor: CGPoint?
    private var height: CGFloat?
    private var pausedSince: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func finish() { completed = true; missingSince = nil; interrupt() }
    mutating func interrupt() { alignedSince = nil; anchor = nil; height = nil; pausedSince = nil; alignmentConfirmed = false }
    private mutating func pause(at now: TimeInterval) {
        guard alignedSince != nil else { return }
        if pausedSince == nil { pausedSince = now }
        if now - (pausedSince ?? now) > 0.20 { interrupt() }
    }
    mutating func update(_ guide: SmartCompositionGuide?, at now: TimeInterval) -> Bool {
        guard let guide, guide.trackingVerified else {
            if completed { return false }
            if missingSince == nil { missingSince = now }
            if let since = missingSince, now - since >= 1.5 { reset() }
            pause(at: now); return false
        }
        let distance = guide.alignmentDistance
        if completed {
            // 只用对齐容差，不等待换场景/延时；容差内手抖不反复显示，超出即恢复。
            if distance > SmartCompositionGuide.alignmentRadius * 1.6 { reset() }
            return false
        }
        missingSince = nil
        guard distance <= SmartCompositionGuide.alignmentRadius else {
            if distance <= SmartCompositionGuide.alignmentRadius * 1.15 { pause(at: now) }
            else { interrupt() }
            return false
        }
        if let pausedSince {
            let gap = now - pausedSince
            if gap > 0.20 { interrupt() }
            else if let since = alignedSince { alignedSince = since + max(0, gap); self.pausedSince = nil }
        }
        if let anchor, let height,
           (hypot(guide.subject.x-anchor.x,guide.subject.y-anchor.y) > 0.025
            || abs(guide.subjectRect.height-height) > max(0.015,height*0.15)) { interrupt() }
        if alignedSince == nil { alignedSince = now; anchor = guide.subject; height = guide.subjectRect.height }
        // 和上一张确认帧比较，允许圈内小幅手持漂移；不把累计漂移误判为一直在运动。
        anchor = guide.subject; height = guide.subjectRect.height
        let confirmedSeconds = now - (alignedSince ?? now)
        alignmentConfirmed = confirmedSeconds >= 0.18
        return confirmedSeconds >= 0.75
    }
}
