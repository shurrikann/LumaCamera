import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

private final class RawMovieProbeDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished: (URL, Error?)?
    private var started = false
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        lock.lock(); started = true; lock.unlock()
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        lock.lock(); finished = (outputFileURL, error); lock.unlock()
    }
    func state() -> (Bool, (URL, Error?)?) { lock.lock(); defer { lock.unlock() }; return (started, finished) }
}

final class ProResRAWPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 不需要外接盘：只核对真实 RAW 输入在锁定回调后的元数据查询，不创建录制文件。
    @MainActor func testRAWMetadataAfterWhiteBalanceLockWithoutWritingFiles() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("RAW metadata requires iOS 26") }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        defer { UIApplication.shared.isIdleTimerDisabled = idle; model.setCameraActive(true) }
        let latencies = try await Task.detached(priority: .userInitiated) {
            let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
            let format = try XCTUnwrap(device.formats.first {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
                    && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            })
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            session.addInput(input)
            session.addOutput(output)
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_96VersatileBayerPacked12]
            session.commitConfiguration()
            session.startRunning()
            let previousWhiteBalance = device.whiteBalanceMode
            defer {
                if (try? device.lockForConfiguration()) != nil {
                    if device.isWhiteBalanceModeSupported(previousWhiteBalance) { device.whiteBalanceMode = previousWhiteBalance }
                    device.unlockForConfiguration()
                }
                session.stopRunning()
            }
            XCTAssertTrue(session.isRunning)
            let codecs = output.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
            var latencies: [Double] = []
            for codec in [AVVideoCodecType.proResRAW, .proResRAWHQ] {
                XCTAssertTrue(codecs.contains(codec))
                guard codecs.contains(codec) else { continue }
                for _ in 0..<3 {
                    try device.lockForConfiguration()
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    let locked = XCTestExpectation(description: "RAW white balance locked")
                    let start = CACurrentMediaTime()
                    device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains) { _ in locked.fulfill() }
                    device.unlockForConfiguration()
                    guard await XCTWaiter.fulfillment(of: [locked], timeout: 5) == .completed else {
                        XCTFail("RAW white balance completion did not arrive"); return [Double]()
                    }
                    XCTAssertEqual(device.whiteBalanceMode, .locked)
                    var queriedMetadata = false
                    let exception = LumaProbeCaptureException {
                        _ = try? RAWVideoWriterConfiguration.read(whiteBalanceMode: device.whiteBalanceMode,
                            // 不请求文件编码配置：此测试只验证系统元数据接口的锁定前提。
                            videoSettings: { [AVVideoCodecKey: codec] }, metadata: {
                                queriedMetadata = true
                                return output.recommendedMovieMetadata(forVideoCodecType: codec, assetWriterOutputFileType: .mov)
                            })
                    }
                    XCTAssertNil(exception, "RAW metadata must not throw an Objective-C exception after locking: \(String(describing: exception))")
                    XCTAssertTrue(queriedMetadata)
                    latencies.append(CACurrentMediaTime() - start)
                }
            }
            XCTAssertEqual(latencies.count, 6)
            return latencies
        }.value
        let report = "RAW-WB-METADATA samples=\(latencies.count) seconds=\(latencies); measures WB-lock completion plus metadata query, no file encoding or external-disk throughput"
        let attachment = XCTAttachment(string: report)
        attachment.name = "RAW-white-balance-metadata-latency"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
    }

    @MainActor func testRealSensorRAWAndRAWHQStorageCompatibility() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("ProRes RAW capture requires iOS 26") }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        defer { UIApplication.shared.isIdleTimerDisabled = idle; model.setCameraActive(true) }
        try await Task.detached(priority: .userInitiated) {
            try await Self.recordRawSamples()
        }.value
    }

    @available(iOS 26, *)
    private static func recordRawSamples() async throws {
        let session = AVCaptureSession()
        let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
        let formats = device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
                && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        print("PRORES-RAW-SENSOR-FORMATS \(formats)")
        let format = try XCTUnwrap(formats.filter {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 3840
        }.min {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }, "No real 12-bit Bayer 4K30 sensor format")
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let movie = AVCaptureMovieFileOutput()
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        let input = try AVCaptureDeviceInput(device: device)
        session.addInput(input)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        session.addOutput(movie)
        if movie.isDeferredStartSupported { movie.isDeferredStartEnabled = false }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        device.unlockForConfiguration()
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }
        let connection = try XCTUnwrap(movie.connection(with: .video))
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        print("PRORES-RAW-CAPTURE codecs=\(movie.availableVideoCodecTypes) sensor=\(dimensions.width)x\(dimensions.height)")
        for codec in [AVVideoCodecType.proResRAW, .proResRAWHQ] {
            XCTAssertTrue(movie.availableVideoCodecTypes.contains(codec), "Codec absent: \(codec)")
            guard movie.availableVideoCodecTypes.contains(codec) else { continue }
            movie.setOutputSettings([AVVideoCodecKey: codec], for: connection)
            for take in 0..<3 {
                let delegate = RawMovieProbeDelegate()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAW-Probe-\(UUID()).mov")
                defer { try? FileManager.default.removeItem(at: url) }
                let began = CACurrentMediaTime()
                let exception = LumaProbeCaptureException { movie.startRecording(to: url, recordingDelegate: delegate) }
                if let exception {
                    print("PRORES-RAW-STORAGE-BLOCK codec=\(codec.rawValue) exception=\(exception.name.rawValue) reason=\(exception.reason ?? "nil")")
                    XCTAssertTrue(exception.reason?.contains("supported only on external storage device") == true,
                        "Unexpected capture failure: \(exception)")
                    break
                }
                for _ in 0..<600 { if delegate.state().0 || delegate.state().1 != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(delegate.state().0, "Recording never started")
                let latency = CACurrentMediaTime() - began
                try await Task.sleep(for: .seconds(2))
                movie.stopRecording()
                for _ in 0..<1500 { if delegate.state().1 != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
                let result = try XCTUnwrap(delegate.state().1, "Recording never finished")
                if let error = result.1 as NSError? {
                    XCTAssertTrue((error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true, "\(error)")
                }
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let track = try XCTUnwrap(tracks.first)
                let descriptions = try await track.load(.formatDescriptions)
                let description = try XCTUnwrap(descriptions.first)
                let expected = codec == .proResRAW ? kCMVideoCodecType_AppleProResRAW : kCMVideoCodecType_AppleProResRAWHQ
                XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), expected)
                let size = CMVideoFormatDescriptionGetDimensions(description)
                let fps = try await track.load(.nominalFrameRate)
                let duration = try await asset.load(.duration).seconds
                XCTAssertEqual(size.width, dimensions.width); XCTAssertEqual(size.height, dimensions.height)
                XCTAssertEqual(fps, 30, accuracy: 2); XCTAssertGreaterThan(duration, 1.5)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output); XCTAssertTrue(reader.startReading())
                var frames = 0
                while output.copyNextSampleBuffer() != nil { frames += 1 }
                XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(frames, 45)
                let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let decoder = try AVAssetReader(asset: asset)
                let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                decoder.add(decoded)
                let started = decoder.startReading()
                let image = started ? decoded.copyNextSampleBuffer().flatMap { CMSampleBufferGetImageBuffer($0) } : nil
                print("PRORES-RAW-REAL codec=\(codec.rawValue) take=\(take) size=\(size.width)x\(size.height) fps=\(fps) duration=\(duration) frames=\(frames) bytes=\(bytes) startSeconds=\(latency) decoded=\(image != nil) decodeError=\(String(describing: decoder.error)) audioTracks=\(audio.count) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                XCTAssertNotNil(image, "RAW playback decode failed: \(String(describing: decoder.error))")
                decoder.cancelReading()
                try? FileManager.default.removeItem(at: url)
            }
        }
        session.stopRunning()
        session.beginConfiguration()
        session.removeOutput(movie)
        let dataOutput = AVCaptureVideoDataOutput()
        session.addOutput(dataOutput)
        dataOutput.automaticallyConfiguresOutputBufferDimensions = false
        dataOutput.deliversPreviewSizedOutputBuffers = false
        print("PRORES-RAW-DATA-PIXELS \(dataOutput.availableVideoPixelFormatTypes)")
        if dataOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_96VersatileBayerPacked12) {
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_96VersatileBayerPacked12]
        }
        session.commitConfiguration()
        session.startRunning()
        let available = dataOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        print("PRORES-RAW-DATA-CODECS \(available)")
        for codec in [AVVideoCodecType.proResRAW, .proResRAWHQ] where available.contains(codec) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAW-Settings-Probe-\(UUID()).mov")
            var settings: [String: Any]?
            let exception = LumaProbeCaptureException {
                settings = dataOutput.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mov, outputFileURL: url)
            }
            print("PRORES-RAW-WRITER-SETTINGS codec=\(codec.rawValue) settings=\(String(describing: settings)) exception=\(String(describing: exception))")
        }
    }
    #endif
}
