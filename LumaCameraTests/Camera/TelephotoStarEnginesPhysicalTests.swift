import AVFoundation
import XCTest
@testable import LumaCamera

final class TelephotoStarEnginesPhysicalTests: XCTestCase {
    @MainActor func testTelephotoRunsAllThreeStarEngines() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实长焦相机")
        #else
        guard AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil else {
            XCTFail("当前设备没有物理长焦摄像头")
            return
        }

        let photo = AstroPhotoEngine(deviceType: .builtInTelephotoCamera)
        defer { photo.stop() }
        photo.start()
        let photoStarted = await wait { photo.session.isRunning }
        XCTAssertTrue(photoStarted, "长焦 RAW 会话未启动")
        photo.frameCount = 3
        photo.begin()
        let photoFinished = await wait { !photo.isCapturing && (photo.result != nil || photo.error != nil) }
        XCTAssertTrue(photoFinished, "RAW 超时")
        let photoResult = try XCTUnwrap(photo.result, photo.error ?? photo.status)
        assert12MP(photoResult)
        print("TELE-PHOTO \(Int(photoResult.size.width * photoResult.scale))x\(Int(photoResult.size.height * photoResult.scale))")
        photo.stop()
        try await Task.sleep(for: .milliseconds(400))

        let trails = AstroTrailsEngine(deviceType: .builtInTelephotoCamera)
        defer { trails.stop() }
        trails.start()
        let trailsStarted = await wait { trails.session.isRunning }
        XCTAssertTrue(trailsStarted, "长焦星轨会话未启动")
        trails.manualSettings.fusionExposureSeconds = 3
        trails.captureDurationSeconds = 3
        trails.autoSaveOnFinish = false
        trails.begin()
        let trailsFinished = await wait { !trails.isCapturing && (trails.result != nil || trails.error != nil) }
        XCTAssertTrue(trailsFinished, "星轨超时")
        let trailsResult = try XCTUnwrap(trails.result, trails.error ?? trails.status)
        assert12MP(trailsResult)
        print("TELE-TRAILS 3s \(Int(trailsResult.size.width * trailsResult.scale))x\(Int(trailsResult.size.height * trailsResult.scale))")
        trails.stop()
        try await Task.sleep(for: .milliseconds(400))

        let timelapse = AstroTimelapseEngine(deviceType: .builtInTelephotoCamera)
        defer { timelapse.stop() }
        timelapse.start()
        let timelapseStarted = await wait { timelapse.session.isRunning }
        XCTAssertTrue(timelapseStarted, "长焦延时会话未启动")
        timelapse.manualSettings.fusionExposureSeconds = 1
        timelapse.intervalSeconds = 1
        timelapse.begin()
        let timelapseFramesReady = await wait { timelapse.capturedFrames >= 2 || timelapse.error != nil }
        XCTAssertTrue(timelapseFramesReady, "4K 采帧超时")
        XCTAssertNil(timelapse.error)
        XCTAssertGreaterThanOrEqual(timelapse.capturedFrames, 2)
        timelapse.finishVerification()
        _ = await wait { !timelapse.isFinishing }
        XCTAssertNil(timelapse.error)
        print("TELE-TIMELAPSE frames=\(timelapse.capturedFrames) status=\(timelapse.status)")
        timelapse.stop()
        #endif
    }

    private func assert12MP(_ image: UIImage, file: StaticString = #filePath, line: UInt = #line) {
        let dims = (Int((image.size.width * image.scale).rounded()), Int((image.size.height * image.scale).rounded()))
        XCTAssertTrue((dims.0 == 4032 && dims.1 == 3024) || (dims.0 == 3024 && dims.1 == 4032),
                      "expected 12MP, got \(dims.0)x\(dims.1)", file: file, line: line)
    }

    @MainActor private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }
}
