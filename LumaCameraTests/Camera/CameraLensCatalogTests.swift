import XCTest
import AVFoundation
@testable import LumaCamera

final class CameraLensCatalogTests: XCTestCase {
    func testDigital8xIsSelectableWithoutNative8x() {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 100, nativeFactors: [])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 4, minimum: 1, maximum: 30, nativeFactors: [1])
        let choice = CameraZoomPolicy.select(8, from: [wide, tele], nativeOnly: false)
        XCTAssertEqual(choice?.id, "tele")
        XCTAssertEqual(choice?.factor ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(choice?.native, false)
        XCTAssertNil(CameraZoomPolicy.select(8, from: [wide, tele], nativeOnly: true))
    }
}
