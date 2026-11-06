import XCTest
import AVFoundation
import UIKit
import ImageIO
@testable import LumaCamera

/// 人像实时取景与实际文件定向回归；替换回调，诊断照片不交给相册保存。
final class PortraitOptimizationPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testFrontPortraitContinuousAdjustmentAndCapture() async throws {
        try await runPortrait(position: .front)
    }

    @MainActor func testRearPortraitContinuousAdjustmentAndCapture() async throws {
        try await runPortrait(position: .back)
    }

    @MainActor func testManualMainHEIFPortraitCanBeEnabledAndCaptured() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldCallback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCallback
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.photoResolution = .standard; model.hdr = false
        model.setMode(.manual); model.setCameraActive(true)
        try await wait(20) { camera.ready && camera.preview != nil }
        if model.currentPosition != .back { model.flipCamera() }
        try await wait(20) { camera.ready && model.currentPosition == .back }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        model.selectFocalLength(main)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait(15) { camera.ready && camera.selectedLens == main.id }
        print("PORTRAIT-MANUAL-ENTRY before portraitSupport=\(camera.supportsPortraitCapture) lens=\(String(describing: camera.photoLensCapabilities[camera.selectedLens])) format=\(model.photoFormat) mode=\(model.mode)")
        model.togglePortraitMode()
        XCTAssertTrue(model.portraitModeEnabled, camera.message ?? "M 挡 HEIF 人像入口不可用")
        guard model.portraitModeEnabled else { throw NSError(domain: "PortraitManualEntryTest", code: 1) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.mode, .manual)
        XCTAssertEqual(model.photoFormat, .heif)
        XCTAssertFalse(model.livePhotoEnabled)
        XCTAssertTrue(model.canSelectFocalLength(main))
        XCTAssertNil(camera.message)
        var photo: CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0 }
        let saves = model.library.pendingSaveCount
        let started = CACurrentMediaTime()
        camera.capture(flashMode: .off, options: model.photoOptions)
        try await wait(30) { photo != nil || camera.message != nil }
        let result = try XCTUnwrap(photo, camera.message ?? "M 挡人像未出片")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(result.resources.first?.data) as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNotNil(properties[kCGImagePropertyExifDictionary as String])
        XCTAssertTrue(model.portraitModeEnabled, "缺少原生深度管线不应在快门后关闭可用的分割人像")
        XCTAssertEqual(model.mode, .manual)
        XCTAssertEqual(model.library.pendingSaveCount, saves)
        print("PORTRAIT-MANUAL-ENTRY captureSeconds=\(CACurrentMediaTime() - started) rows=\(result.diagnostics?.rows ?? [])")
        var repeatedTimes: [Double] = []
        for index in 0..<3 {
            model.togglePortraitMode()
            try await Task.sleep(for: .milliseconds(30))
            model.togglePortraitMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertTrue(model.portraitModeEnabled)
            if index == 2 {
                camera.setPreviewExposureAssist(false)
                model.manualExposure = true
                model.iso = 200
                model.shutter = log2(1.0 / 125)
                model.applyExposure()
                // setExposureModeCustom 异步生效；队列屏障不代表传感器已应用。
                // 先等真实读数，再验证本次人像文件，避免把旧预览曝光当作已设定参数。
                try await wait(8) {
                    guard let readings = camera.readings?.validated else { return false }
                    return abs(readings.iso - 200) < 2 && abs(readings.seconds - 1.0 / 125) < 0.0002
                }
            }
            try await wait(15) { camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            photo = nil
            let start = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: model.photoOptions)
            try await wait(30) { photo != nil || camera.message != nil }
            let savedPhoto = try XCTUnwrap(photo, camera.message ?? "重复开启后人像未出片")
            repeatedTimes.append(CACurrentMediaTime() - start)
            XCTAssertTrue(model.portraitModeEnabled)
            XCTAssertEqual(model.mode, .manual)
            XCTAssertEqual(model.photoFormat, .heif)
            XCTAssertFalse(model.livePhotoEnabled)
            if index == 2 {
                let file = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(savedPhoto.resources.first?.data) as CFData, nil))
                let tags = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
                let exif = try XCTUnwrap(tags[kCGImagePropertyExifDictionary as String] as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double), 1.0 / 125, accuracy: 0.0002)
                XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue), 200, accuracy: 2)
            }
        }
        for _ in 0..<3 {
            model.setMode(.auto)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait(15) { camera.ready }
            try await Task.sleep(for: .milliseconds(100))
            model.setMode(.manual)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait(15) { camera.ready }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(model.portraitModeEnabled)
            XCTAssertNil(camera.message)
        }
        XCTAssertEqual(model.library.pendingSaveCount, saves)
        print("PORTRAIT-MANUAL-RECOVERY repeatedCaptures=\(repeatedTimes) toggleCycles=3 modeRoundTrips=3 manualISO=200 manualExposure=1/125 live=false")
    }

    @MainActor func testRearPortraitSameFrameReference() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldCallback = camera.onCaptureCompleted
        let oldNativeCallback = camera.onOriginalProcessedPhotoForTesting
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCallback
            camera.onOriginalProcessedPhotoForTesting = oldNativeCallback
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
            audit.finish()
        }
        model.setCaptureKind(.photo); model.setMode(.auto)
        model.photoFormat = .jpeg; model.photoResolution = .standard
        model.ratio = .standard; model.hdr = false; model.style = .original
        model.setCameraActive(true)
        try await wait(20) { camera.ready && camera.preview != nil }
        if model.currentPosition != .back { model.flipCamera() }
        try await wait(20) { camera.ready && model.currentPosition == .back }
        if !model.portraitModeEnabled { model.togglePortraitMode() }
        model.portraitBlurStrength = 1
        try await Task.sleep(for: .seconds(1))
        try await wait(15) { camera.ready && !camera.shutterBusy }
        var native: Data?, result: CapturedPhoto?
        camera.onOriginalProcessedPhotoForTesting = { native = $0 }
        camera.onCaptureCompleted = { result = $0 }
        let saves = model.library.pendingSaveCount
        camera.capture(flashMode: .off, options: model.photoOptions)
        try await wait(30) { result != nil || camera.message != nil }
        let photo = try XCTUnwrap(result, camera.message ?? "无临时成片")
        let data = try XCTUnwrap(photo.resources.first?.data)
        let raw = try XCTUnwrap(native)
        // 原生 JPEG 可能依赖 EXIF 旋转，最终编码已归一化；曝光与真实焦距必须保持同一张的来源。
        let originalTags = try fileTags(raw)
        let processedTags = try fileTags(data)
        let originalEXIF = try XCTUnwrap(originalTags[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let processedEXIF = try XCTUnwrap(processedTags[kCGImagePropertyExifDictionary as String] as? [String: Any])
        for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm] {
            let original = try XCTUnwrap(originalEXIF[key as String] as? NSNumber)
            let processed = try XCTUnwrap(processedEXIF[key as String] as? NSNumber)
            XCTAssertEqual(original.doubleValue, processed.doubleValue, accuracy: 0.00001)
        }
        XCTAssertEqual((originalEXIF[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first,
                       (processedEXIF[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first)
        XCTAssertNotNil(processedEXIF[kCGImagePropertyExifISOSpeedRatings as String])
        XCTAssertEqual((processedTags[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
        try await assertCaptureTasksCleared(camera)
        print("PORTRAIT-SAME-FRAME-METADATA iso=\(String(describing: processedEXIF[kCGImagePropertyExifISOSpeedRatings as String])) exposure=\(String(describing: processedEXIF[kCGImagePropertyExifExposureTime as String])) orientation=1 metadataPreserved=true")
        for (name, bytes) in [("Portrait-SameFrame-Native", raw), ("Portrait-SameFrame-Processed", data)] {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.jpeg")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        print("PORTRAIT-SAME-FRAME nativeBytes=\(raw.count) processedBytes=\(data.count) rows=\(photo.diagnostics?.rows ?? [])")
        XCTAssertEqual(model.library.pendingSaveCount, saves)
    }

    @MainActor private func runPortrait(position: AVCaptureDevice.Position) async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let oldCallback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCallback
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
            audit.finish()
        }
        model.setCaptureKind(.photo)
        model.setMode(.auto)
        model.photoFormat = .jpeg
        model.photoResolution = .standard
        model.ratio = .standard
        model.hdr = false
        model.style = .original
        model.setCameraActive(true)
        try await wait(20) { camera.ready && camera.preview != nil }
        if model.currentPosition != position { model.flipCamera() }
        try await wait(20) { camera.ready && model.currentPosition == position && camera.preview != nil }
        if position == .back, let main = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }) {
            model.selectFocalLength(main)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait(15) { camera.ready && !camera.shutterBusy }
        }
        if !model.portraitModeEnabled { model.togglePortraitMode() }
        try await wait(15) { camera.ready && model.portraitModeEnabled }
        model.portraitDepthSliderVisible = true
        camera.resetPreviewPublicationTimesForTesting()
        let baseline = camera.portraitPreviewMetricsForTesting()
        let start = CACurrentMediaTime()
        var missingPreviews = 0
        for index in 0..<180 {
            model.portraitBlurStrength = Double(index % 60) / 59
            if camera.preview == nil { missingPreviews += 1 }
            try await Task.sleep(for: .milliseconds(33))
        }
        // 收起滑块后继续取景，不能因为隐藏调节控件而撤掉当前虚化。
        model.portraitDepthSliderVisible = false
        model.portraitBlurStrength = 1
        try await Task.sleep(for: .seconds(1))
        let metrics = camera.portraitPreviewMetricsForTesting()
        let publications = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= start }
        let gaps = zip(publications, publications.dropFirst()).map { $1 - $0 }.sorted()
        print("PORTRAIT-OPT position=\(position.rawValue) sliderUpdates=180 missingPreviews=\(missingPreviews) publications=\(publications.count) publicationGapP95=\(gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]) maxGap=\(gaps.last ?? 0) segmentationSamples=\(metrics.samples) medianMS=\(metrics.medianMilliseconds) p95MS=\(metrics.p95Milliseconds) maxMS=\(metrics.maximumMilliseconds) requestsCreated=\(metrics.requestCreations - baseline.requestCreations) acceptedMasks=\(metrics.acceptedMasks - baseline.acceptedMasks) failures=\(metrics.failures - baseline.failures)")
        XCTAssertEqual(missingPreviews, 0)
        XCTAssertGreaterThan(publications.count, 40)
        XCTAssertGreaterThan(metrics.samples, 10)
        XCTAssertLessThanOrEqual(metrics.requestCreations - baseline.requestCreations, 3,
            "连续调强度不得逐次重建分割请求")
        XCTAssertGreaterThan(metrics.acceptedMasks - baseline.acceptedMasks, 0,
            "需真实人物入镜才能验收人物分割，不能把空背景记为通过")
        let pending = model.library.pendingSaveCount
        for strength in [0.0, 1.0] {
            model.portraitBlurStrength = strength
            try await wait(15) { camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 }
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0 }
            let started = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: model.photoOptions)
            try await wait(30) { result != nil || camera.message != nil }
            let photo = try XCTUnwrap(result, camera.message ?? "人像无出片")
            let data = try XCTUnwrap(photo.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertGreaterThan((properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0) * (properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0), 10_000_000)
            let attachment = XCTAttachment(image: photo.preview)
            attachment.name = "Portrait-\(position.rawValue)-strength-\(Int(strength * 100))"
            attachment.lifetime = .keepAlways
            add(attachment)
            try await assertCaptureTasksCleared(camera)
            print("PORTRAIT-OPT-CAPTURE position=\(position.rawValue) strength=\(strength) seconds=\(CACurrentMediaTime() - started) bytes=\(data.count) rows=\(photo.diagnostics?.rows ?? [])")
        }
        XCTAssertEqual(model.library.pendingSaveCount, pending)
        // 关闭、快速开关和离开/返回都应释放旧蒙版并继续出新帧。
        for _ in 0..<3 {
            model.togglePortraitMode()
            try await Task.sleep(for: .milliseconds(20))
            model.togglePortraitMode()
            try await Task.sleep(for: .milliseconds(100))
        }
        model.setCameraActive(false)
        try await Task.sleep(for: .milliseconds(300))
        let stopped = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(stopped)
        let previous = camera.preview, resumedAt = CACurrentMediaTime()
        model.setCameraActive(true)
        try await wait(20) {
            camera.ready && camera.preview != nil && camera.preview !== previous
                && camera.previewFrameTimeForTesting > resumedAt
        }
        try await assertCaptureTasksCleared(camera)
        XCTAssertNil(camera.message)
    }

    /// 拍后检查全部收尾状态，不能只因收到照片就忽略硬件 token 或顺序交付缓冲残留。
    @MainActor private func assertCaptureTasksCleared(_ camera: CameraEngine) async throws {
        try await wait(5) { camera.pendingPhotoCount == 0 && !camera.capturing && !camera.shutterBusy }
        let state = await withCheckedContinuation { c in
            camera.photoTaskStateForTesting { c.resume(returning: ($0, $1, $2, $3)) }
        }
        XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, 0)
        XCTAssertEqual(state.2, 0); XCTAssertEqual(state.3, 0)
    }

    /// 直接解码成片资源，不以应用详情文字替代系统照片可见的 EXIF/TIFF。
    private func fileTags(_ data: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    @MainActor private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), "人像测试等待条件超时")
        if !condition() { throw NSError(domain: "PortraitOptimizationTest", code: 1) }
    }
    #endif
}
