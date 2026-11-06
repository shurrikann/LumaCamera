import Foundation
import UIKit
import Vision

/// 后台候选评分有独立取消令牌。离开页面/手动操作时取消Vision请求，不等结果再改相机。
final class SmartFramingWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func setRequest(_ value:VNRequest?) {
        lock.lock(); request = value; let stop = cancelled; lock.unlock()
        if stop { value?.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let current = request; lock.unlock(); current?.cancel() }
}

/// 官方Vision美学评分只用于排列有限候选，不保证“最佳构图”，也不等同其他厂商算法。
/// 每次稳定对齐最多评估4幅；保留主体边缘，不做拍后裁切或云端上传。
enum SmartFramingEvaluator {
    struct Evaluation { let recommendation:SmartFramingRecommendation?; let scores:[Double] }
    static func candidates(guide:SmartCompositionGuide,currentZoom:CGFloat,range:ClosedRange<CGFloat>) -> [SmartFramingRecommendation] {
        let box = guide.subjectRect
        guard box.width > 0, box.height > 0, currentZoom.isFinite, currentZoom > 0 else { return [] }
        if guide.preserveSceneContext { return [.init(zoom:currentZoom,cropScale:1)] }
        let target:CGSize
        switch guide.subjectKind {
        case .face: target = CGSize(width:0.32,height:0.24) // 未检出身体时保留更多环境，避免大头裁切。
        case .person: target = CGSize(width:0.68,height:0.76)
        case .group: target = CGSize(width:0.80,height:0.72)
        case .salient:
            target = box.height > box.width*1.35 ? CGSize(width:0.70,height:0.76) : CGSize(width:0.82,height:0.66)
        }
        let desired = min(target.width/box.width,target.height/box.height)
        let maximum = min(range.upperBound,currentZoom*4)
        let optimal = min(maximum,max(currentZoom,currentZoom*desired))
        var result:[SmartFramingRecommendation] = []
        let proposed = desired > 1.08 ? [currentZoom,sqrt(currentZoom*optimal),optimal,min(maximum,optimal*1.12)] : [currentZoom]
        for zoom in proposed {
            guard zoom >= range.lowerBound, zoom <= range.upperBound else { continue }
            let scale = currentZoom/zoom
            // 中心变焦必须完整容纳主体及少量留白；不会裁去头顶或建筑尖端。
            let crop = CGRect(x:(1-scale)/2,y:(1-scale)/2,width:scale,height:scale)
            let margin = box.insetBy(dx:-box.width*0.06,dy:-box.height*0.06)
            guard crop.contains(margin), !result.contains(where:{ abs($0.zoom-zoom) < 0.08 }) else { continue }
            result.append(.init(zoom:zoom,cropScale:scale))
        }
        return result
    }
    static func evaluate(image:UIImage,guide:SmartCompositionGuide,currentZoom:CGFloat,range:ClosedRange<CGFloat>,work:SmartFramingWork) -> Evaluation {
        guard let cg = image.cgImage else { return .init(recommendation:nil,scores:[]) }
        let choices = candidates(guide:guide,currentZoom:currentZoom,range:range)
        var scores:[Double] = [], best:SmartFramingRecommendation?, baseline:Double?, bestScore = -Double.infinity
        for choice in choices {
            guard !work.isCancelled else { return .init(recommendation:nil,scores:scores) }
            let scale = choice.cropScale, w = CGFloat(cg.width)*scale, h = CGFloat(cg.height)*scale
            guard let crop = cg.cropping(to:CGRect(x:(CGFloat(cg.width)-w)/2,y:(CGFloat(cg.height)-h)/2,width:w,height:h)) else { continue }
            let request = VNCalculateImageAestheticsScoresRequest(); work.setRequest(request)
            do { try VNImageRequestHandler(cgImage:crop,orientation:.up,options:[:]).perform([request]) }
            catch { work.setRequest(nil); return .init(recommendation:nil,scores:scores) }
            work.setRequest(nil)
            guard let observation = request.results?.first, observation.overallScore.isFinite else { continue }
            let score = Double(observation.overallScore)
            scores.append(score)
            if baseline == nil { baseline = score }
            // 小收益优先保留原取景，避免为微小模型差异牺牲像素或反复变焦。
            let ranked = score - 0.015*log(Double(choice.zoom/currentZoom))
            if ranked > bestScore { bestScore = ranked; best = choice }
        }
        guard !work.isCancelled, let best, let baseline,
              bestScore > baseline+0.015, best.zoom/currentZoom >= 1.08 else { return .init(recommendation:nil,scores:scores) }
        return .init(recommendation:best,scores:scores)
    }
}
