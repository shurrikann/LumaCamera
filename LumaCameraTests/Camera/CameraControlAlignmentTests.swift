import XCTest
import CoreGraphics
@testable import LumaCamera

final class CameraControlAlignmentTests: XCTestCase {
    func testAutomaticExposureStripSharesSideBoundsWithModeAndAuxiliaryButtons() {
        for width in [320.0, 375.0, 402.0, 440.0, 600.0] {
            let buttonInset = CameraControlLayout.buttonRowSideInset
            let exposureInset = CameraControlLayout.parameterSideInset(automatic: true)
            let buttonRow = CGRect(x: buttonInset, y: 0, width: width - 2 * buttonInset, height: 44)
            let exposureStrip = CGRect(x: exposureInset, y: 0, width: width - 2 * exposureInset, height: 46)

            XCTAssertEqual(exposureStrip.minX, buttonRow.minX, accuracy: 0.001)
            XCTAssertEqual(exposureStrip.maxX, buttonRow.maxX, accuracy: 0.001)
        }

        XCTAssertEqual(CameraControlLayout.parameterSideInset(automatic: false),
                       CameraControlLayout.manualParameterSideInset,
                       "M-mode parameter layout keeps its established inset")
    }
}
