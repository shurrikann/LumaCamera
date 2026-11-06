import AVFoundation
import Combine
import UIKit
import XCTest
@testable import LumaCamera

/// 以最终路由的新帧标记比较两个方向，不用单纯 ready 或旧画面的刷新冒充首帧。
final class CameraFacingLatencyPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 正常切镜保留上一张取景，避免新路由出帧前落入首次启动的准备提示。
    @MainActor func testManualFacingSwitchKeepsPreviewUntilNewRouteFrame() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func settle() async throws {
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<800 {
                if camera.ready && camera.preview != nil && model.focalTransitionImage == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("相机没有恢复取景")
        }
        model.setCameraActive(true); try await settle()
        model.setCaptureKind(.photo); try await settle()
        model.setMode(.manual); model.photoFormat = .heif; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        try await settle()
        var watching = false, cleared = 0
        let subscription = camera.$preview.sink { if watching && $0 == nil { cleared += 1 } }
        defer { subscription.cancel() }
        var times: [Double] = []
        for seconds in [1.0 / 125, 1.0 / 15, 0.5] {
            model.manualExposure = true; model.iso = 400; model.shutter = log2(seconds); model.applyExposure()
            try await settle()
            for _ in 0..<4 {
                let previous = camera.userSwitchFrameID
                let destination: AVCaptureDevice.Position = model.currentPosition == .front ? .back : .front
                let start = CACurrentMediaTime()
                watching = true
                model.flipCamera()
                for _ in 0..<800 {
                    if camera.ready && model.currentPosition == destination && camera.userSwitchFrameID != previous
                        && model.focalTransitionImage == nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                watching = false
                times.append(CACurrentMediaTime() - start)
                XCTAssertEqual(model.mode, .manual)
                XCTAssertEqual(model.currentPosition, destination)
                XCTAssertNotEqual(camera.userSwitchFrameID, previous)
                XCTAssertNotNil(camera.preview)
            }
        }
        print("MANUAL-FACING-PREVIEW samples=\(times.count) cleared=\(cleared) seconds=\(times)")
        XCTAssertEqual(cleared, 0, "正常切镜不应主动清空预览，避免闪出准备提示")
    }

    @MainActor func testPhotoAndVideoFacingDirectionLatency() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let oldKind = model.captureKind, oldMode = model.mode
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCaptureKind(oldKind); model.setMode(oldMode); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func settle() async {
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<500 {
                if camera.ready && camera.preview != nil && !camera.videoConfiguring && model.focalTransitionImage == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        model.setCameraActive(true); await settle()
        model.setCaptureKind(.photo); await settle()
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.burstModeEnabled { model.toggleBurstMode() }
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        await settle()
        var reports: [String] = []
        for kind in [CameraViewModel.CaptureKind.photo, .video] {
            model.setCaptureKind(kind); await settle()
            if kind == .video {
                if model.timeLapseEnabled { model.toggleTimeLapseMode() }
                if model.slowMotionEnabled { model.toggleSlowMotionMode() }
                if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
                model.videoCodec = .hevc; model.videoColorSpace = .sdr
                model.videoResolution = .hd1080; model.videoFrameRate = .fps30
                await settle()
            }
            for mode in [CameraShootingMode.auto, .manual] {
                model.setMode(mode); await settle()
                for index in 0..<(mode == .auto ? 8 : 4) {
                    let destination: AVCaptureDevice.Position = model.currentPosition == .front ? .back : .front
                    let previousID = camera.userSwitchFrameID, start = CACurrentMediaTime()
                    model.flipCamera()
                    var first: Double?
                    for _ in 0..<500 {
                        if first == nil, camera.ready, model.currentPosition == destination,
                           camera.preview != nil, camera.userSwitchFrameID != previousID {
                            first = CACurrentMediaTime() - start
                        }
                        if first != nil && model.focalTransitionImage == nil { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let visible = CACurrentMediaTime() - start
                    let phases = await withCheckedContinuation { c in camera.lensSwitchPhasesForTesting { c.resume(returning: $0) } }
                    XCTAssertNotNil(first, "新路由没有交付预览帧")
                    XCTAssertEqual(model.currentPosition, destination)
                    XCTAssertNil(model.focalTransitionImage)
                    XCTAssertLessThan(first ?? 10, 2.2)
                    reports.append("FLIP-DIRECTION kind=\(kind) mode=\(mode) to=\(destination == .back ? "back" : "front") index=\(index) first=\(first ?? -1) visible=\(visible) phases=\(phases)")
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let report = reports.joined(separator: "\n")
        let attachment = XCTAttachment(string: report); attachment.name = "Facing-direction-latencies"
        attachment.lifetime = .keepAlways; add(attachment); print(report)
    }
    #endif
}
