import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

/// 区分同一物理镜头内的裁切与真正换镜；以新路由帧标识统计停顿，不把旧预览算作就绪。
final class SlowMotionLensTransitionPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testSlowMotionFocalSwitchLatencyAndRecording() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldKind = model.captureKind, oldMode = model.mode
        let oldFormat = model.photoFormat, oldHDR = model.hdr, oldLive = model.livePhotoEnabled
        let oldSettings = camera.videoSettings, oldRatio = model.videoRatio, oldOpenGate = model.videoOpenGateEnabled
        let oldLensID = camera.selectedLens, oldZoom = camera.currentZoom
        let oldManual = (model.manualExposure, model.manualWB, model.manualFocus)
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        var recording: Result<URL, Error>?
        var temporaryMovie: URL?
        camera.onVideoRecorded = { recording = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }; camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            if let temporaryMovie { try? FileManager.default.removeItem(at: temporaryMovie) }
            if model.slowMotionEnabled { model.toggleSlowMotionMode() }
            model.setCaptureKind(.photo)
            model.photoFormat = oldFormat; model.hdr = oldHDR
            if model.livePhotoEnabled != oldLive && model.livePhotoAvailable { model.toggleLivePhoto() }
            model.videoResolution = oldSettings.resolution; model.videoFrameRate = oldSettings.frameRate
            model.videoColorSpace = oldSettings.colorSpace; model.videoCodec = oldSettings.codec
            model.proResSpecification = oldSettings.proRes; model.videoRatio = oldRatio
            model.videoOpenGateEnabled = oldOpenGate
            model.setMode(oldMode)
            model.manualExposure = oldManual.0; model.manualWB = oldManual.1; model.manualFocus = oldManual.2
            if let lens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(lens); camera.setContinuousZoom(oldZoom)
            }
            model.setCaptureKind(oldKind); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func settle() async {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<600 {
                if camera.ready && !camera.videoConfiguring && model.videoSubmodePreparing == nil && camera.preview != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        model.setCameraActive(true)
        await settle()
        if model.captureKind != .photo { model.setCaptureKind(.photo); await settle() }
        if model.currentPosition != .back { model.flipCamera(); await settle() }
        model.setMode(.auto)
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setCaptureKind(.video)
        model.videoCodec = .hevc; model.videoColorSpace = .sdr
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.videoOpenGateEnabled = false
        await settle()
        if model.cinematicVideoEnabled { model.toggleCinematicVideoMode(); await settle() }
        if model.timeLapseEnabled { model.toggleTimeLapseMode(); await settle() }
        if !model.slowMotionEnabled { model.toggleSlowMotionMode(); await settle() }
        XCTAssertTrue(model.slowMotionEnabled, camera.message ?? "Slow motion did not become ready")
        model.selectVideoResolution(.hd1080)
        model.selectVideoFrameRate(.fps120)
        await settle()
        XCTAssertEqual(camera.videoSettings.captureFrameRate, .fps120)
        await withCheckedContinuation { c in camera.resetRuntimeErrorCountForTesting { c.resume() } }
        var samples: [String] = []
        var latencies: [Double] = []
        for captureRate in [VideoFrameRate.fps120, .fps240] {
            model.selectVideoFrameRate(captureRate)
            await settle()
            XCTAssertEqual(camera.videoSettings.captureFrameRate, captureRate)
            for mode in [CameraShootingMode.auto, .manual] {
                model.setMode(mode)
                model.manualExposure = false; model.manualWB = false; model.manualFocus = false
                model.restoreDeviceParametersForTesting()
                await settle()
                for zoom in [0.5, 1.0, 2.0, 4.0, 8.0, 1.0] {
                    guard let lens = camera.lenses.first(where: { $0.device.position == .back && abs(Double($0.displayZoom) - zoom) < 0.01 }),
                          model.canSelectFocalLength(lens), camera.selectedLens != lens.id else { continue }
                    let previousFrame = camera.userSwitchFrameID, previousDevice = camera.activeCaptureDeviceID
                    let start = CACurrentMediaTime()
                    model.selectFocalLength(lens)
                    for _ in 0..<1000 {
                        if camera.ready && !camera.videoConfiguring && camera.selectedLens == lens.id
                            && camera.preview != nil && camera.userSwitchFrameID != previousFrame { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let latency = CACurrentMediaTime() - start
                    XCTAssertEqual(camera.selectedLens, lens.id)
                    XCTAssertNotEqual(camera.userSwitchFrameID, previousFrame)
                    guard camera.selectedLens == lens.id, camera.userSwitchFrameID != previousFrame else {
                        throw NSError(domain:"SlowMotionFocalRoute",code:1,userInfo:[NSLocalizedDescriptionKey:"焦段未切到最终新路由：\(lens.id)"])
                    }
                    XCTAssertNotNil(camera.preview)
                    XCTAssertTrue(model.slowMotionEnabled)
                    XCTAssertEqual(camera.videoSettings.captureFrameRate, captureRate)
                    let actual = await withCheckedContinuation { c in
                        camera.videoFormatStateForTesting { format, minimum, maximum, _ in c.resume(returning: (format, minimum, maximum)) }
                    }
                    XCTAssertEqual(actual.1, 1.0 / Double(captureRate.rawValue), accuracy: 0.0001)
                    XCTAssertEqual(actual.2, 1.0 / Double(captureRate.rawValue), accuracy: 0.0001)
                    // 慢动作使用该规格兼容的物理输入，核对真实设备和倍率，不只看选中按钮。
                    let exposure = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                    let real = try XCTUnwrap(exposure)
                    XCTAssertEqual(real.deviceID,lens.device.uniqueID)
                    XCTAssertEqual(Double(camera.currentZoom),zoom,accuracy:0.02)
                    XCTAssertEqual(Double(real.physicalZoomFactor),Double(lens.zoomFactor),accuracy:0.02)
                    latencies.append(latency)
                    samples.append("rate=\(captureRate.rawValue) mode=\(mode) zoom=\(zoom) physicalSwitch=\(previousDevice != camera.activeCaptureDeviceID) seconds=\(latency) format=\(actual.0)")
                    try await Task.sleep(for: .milliseconds(150))
                }
                if mode == .auto, let main = camera.lenses.first(where: {
                    $0.device.position == .back && abs($0.displayZoom - 1) < 0.01
                }) {
                    // 再次点击 1× 的 24/28/35 mm 循环也走变焦入口，不得回到普通 30 帧虚拟输入。
                    for expectedZoom in [28.0 / 24.0, 35.0 / 24.0, 1.0] {
                        let previousFrame = camera.userSwitchFrameID
                        model.selectFocalLength(main)
                        await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                        for _ in 0..<300 {
                            if camera.userSwitchFrameID != previousFrame && camera.ready { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        let zoom = await withCheckedContinuation { c in
                            camera.zoomStateForTesting { value, _, _ in c.resume(returning: value) }
                        }
                        XCTAssertEqual(Double(zoom), expectedZoom, accuracy: 0.02)
                        XCTAssertEqual(camera.videoSettings.captureFrameRate, captureRate)
                        XCTAssertTrue(model.slowMotionEnabled)
                    }
                    let deviceID = camera.activeCaptureDeviceID
                    model.updatePreviewPinchZoom(scale: 1.15)
                    await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                    model.finishPreviewPinchZoom()
                    XCTAssertEqual(camera.activeCaptureDeviceID, deviceID)
                    XCTAssertEqual(camera.videoSettings.captureFrameRate, captureRate)
                    XCTAssertTrue(model.slowMotionEnabled)
                    camera.setContinuousZoom(1)
                    await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                    await settle()
                }
            }
        }
        XCTAssertGreaterThanOrEqual(latencies.count, 12)
        let report = "SLOW-FOCAL samples=\(latencies.count)\n" + samples.joined(separator: "\n")
            + "\nMeasures button invocation to final-route preview publication, includes <=10ms polling; not display scanout or encoded cadence."
        let attachment = XCTAttachment(string: report)
        attachment.name = "Slow-motion-focal-switch-latency"; attachment.lifetime = .keepAlways
        add(attachment); print(report)
        for (captureRate,waitMilliseconds) in [(VideoFrameRate.fps120,600),(.fps240,600),(.fps240,3000)] {
        model.selectVideoFrameRate(captureRate)
        await settle()
        recording = nil
        let recordBegan = CACurrentMediaTime()
        camera.startVideoRecording(aspect: .wide)
        for _ in 0..<500 {
            if camera.videoRecording || recording != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(camera.videoRecording, camera.message ?? "Slow-motion recording did not start")
        try await Task.sleep(for: .milliseconds(waitMilliseconds))
        camera.stopVideoRecording()
        for _ in 0..<500 {
            if recording != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let movie = try XCTUnwrap(recording?.get())
        let counts = try XCTUnwrap(camera.lastRecordingFrameCountsForTesting)
        XCTAssertGreaterThan(counts.received,Int(captureRate.rawValue/2))
        XCTAssertGreaterThanOrEqual(Double(counts.written)/Double(counts.received),0.95,"240帧短片不能大量丢弃已收到的采集帧")
        temporaryMovie = movie
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(frameRate, Float(model.videoFrameRate.rawValue), accuracy: 1)
        XCTAssertGreaterThan(duration, 1.2)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames = 0, firstPTS:Double?, lastPTS = -Double.infinity
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            XCTAssertGreaterThan(pts,lastPTS); if firstPTS == nil { firstPTS = pts }; lastPTS = pts; frames += 1
        }
        XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,1)
        let actualFPS = Double(frames-1)/(lastPTS-(firstPTS ?? lastPTS))
        XCTAssertEqual(actualFPS,Double(model.videoFrameRate.rawValue),accuracy:1)
        XCTAssertEqual(frames,counts.written)
        let actualCaptureFPS = Double(counts.received-1)/counts.span
        XCTAssertEqual(actualCaptureFPS,Double(captureRate.rawValue),accuracy:Double(captureRate.rawValue)*0.05)
        print("SLOW-FOCAL-DECODE capture=\(captureRate.rawValue) waitMs=\(waitMilliseconds) received=\(counts.received) written=\(counts.written) frames=\(frames) playbackFPS=\(actualFPS) duration=\(duration) total=\(CACurrentMediaTime()-recordBegan)")
        let state = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(state.contains("runtimeErrors=0"), state)
        try FileManager.default.removeItem(at: movie)
        temporaryMovie = nil; recording = nil
        }

        // 快速点按与离开/返回取景不能把旧换镜任务留在会话里。
        if let ultra = camera.lenses.first(where: { $0.device.position == .back && $0.device.deviceType == .builtInUltraWideCamera }),
           let main = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }) {
            model.selectFocalLength(ultra)
            model.selectFocalLength(main)
            model.setCameraActive(false)
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let resumedAt = CACurrentMediaTime()
            model.setCameraActive(true)
            await settle()
            for _ in 0..<300 { if camera.previewFrameTimeForTesting > resumedAt { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting,resumedAt)
            XCTAssertTrue(camera.ready)
            XCTAssertNotNil(camera.preview)
            XCTAssertTrue(model.slowMotionEnabled)
            XCTAssertEqual(camera.videoSettings.captureFrameRate, .fps240)
        }
    }
    #endif
}
