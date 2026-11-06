import XCTest
import Combine
@testable import LumaCamera

final class CaptureKindSwitchCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor
    func testPhotoAndVideoCaptureAfterCrossModeSwitch() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        model.setCameraActive(true)
        defer { model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false) }
        for _ in 0..<900 {
            if camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "相机未就绪")
        if model.currentPosition != .back { model.flipCamera() }
        model.setCaptureKind(.photo)
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }

        func waitForSwitch() async {
            for _ in 0..<150 {
                if !model.captureKindSwitching, camera.ready, !camera.videoConfiguring { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        model.setCaptureKind(.video)
        await waitForSwitch()
        model.setCaptureKind(.photo)
        await waitForSwitch()
        XCTAssertFalse(model.captureKindSwitching)
        XCTAssertEqual(model.captureKind, .photo)

        let photo = expectation(description: "photo after switch")
        let subscription = model.library.$lastPhoto.compactMap { $0 }.first().sink { _ in photo.fulfill() }
        model.takePhoto()
        await fulfillment(of: [photo], timeout: 6)
        withExtendedLifetime(subscription) {}

        model.setCaptureKind(.video)
        await waitForSwitch()
        XCTAssertFalse(model.captureKindSwitching)
        model.toggleVideoRecording()
        for _ in 0..<150 {
            if camera.videoRecording { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.videoRecording, camera.message ?? "切换后录像未开始")
        model.toggleVideoRecording()
        for _ in 0..<150 {
            if !camera.videoRecording { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(camera.videoRecording)
    }
    #endif
}
