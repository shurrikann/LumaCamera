import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class CaptureStatePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 模型生命周期先经过主队列，再进入相机串行队列；只等待引擎队列不能证明旧会话已停止。
    @MainActor private func stopAndWait(_ model: CameraViewModel) async {
        model.setCameraActive(false)
        await withCheckedContinuation { c in
            DispatchQueue.main.async { model.camera.afterPendingSessionTasks { c.resume() } }
        }
        let running = await withCheckedContinuation { c in
            model.camera.actualSessionRunningForTesting { c.resume(returning: $0) }
        }
        XCTAssertFalse(running, "创建下一个冷启动模型前，旧会话必须完全停止")
        XCTAssertFalse(model.camera.ready)
    }

    /// 独立模型只在旧会话真正停止后启动；任意断言抛错也必须异步收尾，避免污染后续硬件测试。
    @MainActor func testColdRestorationAppliesManualValuesToRealLensAndVideoPipeline() async throws {
        let visible = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let visibleWasReady = visible.camera.ready
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        await stopAndWait(visible)
        let audit = SessionRuntimeErrorAudit()
        defer {
            audit.finish()
            UIApplication.shared.isIdleTimerDisabled = idle
            visible.setCameraActive(visibleWasReady)
        }
        let name = "CaptureHardware-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        // 三轮照片/视频冷启动，分别覆盖焦段倍率恢复与真实 P3 视频编码。
        for (index, video) in [false, true, false, true, false, true].enumerated() {
            var state = SavedCaptureState()
            state.mode = "M"; state.photoMode = "M"; state.video = video
            state.manual = SavedManualCaptureState(exposure: true, whiteBalance: true, focusLocked: true,
                iso: 200, shutter: log2(1.0 / 125), wb: 5500, tint: 10, focus: 0.7, ev: 0)
            state.videoColorSpace = "P3"
            if !video, let lens = visible.camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 4) < 0.01 }) {
                state.lensID = lens.id; state.zoom = Double(lens.displayZoom * 1.25)
            }
            store.saveCaptureState(state)
            let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
            let camera = model.camera
            do {
                var result: Result<URL, Error>?
                camera.onVideoRecorded = { result = $0 }
                let began = CACurrentMediaTime()
                model.setCameraActive(true)
                for _ in 0..<500 {
                    if camera.ready, let readings = camera.readings,
                       abs(readings.iso - 200) < 5, abs(readings.seconds - 1.0 / 125) < 0.001,
                       state.lensID == nil || (camera.selectedLens == state.lensID && abs(Double(camera.currentZoom) - state.zoom) < 0.02) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(camera.ready)
                let readings = try XCTUnwrap(camera.readings)
                XCTAssertEqual(readings.iso, 200, accuracy: 5)
                XCTAssertEqual(readings.seconds, 1.0 / 125, accuracy: 0.001)
                let actual = await withCheckedContinuation { c in
                    camera.exposureColorState { c.resume(returning: $0) }
                }
                let hardware = try XCTUnwrap(actual)
                XCTAssertEqual(hardware.exposureMode, .custom)
                XCTAssertEqual(hardware.whiteBalanceMode, .locked)
                XCTAssertEqual(hardware.focusMode, .locked)
                XCTAssertEqual(Double(hardware.lensPosition), 0.7, accuracy: 0.03)
                XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualWB); XCTAssertTrue(model.manualFocus)
                if let lensID = state.lensID {
                    XCTAssertEqual(camera.selectedLens, lensID)
                    XCTAssertEqual(Double(camera.currentZoom), state.zoom, accuracy: 0.02)
                }
                XCTAssertEqual(model.mode, .manual)
                XCTAssertEqual(model.captureKind, video ? .video : .photo)
                let restoredAfter = CACurrentMediaTime() - began
                if video {
                    for _ in 0..<200 { if model.videoShutterEnabled { break }; try await Task.sleep(for: .milliseconds(20)) }
                    XCTAssertEqual(camera.videoSettings.colorSpace, .p3)
                    XCTAssertEqual(camera.videoSettings.resolution, .hd1080)
                    XCTAssertEqual(camera.videoSettings.frameRate, .fps30)
                    model.toggleVideoRecording()
                    for _ in 0..<200 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
                    XCTAssertTrue(camera.videoRecording)
                    try await Task.sleep(for: .milliseconds(500))
                    camera.stopVideoRecording()
                    for _ in 0..<250 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                    if case .success(let url) = result {
                        defer { try? FileManager.default.removeItem(at: url) }
                        let asset = AVURLAsset(url: url)
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        XCTAssertFalse(tracks.isEmpty)
                        let audio = try await asset.loadTracks(withMediaType: .audio)
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { XCTAssertFalse(audio.isEmpty) }
                    } else { XCTFail("Restored video capture failed: \(String(describing: result))") }
                }
                print("CAPTURE-RESTORE index=\(index) video=\(video) readyAndParameters=\(restoredAfter) total=\(CACurrentMediaTime()-began) iso=\(readings.iso) shutter=\(readings.seconds) zoom=\(camera.currentZoom)")
                await stopAndWait(model)
            } catch {
                await stopAndWait(model)
                throw error
            }
        }
    }
    /// 冷启动过程中快速离开/返回，只允许最新生命周期启动；最终退出后不能被迟到的恢复任务唤醒。
    @MainActor func testColdRestorationRapidCancellationAndReturnDoesNotLeaveSessionRunning() async throws {
        let visible = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let wasReady = visible.camera.ready, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        await stopAndWait(visible)
        let audit = SessionRuntimeErrorAudit()
        defer {
            audit.finish(); UIApplication.shared.isIdleTimerDisabled = idle
            visible.setCameraActive(wasReady)
        }
        let name = "CaptureCancel-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        for index in 0..<3 {
            var state = SavedCaptureState()
            state.mode = "M"; state.photoMode = "M"; state.videoMode = "M"
            state.video = index == 1
            state.manual = SavedManualCaptureState(exposure: true, whiteBalance: true, focusLocked: true,
                iso: 200, shutter: log2(1.0 / 125), wb: 5500, tint: 10, focus: 0.7, ev: 0)
            store.saveCaptureState(state)
            let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
            do {
                let began = CACurrentMediaTime()
                for _ in 0..<10 { model.setCameraActive(true); model.setCameraActive(false) }
                model.setCameraActive(true)
                for _ in 0..<500 {
                    if model.camera.ready, let r = model.camera.readings,
                       abs(r.iso - 200) < 5, abs(r.seconds - 1.0 / 125) < 0.001 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(model.camera.ready)
                let readings = try XCTUnwrap(model.camera.readings)
                XCTAssertEqual(readings.iso, 200, accuracy: 5)
                XCTAssertEqual(readings.seconds, 1.0 / 125, accuracy: 0.001)
                print("CAPTURE-RESTORE-CANCEL index=\(index) requests=21 readyAndParameters=\(CACurrentMediaTime()-began)")
                await stopAndWait(model)
                try await Task.sleep(for: .milliseconds(300))
                let running = await withCheckedContinuation { c in
                    model.camera.actualSessionRunningForTesting { c.resume(returning: $0) }
                }
                XCTAssertFalse(running, "退出后迟到的参数恢复不能重启相机")
                XCTAssertFalse(model.camera.ready)
            } catch {
                await stopAndWait(model)
                throw error
            }
        }
    }
    #endif
}
