import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import LumaCamera

final class VideoColorPhysicalTests: XCTestCase {
    func testColorSettingsAndFallbackNeverConfuseLogWithHDR() {
        let p3 = VideoCaptureSettings(colorSpace: .p3)
        let sdr = VideoCaptureSettings()
        let hdr = VideoCaptureSettings(colorSpace: .hdr)
        XCTAssertTrue(hdr.colorSpace.usesTenBit)
        XCTAssertFalse(p3.colorSpace.usesTenBit)
        XCTAssertEqual(p3.colorSpace.encodingColorProperties[AVVideoColorPrimariesKey] as? String, AVVideoColorPrimaries_P3_D65)
        XCTAssertEqual(VideoCaptureSettings.resolved(.init(colorSpace: .appleLog2), supported: [sdr, p3, hdr]), sdr)
        if #available(iOS 27, *) {
            let log = VideoColorSpace.appleLog.encodingColorProperties
            let log2 = VideoColorSpace.appleLog2.encodingColorProperties
            XCTAssertNil(log[AVVideoTransferFunctionKey]); XCTAssertNil(log2[AVVideoTransferFunctionKey])
            XCTAssertNil(log2[AVVideoColorPrimariesKey])
            XCTAssertEqual(log[AVVideoLogTransferFunctionKey] as? String, AVVideoLogTransferFunction_AppleLog)
            XCTAssertEqual(log2[AVVideoLogTransferFunctionKey] as? String, AVVideoLogTransferFunction_AppleLog2)
        }
    }

    #if !targetEnvironment(simulator)
    @MainActor func testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        let videoCallback = camera.onVideoRecorded, photoCallback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?, photo: CapturedPhoto?
        camera.onVideoRecorded = { result = $0 }
        camera.onCaptureCompleted = { photo = $0 }
        defer {
            camera.onVideoRecorded = videoCallback; camera.onCaptureCompleted = photoCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.videoColorSpace = .sdr; model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        let began = CACurrentMediaTime()
        var samples = 0
        for mode in [CameraShootingMode.auto, .manual] {
            for color in VideoColorSpace.allCases {
                model.setCaptureKind(.video); model.setMode(mode)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                guard camera.supportedVideoSettings.contains(where: { $0.colorSpace == color }) else {
                    print("VIDEO-COLOR-UNSUPPORTED mode=\(mode) color=\(color.rawValue)"); continue
                }
                let settings = VideoCaptureSettings(colorSpace: color)
                model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = color
                camera.setVideoSettings(settings)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                XCTAssertEqual(camera.videoSettings, settings)
                let state = await withCheckedContinuation { c in camera.videoColorStateForTesting { c.resume(returning: ($0, $1, $2)) } }
                XCTAssertEqual(state.0, color.captureColorSpace)
                let formats: [OSType] = color.usesTenBit
                    ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                    : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                XCTAssertTrue(state.1.map { formats.contains($0) } ?? false)
                let cutoff = CACurrentMediaTime()
                for _ in 0..<250 {
                    let expectedPreview = color == .hdr ? camera.preview?.cgImage?.bitsPerComponent == 16
                        : color == .p3 ? camera.preview?.cgImage?.colorSpace?.name == CGColorSpace.displayP3 : true
                    if camera.previewFrameTimeForTesting > cutoff && expectedPreview { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertGreaterThan(camera.previewFrameTimeForTesting, cutoff)
                if color == .hdr { XCTAssertEqual(camera.preview?.cgImage?.bitsPerComponent, 16) }
                if color == .p3 { XCTAssertEqual(camera.preview?.cgImage?.colorSpace?.name, CGColorSpace.displayP3) }
                // Published specification updates can enqueue one last configuration
                // after the queue barrier. Respect the real shutter's readiness gate.
                for _ in 0..<400 {
                    if camera.ready && !camera.videoBusy && !camera.videoConfiguring && !camera.capturing && camera.pendingPhotoCount == 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let beforeStart = "ready=\(camera.ready) busy=\(camera.videoBusy) configuring=\(camera.videoConfiguring) capturing=\(camera.capturing) pending=\(camera.pendingPhotoCount)"
                camera.startVideoRecording(aspect: .wide)
                for _ in 0..<400 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(camera.videoRecording, "mode=\(mode) color=\(color.rawValue) before=\(beforeStart): \(camera.message ?? "No first frame")")
                try await Task.sleep(for: .milliseconds(1000))
                camera.stopVideoRecording()
                for _ in 0..<600 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                let url = try XCTUnwrap(result?.get())
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let track = try XCTUnwrap(tracks.first)
                let descriptions = try await track.load(.formatDescriptions)
                let description = try XCTUnwrap(descriptions.first)
                let ext = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
                let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                let log = ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String
                switch color {
                case .sdr: XCTAssertEqual(primaries, AVVideoColorPrimaries_ITU_R_709_2)
                case .p3: XCTAssertEqual(primaries, AVVideoColorPrimaries_P3_D65)
                case .hdr: XCTAssertEqual(primaries, AVVideoColorPrimaries_ITU_R_2020); XCTAssertEqual(transfer, AVVideoTransferFunction_ITU_R_2100_HLG)
                case .appleLog: XCTAssertEqual(log, kCVImageBufferLogTransferFunction_AppleLog as String)
                case .appleLog2:
                    if #available(iOS 26, *) { XCTAssertEqual(log, kCVImageBufferLogTransferFunction_AppleLog2 as String) }
                }
                if color.usesTenBit { XCTAssertEqual((ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue, 10) }
                let info = try await VideoDetailsReader.read(asset, filename: nil, date: nil, location: nil)
                let actualColor = info.rows.first { $0.title == "色彩空间" }?.value ?? ""
                let expected = color == .p3 ? "Display P3" : color == .appleLog2 ? "Apple Log 2" : color.rawValue
                XCTAssertTrue(actualColor.contains(expected))
                let fps = try await track.load(.nominalFrameRate)
                XCTAssertEqual(fps, 30, accuracy: 2)
                print("VIDEO-COLOR mode=\(mode) space=\(color.rawValue) fps=\(fps) bits=\(ext[kCMFormatDescriptionExtension_BitsPerComponent as String] ?? "nil") primaries=\(primaries ?? "nil") transfer=\(transfer ?? "nil") log=\(log ?? "nil")")
                try? FileManager.default.removeItem(at: url); result = nil
                model.setCaptureKind(.photo)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let photoState = await withCheckedContinuation { c in camera.videoColorStateForTesting { c.resume(returning: ($0, $2)) } }
                XCTAssertTrue(photoState.1, "Photo output must reactivate after \(color)")
                XCTAssertNotEqual(photoState.0, AVCaptureColorSpace.appleLog)
                if #available(iOS 26, *) { XCTAssertNotEqual(photoState.0, AVCaptureColorSpace.appleLog2) }
                camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
                for _ in 0..<700 { if photo != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertNotNil(photo, camera.message ?? "Still photo failed after \(color)")
                photo = nil; samples += 1
            }
        }
        print("VIDEO-COLOR-MATRIX count=\(samples) elapsed=\(CACurrentMediaTime()-began) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    @MainActor func testAppleLogLUTBurnWritesRec709TagsAndTenBitPixels() async throws {
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let oldCallback = camera.onVideoRecorded
        let oldKind = model.captureKind, oldResolution = model.videoResolution, oldRate = model.videoFrameRate
        let oldColor = model.videoColorSpace, oldCodec = model.videoCodec, oldProRes = model.proResSpecification
        let oldLUTID = model.selectedLogLUTID, oldBurn = model.burnLogLUT
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy { camera.stopVideoRecording() }
            camera.onVideoRecorded = oldCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.burnLogLUT = oldBurn
            model.selectedLogLUTID = oldLUTID
            model.setCaptureKind(oldKind)
            model.videoResolution = oldResolution; model.videoFrameRate = oldRate
            model.videoColorSpace = oldColor; model.videoCodec = oldCodec; model.proResSpecification = oldProRes
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
        }

        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.video)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        guard model.supportsVideoColorSpace(.appleLog) else { throw XCTSkip("Apple Log HEVC is not available on this camera route") }
        let settings = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .appleLog)
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoCodec = .hevc
        model.videoColorSpace = .appleLog
        camera.setVideoSettings(settings)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        let preset = try XCTUnwrap(model.logLUTPresets.first)
        model.selectLogLUT(preset.id)
        for _ in 0..<300 { if model.selectedLogLUTCube != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let cube = try XCTUnwrap(model.selectedLogLUTCube)
        model.burnLogLUT = true
        camera.startVideoRecording(aspect: .wide, look: model.effectiveCaptureLook,
                                   logLUTCube: cube, burnLogLUT: true, logLUTName: preset.title)
        for _ in 0..<400 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(camera.videoRecording, camera.message ?? "No first Log LUT video frame")
        try await Task.sleep(for: .seconds(1))
        camera.stopVideoRecording()
        for _ in 0..<600 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }

        let url = try XCTUnwrap(result?.get())
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        XCTAssertNil(extensions[kCMFormatDescriptionExtension_LogTransferFunction as String],
                     "烧录 LUT 后不能继续标为 Apple Log")
        XCTAssertEqual(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
                       kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                       kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual((extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue, 10)
        XCTAssertTrue(VideoCaptureBadges.forRecording(colorSpace: .appleLog, burnedLogLUT: true).hasFilter)
        let duration = try await asset.load(.duration)
        print("LOG-LUT-BURN codec=\(CMFormatDescriptionGetMediaSubType(description)) bits=10 elapsed=\(duration.seconds)")
    }

    @MainActor func testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery() async throws {
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let oldStyle = model.style, oldIntensity = model.intensity, oldEdits = model.filterAdjustments
        let oldCodec = model.videoCodec, oldProRes = model.proResSpecification
        let oldResolution = model.videoResolution, oldRate = model.videoFrameRate
        let oldColor = model.videoColorSpace, oldRatio = model.videoRatio, oldKind = model.captureKind, oldMode = model.mode
        let oldCallback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy { camera.stopVideoRecording() }
            camera.onVideoRecorded = oldCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.setCaptureKind(oldKind)
            model.setMode(oldMode)
            model.videoCodec = oldCodec; model.proResSpecification = oldProRes
            model.videoResolution = oldResolution; model.videoFrameRate = oldRate
            model.videoColorSpace = oldColor; model.videoRatio = oldRatio
            model.style = oldStyle; model.intensity = oldIntensity; model.filterAdjustments = oldEdits
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.video)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        model.videoCodec = .hevc; model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.style = .mono; model.intensity = 1
        model.filterAdjustments = FilterAdjustments()

        for color in [VideoColorSpace.sdr, .p3] {
            guard model.supportsVideoColorSpace(color) else { throw XCTSkip("Device does not offer \(color.rawValue) for this route") }
            model.videoColorSpace = color
            let settings = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: color, codec: .hevc)
            camera.setVideoSettings(settings)
            await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
            XCTAssertEqual(camera.videoSettings, settings)
            XCTAssertEqual(model.effectiveCaptureLook.style, .mono)
            XCTAssertTrue(model.filterControlsEnabled)

            // Confirm that the live view itself has received a filtered frame before recording.
            let previewStart = camera.previewFrameTimeForTesting
            var previewChroma = Double.infinity
            for _ in 0..<100 {
                if camera.previewFrameTimeForTesting > previewStart,
                   let previewImage = camera.preview?.cgImage {
                    previewChroma = meanChroma(in: previewImage)
                    if previewChroma < 3 { break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertLessThan(previewChroma, 3, "The preview should use the same monochrome look as the encoded SDR/P3 movie")
            let begin = CACurrentMediaTime()
            camera.startVideoRecording(aspect: model.videoRatio.frameRatio, copyright: nil, look: model.effectiveCaptureLook)
            for _ in 0..<400 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "Filtered video did not start for \(color.rawValue)")
            try await Task.sleep(for: .milliseconds(1100))
            camera.stopVideoRecording()
            for _ in 0..<600 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let url = try XCTUnwrap(result?.get())
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration).seconds
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            XCTAssertTrue(reader.canAdd(output))
            reader.add(output)
            XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "Could not decode filtered movie")
            var frameCount = 0, chromaTotal = 0, chromaSamples = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                frameCount += 1
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    for y in stride(from: height / 8, to: height * 7 / 8, by: max(1, height / 12)) {
                        for x in stride(from: width / 8, to: width * 7 / 8, by: max(1, width / 12)) {
                            let index = y * rowBytes + x * 4
                            let blue = Int(base[index]), green = Int(base[index + 1]), red = Int(base[index + 2])
                            chromaTotal += abs(red - green) + abs(green - blue)
                            chromaSamples += 2
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Filtered movie decode was incomplete")
            XCTAssertGreaterThan(frameCount, 15, "Short sample should contain usable video frames")
            let meanChroma = Double(chromaTotal) / Double(max(1, chromaSamples))
            XCTAssertLessThan(meanChroma, 12, "The monochrome photo look must be encoded into each SDR/P3 video frame")
            let measuredFPS = Double(frameCount) / max(duration, 0.001)
            XCTAssertGreaterThan(measuredFPS, 20, "Filtered encoding should maintain real-time frame delivery")
            print("VIDEO-FILTER-CAPTURE color=\(color.rawValue) previewChroma=\(previewChroma) frames=\(frameCount) duration=\(duration) measuredFPS=\(measuredFPS) encodedMeanChroma=\(meanChroma) wall=\(CACurrentMediaTime()-begin)")
            try? FileManager.default.removeItem(at: url); result = nil
        }
    }

    /// 用固定洋红输出的诊断 LUT 检查实际文件像素：预览开启且不烧录时，成片不能被替换成洋红。
    /// 独立于自然场景的色调变化，不以滤镜名或文件标签冒充 LUT 已写入。
    @MainActor func testLogAndLog2PreviewOnlyAndBurnHaveDifferentEncodedPixels() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("公开 Log 写入标记需要 iOS27") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.updateVideoLogLUT(nil)
            if camera.videoBusy { camera.stopVideoRecording() }
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            camera.onVideoRecorded = callback; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        model.setCameraActive(true)
        try await waitForVideoCondition { camera.ready && camera.preview != nil }
        if model.currentPosition != .back { model.flipCamera(); try await waitForVideoCondition { camera.ready && model.currentPosition == .back } }
        model.setCaptureKind(.video)
        try await waitForVideoCondition { camera.ready && !camera.videoConfiguring }
        var values: [Float] = []
        for _ in 0..<8 { values += [1,0,1,1] }
        let data = values.withUnsafeBytes { Data($0) }
        let cube = try XCTUnwrap(LogLUTCube(dimension: 2, rgbaData: data))
        let previewContext = CIContext(options: [.cacheIntermediates:false])
        func hasMagentaPreview() -> Bool {
            guard let image = camera.preview?.cgImage else { return false }
            let source = CIImage(cgImage:image)
            let average = source.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:source.extent)])
            var pixel = [UInt8](repeating:0,count:4)
            pixel.withUnsafeMutableBytes { bytes in
                previewContext.render(average,toBitmap:bytes.baseAddress!,rowBytes:4,
                    bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
            }
            return pixel[0] > 160 && pixel[1] < 60 && pixel[2] > 160
        }
        for color in [VideoColorSpace.appleLog, .appleLog2] {
            XCTAssertTrue(model.supportsVideoColorSpace(color), "此设备/路由必须实际提供被测 Log 规格")
            model.videoColorSpace = color
            camera.setVideoSettings(.init(colorSpace: color))
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await waitForVideoCondition { camera.ready && !camera.videoConfiguring && camera.videoSettings.colorSpace == color }
            camera.updateVideoLogLUT(cube)
            // 强制先确认实时预览也在应用这张诊断 LUT。
            let previewAt = CACurrentMediaTime()
            try await waitForVideoCondition { camera.previewFrameTimeForTesting > previewAt && hasMagentaPreview() }
            for burn in [false, true] {
                result = nil
                camera.startVideoRecording(aspect: .wide, logLUTCube: cube, burnLogLUT: burn, logLUTName: "诊断洋红")
                try await waitForVideoCondition { camera.videoRecording || result != nil }
                XCTAssertTrue(camera.videoRecording)
                try await Task.sleep(for: .milliseconds(600))
                camera.stopVideoRecording()
                try await waitForVideoCondition { result != nil }
                let url = try XCTUnwrap(result?.get())
                defer { try? FileManager.default.removeItem(at: url) }
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let track = try XCTUnwrap(tracks.first)
                let descriptions = try await track.load(.formatDescriptions)
                let description = try XCTUnwrap(descriptions.first)
                let tags = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
                let expected = color == .appleLog ? kCVImageBufferLogTransferFunction_AppleLog as String : kCVImageBufferLogTransferFunction_AppleLog2 as String
                XCTAssertEqual(tags[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String, expected)
                XCTAssertEqual((tags[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue, 10)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                var samples = 0, magenta = 0, frames = 0
                while let frame = output.copyNextSampleBuffer() {
                    guard let buffer = CMSampleBufferGetImageBuffer(frame) else { continue }
                    frames += 1
                    CVPixelBufferLockBaseAddress(buffer,.readOnly)
                    if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self) {
                        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
                        for y in stride(from: h/8,to:h*7/8,by:max(1,h/8)) {
                            for x in stride(from:w/8,to:w*7/8,by:max(1,w/8)) {
                                let p = y*row+x*4
                                if base[p] > 160 && base[p+1] < 60 && base[p+2] > 160 { magenta += 1 }
                                samples += 1
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
                }
                XCTAssertEqual(reader.status,.completed)
                XCTAssertGreaterThan(frames,8)
                let fraction = Double(magenta)/Double(max(1,samples))
                if burn { XCTAssertGreaterThan(fraction,0.95,"烧录必须改变实际编码像素") }
                else { XCTAssertLessThan(fraction,0.5,"仅预览不可把诊断 LUT 写入成片；测试场景应非纯洋红") }
                print("LOG-LUT-PIXELS color=\(color.rawValue) burn=\(burn) frames=\(frames) magentaFraction=\(fraction) bits=10 logTag=\(expected)")
                try? FileManager.default.removeItem(at:url); result = nil
            }
            camera.updateVideoLogLUT(nil)
        }
    }

    @MainActor private func waitForVideoCondition(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTFail("视频编码/色彩状态等待超时")
        throw NSError(domain:"VideoColorTest",code:1)
    }

    private func meanChroma(in image: CGImage) -> Double {
        let size = 64
        let source = CIImage(cgImage: image)
        let scale = CGAffineTransform(scaleX: CGFloat(size) / source.extent.width,
                                      y: CGFloat(size) / source.extent.height)
        let scaled = source.transformed(by: scale).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        bytes.withUnsafeMutableBytes { buffer in
            context.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: size * 4,
                           bounds: CGRect(x: 0, y: 0, width: size, height: size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var total = 0, samples = 0
        for pixel in stride(from: 0, to: size * size * 4, by: 16) {
            total += abs(Int(bytes[pixel]) - Int(bytes[pixel + 1]))
            total += abs(Int(bytes[pixel + 1]) - Int(bytes[pixel + 2]))
            samples += 2
        }
        return Double(total) / Double(max(samples, 1))
    }

    #endif
}
