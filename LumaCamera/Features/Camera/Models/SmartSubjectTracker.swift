import CoreGraphics
import Foundation
import Vision
import QuartzCore

/// 仅在智拍串行队列使用。候选被提名后按官方序列跟踪，不每帧重选“最大的框”。
final class SmartSubjectTracker: @unchecked Sendable {
    private struct Target {
        let id:UUID
        let request:VNTrackObjectRequest
        var guide:SmartCompositionGuide
        let feature:SmartFeatureAnchor
        var appearance:SmartSubjectAppearance?
        var consecutiveLocalConfirmations = 0
        var appearanceRefreshedAt:TimeInterval = -.infinity
        var anchor:CGPoint // 左上起点，纹理锚点而非持续变化的对象框中心。
        var trackingRect:CGRect
        var lastConfirmed:TimeInterval
        var lastObserved:TimeInterval
        var objectTrackedThisFrame = false
        var preserveSceneContext = false
    }
    private var context = ""
    private var handler = VNSequenceRequestHandler()
    private var targets:[Target] = []
    private var selected:UUID?
    private var batchLocked = false
    private var emptySince:TimeInterval?
    private var semanticPreferredID: UUID?
    func hasTrackedTargets(context: String) -> Bool { self.context == context && !targets.isEmpty }
    struct Result {
        let selected:SmartCompositionGuide?
        let candidates:[SmartCompositionGuide]
        var retainedCount = 0
        var objectTrackedCount = 0
        var appearanceVerifiedCount = 0
    }
    func update(image:CGImage,candidates:[SmartCompositionGuide],context:String,at now:TimeInterval = CACurrentMediaTime()) -> Result {
        if self.context != context { self.context = context; handler = VNSequenceRequestHandler(); targets = []; selected = nil; semanticPreferredID = nil; batchLocked = false; emptySince = nil }
        guard let frame = SmartFeatureAnchor.Frame(image) else { return Result(selected:nil,candidates:[]) }
        var appearanceVerifiedCount = 0
        if !targets.isEmpty {
            var succeeded = true
            do { try handler.perform(targets.map(\.request),on:image,orientation:.up) }
            catch { succeeded = false }
            for i in targets.indices {
                let observation = succeeded ? targets[i].request.results?.first as? VNDetectedObjectObservation : nil
                let valid = observation.flatMap {
                    $0.confidence >= 0.5 && SmartTrackingContinuity.isContinuous(from:targets[i].trackingRect,to:$0.boundingBox) ? $0 : nil
                }
                let rect = valid?.boundingBox ?? targets[i].trackingRect
                let oldRect = targets[i].trackingRect
                // 局部纹理短暂漏检时，显示点仍随同一对象框平移/缩放，不能冻结在屏幕坐标。
                let predicted = SmartTrackingContinuity.project(targets[i].anchor,from:oldRect,to:rect)
                targets[i].objectTrackedThisFrame = valid != nil
                // 显示身份由持续有效的系统对象跟踪维持；小纹理复核失败只暂停自动动作，
                // 不能在系统仍跟住同一有结构物体时，按纹理超时反复删点/重新分配身份。
                if let valid,valid.confidence >= 0.8,SmartSubjectAppearance(frame:frame,rect:rect) != nil {
                    targets[i].lastObserved = now
                }
                // 即使纹理复核短暂失败，也继续官方跟踪序列；不能反复用上一旧帧作为输入。
                if let valid {
                    targets[i].request.inputObservation = valid
                    targets[i].trackingRect = rect
                }
                if let point = targets[i].feature.match(in:frame,near:predicted),
                   rect.insetBy(dx:-0.03,dy:-0.03).contains(CGPoint(x:point.x,y:1-point.y)) {
                    targets[i].lastConfirmed = now; targets[i].anchor = point
                    targets[i].consecutiveLocalConfirmations += 1
                    // 原始局部模板始终不学习；只有连续两帧被它独立确认且系统仍可靠跟踪，
                    // 才低频更新整体辅助模板，避免初次AF前的模糊关键帧一直造成后续漏检。
                    if let valid,valid.confidence >= 0.8,targets[i].consecutiveLocalConfirmations >= 2,
                       now-targets[i].appearanceRefreshedAt >= 0.5,
                       let appearance = SmartSubjectAppearance(frame:frame,rect:rect) {
                        targets[i].appearance = appearance;targets[i].appearanceRefreshedAt = now
                    }
                    targets[i].guide = Self.guide(rect:rect,kind:targets[i].guide.subjectKind,id:targets[i].id,aspect:targets[i].guide.imageAspect,point:point)
                } else if let valid,valid.confidence >= 0.8,
                          targets[i].appearance?.matches(frame:frame,rect:rect) == true {
                    // 必须同时满足官方对象框高置信连续跟踪与原对象整体像素结构一致。
                    // 这与只有预测框的显示宽限不同，不能仅因框还在就视为确认。
                    appearanceVerifiedCount += 1
                    targets[i].consecutiveLocalConfirmations = 0
                    targets[i].lastConfirmed = now;targets[i].anchor = predicted
                    targets[i].guide = Self.guide(rect:rect,kind:targets[i].guide.subjectKind,id:targets[i].id,aspect:targets[i].guide.imageAspect,point:predicted)
                } else {
                    targets[i].consecutiveLocalConfirmations = 0
                    // 只给短漏检保留身份；有效框可携带同一锚点，不能用预测位置触发自动操作。
                    targets[i].anchor = predicted
                    targets[i].guide = Self.guide(rect:rect,kind:targets[i].guide.subjectKind,id:targets[i].id,aspect:targets[i].guide.imageAspect,point:predicted)
                    targets[i].guide.trackingVerified = false
                }
                targets[i].guide.preserveSceneContext = targets[i].preserveSceneContext
            }
            // 身份保留与显示宽限分开；短暂遮挡恢复时不重新分配UUID或在别处补点。
            targets.removeAll { now - max($0.lastConfirmed,$0.lastObserved) >= SmartTrackingContinuity.identityGrace }
        }
        // 对齐过程中冻结本批候选，不因一个点丢失就立即在别处补点。
        if targets.isEmpty && batchLocked {
            if emptySince == nil { emptySince = now }
            if now-(emptySince ?? now) >= 0.8 { batchLocked = false; selected = nil; emptySince = nil }
        }
        for candidate in batchLocked ? [] : candidates {
            guard targets.count < 3 else { break }
            guard !targets.contains(where:{ SmartCaptureAnalyzer.overlap($0.guide.subjectRect,candidate.subjectRect) > 0.4 }) else { continue }
            guard let (feature,anchor) = SmartFeatureAnchor.seed(in:frame,rect:candidate.subjectRect) else { continue }
            let id = UUID(), observation = VNDetectedObjectObservation(boundingBox:candidate.subjectRect)
            let request = VNTrackObjectRequest(detectedObjectObservation:observation); request.trackingLevel = .accurate
            try? handler.perform([request],on:image,orientation:.up)
            if let seeded = request.results?.first as? VNDetectedObjectObservation { request.inputObservation = seeded }
            targets.append(Target(id:id,request:request,guide:Self.guide(rect:candidate.subjectRect,kind:candidate.subjectKind,id:id,aspect:candidate.imageAspect,point:anchor),feature:feature,
                appearance:SmartSubjectAppearance(frame:frame,rect:candidate.subjectRect),anchor:anchor,trackingRect:candidate.subjectRect,lastConfirmed:now,lastObserved:now))
        }
        if !targets.isEmpty { batchLocked = true; emptySince = nil }
        let visible = targets.filter {
            SmartTrackingContinuity.canDisplay(point:$0.anchor,age:now-max($0.lastConfirmed,$0.lastObserved),
                objectTracked:$0.objectTrackedThisFrame)
        }.map(\.guide)
        selected = Self.selectedID(candidates:visible,previous:selected,retained:Set(targets.map(\.id)),preferred:semanticPreferredID)
        return Result(selected:visible.first { $0.subjectID == selected },candidates:visible,retainedCount:targets.count,
            objectTrackedCount:targets.filter(\.objectTrackedThisFrame).count,appearanceVerifiedCount:appearanceVerifiedCount)
    }
    @discardableResult func applyAdvice(_ advice: SmartLocalCompositionAI.Advice, context: String) -> Bool {
        guard self.context == context, let index = targets.firstIndex(where: { $0.id == advice.subjectID }) else { return false }
        semanticPreferredID = advice.subjectID
        targets[index].preserveSceneContext = advice.preserveSceneContext
        return true
    }
    static func selectedID(candidates:[SmartCompositionGuide],previous:UUID?,retained:Set<UUID>,preferred:UUID? = nil) -> UUID? {
        let verified = candidates.filter(\.trackingVerified)
        // “任一白点进圈”使用绘制圆圈的真实门限，旧0.15锁定区会挡住另一个已进圈的点。
        if let previous, verified.contains(where: { $0.subjectID == previous && $0.alignmentDistance <= SmartCompositionGuide.alignmentRadius }) { return previous }
        if let aligned = verified.filter({ $0.alignmentDistance <= SmartCompositionGuide.alignmentRadius })
            .min(by:{ $0.alignmentDistance < $1.alignmentDistance }) { return aligned.subjectID }
        if let previous, verified.contains(where:{ $0.subjectID == previous && $0.alignmentDistance <= SmartCompositionGuide.alignmentRadius * 1.6 }) { return previous }
        if let preferred, verified.contains(where:{ $0.subjectID == preferred }) { return preferred }
        if let previous, retained.contains(previous) { return previous }
        return verified.min(by:{ $0.alignmentDistance < $1.alignmentDistance })?.subjectID
    }
    private static func guide(rect:CGRect,kind:SmartCompositionGuide.SubjectKind,id:UUID,aspect:CGFloat,point:CGPoint) -> SmartCompositionGuide {
        let distance = hypot((point.x-0.5)*aspect,point.y-0.5)/min(1,aspect)
        return SmartCompositionGuide(stage:.align,direction:.align,subject:point,target:CGPoint(x:0.5,y:0.5),
            text:distance <= SmartCompositionGuide.alignmentRadius ? "已对准中心" : "先对准中心",
            subjectRect:rect,subjectKind:kind,subjectID:id,imageAspect:aspect)
    }
}

