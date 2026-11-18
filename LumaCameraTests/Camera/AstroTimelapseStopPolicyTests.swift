import XCTest
@testable import LumaCamera

final class AstroTimelapseStopPolicyTests: XCTestCase {
    func testManualStopKeepsShortValidClip() {
        XCTAssertTrue(AstroTimelapseStopPolicy.shouldSave(outputFrames: 1, manual: true))
        XCTAssertTrue(AstroTimelapseStopPolicy.shouldSave(outputFrames: 12, manual: true))
    }

    func testAutomaticStopKeepsValidShortClip() {
        XCTAssertTrue(AstroTimelapseStopPolicy.shouldSave(outputFrames: 1, manual: false))
        XCTAssertTrue(AstroTimelapseStopPolicy.shouldSave(outputFrames: 29, manual: false))
        XCTAssertTrue(AstroTimelapseStopPolicy.shouldSave(outputFrames: 30, manual: false))
    }

    func testNoFramesIsNeverSaved() {
        XCTAssertFalse(AstroTimelapseStopPolicy.shouldSave(outputFrames: 0, manual: true))
        XCTAssertFalse(AstroTimelapseStopPolicy.shouldSave(outputFrames: 0, manual: false))
    }
}
