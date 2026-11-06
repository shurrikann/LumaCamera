import XCTest
import AVKit
@testable import LumaCamera

final class HardwareCaptureTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testOnlyCompletedPressOnActiveCameraUsesShutterAndTimer() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(model.camera.ready)
        model.timerSeconds = 3
        model.handleHardwareCapture(phase: .began)
        model.handleHardwareCapture(phase: .cancelled)
        XCTAssertNil(model.countdown)
        model.handleHardwareCapture(phase: .ended)
        XCTAssertEqual(model.countdown, 3)
        // A second completed press follows the screen shutter's countdown cancellation.
        model.handleHardwareCapture(phase: .ended)
        XCTAssertNil(model.countdown)
        model.review = true
        model.handleHardwareCapture(phase: .ended)
        XCTAssertNil(model.countdown)
        model.review = false; model.settings = true
        model.handleHardwareCapture(phase: .ended)
        XCTAssertNil(model.countdown)
        model.settings = false; model.setCameraActive(false)
        model.handleHardwareCapture(phase: .ended)
        XCTAssertNil(model.countdown)
        XCTAssertNil(model.library.lastPhoto)
    }
    #endif
}
