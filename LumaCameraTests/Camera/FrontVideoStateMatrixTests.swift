import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class FrontVideoStateMatrixTests: XCTestCase {
    #if !targetEnvironment(simulator)
    private func wait(_ label: String, timeout: Double = 20,
                      _ predicate: () -> Bool, _ camera: CameraEngine) async throws {
        let end = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < end {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(label + " message=\(camera.message ?? "nil")")
        throw CancellationError()
    }

    @MainActor func testFrontVideoEntryPathsPhotoRoundTripAndFocalLock() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        func physicalZoom() async -> Double {
            await withCheckedContinuation { c in
                camera.exposureColorState { state in c.resume(returning: Double(state?.physicalZoomFactor ?? 0)) }
            }
        }

        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.photo)
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("照片前置", { camera.ready && model.currentPosition == .front }, camera)
        model.selectFocalLength(standard)
        try await wait("照片标准", { camera.selectedLens == standard.id }, camera)
        let entryPhotoZoom = await physicalZoom()
        XCTAssertEqual(entryPhotoZoom, Double(standard.zoomFactor), accuracy: 0.01)

        // 路径1：照片前置标准 → 视频，必须自动回固定超广角且拒绝焦段切换。
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "照片前置换视频", timeout: 20)
        // 视频前置固定 wide 由设备倍率完成，不改写照片镜头选择。
        XCTAssertEqual(camera.selectedLens, standard.id)
        XCTAssertFalse(model.canSelectFocalLength(standard))
        XCTAssertFalse(model.canSelectFocalLength(wide))

        // 路径2：视频后置 → 切前置，仍固定超广角。
        model.setCaptureKind(.photo)
        try await wait("回照片", { camera.ready && model.captureKind == .photo }, camera)
        if model.currentPosition == .front { model.flipCamera() }
        try await wait("照片后置", { camera.ready && model.currentPosition == .back }, camera)
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "后置换视频", timeout: 20)
        model.flipCamera()
        try await wait("视频切前置", { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }, camera)
        let flipZoom = await physicalZoom()
        XCTAssertEqual(camera.selectedLens, standard.id)
        XCTAssertEqual(flipZoom, Double(wide.zoomFactor), accuracy: 0.01,
                       "视频中从后置切前置也必须实际使用超广角")
        XCTAssertFalse(model.canSelectFocalLength(standard))

        // 路径3：视频前置追踪 → 照片，追踪必须清理；再进视频恢复固定广角且追踪关闭。
        model.toggleFrontVideoCentering()
        try await wait("追踪开启", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
        model.setCaptureKind(.photo)
        try await wait("追踪后回照片", { camera.ready && model.captureKind == .photo && !camera.frontVideoCenteringEnabled }, camera)
        XCTAssertFalse(model.frontVideoCenteringRequested)
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "追踪后回视频", timeout: 20)
        XCTAssertEqual(camera.selectedLens, standard.id)
        XCTAssertFalse(model.frontVideoCenteringRequested)
        XCTAssertFalse(camera.frontVideoCenteringEnabled)
        print("FRONT-VIDEO-MATRIX entryPaths=photoFront,videoBackToFront,photoRoundTrip focalLocked=true")
    }


    @MainActor func testFrontVideoUsesWideWithoutChangingPhotoFraming() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        func physicalZoom() async -> Double {
            await withCheckedContinuation { c in
                camera.exposureColorState { state in c.resume(returning: Double(state?.physicalZoomFactor ?? 0)) }
            }
        }
        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("照片前置", { camera.ready && model.currentPosition == .front }, camera)
        camera.setFrontPhotoLandscapeEnabled(false)
        // 复现用户路径：照片超广角 → 切回标准 → 视频前置 → 回照片。
        model.selectFocalLength(wide)
        try await wait("照片超广角", { camera.selectedLens == wide.id && !camera.capturing }, camera)
        model.selectFocalLength(standard)
        try await wait("照片标准", { camera.selectedLens == standard.id && !camera.capturing }, camera)
        let photoZoom = await physicalZoom()
        XCTAssertEqual(photoZoom, Double(standard.zoomFactor), accuracy: 0.01)

        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "前置视频", timeout: 20)
        let videoZoom = await physicalZoom()
        XCTAssertEqual(camera.selectedLens, standard.id, "视频固定广角不能改写照片镜头选择")
        XCTAssertEqual(videoZoom, Double(wide.zoomFactor), accuracy: 0.01, "视频前置实际硬件倍率应为超广角")

        model.setCaptureKind(.photo)
        try await wait("回照片", { camera.ready && model.captureKind == .photo && !camera.videoConfiguring }, camera)
        let returnedZoom = await physicalZoom()
        XCTAssertEqual(camera.selectedLens, standard.id)
        XCTAssertEqual(returnedZoom, photoZoom, accuracy: 0.01, "回照片必须恢复进入视频前的取景倍率")
        print("FRONT-VIDEO-MATRIX photoFraming photoZoom=\(photoZoom) videoZoom=\(videoZoom) returnedZoom=\(returnedZoom) selected=\(camera.selectedLens)")
    }

    @MainActor func testFrontVideoWideSurvivesForegroundResume() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        func physicalZoom() async -> Double {
            await withCheckedContinuation { c in
                camera.exposureColorState { state in c.resume(returning: Double(state?.physicalZoomFactor ?? 0)) }
            }
        }
        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "恢复前视频前置", timeout: 20)
        let beforeResume = await physicalZoom()
        XCTAssertEqual(beforeResume, Double(wide.zoomFactor), accuracy: 0.01)

        model.setCameraActive(false)
        try await wait("停止", { !camera.ready }, camera)
        try await Task.sleep(for: .milliseconds(400))
        model.setCameraActive(true)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "回前台视频前置", timeout: 20)
        let afterResume = await physicalZoom()
        XCTAssertEqual(afterResume, Double(wide.zoomFactor), accuracy: 0.01,
                       "回前台后仍必须保持视频前置超广角")
        XCTAssertEqual(model.captureKind, .video)
        print("FRONT-VIDEO-MATRIX foregroundResumeWide=true")
    }
    @MainActor func testTrackingDualStateTransitionsIncludingInsetAndExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }

        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "前置视频", timeout: 20)

        // A：先追踪，再双拍，再主/小窗往返。
        model.toggleFrontVideoCentering()
        try await wait("追踪", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
        model.toggleDualCapture()
        try await wait("双拍", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
        if !camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("前置主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        }
        XCTAssertTrue(camera.frontVideoCenteringEnabled)
        XCTAssertTrue(camera.frontVideoCenteringActive)
        model.swapDualCaptureCameras()
        try await wait("前置小窗", { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        XCTAssertTrue(camera.frontVideoCenteringActive)
        XCTAssertFalse(model.frontVideoCenteringVisible)
        model.swapDualCaptureCameras()
        try await wait("回前置主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        XCTAssertTrue(camera.frontVideoCenteringActive)
        model.toggleDualCapture()
        try await wait("退出双拍", { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }, camera)
        XCTAssertEqual(model.captureKind, .video)
        XCTAssertFalse(camera.frontVideoCenteringEnabled)

        // B：双拍先开，再在前置主画面开启追踪，然后小窗继续。
        model.toggleDualCapture()
        try await wait("再次双拍", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
        if !camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("再次前置主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        }
        XCTAssertFalse(camera.frontVideoCenteringEnabled)
        try await wait("双拍再次就绪", { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing }, camera)
        model.toggleFrontVideoCentering()
        try await wait("双拍内开追踪", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
        model.swapDualCaptureCameras()
        try await wait("双拍内切小窗", { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        XCTAssertTrue(camera.frontVideoCenteringActive)
        model.swapDualCaptureCameras()
        try await wait("双拍内切回主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        model.toggleFrontVideoCentering()
        try await wait("双拍内关追踪", { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringActive }, camera)
        model.toggleDualCapture()
        try await wait("最后退出双拍", { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }, camera)
        XCTAssertEqual(model.captureKind, .video)
        print("FRONT-VIDEO-MATRIX trackingDual=beforeAndAfter insetContinuation=true exitStopsTracking=true")
    }

    @MainActor func testDualFrontTrackingRecordsAndKeepsVideoMode() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        let callback = camera.onVideoRecorded
        camera.onVideoRecorded = { result = $0 }
        defer { camera.onVideoRecorded = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }

        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "录制前置", timeout: 20)
        model.toggleDualCapture()
        try await wait("双拍", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
        if !camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("前置主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        }
        try await wait("双拍录制就绪", { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing }, camera)
        model.toggleFrontVideoCentering()
        try await wait("追踪", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "双拍追踪录制", timeout: 20)
        model.toggleVideoRecording()
        try await wait("开始录制", { camera.videoRecording }, camera)
        try await Task.sleep(for: .milliseconds(1500))
        model.toggleVideoRecording()
        try await wait("结束录制", { result != nil && !camera.videoBusy }, camera)
        let url = try XCTUnwrap(result?.get())
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(frames, 10)
        XCTAssertEqual(model.captureKind, .video)
        XCTAssertTrue(camera.dualCaptureEnabled)
        XCTAssertTrue(camera.frontVideoCenteringActive)
        print("FRONT-VIDEO-MATRIX dualTrackingRecord frames=\(frames) size=\(try await track.load(.naturalSize))")
    }
    #endif
}
