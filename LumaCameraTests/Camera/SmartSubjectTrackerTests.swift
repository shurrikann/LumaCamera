import XCTest
import UIKit
@testable import LumaCamera

final class SmartSubjectTrackerTests:XCTestCase {
    func testDisplayGraceRequiresBoundedLossAndContinuousOnscreenObject() {
        let point = CGPoint(x:0.3,y:0.4)
        XCTAssertTrue(SmartTrackingContinuity.canDisplay(point:point,age:0.52,objectTracked:true))
        XCTAssertFalse(SmartTrackingContinuity.canDisplay(point:point,age:0.7,objectTracked:true))
        XCTAssertTrue(SmartTrackingContinuity.canDisplay(point:point,age:0.25,objectTracked:false))
        XCTAssertFalse(SmartTrackingContinuity.canDisplay(point:point,age:0.4,objectTracked:false))
        XCTAssertFalse(SmartTrackingContinuity.canDisplay(point:CGPoint(x:1.1,y:0.5),age:0.01,objectTracked:true))
        let old = CGRect(x:0.2,y:0.3,width:0.2,height:0.2)
        let moved = CGRect(x:0.22,y:0.27,width:0.24,height:0.24)
        XCTAssertTrue(SmartTrackingContinuity.isContinuous(from:old,to:moved))
        XCTAssertFalse(SmartTrackingContinuity.isContinuous(from:old,to:CGRect(x:0.75,y:0.7,width:0.2,height:0.2)))
        XCTAssertFalse(SmartTrackingContinuity.isContinuous(from:old,to:CGRect(x:0.2,y:0.3,width:0.7,height:0.6)))
        let projected = SmartTrackingContinuity.project(CGPoint(x:0.25,y:0.55),from:old,to:moved)
        XCTAssertEqual(projected.x,0.28,accuracy:0.00001)
        XCTAssertEqual(projected.y,0.55,accuracy:0.00001)
    }

    func testChangingPrimaryKeepsAllPointIdentitiesInOneStableCollection() {
        let a = UUID(),b = UUID()
        let first = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.2,y:0.4),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectID:a)
        let second = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.8,y:0.4),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectID:b)
        for i in 0..<100 {
            let points = CameraView.smartVisiblePoints(guide:i%2 == 0 ? first:second,candidates:[first,second])
            XCTAssertEqual(points.compactMap(\.subjectID),[a,b])
        }
        XCTAssertEqual(CameraView.smartVisiblePoints(guide:first,candidates:[second]).count,2)
    }

    func testAnyVerifiedCandidateInsideCircleOverridesNearbyUnalignedSelection() {
        let a = UUID(), b = UUID()
        for ratio in FrameRatio.allCases { for landscape in [false,true] {
            let aspect = landscape ? 1/ratio.portraitRatio : ratio.portraitRatio
            var previous = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.59,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectID:a,imageAspect:aspect)
            var aligned = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectID:b,imageAspect:aspect)
            XCTAssertEqual(SmartSubjectTracker.selectedID(candidates:[previous,aligned],previous:a,retained:[a,b]),b)
            aligned.trackingVerified = false
            XCTAssertEqual(SmartSubjectTracker.selectedID(candidates:[previous,aligned],previous:a,retained:[a,b]),a)
            previous = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.51,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectID:a,imageAspect:aspect)
            aligned.trackingVerified = true
            XCTAssertEqual(SmartSubjectTracker.selectedID(candidates:[previous,aligned],previous:a,retained:[a,b]),a)
        } }
    }
    private func guide(_ rect:CGRect) -> SmartCompositionGuide {
        SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:rect.midX,y:1-rect.midY),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:rect)
    }
    @MainActor private func image() -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:600,height:800),format:format).image { c in
            UIColor.darkGray.setFill(); c.fill(CGRect(x:0,y:0,width:600,height:800))
            for i in 0..<3 {
                let x = CGFloat(70+i*180)
                UIColor(hue:CGFloat(i)/3,saturation:0.8,brightness:0.9,alpha:1).setFill()
                c.fill(CGRect(x:x,y:280,width:100,height:220))
                UIColor.white.setFill()
                for k in 0..<8 { c.fill(CGRect(x:x+CGFloat(k*11),y:300+CGFloat(k*17),width:7,height:30)) }
            }
        }.cgImage!
    }
    @MainActor func testThreeStableIdentitiesDoNotFollowDetectionOrder() throws {
        let tracker = SmartSubjectTracker(), cg = image()
        let boxes = [CGRect(x:0.11,y:0.37,width:0.18,height:0.28),CGRect(x:0.41,y:0.37,width:0.18,height:0.28),CGRect(x:0.71,y:0.37,width:0.18,height:0.28)]
        let initial = tracker.update(image:cg,candidates:boxes.map(guide),context:"scene")
        XCTAssertEqual(initial.candidates.count,3)
        let selected = try XCTUnwrap(initial.selected)
        var maximumDrift:CGFloat = 0, durations:[Double] = []
        for i in 0..<12 {
            let start = CACurrentMediaTime()
            let raw = (i%2 == 0 ? boxes : Array(boxes.reversed())).map(guide)
            let result = tracker.update(image:cg,candidates:raw,context:"scene")
            durations.append(CACurrentMediaTime()-start)
            XCTAssertEqual(result.selected?.subjectID,selected.subjectID)
            XCTAssertEqual(Set(result.candidates.compactMap(\.subjectID)),Set(initial.candidates.compactMap(\.subjectID)))
            if let p = result.selected?.subject { maximumDrift = max(maximumDrift,hypot(p.x-selected.subject.x,p.y-selected.subject.y)) }
        }
        XCTAssertLessThan(maximumDrift,0.02)
        print("SMART-TRACK samples=12 targets=3 maximumNormalizedDrift=\(maximumDrift) seconds=\(durations); synthetic static pixels, not real-scene accuracy")
        let changed = tracker.update(image:cg,candidates:[guide(boxes[0])],context:"new-scene")
        XCTAssertEqual(changed.candidates.count,1); XCTAssertNotEqual(changed.selected?.subjectID,selected.subjectID)
    }
}
