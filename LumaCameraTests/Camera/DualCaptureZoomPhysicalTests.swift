import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

@MainActor final class DualCaptureZoomPhysicalTests: XCTestCase {
    func testMainZoomDuringRecordingAndRepeatedSwap() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        let callback = camera.onVideoRecorded
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
            if case let .success(url)? = result { try? FileManager.default.removeItem(at: url) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < end {
                if predicate() { return }; try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        func state() async -> [String: String] {
            await withCheckedContinuation { c in camera.dualCaptureStateForTesting { c.resume(returning: $0) } }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video)
        try await wait("视频") { camera.ready && !camera.videoConfiguring }
        model.toggleDualCapture()
        try await wait("双拍") { camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        if camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("后置主画面") { !camera.dualCaptureMainIsFront }
        }
        // 前置主画面时，小窗属于后置；横幅不能禁用前置焦段切换。
        model.swapDualCaptureCameras(); try await wait("前置主画面") { camera.dualCaptureMainIsFront }
        if !camera.dualCaptureInsetLandscape { model.toggleDualCaptureInsetAspect() }
        try await wait("后置横幅小窗") { camera.dualCaptureInsetLandscape && !model.dualInsetAspectChanging }
        let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        // 前置主画面固定超广角，不再允许切回 1×。
        XCTAssertTrue(camera.dualCaptureFrontWide)
        XCTAssertFalse(model.canSelectFocalLength(standard))
        XCTAssertTrue(camera.dualCaptureFrontWide)
        _ = wide
        model.swapDualCaptureCameras(); try await wait("后置主画面与前置广角小窗") { !camera.dualCaptureMainIsFront && camera.dualCaptureFrontWide }
        model.toggleDualCaptureInsetAspect()
        try await wait("小窗恢复竖幅") { !camera.dualCaptureInsetLandscape && !model.dualInsetAspectChanging }
        try await Task.sleep(for: .milliseconds(300))
        let baseline = await state(), sourceID = baseline["sourceID"], frontZoom = baseline["frontZoom"]
        model.toggleVideoRecording(); try await wait("开始录制") { camera.videoRecording }
        let lens = try XCTUnwrap(model.displayedFocalLenses.first { abs($0.displayZoom - 2) < 0.01 })
        XCTAssertTrue(model.canSelectFocalLength(lens))
        model.selectFocalLength(lens)
        try await Task.sleep(for: .milliseconds(250))
        let tapped = await state()
        XCTAssertEqual(Double(tapped["mainZoom"] ?? "") ?? -1, 2, accuracy: 0.02)
        model.openZoomDial(); XCTAssertTrue(model.zoomDialVisible)
        var publications = [Double](), last = camera.previewFrameTimeForTesting
        let began = CACurrentMediaTime()
        // 高频连续手势覆盖进出整数倍率、立即反向以及末尾目标；实际录制图保持不变。
        for step in 0..<120 {
            model.dragZoomDial(translation: -CGFloat(step % 40) * 2, width: 300)
            try await Task.sleep(for: .milliseconds(20))
            let now = camera.previewFrameTimeForTesting
            if now > last { publications.append(now - last); last = now }
        }
        model.finishZoomDrag()
        let target = camera.currentZoom
        try await Task.sleep(for: .milliseconds(180))
        let zoomed = await state()
        XCTAssertEqual(zoomed["sourceID"], sourceID)
        XCTAssertEqual(zoomed["frontZoom"], frontZoom)
        XCTAssertEqual(Double(zoomed["mainZoom"] ?? "") ?? -1, Double(target), accuracy: 0.03)
        XCTAssertGreaterThan(publications.count, 12)
        print("DUAL-ZOOM samples=120 seconds=\(CACurrentMediaTime()-began) publications=\(publications.count) maxPublicationGap=\(publications.max() ?? -1) framesBefore=\(baseline["frames"] ?? "") framesAfter=\(zoomed["frames"] ?? "")")
        for _ in 0..<3 {
            model.swapDualCaptureCameras(); try await wait("前置主画面") { camera.dualCaptureMainIsFront }
            try await Task.sleep(for: .milliseconds(100))
            model.openZoomDial(); XCTAssertTrue(model.zoomDialVisible)
            model.dragZoomDial(translation: -10, width: 300); model.finishZoomDrag()
            model.swapDualCaptureCameras(); try await wait("后置恢复") { !camera.dualCaptureMainIsFront }
        }
        model.endZoomDial(); camera.stopVideoRecording()
        try await wait("停止") { result != nil && !camera.videoBusy }
        let url = try XCTUnwrap(result).get()
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertGreaterThan(rate, 20)
        model.toggleDualCapture(); try await wait("退出") { !camera.dualCaptureEnabled && camera.ready }
    }
    func testTimeLapseWheelContinuityAndCancel() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        model.toggleTimeLapseMode()
        try await wait("延时") { model.timeLapseEnabled && camera.ready && !model.isPreparingSubmode && !camera.videoConfiguring }
        // ready表示会话配置完成，电影级防抖仍可能在填充初始缓冲；先等待该路由的新帧。
        let readyAt = CACurrentMediaTime()
        try await wait("延时新帧") { camera.previewFrameTimeForTesting > readyAt }
        let input = camera.activeCaptureDeviceID
        var intervals = [Double](), last = 0.0
        for pass in 0..<3 {
            last = 0 // 不把模式启动/弹窗准备时间计入手势期间的采集间隔。
            model.openZoomDial(); XCTAssertTrue(model.zoomDialVisible)
            for step in 0..<60 {
                model.dragZoomDial(translation: -CGFloat(step < 30 ? step : 60-step) * 0.6, width: 300)
                try await Task.sleep(for: .milliseconds(20))
                let now = camera.previewFrameTimeForTesting
                if now > last {
                    if last > 0 {
                        intervals.append(now-last)
                        if now-last > 0.15 { print("TIMELAPSE-GAP pass=\(pass) step=\(step) seconds=\(now-last)") }
                    }
                    last = now
                }
            }
            model.finishZoomDrag(); model.endZoomDial()
            XCTAssertEqual(camera.activeCaptureDeviceID, input, "同镜头范围的手势不得重建输入")
            print("TIMELAPSE-ZOOM pass=\(pass) actual=\(camera.currentZoom)")
        }
        XCTAssertGreaterThan(intervals.count, 25)
        XCTAssertLessThan(intervals.max() ?? 1, 0.2, "连续手势期间不得发生长采集停顿")
        print("TIMELAPSE-ZOOM events=180 publications=\(intervals.count) maxPublicationGap=\(intervals.max() ?? -1)")
        model.toggleTimeLapseMode()
        try await wait("退出") { !model.timeLapseEnabled && camera.ready && !model.isPreparingSubmode }
        XCTAssertFalse(model.zoomDialVisible)
    }

}
