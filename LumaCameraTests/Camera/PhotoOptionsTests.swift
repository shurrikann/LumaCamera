import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import LumaCamera

final class PhotoOptionsTests: XCTestCase {
    private let context = CIContext()
    private var source: CIImage { CIImage(color: CIColor(red: 0.6, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 160)) }

    /// 测试高光使用浮点位图，避免CIColor默认SDR色域把输入截到1。
    private func hdrSource(_ rgb: [Float] = [3, 3, 3]) -> CIImage {
        let pixels = Array(repeating: rgb + [1], count: 120 * 160).flatMap { $0 }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 120 * 16,
            size: CGSize(width: 120, height: 160), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    }

    func testFlashCyclesThroughAllThreeStates() {
        XCTAssertEqual(CameraFlashMode.off.next, .on)
        XCTAssertEqual(CameraFlashMode.on.next, .auto)
        XCTAssertEqual(CameraFlashMode.auto.next, .off)
        XCTAssertEqual(CameraFlashMode.auto.avMode, .auto)
    }
    func testBurstPolicyAllowsOnlyStandardJpegAndHEIFWithoutLiveOrHDR() {
        for format in [PhotoFileFormat.jpeg, .heif] {
            XCTAssertTrue(PhotoBurstPolicy.supports(format: format, resolution: .standard, live: false, hdr: false))
            XCTAssertFalse(PhotoBurstPolicy.supports(format: format, resolution: .high, live: false, hdr: false))
            XCTAssertFalse(PhotoBurstPolicy.supports(format: format, resolution: .standard, live: true, hdr: false))
            XCTAssertFalse(PhotoBurstPolicy.supports(format: format, resolution: .standard, live: false, hdr: true))
        }
        for format in [PhotoFileFormat.raw, .rawJPEG, .tiff, .heifPro] {
            XCTAssertFalse(PhotoBurstPolicy.supports(format: format, resolution: .standard, live: false, hdr: false))
        }
    }

