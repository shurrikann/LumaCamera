import XCTest
import CoreImage
import ImageIO
import UIKit
@testable import LumaCamera

final class ProToneCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testFixedScenePhotoFormatMatrixWithoutSaving() async throws {
        guard let scene = ProcessInfo.processInfo.environment["LUMA_QUALITY_SCENE"], ["indoor", "backlit"].contains(scene) else {
            throw XCTSkip("Requires coordinated fixed scene")
        }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true); model.setMode(.auto)
        model.photoResolution = .standard; model.style = .original; model.metering = .system; model.ev = 0; model.border = false; model.ratio = .standard
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
        let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1) < 0.001 })
        camera.selectLens(lens)
        let matrix: [(String, PhotoFileFormat, Bool, Bool, PhotoTone)] = [
            ("heif", .heif, false, false, .natural), ("heif-hdr", .heif, true, false, .natural),
            ("pro", .heifPro, false, false, .natural), ("pro-hdr", .heifPro, true, false, .natural),
            ("pro-adaptive", .heifPro, false, true, .natural), ("pro-hdr-adaptive", .heifPro, true, true, .natural),
            ("pro-cinematic-hdr-adaptive", .heifPro, true, true, .cinematic)
        ]
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var records: [String] = [], times: [Double] = []
        for (index, item) in (matrix + matrix.reversed()).enumerated() {
            model.hdr = false; model.adaptiveHighDynamic = false; model.photoFormat = item.1
            model.tone = item.4; model.adaptiveHighDynamic = item.3; model.hdr = item.2
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 { if camera.ready && camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(350))
            let options = model.photoOptions
            XCTAssertEqual(options.hdr, item.2); XCTAssertEqual(options.adaptiveHighDynamic, item.3)
            let done = expectation(description: "fixed scene \(scene) \(item.0)")
            var captured: CapturedPhoto?
            camera.onCaptureCompleted = { captured = $0; done.fulfill() }
            let began = CACurrentMediaTime(); camera.capture(flashMode: .off, options: options)
            await fulfillment(of: [done], timeout: 40)
            let photo = try XCTUnwrap(captured, camera.message ?? "No fixed scene photo")
            times.append(CACurrentMediaTime()-began)
            let resource = try XCTUnwrap(photo.resources.first { !$0.alternate && !$0.pairedVideo })
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let image = try XCTUnwrap(CIImage(data: resource.data, options: [.expandToHDR: false, .applyOrientationProperty: true]))
            let reduced = image.transformed(by: CGAffineTransform(scaleX: 64/image.extent.width, y: 64/image.extent.height))
            var rgba = [Float](repeating: 0, count: 64*64*4)
            context.render(reduced, toBitmap: &rgba, rowBytes: 64*16, bounds: CGRect(x:0,y:0,width:64,height:64), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            let luma = (0..<4096).map { max(0, Double(rgba[$0*4]*0.2126+rgba[$0*4+1]*0.7152+rgba[$0*4+2]*0.0722)) }.sorted()
            let record = "scene=\(scene) pass=\(index/matrix.count) kind=\(item.0) seconds=\(times.last ?? 0) p10=\(luma[409]) p50=\(luma[2048]) p90=\(luma[3686]) gainMap=\(HDRImageAssertions.hasGainMap(source)) shutter=\(exif?[kCGImagePropertyExifExposureTime as String] ?? "missing") ISO=\(exif?[kCGImagePropertyExifISOSpeedRatings as String] ?? "missing") orientation=\(props[kCGImagePropertyOrientation as String] ?? "missing")"
            records.append(record); print("FIXED-QUALITY \(record)")
            XCTAssertNotNil(exif?[kCGImagePropertyExifExposureTime as String]); XCTAssertNotNil(exif?[kCGImagePropertyExifISOSpeedRatings as String])
            let orientation = try XCTUnwrap((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue)
            XCTAssertTrue((1...8).contains(orientation))
            if index < matrix.count {
                let attachment = XCTAttachment(data: resource.data, uniformTypeIdentifier: "public.heic")
                attachment.name = "Quality-\(scene)-\(item.0).heic"; attachment.lifetime = .keepAlways; add(attachment)
                if item.0 == "pro-adaptive", let raw = photo.resources.first(where: { $0.filename.lowercased().hasSuffix(".dng") }) {
                    let baseline = XCTAttachment(data: raw.data, uniformTypeIdentifier: "com.adobe.raw-image")
                    baseline.name = "Quality-\(scene)-baseline.dng"; baseline.lifetime = .keepAlways; add(baseline)
                }
            }
        }
        let attachment = XCTAttachment(string: records.joined(separator: "\n")); attachment.name = "Quality-\(scene)-metrics"
        attachment.lifetime = .keepAlways; add(attachment)
        print("FIXED-QUALITY-SUMMARY scene=\(scene) samples=\(times.count) meanSeconds=\(times.reduce(0,+)/Double(times.count)) PhotosWrites=0; brightness statistics are SDR linear luminance, not a quality score")
    }
    @MainActor func testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let format = model.photoFormat, hdr = model.hdr, tone = model.tone, style = model.style, mode = model.mode
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = callback
            model.hdr = false; model.photoFormat = format; model.tone = tone; model.style = style; model.setMode(mode); model.hdr = hdr
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.001 })
        camera.selectLens(lens)
        for _ in 0..<300 { if camera.ready && camera.availablePhotoFormats.contains(.heifPro) { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.photoFormat = .heifPro; model.hdr = true; model.style = .original
        var samples: [Double] = []
        // 两轮正反选择，避免只验证单次诊断 toneID 而遗漏重复拍摄后的状态残留。
        for item in Array(PhotoTone.allCases) + PhotoTone.allCases.reversed() {
            model.tone = item
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let done = expectation(description: "HDR HEIF Pro " + item.rawValue)
            var captured: CapturedPhoto?
            camera.onCaptureCompleted = { captured = $0; done.fulfill() }
            let began = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: model.photoOptions)
            await fulfillment(of: [done], timeout: 35)
            let photo = try XCTUnwrap(captured, camera.message ?? "capture failed")
            samples.append(CACurrentMediaTime() - began)
            XCTAssertEqual(photo.diagnostics?.parameters?.toneID, item.rawValue)
            XCTAssertEqual(photo.preview.cgImage?.bitsPerComponent, 16)
            let resource = try XCTUnwrap(photo.resources.first)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            HDRImageAssertions.assertHDR(source, "PRO-TONE HDR")
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let profile = (properties[kCGImagePropertyProfileName as String] as? String)
                ?? (decoded.colorSpace?.name as String? ?? "")
            if HDRImageAssertions.hasGainMap(source) {
                HDRImageAssertions.assertNativeISOGainMap(source)
            } else {
                XCTAssertTrue(profile.localizedCaseInsensitiveContains("PQ"), "HDR 单图回退应保留 PQ 标记")
            }
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertGreaterThan(try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue), 0)
            XCTAssertGreaterThan(try XCTUnwrap((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue), 0)
            XCTAssertGreaterThan(try XCTUnwrap((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue), 0)
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
            let tasks = await withCheckedContinuation { c in
                camera.photoTaskStateForTesting { c.resume(returning: ($0, $1, $2, $3)) }
            }
            XCTAssertEqual(tasks.0, 0); XCTAssertEqual(tasks.1, 0)
            XCTAssertEqual(tasks.2, 0); XCTAssertEqual(tasks.3, 0)
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertNil(camera.message)
            print("PRO-TONE-HDR tone=\(item.rawValue) seconds=\(samples.last ?? 0) profile=\(profile) gainMap=\(HDRImageAssertions.hasGainMap(source)) dimensions=\(decoded.width)x\(decoded.height) EXIF-preserved=true tasks=0")
        }
        // 快速改影调只提交最终选择；退出/返回之后仍必须交付新帧而非旧预览。
        for index in 0..<40 { model.tone = PhotoTone.allCases[index % PhotoTone.allCases.count] }
        model.tone = .natural
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let stopped = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(stopped)
        let previous = camera.preview, resumedAt = CACurrentMediaTime()
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready, camera.preview !== previous, camera.previewFrameTimeForTesting > resumedAt { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready)
        XCTAssertTrue(camera.preview !== previous)
        XCTAssertGreaterThan(camera.previewFrameTimeForTesting, resumedAt)
        XCTAssertEqual(model.photoOptions.format, .heifPro)
        XCTAssertTrue(model.photoOptions.hdr)
        let sorted = samples.sorted()
        print("PRO-TONE-HDR-SUMMARY samples=\(samples.count) median=\(sorted[sorted.count / 2]) max=\(sorted.last ?? 0) rapidToneChanges=40 resumed=true")
    }

    @MainActor func testSameRAWAcrossToneHDRAndAdaptiveMatrixWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let camera = model.camera
        let previousCallback = camera.onCaptureCompleted
        defer {
            camera.onCaptureCompleted = previousCallback
            model.setCameraActive(false)
        }
        model.photoFormat = .raw
        for _ in 0..<200 {
            if camera.ready, camera.availablePhotoFormats.contains(.raw) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(camera.availablePhotoFormats.contains(.raw))
        let captured = expectation(description: "同一张对照用 RAW")
        var photo: CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0; captured.fulfill() }
        camera.capture(flashMode: .off, options: model.photoOptions)
        await fulfillment(of: [captured], timeout: 35)
        let raw = try XCTUnwrap(photo?.resources.first?.data, camera.message ?? "RAW capture failed")

        let context = CIContext(options: [.cacheIntermediates: false])
        var times: [Double] = []
        for hdr in [false, true] {
            for adaptive in [false, true] {
                let filter = try XCTUnwrap(CIRAWFilter(imageData: raw, identifierHint: nil))
                AdaptiveRAWDeveloper.configure(filter, adaptive: adaptive, hdr: hdr, adjustments: FilterAdjustments())
                filter.scaleFactor = Float(min(1, 1200 / max(filter.nativeSize.width, filter.nativeSize.height)))
                let source = try XCTUnwrap(filter.outputImage)
                var referenceExtent: CGRect?
                for tone in PhotoTone.allCases {
                    let start = CACurrentMediaTime()
                    let encoded = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(tone: tone),
                        options: PhotoOptions(format: .heifPro, hdr: hdr, adaptiveHighDynamic: adaptive), context: context)
                    let data = try XCTUnwrap(encoded.resources.first?.data)
                    let container = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let decoded = try XCTUnwrap(CIImage(data: data, options: [.expandToHDR: hdr]))
                    times.append(CACurrentMediaTime() - start)
                    XCTAssertFalse(decoded.extent.isEmpty)
                    if let referenceExtent { XCTAssertEqual(decoded.extent, referenceExtent) }
                    referenceExtent = decoded.extent
                    if !hdr { XCTAssertFalse(HDRImageAssertions.hasGainMap(container)) }
                    if adaptive {
                        XCTAssertEqual(encoded.resources.first(where: { $0.alternate })?.data, raw)
                        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any])
                        let recipe = try XCTUnwrap(RAWDevelopmentRecipe.read(properties)?.rawDevelopment)
                        XCTAssertEqual(recipe.tone, tone.rawValue)
                        XCTAssertEqual(recipe.hdr, hdr)
                    }
                    print("PRO-TONE-MATRIX hdr=\(hdr) adaptive=\(adaptive) tone=\(tone.rawValue) headroom=\(decoded.contentHeadroom) extent=\(decoded.extent.size)")
                }
            }
        }
        times.sort()
        print("PRO-TONE-MATRIX-TIMING n=\(times.count) median=\(times[times.count / 2]) max=\(times.last ?? 0)")
    }
    #endif
}