/// 项目显示策略，不是Vision平台保证。未通过纹理复核的预测点始终标为未确认，不能触发相机动作。
enum SmartTrackingContinuity {
    static let identityGrace: TimeInterval = 1.2
    static let trackedObjectGrace: TimeInterval = 0.65
    static let missingObjectGrace: TimeInterval = 0.32

    static func canDisplay(point:CGPoint,age:TimeInterval,objectTracked:Bool) -> Bool {
        guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y),
              age.isFinite,age >= 0 else { return false }
        return age <= (objectTracked ? trackedObjectGrace : missingObjectGrace)
    }

    /// 拒绝异常跳框或突变尺度，不能以宽限为由继续画到另一个物体上。
    static func isContinuous(from old:CGRect,to next:CGRect) -> Bool {
        guard next.minX.isFinite,next.minY.isFinite,next.width.isFinite,next.height.isFinite,
              old.width > 0,old.height > 0,next.width > 0.01,next.height > 0.01,
              (0.5...2).contains(next.width/old.width),(0.5...2).contains(next.height/old.height) else { return false }
        let search = old.insetBy(dx:-max(0.06,old.width*0.5),dy:-max(0.06,old.height*0.5))
        return search.contains(CGPoint(x:next.midX,y:next.midY))
    }

    /// Vision框为左下起点，显示锚点为左上起点；保留其在物体框内的相对位置。
    static func project(_ point:CGPoint,from old:CGRect,to next:CGRect) -> CGPoint {
        guard old.width > 0,old.height > 0 else { return point }
        let x = (point.x-old.minX)/old.width
        let y = (point.y-(1-old.maxY))/old.height
        return CGPoint(x:next.minX+x*next.width,y:1-next.maxY+y*next.height)
    }
}
