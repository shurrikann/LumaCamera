import SwiftUI

extension CameraView {
    /// 与参考交互一致：白色实心候选点锁住景物，白色空心圈固定在屏幕中心。
    /// 不画连线、箭头或完成文字；重合后短暂着色，随后淡出以保留干净取景。
    func smartCompositionGuideOverlay(_ guide:SmartCompositionGuide,imageSize:CGSize? = nil) -> some View {
        smartCompositionGuideContent(guide,imageSize:imageSize,reducedMotion:reduceMotion)
    }

    func smartCompositionGuideContent(_ guide:SmartCompositionGuide,imageSize:CGSize? = nil,reducedMotion:Bool) -> some View {
        GeometryReader { geometry in
            let center = CGPoint(x:geometry.size.width/2,y:geometry.size.height/2)
            let diameter = min(geometry.size.width,geometry.size.height)*0.10
            let pointDiameter = max(4,diameter-6) // 3点描边，重合后内外之间各留约1.5点窄缝。
            let done = model.smartFramingComplete && guide.alignmentDistance <= SmartCompositionGuide.alignmentRadius * 1.6
            let hideCandidates = (model.smartAlignmentLatched || model.smartFramingInProgress || done)
                && guide.alignmentDistance <= SmartCompositionGuide.alignmentRadius * 1.6
            let capturing = model.camera.capturing || model.camera.shutterBusy
            let referenceAligned = guide.trackingVerified && guide.alignmentDistance <= SmartCompositionGuide.alignmentRadius
            // 主候选只是逻辑选择，所有白点始终留在同一ForEach中；切换主候选不重建原点。
            let points = Self.smartVisiblePoints(guide:guide,candidates:model.smartCompositionCandidates)
            ZStack {
                if !capturing {
                    ZStack {
                    ForEach(points,id:\.subjectID) { candidate in
                        Circle().fill(.white).frame(width:pointDiameter,height:pointDiameter)
                            .shadow(color:.black.opacity(0.3),radius:1)
                            .position(Self.displayPoint(candidate.subject,imageSize:imageSize,displaySize:geometry.size))
                            .animation(reducedMotion ? nil : .linear(duration:0.045),value:candidate.subject)
                    }
                    }
                    .opacity(hideCandidates ? 0 : 1)
                    .animation(.easeOut(duration:reducedMotion ? 0.06 : 0.10),value:hideCandidates)
                }
                Circle().stroke(done || referenceAligned ? AppTheme.accent : .white.opacity(0.95),lineWidth:3)
                    .frame(width:diameter,height:diameter)
                    .shadow(color:.black.opacity(0.25),radius:1)
                    .position(center)
                    .opacity(!capturing && (!done || model.smartFramingFeedbackVisible) ? 1 : 0)
                    .animation(.easeOut(duration:reducedMotion ? 0.08 : 0.12),value:referenceAligned)
                if model.smartFramingInProgress {
                    ProgressView().controlSize(.mini).tint(AppTheme.accent).position(center)
                }
            }
        }
        // 仅点位做45ms短线性补间，不叠加坐标低通；换对象不跨身份插值。
        .animation(.easeOut(duration:reducedMotion ? 0.06 : 0.10),value:model.smartFramingFeedbackVisible)
        .allowsHitTesting(false)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(model.smartFramingComplete ? "取景完成，可手动拍摄" : "将任一白色候选点移入中心圆圈并保持稳定")
    }
}

extension CameraView {
    /// 短漏检可能只剩稳定器保留的主点；去重后仍使用同一身份绘制，不在树的两处分配白点。
    static func smartVisiblePoints(guide:SmartCompositionGuide,candidates:[SmartCompositionGuide]) -> [SmartCompositionGuide] {
        var points = candidates.map { $0.subjectID == guide.subjectID ? guide:$0 }
        if !points.contains(where:{ $0.subjectID == guide.subjectID }) { points.append(guide) }
        return points
    }

    /// 将分析图像中的点映射到实际预览；分析已经裁成可见画幅时可省略imageSize。
    static func displayPoint(_ point:CGPoint,imageSize:CGSize?,displaySize:CGSize) -> CGPoint {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0, displaySize.width > 0, displaySize.height > 0 else {
            return CGPoint(x:point.x*displaySize.width,y:point.y*displaySize.height)
        }
        let scale = max(displaySize.width/imageSize.width,displaySize.height/imageSize.height)
        let rendered = CGSize(width:imageSize.width*scale,height:imageSize.height*scale)
        let origin = CGPoint(x:(displaySize.width-rendered.width)/2,y:(displaySize.height-rendered.height)/2)
        return CGPoint(x:origin.x+point.x*rendered.width,y:origin.y+point.y*rendered.height)
    }
}
