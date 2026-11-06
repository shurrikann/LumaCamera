import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

/// 真实硬件正常完成后，注入应用漏收最终通知；不故意让系统服务长时间占用摄像头。
final class PhotoCaptureTimeoutPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor private func wait(_ message: String, seconds: Double = 12,
                                 until predicate: () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw NSError(domain: "PhotoTimeoutTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor private func state(_ camera: CameraEngine) async -> (Int, Int, Int, Int) {
        await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning: ($0, $1, $2, $3)) } }
    }
    @MainActor private func ready(_ camera: CameraEngine) async throws {
        try await wait("相机未交付恢复后的预览") { camera.ready && camera.preview != nil && !camera.recoveringSession }
    }

    @MainActor func testMissingPortraitFinalReleasesOrderedResultsAndVideoCanRecord() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, videoCallback = camera.onVideoRecorded
        let idle = UIApplication.shared.isIdleTimerDisabled
        var photos: [CapturedPhoto] = [], movie: Result<URL, Error>?
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCaptureCompleted = { if let photo = $0 { photos.append(photo) } }
        camera.onVideoRecorded = { movie = $0 }
        defer {
            camera.dropFinalPhotoCallbackForTesting = false; camera.nativeCaptureTimeoutForTesting = nil
            camera.replayAndClearDroppedPhotoFinalForTesting()
            if camera.videoBusy { camera.stopVideoRecording() }
            if case .success(let url) = movie { try? FileManager.default.removeItem(at: url) }
            camera.onCaptureCompleted = callback; camera.onVideoRecorded = videoCallback
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        model.setCameraActive(true); try await ready(camera)
        if model.currentPosition != .back { model.flipCamera(); try await ready(camera) }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        if camera.selectedLens != main.id { model.selectFocalLength(main); try await ready(camera) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let originalOutput = await withCheckedContinuation { c in camera.photoOutputIdentityForTesting { c.resume(returning: $0) } }
        camera.nativeCaptureTimeoutForTesting = 6
        camera.dropFinalPhotoCallbackForTesting = true
        var portrait = PhotoOptions(format: .heif); portrait.portraitMode = true
        let began = CACurrentMediaTime()
        camera.capture(flashMode: .off, options: portrait)
        try await wait("未执行漏回调注入", seconds: 5) {
            await withCheckedContinuation { c in camera.droppedPhotoFinalForTesting { c.resume(returning: $0) } }
        }
        XCTAssertEqual(camera.pendingPhotoCount, 1)
        camera.dropFinalPhotoCallbackForTesting = false
        // 较新的成功照片先收尾，必须等待前一请求结束后按快门顺序交付。
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
        try await wait("后续照片未进入有序结果缓冲", seconds: 4) { (await self.state(camera)).3 == 1 }
        XCTAssertTrue(photos.isEmpty)
        try await wait("超时后任务/计数未清空") {
            let s = await self.state(camera)
            return s.0 == 0 && s.1 == 0 && s.2 == 0 && s.3 == 0 && camera.pendingPhotoCount == 0
        }
        let released = CACurrentMediaTime() - began
        XCTAssertEqual(photos.count, 1, "丢弃超时照片，但须保留后续已成功的照片")
        XCTAssertFalse(camera.capturing); XCTAssertFalse(camera.shutterBusy)
        try await ready(camera)
        let replacementOutput = await withCheckedContinuation { c in camera.photoOutputIdentityForTesting { c.resume(returning: $0) } }
        XCTAssertNotEqual(originalOutput, replacementOutput, "不能在已漏回调的旧输出上继续提交")
        let fallback = await withCheckedContinuation { c in camera.portraitFallbackForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(fallback, "本轮后置主摄原生人像请求超时后，必须实际关闭该设备原生蒙版路线")
        camera.replayAndClearDroppedPhotoFinalForTesting()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(camera.pendingPhotoCount, 0); XCTAssertEqual(photos.count, 1)
        camera.nativeCaptureTimeoutForTesting = nil; camera.message = nil
        camera.capture(flashMode: .off, options: portrait)
        try await wait("恢复后 HEIF 照片未交付") { photos.count == 2 && camera.pendingPhotoCount == 0 }
        model.setCaptureKind(.video)
        try await wait("恢复后视频未就绪") { model.videoShutterEnabled && camera.ready && !camera.videoConfiguring }
        camera.startVideoRecording(aspect: .wide)
        try await wait("恢复后视频未开始") { camera.videoRecording || movie != nil }
        XCTAssertTrue(camera.videoRecording)
        try await Task.sleep(for: .milliseconds(500)); camera.stopVideoRecording()
        try await wait("恢复后视频没有结束") { movie != nil }
        let url = try XCTUnwrap(movie?.get())
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
        print("PHOTO-TIMEOUT-RECOVERY injected=true releasedSeconds=\(released) photosAfterRecovery=\(photos.count) reorderedSuccessRetained=true oldCompletionReplayed=2 portraitFallback=\(fallback) videoRecorded=true noPhotosWrites=true")
    }

    @MainActor func testTimeoutAfterLeavingCameraCannotRestartUntilUserReturns() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        var photos = 0
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCaptureCompleted = { if $0 != nil { photos += 1 } }
        defer {
            camera.dropFinalPhotoCallbackForTesting = false; camera.nativeCaptureTimeoutForTesting = nil
            camera.replayAndClearDroppedPhotoFinalForTesting(); camera.onCaptureCompleted = callback
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true); try await ready(camera)
        camera.nativeCaptureTimeoutForTesting = 4; camera.dropFinalPhotoCallbackForTesting = true
        camera.capture(flashMode: .off, options: PhotoOptions(format: .heif))
        try await wait("未执行漏回调注入", seconds: 3) {
            await withCheckedContinuation { c in camera.droppedPhotoFinalForTesting { c.resume(returning: $0) } }
        }
        model.setCameraActive(false)
        try await wait("退出后未释放超时任务") { camera.pendingPhotoCount == 0 && !camera.capturing }
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running); XCTAssertFalse(camera.ready); XCTAssertEqual(photos, 0)
        camera.dropFinalPhotoCallbackForTesting = false; camera.nativeCaptureTimeoutForTesting = nil
        camera.replayAndClearDroppedPhotoFinalForTesting()
        model.setCameraActive(true); try await ready(camera)
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
        try await wait("用户返回后不能正常拍照") { photos == 1 && camera.pendingPhotoCount == 0 }
        print("PHOTO-TIMEOUT-LIFECYCLE injected=true backgroundRestart=false pending=0 returnedPhoto=1 noPhotosWrites=true")
    }

    @MainActor func testFourUnfinishedRequestsReleaseAllCapacityAndCanCaptureAgain() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        var photos = 0
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCaptureCompleted = { if $0 != nil { photos += 1 } }
        defer {
            camera.dropFinalPhotoCallbackForTesting = false; camera.nativeCaptureTimeoutForTesting = nil
            camera.replayAndClearDroppedPhotoFinalForTesting(); camera.onCaptureCompleted = callback
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        model.setCameraActive(true); try await ready(camera)
        camera.nativeCaptureTimeoutForTesting = 10; camera.dropFinalPhotoCallbackForTesting = true
        let options = PhotoOptions(format: .heif), began = CACurrentMediaTime()
        for index in 0..<4 {
            let previous = await withCheckedContinuation { c in camera.droppedPhotoTokenForTesting { c.resume(returning: $0) } }
            camera.capture(flashMode: .off, options: options)
            try await wait("第 \(index + 1) 个请求未到达漏回调检查点", seconds: 4) {
                let current = await withCheckedContinuation { c in camera.droppedPhotoTokenForTesting { c.resume(returning: $0) } }
                return current != nil && current != previous
            }
        }
        let blocked = await state(camera)
        XCTAssertEqual(camera.pendingPhotoCount, 4)
        XCTAssertEqual(blocked.0, 4); XCTAssertEqual(blocked.1, 4); XCTAssertEqual(blocked.2, 4)
        XCTAssertFalse(camera.hasCaptureCapacity(for: options))
        try await wait("四个旧输出请求未全部释放") {
            let s = await self.state(camera)
            return s.0 == 0 && s.1 == 0 && s.2 == 0 && s.3 == 0 && camera.pendingPhotoCount == 0
        }
        try await ready(camera)
        XCTAssertFalse(camera.capturing); XCTAssertEqual(camera.pendingCaptureWeight, 0)
        XCTAssertTrue(camera.hasCaptureCapacity(for: options)); XCTAssertEqual(photos, 0)
        camera.dropFinalPhotoCallbackForTesting = false; camera.nativeCaptureTimeoutForTesting = nil
        camera.message = nil; camera.replayAndClearDroppedPhotoFinalForTesting()
        camera.capture(flashMode: .off, options: options)
        try await wait("四个旧请求清理后新照片未交付") { photos == 1 && camera.pendingPhotoCount == 0 }
        print("PHOTO-TIMEOUT-FOUR injected=true unfinishedBefore=4 unfinishedAfter=0 resumedPhoto=1 totalSeconds=\(CACurrentMediaTime() - began) noPhotosWrites=true")
    }
    #endif
}
