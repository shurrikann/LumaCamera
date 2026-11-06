import XCTest
@testable import LumaCamera
final class CameraMacroPolicyTests: XCTestCase {
    func testMacroRequiresActualUltraWideFallbackInAutomaticRearCamera() {
        XCTAssertTrue(CameraMacroPolicy.isActive(manual:false,virtual:true,rear:true,ultraWide:true,displayZoom:1))
        for zoom in [CGFloat(0.5), .nan, .infinity] { XCTAssertFalse(CameraMacroPolicy.isActive(manual:false,virtual:true,rear:true,ultraWide:true,displayZoom:zoom)) }
        XCTAssertTrue(CameraMacroPolicy.isActive(manual:true,virtual:true,rear:true,ultraWide:true,displayZoom:2), "M挡也应识别微距")
        XCTAssertFalse(CameraMacroPolicy.isActive(manual:false,virtual:false,rear:true,ultraWide:true,displayZoom:1))
        XCTAssertFalse(CameraMacroPolicy.isActive(manual:false,virtual:true,rear:false,ultraWide:true,displayZoom:1))
        XCTAssertFalse(CameraMacroPolicy.isActive(manual:false,virtual:true,rear:true,ultraWide:false,displayZoom:1))
        XCTAssertFalse(CameraMacroPolicy.isActive(manual:false,virtual:true,rear:true,ultraWide:true,displayZoom:1,
                                                  routeChangePending:true),
                       "The old route's macro state is suppressed during an explicit focal-length change")
    }

    func testExplicitLensChangeInvalidatesStaleMacroSampleGeneration() {
        let state = LivePreviewState()
        let oldGeneration = state.snapshot().macroRouteGeneration
        let selectionGeneration = state.beginMacroRouteChange()
        XCTAssertNotEqual(selectionGeneration, oldGeneration)
        XCTAssertTrue(state.snapshot().macroRouteChangePending)

        state.finishMacroRouteChange(generation: selectionGeneration)
        let current = state.snapshot()
        XCTAssertFalse(current.macroRouteChangePending)
        XCTAssertNotEqual(current.macroRouteGeneration, oldGeneration)
        XCTAssertNotEqual(current.macroRouteGeneration, selectionGeneration)
    }
}
