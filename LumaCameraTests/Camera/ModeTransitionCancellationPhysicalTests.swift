import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

#if !targetEnvironment(simulator)
@MainActor final class ModeTransitionCancellationPhysicalTests: XCTestCase {
    private func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 20
        while !predicate() {
            guard CACurrentMediaTime() < deadline else {
                XCTFail(label)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func startVideo(_ model: CameraViewModel) async throws {
        model.setCameraActive(true)
        try await waitUntil("照片启动未完成") { model.camera.ready && !model.isPreparingTransition }
        model.requestCaptureKind(.video)
        try await waitUntil("视频启动未完成") {
            model.captureKind == .video && model.camera.ready && !model.isPreparingTransition
        }
    }

    func testPhotoRequestCancelsCinematicPreparationImmediately() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        try await startVideo(model)
        for cycle in 0..<3 {
            let started = CACurrentMediaTime()
            model.toggleCinematicVideoMode()
            model.requestCaptureKind(.photo)
            // 真实入口的返回请求应立即取消准备，随后等照片会话重新送帧。
            XCTAssertEqual(model.captureKind, .photo, "cycle=\(cycle) 返回照片仍在等待电影准备")
            try await waitUntil("取消电影后照片未恢复") {
                model.captureKind == .photo && model.camera.ready && !model.isPreparingTransition
                    && model.camera.previewFrameTimeForTesting > started
            }
            XCTAssertFalse(model.cinematicVideoEnabled)
            XCTAssertFalse(model.camera.cinematicVideoCaptureActive)
            XCTAssertNil(model.camera.message)
            print("MODE-CANCEL cycle=\(cycle) photoReadySeconds=\(CACurrentMediaTime() - started)")
            model.requestCaptureKind(.video)
            try await waitUntil("再次进入视频未完成") {
                model.captureKind == .video && model.camera.ready && !model.isPreparingTransition
            }
        }
    }

    func testLeavingCameraDiscardsQueuedModeAndSubmodeRequests() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        try await startVideo(model)
        model.toggleCinematicVideoMode()
        model.toggleTimeLapseMode()
        model.requestCaptureKind(.photo)
        let kindAtExit = model.captureKind
        let timeLapseAtExit = model.timeLapseEnabled
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        try await waitUntil("退出相机后仍有切换请求") { !model.isPreparingTransition }
        XCTAssertEqual(model.captureKind, kindAtExit)
        XCTAssertEqual(model.timeLapseEnabled, timeLapseAtExit)
        model.setCameraActive(true)
        try await waitUntil("重新打开相机未恢复") { model.camera.ready && !model.isPreparingTransition }
        XCTAssertEqual(model.captureKind, kindAtExit)
        XCTAssertEqual(model.timeLapseEnabled, timeLapseAtExit)
        XCTAssertEqual(model.camera.cinematicVideoCaptureActive, model.cinematicVideoEnabled)
        XCTAssertNil(model.camera.message)
    }

