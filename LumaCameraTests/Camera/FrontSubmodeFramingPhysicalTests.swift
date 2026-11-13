import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

/// 照片保留前置宽窄取景，视频按当前功能规则固定超广角。
final class FrontSubmodeFramingPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testFrontPhotoAndVideoFramingAfterSubmodes() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        let oldKind = model.captureKind, oldMode = model.mode
        let oldFormat = model.photoFormat, oldHDR = model.hdr, oldLive = model.livePhotoEnabled
        let oldVideo = camera.videoSettings, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.timeLapseEnabled { model.toggleTimeLapseMode() }
            if model.slowMotionEnabled { model.toggleSlowMotionMode() }
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
            model.setCaptureKind(.photo)
            if model.portraitModeEnabled { model.togglePortraitMode() }
            if model.nightModeEnabled { model.toggleNightMode() }
            if model.burstModeEnabled { model.toggleBurstMode() }
            if model.slowShutterEnabled { model.toggleSlowShutterMode() }
            model.photoFormat = oldFormat; model.hdr = oldHDR
            if model.livePhotoEnabled != oldLive && model.livePhotoAvailable { model.toggleLivePhoto() }
            model.videoResolution = oldVideo.resolution; model.videoFrameRate = oldVideo.frameRate
            model.videoColorSpace = oldVideo.colorSpace; model.videoCodec = oldVideo.codec
            model.proResSpecification = oldVideo.proRes
            model.setMode(oldMode); model.setCaptureKind(oldKind); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        func settle() async {
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<700 {
                if camera.ready && camera.preview != nil && !model.isPreparingTransition { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            // 能力发布在主队列，随后按朝向刷新子模块镜头集合。
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
        func clearPhotoSubmode() {
            if model.portraitModeEnabled { model.togglePortraitMode() }
            if model.nightModeEnabled { model.toggleNightMode() }
            if model.burstModeEnabled { model.toggleBurstMode() }
            if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        }
        func clearVideoSubmode() {
            if model.timeLapseEnabled { model.toggleTimeLapseMode() }
            if model.slowMotionEnabled { model.toggleSlowMotionMode() }
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
        }
        var samples: [String] = []
        func checkFront(_ label: String) async throws {
            if model.currentPosition != .front { model.flipCamera(); await settle() }
            let front = camera.lenses.filter { $0.device.position == .front }
            let standard = try XCTUnwrap(front.first { $0.frontFraming == .standard })
            let wide = try XCTUnwrap(front.first { $0.frontFraming == .wide })
            if model.captureKind == .video {
                let previous = camera.selectedLens
                for lens in [standard, wide] {
                    XCTAssertFalse(model.canSelectFocalLength(lens), "\(label) 视频前置应固定宽取景")
                    model.selectFocalLength(lens)
                }
                await settle()
                XCTAssertEqual(camera.selectedLens, previous, label)
                let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
                XCTAssertEqual(try XCTUnwrap(state).physicalZoomFactor, wide.zoomFactor, accuracy: 0.03, label)
                XCTAssertNotNil(camera.preview)
                return
            }
            for lens in [wide, standard, wide, standard] {
                XCTAssertTrue(model.canSelectFocalLength(lens), "\(label): current=\(camera.selectedLens) blocked=\(lens.id) allowed=\(String(describing: model.compatibleSubmodeLensIDs)) preparing=\(model.isPreparingSubmode)")
                let start = CACurrentMediaTime()
                model.selectFocalLength(lens)
                await settle()
                for _ in 0..<200 {
                    if camera.selectedLens == lens.id && model.focalTransitionImage == nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let actual = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
                let state = await withCheckedContinuation { c in camera.frontFramingStateForTesting { c.resume(returning: $0) } }
                if lens.frontFraming == .standard { print("FRONT-ACTUAL \(label) \(state)") }
                XCTAssertEqual(camera.selectedLens, lens.id, label)
                XCTAssertEqual(try XCTUnwrap(actual).physicalZoomFactor, lens.zoomFactor, accuracy: 0.03, "\(label): \(state)")
                XCTAssertNotNil(camera.preview)
                samples.append("\(label) framing=\(String(describing: lens.frontFraming)) seconds=\(CACurrentMediaTime()-start) physicalZoom=\(actual?.physicalZoomFactor ?? -1)")
            }
        }
        model.setCameraActive(true)
        await settle()
        model.setCaptureKind(.photo); model.setMode(.auto)
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        clearPhotoSubmode(); await settle()
        try await checkFront("photo-normal")
        for child in ["slow", "night", "portrait", "burst"] {
            if model.currentPosition != .back { model.flipCamera(); await settle() }
            switch child {
            case "slow": model.toggleSlowShutterMode()
            case "night": model.toggleNightMode()
            case "portrait": model.togglePortraitMode()
            default: model.toggleBurstMode()
            }
            await settle()
            try await checkFront("photo-\(child)-active")
            clearPhotoSubmode(); await settle()
            try await checkFront("photo-\(child)-off")
        }
        model.setCaptureKind(.video)
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.videoColorSpace = .sdr; model.videoCodec = .hevc
        clearVideoSubmode(); await settle()
        try await checkFront("video-normal")
        for child in [VideoSubmode.timeLapse, .slowMotion, .cinematic] {
            if model.currentPosition != .back { model.flipCamera(); await settle() }
            switch child {
            case .timeLapse: model.toggleTimeLapseMode()
            case .slowMotion: model.toggleSlowMotionMode()
            case .cinematic: model.toggleCinematicVideoMode()
            }
            await settle()
            try await checkFront("video-\(child)-active")
            clearVideoSubmode(); await settle()
            try await checkFront("video-\(child)-off")
        }
        // 视频快速点击保留固定宽取景，返回照片后恢复两种取景。
        model.setMode(.manual); await settle()
        try await checkFront("video-manual")
        let front = camera.lenses.filter { $0.device.position == .front }
        for index in 0..<30 { model.selectFocalLength(front[index % front.count]) }
        model.setCameraActive(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true); await settle()
        try await checkFront("video-resume")
        model.setCaptureKind(.photo); model.setMode(.auto); await settle()
        try await checkFront("photo-return")
        let report = samples.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Front-framing-after-submodes"; attachment.lifetime = .keepAlways
        add(attachment); print("FRONT-SUBMODE\n\(report)")
    }
    #endif
}
