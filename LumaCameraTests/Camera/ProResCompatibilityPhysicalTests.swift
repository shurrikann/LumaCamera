import AVFoundation
import CoreImage
import UIKit
import VideoToolbox
import XCTest
@testable import LumaCamera

private final class ProResProbeSamples: @unchecked Sendable {
    let lock = NSLock()
    var samples: [CMSampleBuffer] = []
    var errors: [OSStatus] = []
    func receive(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if status != noErr { errors.append(status) }
        if let sample { samples.append(sample) }
    }
}

private final class ProResCameraFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); defer { lock.unlock() }
        if buffer == nil { buffer = CMSampleBufferGetImageBuffer(sampleBuffer) }
    }
    func frame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}

final class ProResCompatibilityPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testActualCameraFrameEncodesWithAllConventionalProfiles() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        defer { UIApplication.shared.isIdleTimerDisabled = idle; model.setCameraActive(true) }
        try await Task.detached(priority: .userInitiated) {
            let session = AVCaptureSession()
            let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput(), delegate = ProResCameraFrame()
            session.beginConfiguration()
            session.sessionPreset = .hd4K3840x2160
            session.addInput(input); session.addOutput(output)
            output.automaticallyConfiguresOutputBufferDimensions = false
            output.deliversPreviewSizedOutputBuffers = false
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "ProRes.camera.probe"))
            session.commitConfiguration(); session.startRunning()
            defer { session.stopRunning(); output.setSampleBufferDelegate(nil, queue: nil) }
            print("PRORES-CAMERA-CODECS \(output.availableVideoCodecTypesForAssetWriter(writingTo: .mov))")
            let rawFormats = device.formats.filter {
                let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return subtype == kCVPixelFormatType_16VersatileBayer || subtype == kCVPixelFormatType_64RGBA_DownscaledProResRAW || subtype == kCVPixelFormatType_96VersatileBayerPacked12
            }
            print("PRORES-CAMERA-RAW-FORMATS \(rawFormats.map { String(describing: $0) })")
            for _ in 0..<500 { if delegate.frame() != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            let frame = try XCTUnwrap(delegate.frame())
            let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
            XCTAssertEqual(width, 3840); XCTAssertEqual(height, 2160)
            let context = CIContext(options: [.cacheIntermediates: false])
            for (name, codec) in [("422 Proxy", kCMVideoCodecType_AppleProRes422Proxy), ("422 LT", kCMVideoCodecType_AppleProRes422LT),
                ("422", kCMVideoCodecType_AppleProRes422), ("422 HQ", kCMVideoCodecType_AppleProRes422HQ),
                ("4444", kCMVideoCodecType_AppleProRes4444), ("4444 XQ", kCMVideoCodecType_AppleProRes4444XQ)] {
                try await Self.probe(name: "CAMERA " + name, codec: codec, width: width, height: height, fps: 30, context: context, cameraFrame: frame)
            }
        }.value
    }

    /// Encoder probe only: synthetic frames, temporary MOV files, no Photos writes.
    @MainActor func testDeviceEncodersProduceDecodableProResFiles() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        defer { UIApplication.shared.isIdleTimerDisabled = idle; model.setCameraActive(true) }
        try await Task.detached(priority: .userInitiated) {
            let codecs: [(String, CMVideoCodecType)] = [
                ("422 Proxy", kCMVideoCodecType_AppleProRes422Proxy),
                ("422 LT", kCMVideoCodecType_AppleProRes422LT),
                ("422", kCMVideoCodecType_AppleProRes422),
                ("422 HQ", kCMVideoCodecType_AppleProRes422HQ),
                ("4444", kCMVideoCodecType_AppleProRes4444),
                ("4444 XQ", kCMVideoCodecType_AppleProRes4444XQ)
            ]
            var encoders: CFArray?
            let listStatus = VTCopyVideoEncoderList(nil, &encoders)
            print("PRORES-ENCODER-LIST status=\(listStatus) entries=\(String(describing: encoders))")
            let context = CIContext(options: [.cacheIntermediates: false])
            for (name, codec) in codecs {
                for (width, height, fps) in [(1920, 1080, 30), (3840, 2160, 30), (3840, 2160, 60), (3840, 2160, 120)] {
                    try await Self.probe(name: name, codec: codec, width: width, height: height, fps: fps, context: context)
                }
            }
            if #available(iOS 26, *) {
                for (name, codec) in [("RAW", kCMVideoCodecType_AppleProResRAW), ("RAW HQ", kCMVideoCodecType_AppleProResRAWHQ)] {
                    var session: VTCompressionSession?
                    let status = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: codec,
                        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
                    print("PRORES-RAW-CREATE name=\(name) status=\(status) NOTE=no-Bayer-encode-tested")
                    if let session { VTCompressionSessionInvalidate(session) }
                }
            }
        }.value
    }

    private static func probe(name: String, codec: CMVideoCodecType, width: Int, height: Int, fps: Int, context: CIContext, cameraFrame: CVPixelBuffer? = nil) async throws {
        let box = ProResProbeSamples()
        var optionalSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                guard let refcon else { return }
                Unmanaged<ProResProbeSamples>.fromOpaque(refcon).takeUnretainedValue().receive(status, sample)
            }, refcon: Unmanaged.passUnretained(box).toOpaque(), compressionSessionOut: &optionalSession)
        guard status == noErr, let session = optionalSession else {
            print("PRORES-PROBE name=\(name) size=\(width)x\(height) fps=\(fps) create=\(status) UNSUPPORTED")
            return
        }
        defer { VTCompressionSessionInvalidate(session) }
        let realTime = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let frameRate = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr, let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            print("PRORES-PROBE name=\(name) size=\(width)x\(height) fps=\(fps) prepare=\(prepare) UNSUPPORTED")
            return
        }
        let began = CACurrentMediaTime()
        for index in 0..<24 {
            try autoreleasepool {
                var optionalBuffer: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer), kCVReturnSuccess)
                let buffer = try XCTUnwrap(cameraFrame ?? optionalBuffer)
                let image = CIFilter(name: "CICheckerboardGenerator", parameters: [
                    "inputCenter": CIVector(x: CGFloat(index * 3), y: 0), "inputWidth": 23,
                    "inputColor0": CIColor(red: 0.1, green: 0.4, blue: 0.8),
                    "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.2)])!.outputImage!
                if cameraFrame == nil { context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
                let code = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                    presentationTimeStamp: CMTime(value: Int64(index), timescale: Int32(fps)),
                    duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
                XCTAssertEqual(code, noErr)
            }
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        let elapsed = CACurrentMediaTime() - began
        XCTAssertTrue(box.errors.isEmpty)
        XCTAssertEqual(box.samples.count, 24)
        guard let first = box.samples.first, let format = CMSampleBufferGetFormatDescription(first) else { return }
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), codec)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProRes-Probe-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for sample in box.samples {
            for _ in 0..<500 { if input.isReadyForMoreMediaData { break }; try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(input.append(sample))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), codec)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer())
        reader.cancelReading()
        print("PRORES-PROBE name=\(name) size=\(width)x\(height) fps=\(fps) PASS frames=\(box.samples.count) encodeWithRenderSeconds=\(elapsed) realtimeProperty=\(realTime) fpsProperty=\(frameRate) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }
    #endif
}
