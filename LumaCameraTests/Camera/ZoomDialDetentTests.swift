import XCTest
@testable import LumaCamera

final class ZoomDialDetentTests: XCTestCase {
    func testOrdinaryTicksInBothDirections() {
        var dial = ZoomDialDetents()
        dial.reset(at: 1)
        XCTAssertEqual(dial.move(to: CGFloat(pow(2, 1.1 / 12))), .tick)
        XCTAssertNil(dial.move(to: CGFloat(pow(2, 1.2 / 12))))
        XCTAssertEqual(dial.move(to: CGFloat(pow(2, 2.1 / 12))), .tick)
        XCTAssertEqual(dial.move(to: CGFloat(pow(2, 0.9 / 12))), .tick)
    }
    func testEveryAnchorIsStrongerInBothDirections() {
        for zoom in [CGFloat(0.5), 1, 2, 4, 8] {
            var dial = ZoomDialDetents()
            dial.reset(at: zoom * 0.99)
            XCTAssertEqual(dial.move(to: zoom), .anchor)
            dial.reset(at: zoom * 1.01)
            XCTAssertEqual(dial.move(to: zoom), .anchor)
        }
    }
    func testJitterAndStationaryValuesDoNotRepeatFeedback() {
        var dial = ZoomDialDetents()
        dial.reset(at: 0.99)
        XCTAssertEqual(dial.move(to: 1), .anchor)
        XCTAssertNil(dial.move(to: 1))
        XCTAssertNil(dial.move(to: 0.999))
        XCTAssertNil(dial.move(to: 1.001))
        _ = dial.move(to: 1.05)
        XCTAssertEqual(dial.move(to: 0.99), .anchor)
    }
    func testFastDragCoalescesTicksAndPrioritizesAnchor() {
        var dial = ZoomDialDetents()
        dial.reset(at: 0.6)
        XCTAssertEqual(dial.move(to: 9), .anchor)
        XCTAssertNil(dial.move(to: 9))
        XCTAssertNil(dial.move(to: .nan))
        XCTAssertNil(dial.move(to: 0))
    }
}
