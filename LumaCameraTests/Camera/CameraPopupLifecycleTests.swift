import XCTest
@testable import LumaCamera

final class CameraPopupLifecycleTests: XCTestCase {
    @MainActor
    func testLeavingCameraClosesAllFunctionPopups() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.openParameter(.iso)
        XCTAssertTrue(model.popupVisible)
        model.setCameraActive(false)
        XCTAssertFalse(model.popupVisible)
        XCTAssertNil(model.panel)
        XCTAssertNil(model.toolbarPanel)

        model.openTools()
        model.toolbarPanel = .format
        model.setCameraActive(false)
        XCTAssertFalse(model.tools)
        XCTAssertNil(model.toolbarPanel)

        model.openFunctions()
        model.setCameraActive(false)
        XCTAssertFalse(model.functions)
    }

    @MainActor
    func testGalleryReviewKeepsPopupState() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.review = true
        model.openParameter(.iso)
        XCTAssertTrue(model.popupVisible)
        model.setCameraActive(false)
        XCTAssertTrue(model.popupVisible, "Opening the gallery must not be treated as leaving the camera")
        model.review = false
        model.closePopups()
    }
}
