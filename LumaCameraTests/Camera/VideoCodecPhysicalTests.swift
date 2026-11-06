import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class VideoCodecPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testActualCodecsAndColorsRepeatedRecording() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let previousPosition = model.currentPosition
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onVideoRecorded = callback
            if model.currentPosition != previousPosition { model.flipCamera() }
            model.videoCodec = .hevc; model.proResSpecification = .hq; model.videoColorSpace = .sdr
            model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        if model.currentPosition != .back { model.flipCamera() }
        for _ in 0..<300 {
            if camera.ready && model.currentPosition == .back && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.currentPosition, .back, "Codec matrix starts on the rear camera")
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        var requests: [VideoCaptureSettings] = [.init(), .init(codec: .h264), .init(colorSpace: .p3, codec: .h264)]
        for spec in ProResSpecification.allCases where spec.isSelectable {
            requests.append(.init(codec: .proRes, proRes: spec))
        }
        for color in [VideoColorSpace.hdr, .appleLog, .appleLog2] {
            requests.append(.init(colorSpace: color, codec: .proRes))
        }
        requests += [
            .init(resolution: .uhd4K, frameRate: .fps60, codec: .h264),
            .init(resolution: .uhd4K, frameRate: .fps60, codec: .proRes),
            .init(resolution: .uhd4K, frameRate: .fps120, codec: .proRes),
            .init(resolution: .uhd4K, frameRate: .fps120, codec: .proRes, proRes: .four4xq)
        ]
        let began = CACurrentMediaTime()
        let scenarios = requests.map { ($0, FrameRatio.wide, CameraShootingMode.manual, false) } + VideoRatio.aspectOptions.filter { $0 != .ratio16x9 }.map {
            (VideoCaptureSettings(codec: .proRes), $0.frameRatio, CameraShootingMode.manual, false)
        } + [(.init(codec: .proRes), .wide, .auto, false), (.init(codec: .proRes), .wide, .auto, true)]
        for (settings, ratio, mode, front) in scenarios {
            result = nil
            model.setCaptureKind(.video); model.setMode(mode)
            let requestedPosition: AVCaptureDevice.Position = front ? .front : .back
            if model.currentPosition != requestedPosition { model.flipCamera() }
            for _ in 0..<300 {
                if camera.ready && model.currentPosition == requestedPosition && camera.preview != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.currentPosition, requestedPosition, "Codec scenario must use its requested camera position")
            camera.setVideoSettings(settings)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.videoSettings, settings)
            let activeFormat: (String, Double, Double, [String]) = await withCheckedContinuation { continuation in
                camera.videoFormatStateForTesting { name, minimum, maximum, ranges in
                    continuation.resume(returning: (name, minimum, maximum, ranges))
                }
            }
            print("VIDEO-ACTIVE requested=\(settings.resolution.rawValue)/\(settings.frameRate.rawValue)/\(settings.codec.rawValue)/\(settings.proRes.rawValue) position=\(model.currentPosition.rawValue) format=\(activeFormat.0) minDuration=\(activeFormat.1) maxDuration=\(activeFormat.2) supported=\(activeFormat.3)")
            // 规格和 ready 的主线程回报可能在会话 barrier 后继续触发协调。
            // 与真实快门相同，等加载结束再按下，不把被正确拦截的早按记成编码失败。
            for _ in 0..<500 {
                if camera.ready && !camera.videoConfiguring && !camera.videoBusy
                    && !camera.capturing && camera.pendingPhotoCount == 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertFalse(camera.videoConfiguring)
            XCTAssertFalse(camera.videoBusy)
            XCTAssertFalse(camera.capturing)
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertEqual(camera.videoSettings, settings)
            camera.startVideoRecording(aspect: ratio)
            for _ in 0..<600 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "Recording never started")
            try await Task.sleep(for: .seconds(1))
            camera.stopVideoRecording()
            for _ in 0..<900 { if result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            let url = try XCTUnwrap(result?.get())
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(descriptions.first)
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            if settings.colorSpace == .hdr { XCTAssertEqual(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String, AVVideoTransferFunction_ITU_R_2100_HLG) }
            if settings.colorSpace == .appleLog { XCTAssertEqual(ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String, kCVImageBufferLogTransferFunction_AppleLog as String) }
            if #available(iOS 26, *), settings.colorSpace == .appleLog2 { XCTAssertEqual(ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String, kCVImageBufferLogTransferFunction_AppleLog2 as String) }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            XCTAssertEqual(Double(min(size.height, size.width)) / Double(max(size.width, size.height)), Double(ratio.portraitRatio), accuracy: 0.003)
            XCTAssertEqual(VideoDetailsReader.codecName(subtype), settings.codec == .proRes ? "ProRes " + settings.proRes.rawValue : settings.codec.rawValue)
            let fps = try await track.load(.nominalFrameRate)
            XCTAssertEqual(fps, Float(settings.frameRate.rawValue), accuracy: 5)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var decodedFrames = 0
            var firstPresentationTime: Double?
            var lastPresentationTime: Double?
            while let sample = output.copyNextSampleBuffer() {
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard time.isFinite else { continue }
                decodedFrames += 1
                if firstPresentationTime == nil { firstPresentationTime = time }
                lastPresentationTime = time
            }
            let decodedFrameRate: Double
            if decodedFrames > 1, let firstPresentationTime, let lastPresentationTime, lastPresentationTime > firstPresentationTime {
                decodedFrameRate = Double(decodedFrames - 1) / (lastPresentationTime - firstPresentationTime)
            } else {
                decodedFrameRate = .nan
            }
            XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "实际视频必须完整解码")
            XCTAssertGreaterThan(decodedFrames, 1)
            XCTAssertTrue(decodedFrameRate.isFinite)
            XCTAssertEqual(decodedFrameRate, Double(settings.frameRate.rawValue), accuracy: 2,
                           "实际解码时间戳帧率不能只靠 nominalFrameRate 判断")
            reader.cancelReading()
            print("VIDEO-CODEC-REAL codec=\(settings.avCodec.rawValue) color=\(settings.colorSpace) size=\(size.width)x\(size.height) nominalFPS=\(fps) decodedFrames=\(decodedFrames) decodedFPS=\(decodedFrameRate) ratio=\(ratio.rawValue) rawCapabilities=\(camera.rawVideoSettings.count) duration=\(try await asset.load(.duration).seconds) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            try? FileManager.default.removeItem(at: url)
        }
        print("VIDEO-CODEC-MATRIX count=\(scenarios.count) elapsed=\(CACurrentMediaTime()-began)")
        XCTAssertFalse(ExternalVideoStorage.shared.available)
        model.videoCodec = .proRes
        let previous = model.proResSpecification
        model.selectProResSpecification(.raw); model.selectProResSpecification(.rawHQ)
        XCTAssertEqual(model.proResSpecification, previous)
    }
    #endif
}
