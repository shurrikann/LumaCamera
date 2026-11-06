import XCTest
@testable import LumaCamera

final class LevelHapticGateTests: XCTestCase {
    func testOnlyStableEntryTriggersAndJitterCannotRepeatFeedback() {
        var gate = LevelHapticGate()
        XCTAssertFalse(gate.update(roll: 0.1, time: 0, enabled: true))
        XCTAssertFalse(gate.update(roll: 0, time: 0.1, enabled: true))
        XCTAssertTrue(gate.update(roll: 0, time: 0.4, enabled: true))
        for i in 1...100 { XCTAssertFalse(gate.update(roll: i % 2 == 0 ? 0.03 : 0, time: 0.4 + Double(i) / 100, enabled: true)) }
        XCTAssertFalse(gate.update(roll: 0.1, time: 2, enabled: true))
        XCTAssertFalse(gate.update(roll: 0, time: 2.1, enabled: true))
        XCTAssertTrue(gate.update(roll: 0, time: 2.4, enabled: true))
        XCTAssertFalse(gate.update(roll: 0, time: 3, enabled: false))
        XCTAssertFalse(gate.update(roll: 0, time: 4, enabled: true))
        XCTAssertFalse(gate.update(roll: .nan, time: 5, enabled: true))
    }
}
