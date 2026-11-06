import XCTest
@testable import LumaCamera

final class ManualZoomPolicyTests: XCTestCase {
    func testEachPresetGetsItsOwnFivefoldRangeOnTheSamePhysicalLens() {
        for (anchor, base) in [(0.5,0.5),(1.0,1.0),(2.0,1.0),(4.0,4.0),(8.0,4.0)] {
            let range = ManualZoomPolicy.range(anchor: anchor, physicalBase: base, minimum: 1, maximum: 20)
            XCTAssertEqual(range.lowerBound, anchor)
            XCTAssertEqual(range.upperBound, anchor * 5)
        }
    }
    func testHardwareLimitsNeverRequestAnUnsupportedZoomFactor() {
        XCTAssertEqual(ManualZoomPolicy.range(anchor: 8, physicalBase: 4, minimum: 1, maximum: 6), 8...24)
        XCTAssertEqual(ManualZoomPolicy.range(anchor: .nan, physicalBase: 1, minimum: 1, maximum: 20), 1...1)
    }
}
