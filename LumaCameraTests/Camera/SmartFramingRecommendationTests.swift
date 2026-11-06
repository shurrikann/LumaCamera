import XCTest
@testable import LumaCamera

final class SmartFramingRecommendationTests: XCTestCase {
    func testSmallSubjectGetsZoomIn() {
        let recommendation = SmartFramingRecommendation.make(subjectHeight: 0.21, currentZoom: 1, maxZoom: 8)
        XCTAssertEqual(recommendation?.zoom ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(recommendation?.cropScale ?? 0, 0.5, accuracy: 0.01)
    }

    func testLargeSubjectDoesNotZoomOutBelowOne() {
        XCTAssertNil(SmartFramingRecommendation.make(subjectHeight: 0.6, currentZoom: 1, maxZoom: 8))
    }

    func testZoomClampsToMaximum() {
        let recommendation = SmartFramingRecommendation.make(subjectHeight: 0.05, currentZoom: 2, maxZoom: 4)
        XCTAssertEqual(recommendation?.zoom ?? 0, 4, accuracy: 0.01)
    }
    func testSelectedSubjectFocusFollowsZoomProjection() {
        let point = SmartFramingRecommendation.focusPoint(CGPoint(x:0.54,y:0.48),from:1,to:3)
        XCTAssertEqual(point.x,0.62,accuracy:0.0001)
        XCTAssertEqual(point.y,0.44,accuracy:0.0001)
        XCTAssertEqual(SmartFramingRecommendation.focusPoint(CGPoint(x:0.5,y:0.5),from:2,to:4),CGPoint(x:0.5,y:0.5))
    }
    func testFocusMovesInsideSubjectWithoutChangingDisplayedAnchor() {
        let g = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.4,y:0.3),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:CGRect(x:0.4,y:0.2,width:0.4,height:0.5))
        let safe = SmartFramingRecommendation.focusPoint(for:g,from:1,to:1)
        XCTAssertEqual(safe.x,0.448,accuracy:0.0001)
        XCTAssertEqual(safe.y,0.36,accuracy:0.0001)
        XCTAssertEqual(g.subject,CGPoint(x:0.4,y:0.3),"只修正AF采样点，不能移动已跟踪的白点")
        let zoomed = SmartFramingRecommendation.focusPoint(for:g,from:1,to:2)
        XCTAssertEqual(zoomed.x,0.396,accuracy:0.0001)
        XCTAssertEqual(zoomed.y,0.22,accuracy:0.0001)
    }

}
