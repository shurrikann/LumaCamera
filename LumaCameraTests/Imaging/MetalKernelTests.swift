import XCTest
@testable import LumaCamera

final class MetalKernelTests: XCTestCase {
    func testEveryCompiledKernelLoadsFromApplicationBundle() {
        XCTAssertNotNil(MetalImageKernels.general("chromaticShift"))
        for name in ["bloomLayer", "addLight", "restoreAlpha", "lights", "filmGrain", "focusPeak", "proTone"] {
            XCTAssertNotNil(MetalImageKernels.color(name), name)
        }
    }
}
