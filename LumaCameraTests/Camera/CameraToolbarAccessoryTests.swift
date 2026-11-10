import XCTest
@testable import LumaCamera

final class CameraToolbarAccessoryTests: XCTestCase {
    func testSlowShutterAlwaysOccupiesTheLiveSlot() {
        XCTAssertEqual(CameraToolbarAccessory.resolve(slowShutter: true, virtualAperture: true,
                                                      portrait: true, burst: true, heifPro: true), .slowShutter)
    }

    func testProToneOnlyReplacesLiveWithoutHigherPriorityModes() {
        XCTAssertEqual(CameraToolbarAccessory.resolve(slowShutter: false, virtualAperture: false,
                                                      portrait: false, burst: false, heifPro: true), .proTone)
        XCTAssertEqual(CameraToolbarAccessory.resolve(slowShutter: false, virtualAperture: false,
                                                      portrait: false, burst: false, heifPro: false), .live)
        XCTAssertEqual(CameraToolbarAccessory.resolve(slowShutter: false, virtualAperture: false,
                                                      portrait: true, burst: false, heifPro: true), .portraitDepth)
    }
}
