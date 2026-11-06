import XCTest
import UIKit
import ImageIO
import CoreImage
@testable import LumaCamera

@MainActor
final class HDRCaptureDiagnosticsTests: XCTestCase {
    func testHDRPreviewVersusFinalMetrics() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.style = .original }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.style = .original
        model.hdr = true
        for _ in 0..<250 { if camera.hdrPreviewActive && camera.ready { break }; try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(500))
        // 同一现场检查普通HEIF与Pro各影调，不把存在增益图等同于亮度正确。
        let cases: [(PhotoFileFormat, PhotoTone)] = [(.heif, .natural), (.heifPro, .natural), (.heifPro, .contrast), (.heifPro, .cinematic), (.heifPro, .bright)]
        var captureTimes: [Double] = []
        for (format, tone) in cases + cases.reversed() {
        model.photoFormat = format; model.tone = tone
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        print("HDR-COMPARISON format=\(format.rawValue) tone=\(tone.rawValue)")
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
        let data = try XCTUnwrap(photo.resources.first?.data)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        HDRImageAssertions.assertNativeISOGainMap(src)
        let sdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let hdr = try XCTUnwrap(CIImage(data: data, options: [.expandToHDR: true]))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func stat(_ image: CIImage, _ filter: String) -> [Float] {
            let f = CIFilter(name: filter, parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])!.outputImage!
            var p = [Float](repeating: 0, count: 4)
            p.withUnsafeMutableBytes { ctx.render(f, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x:0,y:0,width:1,height:1), format: .RGBAf, colorSpace: cs) }
            return p
        }
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
