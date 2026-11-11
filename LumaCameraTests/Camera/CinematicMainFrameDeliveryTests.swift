import XCTest
import AVFoundation
@testable import LumaCamera

#if !targetEnvironment(simulator)
final class CinematicMainFrameDeliveryTests: XCTestCase {
    @MainActor func testMainCameraCinematicSustainsFrameDelivery() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        for _ in 0..<500 {
            if model.camera.ready && !model.camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        model.setCaptureKind(.video)
        for _ in 0..<500 {
            if model.camera.ready && !model.camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        model.toggleCinematicVideoMode()
        for _ in 0..<500 {
            if model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.cinematicVideoEnabled, model.camera.message ?? "")
        XCTAssertTrue(model.camera.cinematicVideoCaptureActive, model.camera.message ?? "")
        try await Task.sleep(for: .milliseconds(500))
        let start = await frames(model.camera)
        try await Task.sleep(for: .milliseconds(2400))
        let end = await frames(model.camera)
        print("CIN-MAIN frames2s4=\(end - start) total=\(end)")
        XCTAssertGreaterThan(end - start, 20, "电影模式主相机未持续出帧")
        model.setCameraActive(false)
    }
    private func frames(_ camera: CameraEngine) async -> Int {
        await withCheckedContinuation { c in camera.recordingFrameCountForTesting { c.resume(returning: $0) } }
    }
}
#endif
