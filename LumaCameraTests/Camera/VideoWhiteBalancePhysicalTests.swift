import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

/// 真机确认录像白平衡偏好只在录制期间生效，并在完成后恢复设备模式。
final class VideoWhiteBalancePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let camera = model.camera
        let oldCallback = camera.onVideoRecorded
        let oldPreferences = model.preferences
        let oldKind = model.captureKind
        let oldMode = model.mode
        let oldPosition = model.currentPosition
        let oldCodec = model.videoCodec
        let oldResolution = model.videoResolution
        let oldFrameRate = model.videoFrameRate
        let oldColor = model.videoColorSpace
        let oldRatio = model.videoRatio
        let oldOpenGate = model.videoOpenGateEnabled
        let oldManualWB = model.manualWB
        let oldWB = model.wb
        let oldTint = model.whiteBalanceTint
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = oldCallback
                }; camera.stopVideoRecording()
            } else { camera.onVideoRecorded = oldCallback }
            model.preferences = oldPreferences
            model.setCaptureKind(.photo)
            model.setMode(oldMode)
            model.manualWB = oldManualWB; model.wb = oldWB; model.whiteBalanceTint = oldTint
            model.applyWhiteBalance()
            model.videoCodec = oldCodec; model.videoResolution = oldResolution
            model.videoFrameRate = oldFrameRate; model.videoColorSpace = oldColor
            model.videoRatio = oldRatio; model.videoOpenGateEnabled = oldOpenGate
            if model.currentPosition != oldPosition { model.flipCamera() }
            model.setCaptureKind(oldKind)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera session did not become ready")
        if model.currentPosition != .back { model.flipCamera() }
        for _ in 0..<300 {
            if camera.ready && model.currentPosition == .back && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        model.setMode(.auto)
        model.manualWB = false
        model.applyWhiteBalance()
        model.setCaptureKind(.video)
        model.videoCodec = .hevc; model.videoResolution = .hd1080
        model.videoFrameRate = .fps30; model.videoColorSpace = .sdr
        model.videoRatio = .ratio16x9; model.videoOpenGateEnabled = false
        let settings = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30,
                                            colorSpace: .sdr, codec: .hevc)
        camera.setVideoSettings(settings)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<300 {
            if camera.ready && !camera.videoConfiguring
                && camera.supportedVideoSettings.contains(where: {
                    $0.resolution == .hd1080 && $0.frameRate == .fps30 && $0.colorSpace == .sdr
                }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("VIDEO-WB-ROUTE ready=\(camera.ready) kind=\(model.captureKind) position=\(model.currentPosition.rawValue) preview=\(camera.preview != nil) videoConfiguring=\(camera.videoConfiguring) requested=\(camera.videoSettings.resolution.rawValue)/\(camera.videoSettings.frameRate.rawValue)/\(camera.videoSettings.colorSpace.rawValue)/\(camera.videoSettings.codec.rawValue) supportedCount=\(camera.supportedVideoSettings.count) message=\(camera.message ?? "nil")")
        guard camera.ready, camera.supportedVideoSettings.contains(where: {
            $0.resolution == .hd1080 && $0.frameRate == .fps30 && $0.colorSpace == .sdr
        }) else { throw XCTSkip("Rear camera HEVC SDR 1080p30 route unavailable after wait; count=\(camera.supportedVideoSettings.count)") }

        var recordingStartLatencies: [Double] = []
        let scenarios: [(CameraShootingMode,VideoCaptureSettings,Bool)] = [
            (.auto,.init(),false),
            (.auto,.init(resolution:.uhd4K,frameRate:.fps60,colorSpace:.hdr),false),
            (.manual,.init(colorSpace:.p3,codec:.h264),false),
            (.manual,.init(colorSpace:.appleLog),false),
            (.manual,.init(colorSpace:.appleLog2,codec:.proRes,proRes:.hq),false),
            (.manual,.init(),true)
        ]
        // 跨实际编码/色彩路由重复开关，并保证已有手动白平衡不会因偏好而解锁。
        for (scenarioIndex,scenario) in scenarios.enumerated() {
            model.setMode(scenario.0)
            model.videoResolution = scenario.1.resolution; model.videoFrameRate = scenario.1.frameRate
            model.videoColorSpace = scenario.1.colorSpace; model.videoCodec = scenario.1.codec
            model.proResSpecification = scenario.1.proRes
            model.manualWB = scenario.2
            if scenario.2 { model.wb = 5400; model.whiteBalanceTint = 8 }
            model.applyWhiteBalance()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.videoSettings,scenario.1)
            print("VIDEO-WB-SCENARIO index=\(scenarioIndex) mode=\(model.mode) spec=\(camera.videoSettings) manualWB=\(scenario.2)")
            for lockEnabled in [false,true] {
            result = nil
            model.preferences.lockVideoWhiteBalance = lockEnabled
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"WB-\(scenarioIndex)-\(lockEnabled)")
            let before = await withCheckedContinuation { continuation in
                camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
            }
            let startTime = CACurrentMediaTime()
            model.toggleVideoRecording()
            for _ in 0..<400 {
                if camera.videoRecording || result != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let startLatency = CACurrentMediaTime() - startTime
            recordingStartLatencies.append(startLatency)
            XCTAssertTrue(camera.videoRecording, camera.message ?? "HEVC recording failed; lock=\(lockEnabled)")
            XCTAssertLessThan(startLatency, 3, "WB preference must not delay recording startup beyond 3 seconds")
            let during = await withCheckedContinuation { continuation in
                camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
            }
            if lockEnabled {
                XCTAssertEqual(during.0, .locked, "Enabled preference must lock WB before the first encoded frame")
                try await Task.sleep(for: .milliseconds(700))
                let later = await withCheckedContinuation { continuation in
                    camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
                }
                print("VIDEO-WB-GAINS during=\(during.1) later=\(later.1)")
                XCTAssertEqual(later.0, .locked)
                XCTAssertEqual(later.1.redGain, during.1.redGain, accuracy: 0.0001)
                XCTAssertEqual(later.1.greenGain, during.1.greenGain, accuracy: 0.0001)
                XCTAssertEqual(later.1.blueGain, during.1.blueGain, accuracy: 0.0001)
            } else {
                XCTAssertEqual(during.0, before.0, "Default-off preference must preserve the existing WB mode")
            }

            try await Task.sleep(for: .milliseconds(500))
            model.toggleVideoRecording()
            for _ in 0..<500 {
                if result != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let url = try XCTUnwrap(result?.get(), "Recording completion failed; lock=\(lockEnabled)")
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration).seconds
            XCTAssertFalse(tracks.isEmpty)
            XCTAssertGreaterThan(duration, 0.5)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            XCTAssertGreaterThan(frames,1); XCTAssertEqual(reader.status,.completed)
            print("VIDEO-WB-DECODE index=\(scenarioIndex) enabled=\(lockEnabled) frames=\(frames)")
            await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
            let after = await withCheckedContinuation { continuation in
                camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
            }
            XCTAssertEqual(after.0, before.0, "Recording must restore the prior WB mode; lock=\(lockEnabled)")
            print("VIDEO-WB-LOCK enabled=\(lockEnabled) modeBefore=\(before.0.rawValue) modeDuring=\(during.0.rawValue) modeAfter=\(after.0.rawValue) duration=\(duration) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            try? FileManager.default.removeItem(at: url)
            result = nil
        }
        }
        let orderedLatencies = recordingStartLatencies.sorted()
        let p50 = orderedLatencies[orderedLatencies.count/2]
        print("VIDEO-WB-START-LATENCY samples=\(orderedLatencies.count) p50=\(p50)s max=\(orderedLatencies.last ?? .nan)s modeOrder=off,on across six scenarios")

        // 录制启动与用户立即取消竞争时，不应误启动写入器或遗留锁定模式。
        let beforeCancel = await withCheckedContinuation { continuation in
            camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
        }
        model.preferences.lockVideoWhiteBalance = true
        camera.startVideoRecording(aspect: .wide, lockWhiteBalance: true)
        camera.stopVideoRecording()
        for _ in 0..<300 {
            if !camera.videoBusy && !camera.videoRecording { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(camera.videoBusy, "Immediate cancel must release the shutter busy state")
        XCTAssertFalse(camera.videoRecording)
        // 启动取消现在按统一录像完成契约回传 CancellationError，不交付成功URL。
        if let result {
            switch result {
            case .success: XCTFail("取消不能交付成功视频")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
        } else { XCTFail("取消也应交付完成回调") }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        var afterCancel = await withCheckedContinuation { continuation in
            camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
        }
        for _ in 0..<150 where afterCancel.0 != beforeCancel.0 {
            try await Task.sleep(for: .milliseconds(20))
            afterCancel = await withCheckedContinuation { continuation in
                camera.videoWhiteBalanceStateForTesting { continuation.resume(returning: ($0, $1)) }
            }
        }
        XCTAssertEqual(afterCancel.0, beforeCancel.0, "Immediate cancel must restore the prior WB mode")
        XCTAssertTrue(camera.ready, "Immediate cancel must leave the camera available")
    }
    #endif
}
