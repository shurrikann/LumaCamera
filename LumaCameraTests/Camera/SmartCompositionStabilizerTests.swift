import XCTest
import CoreGraphics
@testable import LumaCamera

final class SmartCompositionStabilizerTests: XCTestCase {
    private func guide(_ stage: SmartCompositionGuide.Stage,
                       _ direction: SmartCompositionGuide.Direction,
                       text: String = "提示",
                       subject: CGPoint = CGPoint(x: 0.3, y: 0.3)) -> SmartCompositionGuide {
        SmartCompositionGuide(stage: stage, direction: direction, subject: subject,
                              target: CGPoint(x: 0.5, y: 0.5), text: text)
    }

    func testStageChangeWaitsForDwell() {
        var stabilizer = SmartCompositionStabilizer()
        let align = guide(.align, .align, text: "先对准中心")
        XCTAssertEqual(stabilizer.update(align, at: 0)?.stage, .align)
        let compose = guide(.compose, .right, text: "向右移动", subject: CGPoint(x: 0.5, y: 0.5))
        let held = stabilizer.update(compose, at: 0.2)
        XCTAssertEqual(held?.stage, .align)
        XCTAssertEqual(held?.target, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(stabilizer.update(compose, at: 0.9)?.stage, .align)
        XCTAssertEqual(stabilizer.update(compose, at: 1.1)?.stage, .compose)
    }

    func testDirectionChangeWaitsWithoutDelayingTrackedPoint() {
        var stabilizer = SmartCompositionStabilizer()
        _ = stabilizer.update(guide(.compose, .right, text: "向右移动", subject: CGPoint(x: 0.2, y: 0.3)), at: 0)
        let left = stabilizer.update(guide(.compose, .left, text: "向左移动", subject: CGPoint(x: 0.8, y: 0.3)), at: 0.2)
        XCTAssertEqual(left?.direction, .right)
        XCTAssertEqual(stabilizer.update(nil, at: 0.25)?.subject.x, 0.8,
                       "文字迟滞期间漏检不能跳回之前的旧坐标")
        let moved = stabilizer.update(guide(.compose, .left, text: "向左移动", subject: CGPoint(x: 0.8, y: 0.3)), at: 0.7)
        XCTAssertEqual(moved?.direction, .left)
        XCTAssertEqual(moved?.subject.x, 0.8, "已确认的物体位置不能再次平滑成滞后点")
    }

    func testMissingGuideClearsAfterGrace() {
        var stabilizer = SmartCompositionStabilizer()
        _ = stabilizer.update(guide(.compose, .right), at: 0)
        XCTAssertEqual(stabilizer.update(nil, at: 0.1)?.trackingVerified, false)
        XCTAssertNil(stabilizer.update(nil, at: 2.0))
    }
}
