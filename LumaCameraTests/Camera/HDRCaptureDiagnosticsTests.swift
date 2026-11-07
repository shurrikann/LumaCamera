import XCTest
import UIKit
import ImageIO
import CoreImage
import AVFoundation
import Photos
@testable import LumaCamera

@MainActor
final class HDRCaptureDiagnosticsTests: XCTestCase {
    /// 只读核对用户22:00样片和本轮已授权样片的实际资源名/EXIF/应用记录，不创建资产。
    func testReadOnlyDeferredHDRFileIdentityAndEV() async throws {
        let options = PHFetchOptions()
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-11-06T21:49:20+08:00")!
        let end = formatter.date(from: "2026-11-06T22:00:45+08:00")!
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var found = 0
        var readTimes = [Double]()
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let names = PHAssetResource.assetResources(for: asset).map { "\($0.type.rawValue):\($0.originalFilename)" }
            let stored = PhotoCaptureDiagnosticsStore.shared.load(assetID: asset.localIdentifier)
            let service = SystemPhotoLibraryService()
            var detail: PhotoDetails?
            for _ in 0..<3 {
                let began = CACurrentMediaTime()
                let loaded: PhotoDetails = try await withCheckedThrowingContinuation { c in
                    _ = service.details(id: asset.localIdentifier) { c.resume(with: $0) }
                }
                readTimes.append(CACurrentMediaTime() - began)
                detail = loaded
                if stored?.rows.contains(where: { $0.title == "HDR处理" && $0.value == "系统延迟融合完成" }) == true {
                    XCTAssertEqual(loaded.captureParameters?.exifExposureBiasEV ?? 999, -0.9339108095202867, accuracy: 0.0001)
                    XCTAssertEqual(loaded.captureParameters?.requestedExposureBiasEV, 0)
                    XCTAssertTrue(PhotoInfoPresentation(details: loaded).parameterItems.contains(where: { $0.title == "EV" && $0.value == "EV -0.9" }))
                }
            }
            let current = try XCTUnwrap(detail)
            print("HDR24-DETAIL rows=\(current.rows.filter { $0.title.contains("曝光") || $0.title == "快门" || $0.title == "ISO" }) presentation=\(PhotoInfoPresentation(details: current).parameterItems) storedRows=\(stored?.rows ?? [])")
            print("HDR24-IDENTITY id=\(asset.localIdentifier) date=\(asset.creationDate?.description ?? "") resources=\(names) requestedEV=\(stored?.parameters?.requestedExposureBiasEV.map { String($0) } ?? "nil") storedEXIF=\(stored?.parameters?.exifExposureBiasEV.map { String($0) } ?? "nil")")
            if let date = asset.creationDate, date >= formatter.date(from: "2026-11-06T22:00:25+08:00")! {
                found += 1
            }
        }
        guard found > 0 else { throw XCTSkip("用户原样片已不在当前授权图库；不得把缺少样片算验证通过") }
        print("HDR24-FINAL-INFO-PERF samples=\(readTimes.count) maxSeconds=\(readTimes.max() ?? 0)；读取最终元数据，不是绘制帧率")
    }

    /// 回退12MP后按快门至最终HEIC交付的真实画幅耗时；接管回调，不保存系统相册。
    func testImmediateHDR12AllAspectCaptureTiming() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let runtime = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish() }
        model.setCaptureKind(.photo); model.setMode(.auto); model.photoFormat = .heif
        model.photoResolution = .standard; model.hdr = true; model.metering = .global; model.ev = 0
        let old = camera.onCaptureCompleted
        defer { camera.onCaptureCompleted = old }
        for ratio in FrameRatio.photoOptions {
            model.ratio = ratio
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<400 { if camera.ready && !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(250))
            var times = [Double]()
            for _ in 0..<2 {
                var captured: CapturedPhoto?
                let done = expectation(description: "即时HDR各画幅成片")
                camera.onCaptureCompleted = { captured = $0; done.fulfill() }
                let began = CACurrentMediaTime()
                camera.capture(flashMode: .off, options: PhotoOptions(format: .heif, hdr: true))
                await fulfillment(of: [done], timeout: 30)
                times.append(CACurrentMediaTime() - began)
                let photo = try XCTUnwrap(captured, camera.message ?? "成片失败")
                let resource = try XCTUnwrap(photo.resources.first)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
                HDRImageAssertions.assertHDR(source, "12MP回退各画幅")
                let image = try XCTUnwrap(CIImage(data: resource.data, options: [.applyOrientationProperty: true]))
                XCTAssertEqual(max(image.extent.width, image.extent.height) / min(image.extent.width, image.extent.height), ratio.landscapeRatio, accuracy: 0.002)
                XCTAssertLessThanOrEqual(image.extent.width * image.extent.height, 16_000_000)
                XCTAssertTrue(resource.filename.hasPrefix("luma-"))
                let config = await withCheckedContinuation { c in camera.photoOutputConfigurationForTesting { c.resume(returning: $0) } }
                XCTAssertEqual(config["deferredPhotoDelivery"], "false")
                let tasks = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning: [$0,$1,$2,$3]) } }
                XCTAssertTrue(tasks.allSatisfy { $0 == 0 }); XCTAssertNil(camera.message)
            }
            print("HDR12-ASPECT-TIMING ratio=\(ratio.rawValue) samples=2 seconds=\(times) mean=\(times.reduce(0,+)/Double(times.count))；按快门到最终HEIC交付，不含系统相册提交")
        }
    }

    func testHDRPreviewVersusFinalMetrics() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.style = .original }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.style = .original
        model.ratio = .standard
        model.hdr = true
        for _ in 0..<250 { if camera.hdrPreviewActive && camera.ready { break }; try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(500))
        // 同次拍摄比较系统源文件与输出，不把存在增益图等同于亮度正确。
        // 本轮只核对普通HEIF，避免混入RAW显影/Pro影调路径。
        let cases: [(PhotoFileFormat, PhotoTone)] = [(.heif, .natural)]
        let oldQuality = camera.onHEIFHDRQualityForTesting
        var quality: Int?
        camera.onHEIFHDRQualityForTesting = { quality = $0 }
        defer { camera.onHEIFHDRQualityForTesting = oldQuality }
        let oldSource = camera.onProcessedHEIFHDRForTesting
        var systemData: Data?
        camera.onProcessedHEIFHDRForTesting = { systemData = $0 }
        defer { camera.onProcessedHEIFHDRForTesting = oldSource }
        var captureTimes: [Double] = []
        for (format, tone) in cases + cases.reversed() {
        model.photoFormat = format; model.tone = tone
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        print("HDR-COMPARISON format=\(format.rawValue) tone=\(tone.rawValue)")
        systemData = nil
        let exposureState = await withCheckedContinuation { c in camera.heifExposureSnapshotForTesting { c.resume(returning: $0) } }
        print("HDR-EXPOSURE modelEV=\(model.ev) \(exposureState)")
        XCTAssertEqual(model.ev, 0)
        let preview = try XCTUnwrap(camera.preview)
        var captured: CapturedPhoto?
        let done = expectation(description: "capture")
        let old = camera.onCaptureCompleted
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        defer { camera.onCaptureCompleted = old }
        let captureStart = CACurrentMediaTime()
        var thumbnailSeconds = -1.0
        let oldThumbnail = camera.onCaptureThumbnailReady
        camera.onCaptureThumbnailReady = { _ in if thumbnailSeconds < 0 { thumbnailSeconds = CACurrentMediaTime() - captureStart } }
        defer { camera.onCaptureThumbnailReady = oldThumbnail }
        camera.capture(flashMode: .off, options: model.photoOptions)
        await fulfillment(of: [done], timeout: 45)
        print("HDR-METRICS captureSeconds=\(CACurrentMediaTime()-captureStart) thumbnailSeconds=\(thumbnailSeconds)")
        captureTimes.append(CACurrentMediaTime() - captureStart)
        let photo = try XCTUnwrap(captured, camera.message ?? "capture failed")
        XCTAssertEqual(quality, AVCapturePhotoOutput.QualityPrioritization.quality.rawValue)
        print("HDR-QUALITY actual=\(quality ?? -1)")
        XCTAssertNotNil(photo.resources.first?.filename.range(of: "^luma-[0-9]{8}-[0-9]{6}-[0-9]{3}\\.heic$", options: .regularExpression))
        print("HDR-FILENAME \(photo.resources.first?.filename ?? "")")
        let data = try XCTUnwrap(photo.resources.first?.data)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        HDRImageAssertions.assertHDR(src, "普通HEIF系统资源")
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap))
        let sdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let pixels = sdr.width * sdr.height
        XCTAssertGreaterThanOrEqual(pixels, 11_000_000)
        XCTAssertLessThanOrEqual(pixels, 16_000_000, "标准HDR档已回到即时12MP，不能再交付24MP")
        let configuration = await withCheckedContinuation { c in camera.photoOutputConfigurationForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(configuration["deferredPhotoDelivery"], "false")
        print("HDR12-ROLLBACK actual=\(sdr.width)x\(sdr.height) deferred=\(configuration["deferredPhotoDelivery"] ?? "unknown")")
        let hdr = try XCTUnwrap(CIImage(data: data, options: [.expandToHDR: true]))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func stat(_ image: CIImage, _ filter: String) -> [Float] {
            let f = CIFilter(name: filter, parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])!.outputImage!
            var p = [Float](repeating: 0, count: 4)
            p.withUnsafeMutableBytes { ctx.render(f, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x:0,y:0,width:1,height:1), format: .RGBAf, colorSpace: cs) }
            return p
        }
        let nativeData = try XCTUnwrap(systemData, "必须取得同次拍摄的系统原片")
        let nativeHDR = try XCTUnwrap(CIImage(data: nativeData, options: [.applyOrientationProperty: true, .expandToHDR: true]))
        let nativeSDR = try XCTUnwrap(CIImage(data: nativeData, options: [.applyOrientationProperty: true, .expandToHDR: false]))
        XCTAssertEqual(data, nativeData, "无调色4:3普通HEIF HDR应逐字节保留系统成片")
        print("HDR-NATIVE hdrMean=\(stat(nativeHDR, "CIAreaAverage")) sdrMean=\(stat(nativeSDR, "CIAreaAverage")) headroom=\(nativeHDR.contentHeadroom)")
        // 同一真实系统源图检查全部画幅，不能只用点光源最大值判断裁切HDR是否正常。
        for ratio in FrameRatio.photoOptions {
            let look = CaptureLook(ratio: ratio, landscape: nativeHDR.extent.width > nativeHDR.extent.height)
            let began = CACurrentMediaTime()
            let result = try PhotoEncoder.encode(source: nativeHDR, raw: nil, look: look,
                options: PhotoOptions(format: .heif, hdr: true), context: ctx, systemHEIF: nativeData)
            let bytes = try XCTUnwrap(result.resources.first?.data)
            let output = try XCTUnwrap(CIImage(data: bytes, options: [.applyOrientationProperty: true, .expandToHDR: true]))
            let reference = ratio.crop(nativeHDR, landscape: look.landscape)
            let ref = stat(reference, "CIAreaAverage"), actual = stat(output, "CIAreaAverage")
            for c in 0..<3 {
                XCTAssertEqual(actual[c], ref[c], accuracy: max(0.01, abs(ref[c]) * 0.02), "\(ratio) 裁切不能改变曝光")
            }
            XCTAssertEqual(output.extent.width / output.extent.height,
                reference.extent.width / reference.extent.height, accuracy: 0.002)
            print("HDR-NATIVE-RATIO ratio=\(ratio) seconds=\(CACurrentMediaTime()-began) reference=\(ref) actual=\(actual)")
        }
        let nativeShot = XCTAttachment(data: nativeData, uniformTypeIdentifier: "public.heic")
        nativeShot.name = "system-original-\(captureTimes.count).heic"; nativeShot.lifetime = .keepAlways; add(nativeShot)
        let sdrAvg = stat(CIImage(cgImage: sdr), "CIAreaAverage")
        let sdrMax = stat(CIImage(cgImage: sdr), "CIAreaMaximum")
        let hdrAvg = stat(hdr, "CIAreaAverage")
        let hdrMax = stat(hdr, "CIAreaMaximum")
        let pCG = try XCTUnwrap(preview.cgImage)
        let previewCI = CIImage(cgImage: pCG)
        let previewAvg = stat(previewCI, "CIAreaAverage")
        let previewMax = stat(previewCI, "CIAreaMaximum")
        print("HDR-METRICS headroom=\(hdr.contentHeadroom) depth=\((CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any])?[kCGImagePropertyDepth] ?? "nil")")
        print("HDR-METRICS sdr avg=\(sdrAvg[0...2]) max=\(sdrMax[0...2])")
        print("HDR-METRICS hdr avg=\(hdrAvg[0...2]) max=\(hdrMax[0...2])")
        print("HDR-METRICS preview avg=\(previewAvg[0...2]) max=\(previewMax[0...2])")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.heic")
        attachment.name = "captured-\(format.rawValue)-\(tone.rawValue)-\(captureTimes.count).heic"; attachment.lifetime = XCTAttachment.Lifetime.keepAlways; add(attachment)
        let png = UIImage(cgImage: pCG).pngData()!
        let pa = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        pa.name = "preview.png"; pa.lifetime = XCTAttachment.Lifetime.keepAlways; add(pa)
        XCTAssertGreaterThan(hdrMax[0...2].max() ?? 0, 1.0, "HDR对照必须保留超出SDR的高光")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertGreaterThan((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertGreaterThan((exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue ?? 0, 0)
        let tasks = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning: [$0, $1, $2, $3]) } }
        XCTAssertTrue(tasks.allSatisfy { $0 == 0 }); XCTAssertNil(camera.message)
        }
        captureTimes.sort()
        print("HDR-CAPTURE-SUMMARY count=\(captureTimes.count) medianSeconds=\(captureTimes[captureTimes.count/2]) maxSeconds=\(captureTimes.last ?? 0)")
    }
}
