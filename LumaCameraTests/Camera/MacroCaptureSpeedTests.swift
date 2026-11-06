import XCTest
@testable import LumaCamera

@MainActor
final class MacroCaptureSpeedTests: XCTestCase {
    func testMacroSDRCaptureSpeed() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.hdr = false
        var captured: CapturedPhoto?
        let done = expectation(description: "sdr")
        let old = camera.onCaptureCompleted
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        defer { camera.onCaptureCompleted = old }
        let start = CACurrentMediaTime()
        camera.capture(flashMode: .off, options: model.photoOptions)
        await fulfillment(of: [done], timeout: 45)
        print("MACRO-SPEED sdr seconds=\(CACurrentMediaTime()-start) photo=\(captured != nil)")
        XCTAssertNotNil(captured)
    }
}
