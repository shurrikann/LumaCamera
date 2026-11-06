import XCTest
import UIKit
@testable import LumaCamera

final class SmartFeatureAnchorTests:XCTestCase {
    @MainActor private func scene(shift:CGPoint = .zero,blank:Bool = false,occlusion:CGRect? = nil) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:320,height:240),format:format).image { c in
            UIColor.gray.setFill(); c.fill(CGRect(x:0,y:0,width:320,height:240))
            guard !blank else { return }
            var seed:UInt64 = 24681357
            for y in 60..<170 { for x in 90..<210 {
                seed = seed &* 6364136223846793005 &+ 1
                let value = CGFloat((seed >> 32)&255)/255
                UIColor(white:value,alpha:1).setFill(); c.fill(CGRect(x:CGFloat(x)+shift.x,y:CGFloat(y)+shift.y,width:1,height:1))
            } }
            if let occlusion { UIColor.gray.setFill(); c.fill(occlusion) }
        }.cgImage!
    }
    /// 同一物体仍在框内时，局部纹理短暂被遮住不应造成点位闪灭；未确认时不得自动取景。
    @MainActor func testLocalTextureMissKeepsSameSubjectVisibleAndRecoversWithoutReseeding() throws {
        let rect = CGRect(x:0.28,y:0.28,width:0.38,height:0.47)
        let guide = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:rect.midX,y:1-rect.midY),
            target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:rect)
        let tracker = SmartSubjectTracker()
        let initial = try XCTUnwrap(tracker.update(image:scene(),candidates:[guide],context:"occlusion",at:0).selected)
        let patch = CGRect(x:initial.subject.x*320-20,y:initial.subject.y*240-20,width:40,height:40)
        let covered = scene(occlusion:patch)
        var gate = SmartAutoFramingGate()
        for t in [0.10,0.24,0.38,0.52,0.76,0.98] {
            let result = tracker.update(image:covered,candidates:[],context:"occlusion",at:t)
            let held = try XCTUnwrap(result.selected,"物体仍在，只是局部纹理复核失败，不应立刻闪灭：t=\(t)")
            XCTAssertEqual(held.subjectID,initial.subjectID)
            if held.trackingVerified {
                XCTAssertEqual(result.appearanceVerifiedCount,1)
                XCTAssertEqual(result.objectTrackedCount,1,"整体像素复核也必须有当前有效对象框")
            }
            XCTAssertFalse(gate.update(held,at:t))
        }
        let recovered = try XCTUnwrap(tracker.update(image:scene(),candidates:[],context:"occlusion",at:1.05).selected)
        XCTAssertEqual(recovered.subjectID,initial.subjectID); XCTAssertTrue(recovered.trackingVerified)
        // 显示有上限，但身份可以等更久；恢复不依赖重新提名另一批候选。
        XCTAssertNil(tracker.update(image:scene(blank:true),candidates:[],context:"occlusion",at:1.80).selected,
            "持续丢失仍需移除，不能为了不闪烁而长期留下假点")
        let reacquired = try XCTUnwrap(tracker.update(image:scene(),candidates:[],context:"occlusion",at:2.0).selected)
        XCTAssertEqual(reacquired.subjectID,initial.subjectID)
        let lost = tracker.update(image:scene(blank:true),candidates:[],context:"occlusion",at:3.3)
        XCTAssertNil(lost.selected); XCTAssertEqual(lost.retainedCount,0)
        let newBatch = try XCTUnwrap(tracker.update(image:scene(),candidates:[guide],context:"occlusion",at:4.2).selected)
        XCTAssertNotEqual(newBatch.subjectID,initial.subjectID)
    }

    @MainActor func testWholeSubjectStructureConfirmsSameObjectButRejectsReplacement() throws {
        let rect = CGRect(x:0.28,y:0.28,width:0.38,height:0.47)
        let frame = try XCTUnwrap(SmartFeatureAnchor.Frame(scene()))
        let appearance = try XCTUnwrap(SmartSubjectAppearance(frame:frame,rect:rect))
        XCTAssertTrue(appearance.matches(frame:frame,rect:rect))
        let blank = try XCTUnwrap(SmartFeatureAnchor.Frame(scene(blank:true)))
        XCTAssertFalse(appearance.matches(frame:blank,rect:rect))
        XCTAssertFalse(appearance.matches(frame:frame,rect:CGRect(x:0.05,y:0.05,width:0.2,height:0.2)))
        XCTAssertNil(SmartSubjectAppearance(frame:blank,rect:rect))
    }
    @MainActor func testAnchorFollowsTextureAndRejectsBlankReplacement() throws {
        let reference = try XCTUnwrap(SmartFeatureAnchor.Frame(scene()))
        let (anchor,point) = try XCTUnwrap(SmartFeatureAnchor.seed(in:reference,rect:CGRect(x:0.28,y:0.28,width:0.38,height:0.47)))
        XCTAssertGreaterThan(point.x,0.28+0.038); XCTAssertLessThan(point.x,0.66-0.038)
        XCTAssertGreaterThan(point.y,0.25+0.047); XCTAssertLessThan(point.y,0.72-0.047)
        let moved = try XCTUnwrap(SmartFeatureAnchor.Frame(scene(shift:CGPoint(x:7,y:-5))))
        let expected = CGPoint(x:point.x+7/320,y:point.y-5/240)
        let actual = try XCTUnwrap(anchor.match(in:moved,near:point))
        XCTAssertEqual(actual.x,expected.x,accuracy:1.1/320); XCTAssertEqual(actual.y,expected.y,accuracy:1.1/240)
        let blank = try XCTUnwrap(SmartFeatureAnchor.Frame(scene(blank:true)))
        XCTAssertNil(anchor.match(in:blank,near:point),"纹理丢失应隐藏而非跳到新对象")
        XCTAssertNil(SmartFeatureAnchor.seed(in:blank,rect:CGRect(x:0.2,y:0.2,width:0.4,height:0.4)))
    }
    @MainActor func testCandidateBatchDoesNotRefillImmediatelyDuringAlignment() throws {
        let image = scene(), tracker = SmartSubjectTracker()
        let rect = CGRect(x:0.28,y:0.28,width:0.38,height:0.47)
        let a = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:rect.midX,y:1-rect.midY),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectRect:rect)
        let first = tracker.update(image:image,candidates:[a],context:"same")
        let id = try XCTUnwrap(first.selected?.subjectID)
        let b = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.8,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:CGRect(x:0.75,y:0.4,width:0.2,height:0.2))
        let next = tracker.update(image:image,candidates:[b,a],context:"same")
        XCTAssertEqual(next.candidates.count,1); XCTAssertEqual(next.selected?.subjectID,id)
        XCTAssertFalse(tracker.applyAdvice(.init(subjectID:id,preserveSceneContext:true),context:"expired"))
        XCTAssertFalse(tracker.applyAdvice(.init(subjectID:UUID(),preserveSceneContext:true),context:"same"))
        XCTAssertTrue(tracker.applyAdvice(.init(subjectID:id,preserveSceneContext:true),context:"same"))
        let advised = tracker.update(image:image,candidates:[],context:"same")
        XCTAssertEqual(advised.selected?.subjectID,id); XCTAssertTrue(advised.selected?.preserveSceneContext == true)
    }
    @MainActor func testTrackedDotFollowsSmallPanWithoutScreenSpaceSmoothing() throws {
        let rect = CGRect(x:0.28,y:0.28,width:0.38,height:0.47)
        let candidate = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:rect.midX,y:1-rect.midY),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:rect)
        let tracker = SmartSubjectTracker()
        let first = try XCTUnwrap(tracker.update(image:scene(),candidates:[candidate],context:"pan",at:0).selected)
        var durations = [Double](), maximumError:CGFloat = 0
        for i in 1...24 {
            let shift = CGPoint(x:i,y:-(i/2))
            let frame = scene(shift:shift)
            let started = CACurrentMediaTime()
            let result = tracker.update(image:frame,candidates:[],context:"pan",at:Double(i)/15)
            durations.append(CACurrentMediaTime()-started)
            let guide = try XCTUnwrap(result.selected, "连续小幅移动不能一帧有点一帧无点")
            XCTAssertEqual(guide.subjectID,first.subjectID)
            XCTAssertTrue(guide.trackingVerified)
            let expected = CGPoint(x:first.subject.x+shift.x/320,y:first.subject.y+shift.y/240)
            maximumError = max(maximumError,hypot(guide.subject.x-expected.x,guide.subject.y-expected.y))
        }
        XCTAssertLessThanOrEqual(maximumError,2.0/240)
        let sorted = durations.sorted()
        print("SMART-PAN samples=24 maximumNormalizedError=\(maximumError) medianSeconds=\(sorted[12]) p95Seconds=\(sorted[22]) syntheticTranslation=true notScreenFPS=true")
    }
    @MainActor func testBriefMissRetainsIdentityAndLongLossRemovesMarker() throws {
        let rect = CGRect(x:0.28,y:0.28,width:0.38,height:0.47)
        let candidate = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:rect.midX,y:1-rect.midY),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:rect)
        let tracker = SmartSubjectTracker()
        let first = try XCTUnwrap(tracker.update(image:scene(),candidates:[candidate],context:"miss",at:0).selected)
        let missed = try XCTUnwrap(tracker.update(image:scene(blank:true),candidates:[],context:"miss",at:0.06).selected)
        XCTAssertEqual(missed.subjectID,first.subjectID); XCTAssertFalse(missed.trackingVerified)
        let recovered = try XCTUnwrap(tracker.update(image:scene(),candidates:[],context:"miss",at:0.12).selected)
        XCTAssertEqual(recovered.subjectID,first.subjectID); XCTAssertTrue(recovered.trackingVerified)
        XCTAssertNil(tracker.update(image:scene(blank:true),candidates:[],context:"miss",at:0.7).selected)
        let restarted = try XCTUnwrap(tracker.update(image:scene(),candidates:[candidate],context:"restart",at:0.8).selected)
        XCTAssertNotEqual(restarted.subjectID,first.subjectID)
    }
}