    func testPhotoSubmodePoliciesExposeSafeFormatsAndResolutionFallbacks() {
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.formats(for: .night), [.heif, .jpeg])
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.formats(for: .burst), [.heif, .jpeg])
        XCTAssertTrue(PhotoSubmodeSettingsPolicy.formats(for: .portrait).contains(.heifPro),
                      "人像在当前相机路线支持 ProRAW 时应保留其既有支持能力。")

        let allResolutions: Set<PhotoResolution> = [.standard, .high]
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.resolution(for: .night, requested: .high,
                                                               supported: allResolutions), .standard)
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.resolution(for: .burst, requested: .high,
                                                               supported: allResolutions), .standard)
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.resolution(for: .portrait, requested: .high,
                                                               supported: allResolutions), .high)
        XCTAssertNil(PhotoSubmodeSettingsPolicy.resolution(for: .night, requested: .standard,
                                                            supported: []))
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.preferredFormat(for: .night, requested: .raw,
            supported: [.jpeg, .heif]), .heif, "夜景从 RAW 进入时应自动回退到当前路线优先支持的处理格式。")
        XCTAssertEqual(PhotoSubmodeSettingsPolicy.preferredFormat(for: .portrait, requested: .raw,
            supported: [.jpeg, .heif]), .heif, "人像模式在目标镜头不支持所选 RAW 路线时应选 HEIF。")
        XCTAssertNil(PhotoSubmodeSettingsPolicy.preferredFormat(for: .night, requested: .raw,
            supported: [.raw]), "没有兼容格式时不得保留不支持的 RAW。")

        let nightRoute = PhotoLensCaptureCapabilities(formats: [.heif, .jpeg], resolutions: [.standard],
            supportsNightCapture: true, supportsPortraitCapture: false)
        XCTAssertTrue(nightRoute.supports(.night))
        XCTAssertFalse(nightRoute.supports(.portrait))
        XCTAssertTrue(nightRoute.supports(.burst), "JPG/HEIF 12MP 路线可用连拍。")
    }

    func testPortraitPolicyAllows48MPWhenCurrentCameraFormatProvidesIt() {
        for format in [PhotoFileFormat.jpeg, .heif] {
            XCTAssertTrue(PortraitCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false))
            XCTAssertTrue(PortraitCapturePolicy.supports(format: format, resolution: .high, live: false, hdr: false),
                          "Portrait matte delivery has no documented blanket 12MP restriction.")
            XCTAssertFalse(PortraitCapturePolicy.supports(format: format, resolution: .high, live: true, hdr: false))
            XCTAssertFalse(PortraitCapturePolicy.supports(format: format, resolution: .high, live: false, hdr: true))
        }
        for format in [PhotoFileFormat.raw, .rawJPEG, .tiff, .heifPro] {
            XCTAssertFalse(PortraitCapturePolicy.supports(format: format, resolution: .high, live: false, hdr: false))
        }
        XCTAssertEqual(PortraitCapturePolicy.availableFormats(proRAWAvailable: false), [.jpeg, .heif])
        XCTAssertEqual(PortraitCapturePolicy.availableFormats(proRAWAvailable: true), [.jpeg, .heif, .raw, .rawJPEG, .heifPro])
        for format in [PhotoFileFormat.raw, .rawJPEG, .heifPro] {
            XCTAssertTrue(PortraitCapturePolicy.supports(format: format, resolution: .high, live: false, hdr: false,
                                                          proRAWAvailable: true),
                          "Portrait effects mattes are supported in ProRAW, but not Bayer RAW.")
        }
        XCTAssertFalse(PortraitCapturePolicy.supports(format: .heif, resolution: .high, live: false, hdr: true,
                                                       proRAWAvailable: true),
                       "HDR is not an Apple-documented Portrait restriction, but this app's capture route has not passed the real-device combination test.")
        XCTAssertFalse(PortraitCapturePolicy.supports(format: .jpeg, resolution: .standard, live: false, hdr: true,
                                                       proRAWAvailable: true))
    }

    func testSoftwarePortraitDoesNotRequireNativeDepthDelivery() {
        XCTAssertTrue(PortraitCapturePolicy.supportsSoftwarePortrait(formats: [.heif, .jpeg], resolutions: [.standard, .high]))
        XCTAssertTrue(PortraitCapturePolicy.supportsSoftwarePortrait(formats: [.jpeg], resolutions: [.standard]))
        XCTAssertFalse(PortraitCapturePolicy.supportsSoftwarePortrait(formats: [.raw, .tiff], resolutions: [.standard]))
        XCTAssertFalse(PortraitCapturePolicy.supportsSoftwarePortrait(formats: [.heif], resolutions: []))
        XCTAssertFalse(PortraitCapturePolicy.supports(format: .heif, resolution: .standard, live: true, hdr: false))
    }

    func testNightPolicyRequiresThreeFrameAEBracketAndCompatiblePhotoSettings() {
        for format in [PhotoFileFormat.jpeg, .heif] {
            XCTAssertTrue(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false,
                                                       timerSeconds: 0, maximumBracketedCapturePhotoCount: 3))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .high, live: false, hdr: false, timerSeconds: 0))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: true, hdr: false, timerSeconds: 0))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: true, timerSeconds: 0))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false, timerSeconds: 3))
            XCTAssertTrue(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false, timerSeconds: 0, manualMode: true))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false, timerSeconds: 0, flashMode: .auto))
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false, timerSeconds: 0, maximumBracketedCapturePhotoCount: 2))
        }
        for format in [PhotoFileFormat.raw, .rawJPEG, .tiff, .heifPro] {
            XCTAssertFalse(NightCapturePolicy.supports(format: format, resolution: .standard, live: false, hdr: false, timerSeconds: 0))
        }
    }

    @MainActor
    func testNightTapWaitsForAReadyCameraBeforeChangingCaptureState() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let settings = (model.mode, model.photoFormat, model.photoResolution, model.hdr, model.livePhotoEnabled,
                        model.flashMode, model.timerSeconds)
        model.toggleNightMode()
        XCTAssertFalse(model.nightModeEnabled, "相机尚未就绪时，按钮不能留下半启用的夜景状态。")
        XCTAssertFalse(model.showsNightIndicator)
        XCTAssertEqual(model.mode, settings.0)
        XCTAssertEqual(model.photoFormat, settings.1)
        XCTAssertEqual(model.photoResolution, settings.2)
        XCTAssertEqual(model.hdr, settings.3)
        XCTAssertEqual(model.livePhotoEnabled, settings.4)
        XCTAssertEqual(model.flashMode, settings.5)
        XCTAssertEqual(model.timerSeconds, settings.6)
        XCTAssertFalse(model.photoOptions.nightMode)
    }

    func testNightEnvironmentGateRequiresStableLowLightAndUsesHysteresis() {
        var gate = NightCaptureEnvironmentGate()
        XCTAssertFalse(gate.update(iso: 400, seconds: 1.0 / 60, exposureBiasEV: 0))
        XCTAssertFalse(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 0), "One dark reading must not flash the indicator orange.")
        XCTAssertTrue(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 0))
        XCTAssertTrue(gate.update(iso: 1600, seconds: 1.0 / 30, exposureBiasEV: 0), "Values between enter and exit thresholds should preserve the triggered state.")
        XCTAssertTrue(gate.update(iso: 400, seconds: 1.0 / 30, exposureBiasEV: 0))
        XCTAssertTrue(gate.update(iso: 400, seconds: 1.0 / 30, exposureBiasEV: 0))
        XCTAssertFalse(gate.update(iso: 400, seconds: 1.0 / 30, exposureBiasEV: 0), "Three bright readings should clear the trigger.")
    }

    func testNightEnvironmentGateNormalizesExposureCompensationAndResets() {
        var gate = NightCaptureEnvironmentGate()
        XCTAssertFalse(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 1))
        XCTAssertFalse(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 1))
        XCTAssertFalse(gate.isTriggered)
        XCTAssertFalse(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 0))
        XCTAssertTrue(gate.update(iso: 3200, seconds: 1.0 / 30, exposureBiasEV: 0))
        gate.reset()
        XCTAssertFalse(gate.isTriggered)
    }

    func testNightEnvironmentGateRepeatedReadingsPerformance() {
        measure(metrics: [XCTClockMetric()]) {
            var gate = NightCaptureEnvironmentGate()
            for sample in 0..<20_000 {
                let isDim = (sample / 500).isMultiple(of: 2)
                _ = gate.update(iso: isDim ? 3200 : 100, seconds: 1.0 / 30, exposureBiasEV: 0)
            }
        }
    }

    func testNightIndicatorMapsClosedWaitingTriggeredAndUnsupportedStates() {
        XCTAssertEqual(NightIndicatorState.resolve(isEnabled: false, captureSupported: true, environmentTriggered: true), .hidden)
        XCTAssertEqual(NightIndicatorState.resolve(isEnabled: true, captureSupported: true, environmentTriggered: false), .waitingForLowLight)
        XCTAssertEqual(NightIndicatorState.resolve(isEnabled: true, captureSupported: true, environmentTriggered: true), .triggered)
        XCTAssertEqual(NightIndicatorState.resolve(isEnabled: true, captureSupported: false, environmentTriggered: true), .unsupported)
    }

    func testNightMergerRepeatedSyntheticThreeFrameBracket() throws {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 240)
        var pattern = CIImage(color: .black).cropped(to: extent)
        for index in 0..<36 {
            let x = CGFloat((index * 47) % 300)
            let y = CGFloat((index * 71) % 220)
            let side = CGFloat(12 + index % 17)
            let color = CIColor(red: CGFloat((index * 37) % 100) / 100,
                                green: CGFloat((index * 61) % 100) / 100,
                                blue: CGFloat((index * 83) % 100) / 100)
            let tile = CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: side, height: side))
            pattern = tile.composited(over: pattern)
        }
        let bracket = [-1.0, 0.0, 1.0].map { ev in
            pattern.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        let context = CIContext()
        let sampleCount = 10
        var elapsed: TimeInterval = 0
        for _ in 0..<sampleCount {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try NightPhotoMerger.merge(bracket, context: context, maximumRegistrationDimension: 320)
            elapsed += CFAbsoluteTimeGetCurrent() - start
            XCTAssertGreaterThan(result.image.extent.width, 0)
            XCTAssertGreaterThan(result.image.extent.height, 0)
            XCTAssertEqual(result.alignedFrameCount, 3, "A stationary synthetic bracket should align and fuse all three exposures.")
            XCTAssertTrue(result.croppedFraction.isFinite && (0...1).contains(result.croppedFraction))
        }
        print("Night synthetic merge: n=\(sampleCount), 320x240, average=\(Int(elapsed / Double(sampleCount) * 1000)) ms")
        XCTAssertThrowsError(try NightPhotoMerger.merge([], context: context))
    }
    func testEncodedFormatsMatchTheirFileContainersAndCrop() throws {
        for (format, type) in [(PhotoFileFormat.jpeg, UTType.jpeg), (.heif, UTType.heic), (.tiff, UTType.tiff)] {
            let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(ratio: .square), options: PhotoOptions(format: format), context: context)
            XCTAssertEqual(photo.resources.count, 1)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(decoded) as String?, type.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 120)
        }
    }
    func testEncodedPhotosPreserveExposureMetadata() throws {
        let exif: [String: Any] = [
            kCGImagePropertyExifExposureTime as String: 1.0,
            kCGImagePropertyExifISOSpeedRatings as String: [4000],
            kCGImagePropertyExifFNumber as String: 1.78
        ]
        let tagged = source.settingProperties([kCGImagePropertyExifDictionary as String: exif])
        for format in [PhotoFileFormat.heif, .jpeg, .tiff] {
            let photo = try PhotoEncoder.encode(source: tagged, raw: nil, look: CaptureLook(), options: PhotoOptions(format: format), context: context)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            let saved = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertEqual(saved[kCGImagePropertyExifExposureTime] as? Double, 1.0, "\(format) 丢失曝光时间")
            let iso = saved[kCGImagePropertyExifISOSpeedRatings] as? [Int]
            XCTAssertEqual(iso?.first, 4000, "\(format) 丢失 ISO")
        }
    }

    func testHDRHEIFWithFilterKeepsGainMap() throws {
        let image = hdrSource([3, 1.5, 0.5])
        let look = CaptureLook(style: .leicaM9, intensity: 0.8)
        let photo = try PhotoEncoder.encode(source: image, raw: nil, look: look,
                                            options: PhotoOptions(format: .heif, hdr: true), context: context)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap), "HDR成片必须带ISO增益图")
        HDRImageAssertions.assertNativeISOGainMap(source)
        XCTAssertEqual((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any])?[kCGImagePropertyDepth] as? Int, 8)
    }

    func testHDRHEIFKeepsMidtonesAndConfinesGainToHighlightShoulder() throws {
        let w=48, h=64
        var pixels=[Float](repeating:0,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let v: Float = x < 20 ? 0.5 : x < 32 ? 0.9 : 3.0
            let i=(y*w+x)*4; pixels[i]=v; pixels[i+1]=v; pixels[i+2]=v; pixels[i+3]=1
        }}
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let source = CIImage(bitmapData: data, bytesPerRow: w*16, size: CGSize(width:w,height:h), format:.RGBAf, colorSpace:cs)
        let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(), options: PhotoOptions(format: .heif, hdr: true), context: context)
        let sourceFile = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(sourceFile, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        HDRImageAssertions.assertNativeISOGainMap(sourceFile)
        let sdrCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceFile, 0, nil))
        let hdr = try XCTUnwrap(CIImage(data: photo.resources[0].data, options: [.expandToHDR:true]))
        print("HDR-SHOULDER headroom=\(hdr.contentHeadroom) sdr=\(sdrCG.width)x\(sdrCG.height) hdrExt=\(hdr.extent)")
        func sample(_ image: CIImage, _ x: Int) -> Float {
            var p=[Float](repeating:0,count:4)
            p.withUnsafeMutableBytes { context.render(image, toBitmap:$0.baseAddress!, rowBytes:16, bounds:CGRect(x:x,y:h/2,width:1,height:1), format:.RGBAf, colorSpace:cs) }
            return max(p[0],p[1],p[2])
        }
        let sdr = CIImage(cgImage: sdrCG)
        let midRatio = sample(hdr,10) / max(sample(sdr,10), 0.001)
        let nearWhiteRatio = sample(hdr,26) / max(sample(sdr,26), 0.001)
        let highRatio = sample(hdr,44) / max(sample(sdr,44), 0.001)
        print("HDR-SHOULDER mid=\(midRatio) nearWhite=\(nearWhiteRatio) high=\(highRatio) sdrMid=\(sample(sdr,10)) sdrHigh=\(sample(sdr,44))")
        XCTAssertEqual(midRatio, 1, accuracy: 0.15, "0–0.8中间调SDR与HDR应基本一致")
        XCTAssertLessThan(nearWhiteRatio, 1.25, "0.9仍在肩部前，增益应小")
        XCTAssertGreaterThan(highRatio, 1.5, "高光肩部才应产生HDR增益")
    }

    func testHEIFProHDRToneChangesHDRPixels() throws {
        // 同一扩展线性源图覆盖暗部、中间调、参考白和HDR高光；普通CIColor会截断>1。
        let values: [Float] = [0.03, 0.18, 0.5, 0.9, 1.5, 3, 6]
        let w = values.count * 16, h = 84
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, v = values[x / 16]
            pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v
        }}
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = CIImage(bitmapData: data, bytesPerRow: w * 16,
            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: cs)
        func samples(_ image: CIImage) -> [Float] {
            values.indices.map { index in
                var p = [Float](repeating: 0, count: 4)
                p.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: index * 16 + 8, y: h / 2, width: 1, height: 1), format: .RGBAf, colorSpace: cs) }
                return p[0]
            }
        }
        let natural = samples(Imaging.filtered(source, look: CaptureLook(), hdr: true))
        for tone in PhotoTone.allCases {
            let look = CaptureLook(style: .original, intensity: 0, landscape: true, tone: tone)
            let beforeEncoding = samples(Imaging.filtered(source, look: look, hdr: true))
            print("HDR-SAME-SOURCE tone=\(tone.rawValue) pixels=\(beforeEncoding)")
            XCTAssertTrue(beforeEncoding.allSatisfy { $0.isFinite && $0 > 0 })
            for i in 4..<values.count {
                XCTAssertGreaterThan(beforeEncoding[i], natural[i] * 0.7, "影调不能把原有HDR高光压回SDR")
            }
            if tone == .contrast {
                XCTAssertLessThan(beforeEncoding[1], natural[1] * 0.8, "保留高光不能抹掉高对比中间调风格")
            }
            for format in [PhotoFileFormat.heif, .heifPro] {
                let began = CACurrentMediaTime()
                let photo = try PhotoEncoder.encode(source: source, raw: nil, look: look,
                    options: PhotoOptions(format: format, hdr: true), context: context)
                let resource = try XCTUnwrap(photo.resources.first)
                let decoded = try XCTUnwrap(CIImage(data: resource.data, options: [.expandToHDR: true]))
                let output = samples(decoded)
                for i in values.indices {
                    XCTAssertEqual(output[i], beforeEncoding[i], accuracy: max(0.015, beforeEncoding[i] * 0.12),
                        "\(format) \(tone) 编码不能改变原有曝光/高光")
                }
                print("HDR-ENCODE-ROUNDTRIP format=\(format) tone=\(tone) seconds=\(CACurrentMediaTime()-began) pixels=\(output) headroom=\(decoded.contentHeadroom)")
            }
        }
    }

    #if !targetEnvironment(simulator)
    func testHEIFProHDRToneWritesGainMapOnDevice() throws {
        let source = hdrSource()
        func encoded(_ tone: PhotoTone) throws -> Data {
            let look = CaptureLook(style: .original, intensity: 0, tone: tone)
            let photo = try PhotoEncoder.encode(source: source, raw: nil, look: look,
                                                options: PhotoOptions(format: .heifPro, hdr: true), context: context)
            return try XCTUnwrap(photo.resources.first?.data)
        }
        for tone in [PhotoTone.natural, .contrast] {
            let data = try encoded(tone)
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap), "\(tone) HDR必须带ISO增益图")
            HDRImageAssertions.assertNativeISOGainMap(src)
        }
    }
    #endif

    func testSDRHEIFHasNoGainMap() throws {
        let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(),
                                            options: PhotoOptions(format: .heif, hdr: false), context: context)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 8)
        XCTAssertFalse(HDRImageAssertions.hasGainMap(decoded), "HDR 关闭不能输出增益图")
        let lowRange = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(),
            options: PhotoOptions(format: .heif, hdr: true), context: context)
        XCTAssertNotNil(CGImageSourceCreateWithData(lowRange.resources[0].data as CFData, nil),
            "HDR开启但场景没有扩展高光时也必须交付有效HEIF")
    }

    func testLiveFilterColorsMatchSavedTIFFAcrossStylesAndTones() throws {
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 120, y: 160), "inputColor0": CIColor(red: 0.1, green: 0.6, blue: 0.8), "inputColor1": CIColor(red: 0.9, green: 0.3, blue: 0.2)])!.outputImage!.cropped(to: source.extent)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func sample(_ image: CIImage, at point: CGPoint) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8, colorSpace: space) }
            return bytes
        }
        for style in FilmStyle.allCases {
            for tone in PhotoTone.allCases {
                let look = CaptureLook(style: style, intensity: 0.65, ratio: .standard, tone: tone)
                let live = Imaging.filtered(gradient, look: look)
                let cg = try XCTUnwrap(context.createCGImage(live, from: live.extent, format: .RGBA8, colorSpace: space))
                let display = CIImage(cgImage: cg)
                let photo = try PhotoEncoder.encode(source: gradient, raw: nil, look: look, options: PhotoOptions(format: .tiff), context: context)
                let saved = try XCTUnwrap(CIImage(data: photo.resources[0].data))
                for point in [CGPoint(x: 15, y: 20), CGPoint(x: 60, y: 80), CGPoint(x: 105, y: 140)] {
                    let expected = sample(display, at: point), actual = sample(saved, at: point)
                    for channel in 0..<3 { XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 2, "\(style) / \(tone)") }
                }
            }
        }
    }

    func testHDRHEIFWritesGainMapWithSDRBase() throws {
        let image = hdrSource([3, 1.5, 0.5])
        let photo = try PhotoEncoder.encode(source: image, raw: nil, look: CaptureLook(), options: PhotoOptions(format: .heifPro, hdr: true), context: context)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        let isoGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(decoded, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        XCTAssertTrue(isoGainMap, "HDR HEIF 必须带 ISO 增益图")
        HDRImageAssertions.assertNativeISOGainMap(decoded)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 8, "增益图路径应以 SDR 基底作为主图")
    }
    func testMeanMeteringMeasuresEntireFrameInLinearLight() {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let white = CIImage(color: .white).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        XCTAssertEqual(Imaging.meanLuminance(white.composited(over: black), context: context), 0.5, accuracy: 0.02)
    }
    func testRAWPairPreservesDNGBytesAndJPEGPrimary() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T12:34:56Z")).addingTimeInterval(0.789)
        XCTAssertEqual(PhotoEncoder.captureFilenamePrefix(date: date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), "luma-20261106-203456-789")
        let raw = Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0])
        let photo = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(), options: PhotoOptions(format: .rawJPEG), context: context, captureDate: date)
        XCTAssertEqual(photo.resources.count, 2)
        let prefix = PhotoEncoder.captureFilenamePrefix(date: date)
        XCTAssertEqual(photo.resources[0].filename, prefix + ".jpg")
        XCTAssertEqual(photo.resources[1].filename, prefix + ".dng")
        let names = (0..<1000).map { PhotoEncoder.captureFilenamePrefix(date: date.addingTimeInterval(Double($0) / 1000)) }
        XCTAssertEqual(Set(names).count, 1000, "毫秒时间戳不应在连续毫秒内重名")
        XCTAssertEqual(photo.resources[1].data, raw)
        XCTAssertTrue(photo.resources[1].alternate)
        XCTAssertTrue(photo.resources[0].filename.hasSuffix(".jpg"))
        XCTAssertTrue(photo.resources[1].filename.hasSuffix(".dng"))
        XCTAssertThrowsError(try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(), options: PhotoOptions(format: .raw), context: context))
    }
    func testNewRatiosAreCenteredAndXPANUsesFilmGateRatio() {
        XCTAssertEqual(FrameRatio.xpan.portraitRatio, 24.0 / 65, accuracy: 0.00001)
        XCTAssertFalse(FrameRatio.photoOptions.contains(.openGate))
        XCTAssertEqual(FrameRatio.photoOptions.count, FrameRatio.allCases.count - 1)
        // 奇偶尺寸组合无法始终同时满足“整数像素边界”和“数学中心完全重合”。
        // 最多半像素的居中误差是量化边界；仍检查源图内裁切、整数边界和真实渲染尺寸，不能只放宽容差。
        for size in [CGSize(width: 120, height: 160), CGSize(width: 121, height: 161),
                     CGSize(width: 160, height: 121), CGSize(width: 161, height: 120)] {
            let bounds = CGRect(origin: CGPoint(x: 7, y: -3), size: size)
            let image = CIImage(color: .white).cropped(to: bounds)
            for landscape in [false, true] {
                for ratio in FrameRatio.allCases {
                    let cropped = ratio.crop(image, landscape: landscape)
                    let extent = cropped.extent
                    XCTAssertTrue(bounds.contains(extent), "\(ratio) 不得裁出源图边界")
                    XCTAssertEqual(extent, extent.integral)
                    XCTAssertEqual(extent.midX, bounds.midX, accuracy: 0.5)
                    XCTAssertEqual(extent.midY, bounds.midY, accuracy: 0.5)
                    if ratio != .openGate {
                        let expected = landscape ? ratio.landscapeRatio : ratio.portraitRatio
                        XCTAssertEqual(extent.width / extent.height, expected, accuracy: 2.0 / extent.height)
                    } else {
                        XCTAssertEqual(extent, bounds, "Open Gate 不应裁切")
                    }
                    let rendered = context.createCGImage(cropped, from: extent)
                    XCTAssertEqual(rendered?.width, Int(extent.width))
                    XCTAssertEqual(rendered?.height, Int(extent.height))
                }
            }
        }
    }
    func testToneChangesPixelsButNaturalPreservesSource() throws {
        let natural = try XCTUnwrap(Imaging.render(source, look: CaptureLook(), context: context).flatMap { $0.pngData() })
        for tone in PhotoTone.allCases where tone != .natural {
            let actual = try XCTUnwrap(Imaging.render(source, look: CaptureLook(tone: tone), context: context).flatMap { $0.pngData() })
            XCTAssertNotEqual(actual, natural)
        }
    }
    @MainActor
    func testToolbarPanelCoexistsWithFiltersAndReplacesManualPanel() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.panel = .film
        model.toggleToolbarPanel(.format)
        XCTAssertEqual(model.panel, .film)
        XCTAssertEqual(model.toolbarPanel, .format)
        model.panel = .manual
        model.toggleToolbarPanel(.ratio)
        XCTAssertNil(model.panel)
        model.selectRatio(.xpan)
        XCTAssertEqual(model.ratio, .xpan)
        model.selectRatio(.openGate)
        XCTAssertEqual(model.ratio, .xpan)
        model.closePopups()
        XCTAssertNil(model.toolbarPanel)
    }
}
