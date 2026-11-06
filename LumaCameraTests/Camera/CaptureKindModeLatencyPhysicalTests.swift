import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

/// 覆盖照片 A/M 与视频 A/M 的交叉往返，区分配置、恢复新帧与过渡收尾。
final class CaptureKindModeLatencyPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 快速请求及切换中退后台，验证最外层事务始终结束，最后一次选择仍能出帧。
    @MainActor func testRapidCrossModeSwitchAndStopRecovery() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func settle() async throws {
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<900 {
                if camera.ready && camera.preview != nil && !camera.videoConfiguring && model.focalTransitionImage == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("快速切换后未恢复取景：\(camera.message ?? "无错误信息")")
        }
        model.setCameraActive(true); try await settle()
        model.setCaptureKind(.photo); model.setMode(.auto); try await settle()
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.videoCodec = .hevc; model.videoColorSpace = .sdr
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        try await settle()
        for round in 0..<4 {
            for index in 0..<5 {
                model.setCaptureKind(.video)
                model.setMode(index.isMultiple(of: 2) ? .manual : .auto)
                model.setCaptureKind(.photo)
            }
            if round.isMultiple(of: 2) {
                model.setCameraActive(false)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                model.setCameraActive(true)
            }
            try await settle()
            XCTAssertEqual(model.captureKind, .photo)
            XCTAssertEqual(model.mode, .auto)
            let frame = camera.previewFrameTimeForTesting
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting, frame, "恢复后预览应持续更新")
            XCTAssertTrue(camera.ready)
        }
    }

    @MainActor func testCrossModePhotoVideoLatencyAndRestoration() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func settle() async {
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<700 {
                if camera.ready && camera.preview != nil && !camera.videoConfiguring && model.focalTransitionImage == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        model.setCameraActive(true); await settle()
        model.setCaptureKind(.photo); await settle()
        if model.currentPosition != .back { model.flipCamera(); await settle() }
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.videoCodec = .hevc; model.videoColorSpace = .sdr
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        model.selectFocalLength(main); await settle()
        var report: [String] = []
        func transition(_ kind: CameraViewModel.CaptureKind, label: String) async throws {
            let start = CACurrentMediaTime(), oldFrame = camera.previewFrameTimeForTesting
            model.setCaptureKind(kind)
            let configured = await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume(returning: CACurrentMediaTime()) } }
            var first: Double?
            for _ in 0..<600 {
                if first == nil, camera.previewFrameTimeForTesting > max(configured, oldFrame) { first = CACurrentMediaTime() - start }
                if first != nil && model.focalTransitionImage == nil && !camera.videoConfiguring { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(first, "切换后需要最终配置的新预览")
            XCTAssertTrue(camera.ready); XCTAssertNil(model.focalTransitionImage)
            report.append("CAPTURE-KIND \(label) to=\(kind) configure=\(configured-start) frame=\(first ?? -1) visible=\(CACurrentMediaTime()-start)")
        }
        for photoMode in [CameraShootingMode.auto, .manual] {
            for videoMode in [CameraShootingMode.auto, .manual] {
                for cycle in 0..<3 {
                    model.setCaptureKind(.photo); await settle()
                    model.setMode(photoMode)
                    model.manualExposure = false; model.manualWB = false; model.manualFocus = false
                    model.applyExposure(); model.applyWhiteBalance(); await settle()
                    try await transition(.video, label: "photo=\(photoMode) video=\(videoMode) cycle=\(cycle)")
                    model.setMode(videoMode); await settle()
                    try await transition(.photo, label: "photo=\(photoMode) video=\(videoMode) cycle=\(cycle)")
                    XCTAssertEqual(model.mode, photoMode, "返回照片必须恢复原照片挡位")
                    try await transition(.video, label: "remembered-video photo=\(photoMode) video=\(videoMode) cycle=\(cycle)")
                    XCTAssertEqual(model.mode, videoMode, "再次进入视频必须恢复原视频挡位")
                    try await transition(.photo, label: "remembered-photo photo=\(photoMode) video=\(videoMode) cycle=\(cycle)")
                    XCTAssertEqual(model.mode, photoMode)
                    try await Task.sleep(for: .milliseconds(120))
                }
            }
        }
        let text = report.joined(separator: "\n"); print(text)
        let attachment = XCTAttachment(string: text); attachment.name = "Photo-video-cross-mode-latency"; attachment.lifetime = .keepAlways; add(attachment)
    }
    #endif
}
