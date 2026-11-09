import XCTest
@testable import LumaCamera

final class SmartCaptureCadenceTests: XCTestCase {
    func testAdaptiveCadenceAcrossGuidePopupAndLowPower() {
        XCTAssertEqual(SmartCaptureCadence.interval(hasVisibleGuide: true, analysisAllowed: true,
            lowPower: false, thermalSerious: false), 1.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(SmartCaptureCadence.interval(hasVisibleGuide: false, analysisAllowed: true,
            lowPower: false, thermalSerious: false), 1.0 / 8.0, accuracy: 0.0001)
        XCTAssertEqual(SmartCaptureCadence.interval(hasVisibleGuide: true, analysisAllowed: false,
            lowPower: false, thermalSerious: false), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SmartCaptureCadence.interval(hasVisibleGuide: true, analysisAllowed: true,
            lowPower: true, thermalSerious: false), 0.10, accuracy: 0.0001)
        XCTAssertEqual(SmartCaptureCadence.interval(hasVisibleGuide: false, analysisAllowed: true,
            lowPower: false, thermalSerious: true), 0.20, accuracy: 0.0001)
    }
}