    func testPhotoAndVideoSubmodeMatrixRestoresFramesAndMode() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        model.setCameraActive(true)
        try await waitUntil("照片启动未完成") { camera.ready && !model.isPreparingTransition }
        model.photoFormat = .heif
        let photos: [(String, () -> Void, () -> Bool)] = [
            ("慢门", { model.toggleSlowShutterMode() }, { model.slowShutterEnabled }),
            ("人像", { model.togglePortraitMode() }, { model.portraitModeEnabled }),
            ("连拍", { model.toggleBurstMode() }, { model.burstModeEnabled }),
            ("星芒", { model.toggleVirtualAperture() }, { model.virtualApertureEnabled })
        ]
        let videos: [(String, () -> Void, () -> Bool)] = [
            ("延时", { model.toggleTimeLapseMode() }, { model.timeLapseEnabled }),
            ("慢动作", { model.toggleSlowMotionMode() }, { model.slowMotionEnabled }),
            ("电影", { model.toggleCinematicVideoMode() }, { model.cinematicVideoEnabled && camera.cinematicVideoCaptureActive }),
            ("双拍", { model.toggleDualCapture() }, { camera.dualCaptureEnabled }),
            ("星芒", { model.toggleVirtualAperture() }, { model.virtualApertureEnabled })
        ]
        var samples = [Double]()
        for (photoIndex, photo) in photos.enumerated() {
            for (videoIndex, video) in videos.enumerated() {
                model.setMode((photoIndex + videoIndex).isMultiple(of: 2) ? .auto : .manual)
                try await waitUntil("照片挡位未就绪") { camera.ready && !model.isPreparingTransition }
                photo.1()
                try await waitUntil("照片子模式未启用 \(photo.0)") {
                    photo.2() && camera.ready && !model.isPreparingTransition
                }
                let savedMode = model.mode
                let entry = CACurrentMediaTime()
                model.requestCaptureKind(.video)
                try await waitUntil("进入视频未完成") {
                    model.captureKind == .video && camera.ready && !model.isPreparingTransition
                        && camera.previewFrameTimeForTesting > entry
                }
                let videoEntrySeconds = CACurrentMediaTime() - entry
                let submode = CACurrentMediaTime()
                video.1()
                try await waitUntil("视频子模式未启用 \(video.0)，\(camera.message ?? "")") {
                    video.2() && camera.ready && !model.isPreparingTransition
                }
                let submodeSeconds = CACurrentMediaTime() - submode
                let returning = CACurrentMediaTime()
                model.requestCaptureKind(.photo)
                try await waitUntil("返回照片未完成") {
                    model.captureKind == .photo && camera.ready && !model.isPreparingTransition
                        && camera.previewFrameTimeForTesting > returning
                }
                let returnSeconds = CACurrentMediaTime() - returning
                XCTAssertEqual(model.mode, savedMode)
                XCTAssertFalse(model.timeLapseEnabled || model.slowMotionEnabled || model.cinematicVideoEnabled)
                XCTAssertFalse(camera.dualCaptureEnabled || camera.cinematicVideoCaptureActive)
                XCTAssertNil(camera.message)
                // 以每次返回后的真实新帧验证恢复，避免只检查按钮标志。
                let first = camera.previewFrameTimeForTesting
                try await waitUntil("返回后预览没有继续更新") { camera.previewFrameTimeForTesting > first }
                samples.append(contentsOf: [videoEntrySeconds, submodeSeconds, returnSeconds])
                print("MODE-MATRIX photo=\(photo.0) video=\(video.0) entry=\(videoEntrySeconds) submode=\(submodeSeconds) return=\(returnSeconds)")
            }
        }
        samples.sort()
        print("MODE-MATRIX-SUMMARY combinations=20 samples=\(samples.count) median=\(samples[samples.count / 2]) max=\(samples.last ?? 0) metric=routeAndSourceFrameReadiness")
    }

    func testDualCaptureEffectHandoffAndReturnCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        try await startVideo(model)
        guard model.dualCaptureAvailable else { throw XCTSkip("当前设备不支持双拍") }
        for cycle in 0..<3 {
            model.toggleDualCapture()
            try await waitUntil("双拍未就绪") {
                camera.dualCaptureEnabled && camera.ready && !model.isPreparingTransition
            }
            let started = CACurrentMediaTime()
            model.toggleVirtualAperture()
            try await waitUntil("双拍退出后星芒未就绪") {
                model.virtualApertureEnabled && !camera.dualCaptureEnabled
                    && camera.ready && !model.isPreparingTransition
            }
            print("DUAL-EFFECT cycle=\(cycle) seconds=\(CACurrentMediaTime() - started)")
            model.toggleDualCapture()
            try await waitUntil("再次开启双拍未就绪") {
                camera.dualCaptureEnabled && camera.ready && !model.isPreparingTransition
            }
            model.toggleVirtualAperture()
            model.requestCaptureKind(.photo)
            try await waitUntil("星芒准备期间返回照片未完成") {
                model.captureKind == .photo && camera.ready && !model.isPreparingTransition
            }
            XCTAssertFalse(model.virtualApertureEnabled)
            XCTAssertFalse(camera.dualCaptureEnabled)
            XCTAssertNil(camera.message)
            model.requestCaptureKind(.video)
            try await waitUntil("取消后视频未恢复") {
                model.captureKind == .video && camera.ready && !model.isPreparingTransition
            }
        }
    }
}
#endif
