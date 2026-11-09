import CoreGraphics
import XCTest
@testable import LumaCamera

final class SmartSubjectContinuityTests: XCTestCase {
    private func guide(_ id: UUID, x: CGFloat = 0.4, verified: Bool = true) -> SmartCompositionGuide {
        SmartCompositionGuide(stage: .align, direction: .align,
            subject: CGPoint(x: x, y: 0.4), target: CGPoint(x: 0.5, y: 0.5),
            text: "先对准中心", subjectID: id, trackingVerified: verified)
    }

    func testNewSubjectMustDwellAndUnverifiedCandidateCannotStealPoint() {
        var continuity = SmartSubjectContinuity(switchDwell: 0.6, holdDuration: 0.65)
        let a = UUID(), b = UUID()
        XCTAssertEqual(continuity.update(guide(a), at: 0)?.subjectID, a)
        XCTAssertEqual(continuity.update(guide(a), at: 0.1)?.subjectID, a)
        // 新点刚出现，继续显示旧点。
        XCTAssertEqual(continuity.update(guide(b), at: 0.15)?.subjectID, a)
        XCTAssertEqual(continuity.update(guide(b), at: 0.45)?.subjectID, a)
        // 旧点超出保留时间且新点未验证，暂时隐藏，不能跳到未确认目标。
        XCTAssertNil(continuity.update(guide(b, verified: false), at: 0.8))
        XCTAssertNil(continuity.update(guide(b, verified: false), at: 0.9))
        // 新点重新验证后，仍需重新累计 dwell。
        XCTAssertEqual(continuity.update(guide(b), at: 1.0)?.subjectID, b)
        XCTAssertEqual(continuity.update(guide(b), at: 1.7)?.subjectID, b)
    }

    func testSameSubjectUpdatesLiveAndShortLossHoldsThenHides() {
        var continuity = SmartSubjectContinuity(switchDwell: 0.6, holdDuration: 0.65)
        let a = UUID()
        XCTAssertEqual(continuity.update(guide(a, x: 0.3), at: 0)?.subject, CGPoint(x: 0.3, y: 0.4))
        XCTAssertEqual(continuity.update(guide(a, x: 0.6), at: 0.1)?.subject, CGPoint(x: 0.6, y: 0.4))
        let held = continuity.update(nil, at: 0.5)
        XCTAssertEqual(held?.subjectID, a)
        XCTAssertEqual(held?.trackingVerified, false)
        XCTAssertNotNil(continuity.update(nil, at: 0.7))
        XCTAssertNil(continuity.update(nil, at: 0.8))
    }
}
