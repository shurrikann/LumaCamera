import XCTest
import UIKit
@testable import LumaCamera
final class HDRPreviewPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testProbeCurrentCameraHDRPreviewFormats() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        let value = await withCheckedContinuation { c in camera.previewHDRCapabilitiesForTesting { c.resume(returning:$0) } }
        print("HDR-PREVIEW-CAPABILITIES \(value)")
        XCTAssertTrue(camera.ready)
    }
    #endif
}
