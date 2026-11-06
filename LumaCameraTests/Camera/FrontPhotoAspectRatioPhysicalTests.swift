import SwiftUI
import XCTest
import ImageIO
import CoreImage
import Vision
@testable import LumaCamera

/// 真机核对 Center Stage 动态宽高比切换、连续点按和照片/视频路由隔离。
final class FrontPhotoAspectRatioPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRepeatedFrontPhotoAspectChangesKeepPreviewReady() async throws {
        try await exerciseFrontAspect(manualSmooth: false)
    }

    @MainActor func testManualHEIFSmoothFrontAspectChangesKeepPreviewReady() async throws {
        try await exerciseFrontAspect(manualSmooth: true)
    }

    @MainActor func testRealLandscapeToPortraitThenAspectFraming() async throws {
        try await exerciseFrontAspect(manualSmooth: true, physicalPose: true)
    }

    @MainActor private func exerciseFrontAspect(manualSmooth: Bool, physicalPose: Bool = false) async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldKind = model.captureKind, oldPosition = model.currentPosition, oldMode = model.mode
        let oldFormat = model.photoFormat, oldResolution = model.photoResolution, oldHDR = model.hdr
        let oldRatio = model.ratio, oldLive = model.livePhotoEnabled
        let oldSmooth = model.smoothPreview, oldManualExposure = model.manualExposure
        let oldISO = model.iso, oldShutter = model.shutter
        let oldLandscape = camera.frontPhotoLandscapeEnabled
        let oldCallback = camera.onCaptureCompleted
        let oldOriginalPhotoCallback = camera.onOriginalProcessedPhotoForTesting
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCallback
            camera.onOriginalProcessedPhotoForTesting = oldOriginalPhotoCallback
            if model.captureKind != .photo { model.setCaptureKind(.photo) }
            if model.currentPosition != oldPosition { model.flipCamera() }
            model.setMode(oldMode)
            model.smoothPreview = oldSmooth; model.manualExposure = oldManualExposure
            model.iso = oldISO; model.shutter = oldShutter; model.applyExposure()
            model.photoFormat = oldFormat; model.photoResolution = oldResolution; model.hdr = oldHDR
            model.ratio = oldRatio
            if oldLive && !model.livePhotoEnabled && model.livePhotoAvailable { model.toggleLivePhoto() }
            if oldLandscape && model.currentPosition == .front && camera.frontPhotoAspectRatioSwitchAvailable {
                camera.setFrontPhotoLandscapeEnabled(true)
            }
            if model.captureKind != oldKind { model.setCaptureKind(oldKind); model.setMode(oldMode) }
            model.flushCaptureSettings()
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.setCameraActive(true)
        for _ in 0..<800 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard camera.ready else {
            let state = await withCheckedContinuation { c in camera.sessionDetailsForTesting { c.resume(returning: $0) } }
            XCTFail("前置宽高比测试的相机没有就绪：denied=\(camera.denied)，message=\(camera.message ?? "无")，\(state)")
            return
        }
        model.setCaptureKind(.photo); model.setMode(manualSmooth ? .manual : .auto)
        model.photoFormat = manualSmooth ? .heif : .jpeg; model.photoResolution = .standard; model.hdr = false; model.ratio = .standard
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.burstModeEnabled { model.toggleBurstMode() }
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        model.smoothPreview = manualSmooth
        model.manualExposure = manualSmooth
        if manualSmooth { model.iso = 100; model.shutter = log2(1.0 / 120); model.applyExposure() }
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        if model.currentPosition != .front { model.flipCamera() }
        for _ in 0..<600 {
            if camera.ready && model.currentPosition == .front && camera.preview != nil
                && camera.frontPhotoAspectRatioSwitchAvailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard camera.frontPhotoAspectRatioSwitchAvailable else {
            throw XCTSkip("Active front format does not support both dynamic photo aspect ratios")
        }
        XCTAssertTrue(model.canToggleFrontPhotoAspectRatio)
        if physicalPose {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            defer { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            print("FRONT-POSE 请横持手机，等待观察到横屏后再竖持")
            var sawLandscape = false, sawPortrait = false
            for _ in 0..<1000 {
                if UIDevice.current.orientation.isLandscape {
                    model.updateFrontFramingForOrientation(isLandscape: true)
                    sawLandscape = true; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("FRONT-POSE observed-landscape=\(sawLandscape)，现在请竖持")
            for _ in 0..<1000 {
                if UIDevice.current.orientation == .portrait {
                    model.updateFrontFramingForOrientation(isLandscape: false)
                    sawPortrait = true; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard sawLandscape && sawPortrait else { throw XCTSkip("未完成真实横持→竖持姿态，不计该组合视觉验收") }
            try await Task.sleep(for: .milliseconds(400))
        }
        try await Task.sleep(for: .milliseconds(400))

        func attachVisibleView(_ name: String) {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) else { return }
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "front-visible-\(manualSmooth ? "manualHEIF" : "autoJPG")-\(name)"
            attachment.lifetime = .keepAlways; add(attachment)
        }

        var captures: [CapturedPhoto] = []
        var originalCaptureData: Data?
        camera.onCaptureCompleted = { if let photo = $0 { captures.append(photo) } }
        camera.onOriginalProcessedPhotoForTesting = { originalCaptureData = $0 }
        func captureInMemory() async throws -> CapturedPhoto {
            let before = captures.count
            originalCaptureData = nil
            camera.capture(flashMode: model.flashMode, options: model.photoOptions)
            for _ in 0..<600 {
                if captures.count > before && camera.pendingPhotoCount == 0 && originalCaptureData != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try XCTUnwrap(captures.last, "Front capture should complete without saving into Photos")
        }
        func dumpOriginalMetadata(_ data: Data?, label: String) {
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                print("FRONT-PHOTO-ASPECT original-\(label)=unavailable"); return
            }
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? -1
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? -1
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? -1
            let raw = CIImage(data: data)?.extent ?? .null
            let oriented = CIImage(data: data, options: [.applyOrientationProperty: true])?.extent ?? .null
            print("FRONT-PHOTO-ASPECT original-\(label)=pixels:\(width)x\(height) exif:\(orientation) raw:\(Int(raw.width))x\(Int(raw.height)) display:\(Int(oriented.width))x\(Int(oriented.height))")
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 800] as CFDictionary) {
                let attachment = XCTAttachment(image: UIImage(cgImage: cg))
                attachment.name = "front-original-\(label)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        func compareFraming(_ preview: UIImage?, _ final: UIImage, label: String) throws {
            // 在快门前一帧和成片中比较归一化人脸范围，不把相同输出宽高当成相同视野。
            let orientation: CGImagePropertyOrientation
            switch UIDevice.current.orientation {
            case .landscapeLeft: orientation = .left
            case .landscapeRight: orientation = .right
            case .portraitUpsideDown: orientation = .down
            default: orientation = .up
            }
            func face(_ image: UIImage?, orientation: CGImagePropertyOrientation) throws -> CGRect? {
                guard let cg = image?.cgImage else { return nil }
                let request = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
                return request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?.boundingBox
            }
            // 取景仍在固定布局中；成片已按协调器摆正，不能再对成片施加设备方向。
            guard let a = try face(preview, orientation: orientation), let b = try face(final, orientation: .up) else {
                print("FRONT-FRAMING \(label) no-face:未获得主体几何指标，仅检查图像与界面附件")
                return
            }
            print("FRONT-FRAMING \(label) preview=\(a) photo=\(b) width-delta=\(abs(a.width-b.width)) height-delta=\(abs(a.height-b.height))")
            XCTAssertLessThan(abs(a.width - b.width), 0.06, "预览与成片的主体宽度应一致；允许拍摄间主体小幅移动")
            XCTAssertLessThan(abs(a.height - b.height), 0.06, "预览与成片的主体高度应一致，不能被不同画幅压缩")
        }
        func dimensions(_ photo: CapturedPhoto) throws -> (Int, Int) {
            let resource = try XCTUnwrap(photo.resources.first(where: { !$0.alternate && !$0.pairedVideo }))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
            let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
            return (width, height)
        }
        // 复现横持自动广取景→竖持普通取景，再开关画幅的组合路径。
        for landscapeOrientation in [true, false, true, false] {
            model.updateFrontFramingForOrientation(isLandscape: landscapeOrientation)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(250))
        }
        if camera.frontPhotoLandscapeEnabled { model.toggleFrontPhotoAspectRatio() }
        for _ in 0..<200 where camera.frontPhotoLandscapeEnabled { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 {
            if let preview = camera.preview, preview.size.height > preview.size.width { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let portraitPreviewSize = try XCTUnwrap(camera.preview?.size)
        XCTAssertGreaterThan(portraitPreviewSize.height, portraitPreviewSize.width,
                             "Portrait selection should keep the preview upright")
        let portraitBefore = camera.preview
        let portraitPhoto = try await captureInMemory()
        try compareFraming(portraitBefore, portraitPhoto.preview, label: "portrait")
        attachVisibleView("portrait")
        let portraitDiagnostics = await withCheckedContinuation { c in camera.frontPhotoAspectDiagnosticsForTesting { c.resume(returning: $0) } }
        print("FRONT-PHOTO-ASPECT mode=\(manualSmooth ? "manualHEIFsmooth" : "autoJPG") portrait-pipeline \(portraitDiagnostics)")
        dumpOriginalMetadata(originalCaptureData, label: "portrait")
        let portraitAttachment = XCTAttachment(image: portraitPhoto.preview)
        portraitAttachment.name = "front-final-portrait"; portraitAttachment.lifetime = .keepAlways; add(portraitAttachment)
        if let preview = camera.preview {
            let attachment = XCTAttachment(image: preview)
            attachment.name = "front-preview-portrait"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let portraitDimensions = try dimensions(portraitPhoto)
        print("FRONT-PHOTO-ASPECT encoded-portrait-pixels=\(portraitDimensions.0)x\(portraitDimensions.1)")
        let portraitAngle = await withCheckedContinuation { c in camera.frontPhotoCaptureRotationForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(portraitDimensions.0 > portraitDimensions.1,
                       CaptureOrientation.frontPhotoLandscape(sensorLandscape: false, captureAngle: portraitAngle))
        XCTAssertGreaterThan(portraitDimensions.0 * portraitDimensions.1, 10_000_000)

        var durations: [Double] = []
        for index in 0..<8 {
            let expected = !camera.frontPhotoLandscapeEnabled
            let started = CACurrentMediaTime()
            model.toggleFrontPhotoAspectRatio()
            for _ in 0..<200 {
                if let preview = camera.preview {
                    XCTAssertEqual(preview.size.width > preview.size.height, camera.frontPhotoLandscapeEnabled,
                                   "显示框必须始终匹配当前帧的宽高方向")
                }
                if camera.frontPhotoLandscapeEnabled == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(camera.frontPhotoLandscapeEnabled, expected, "Aspect toggle \(index) must complete")
            XCTAssertTrue(camera.ready)
            XCTAssertNotNil(camera.preview)
            XCTAssertNil(model.focalTransitionImage, "Changing aspect must not start a lens-change freeze transition")
            durations.append(CACurrentMediaTime() - started)
        }
        // 快速请求随后回退：确认过期回调不会留下错误画幅或阻断后续预览。
        camera.resetPreviewPublicationTimesForTesting()
        for index in 0..<12 {
            camera.setFrontPhotoLandscapeEnabled(index.isMultiple(of: 2))
            try await Task.sleep(for: .milliseconds(15))
        }
        camera.setFrontPhotoLandscapeEnabled(false)
        for _ in 0..<300 {
            if !camera.frontPhotoLandscapeEnabled, (camera.preview?.size.height ?? 0) > (camera.preview?.size.width ?? 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(camera.frontPhotoLandscapeEnabled)
        try await Task.sleep(for: .milliseconds(500))
        let times = camera.previewPublicationTimesForTestingSnapshot
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        XCTAssertGreaterThan(times.count, 3, "快速切换后必须持续出帧")
        print("FRONT-PHOTO-ASPECT rapid-requests=12 recovery-frames=\(times.count) max-publication-gap=\(gaps.max() ?? 0); app frame publications, not display FPS")
        if !camera.frontPhotoLandscapeEnabled { model.toggleFrontPhotoAspectRatio() }
        for _ in 0..<200 where !camera.frontPhotoLandscapeEnabled { try await Task.sleep(for: .milliseconds(10)) }
        let requestedLandscape = model.effectiveCaptureLook.landscape
        let queuedLandscape = await withCheckedContinuation { c in
            camera.captureLookForTesting { c.resume(returning: $0.landscape) }
        }
        let appliedLandscape = await withCheckedContinuation { c in
            camera.frontPhotoLandscapeAppliedForTesting { c.resume(returning: $0) }
        }
        print("FRONT-PHOTO-ASPECT capture-input ui=\(camera.frontPhotoLandscapeEnabled) model=\(requestedLandscape) engine=\(queuedLandscape) applied=\(appliedLandscape)")
        let diagnostics = await withCheckedContinuation { c in
            camera.frontPhotoAspectDiagnosticsForTesting { c.resume(returning: $0) }
        }
        print("FRONT-PHOTO-ASPECT preview-pipeline \(diagnostics)")
        XCTAssertTrue(appliedLandscape, "A landscape shutter must only be accepted after the device confirms the ratio change")
        XCTAssertTrue(queuedLandscape, "The preview and capture look should converge to the confirmed landscape framing")
        for _ in 0..<100 {
            if let preview = camera.preview, preview.size.width > preview.size.height { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let previewSize = try XCTUnwrap(camera.preview?.size)
        XCTAssertGreaterThan(previewSize.width, previewSize.height, "The visible preview should follow the selected landscape framing")
        let pair = await withCheckedContinuation { c in camera.readNextPreviewPairForTesting { c.resume(returning: ($0, $1)) } }
        for (name, image) in [("raw", pair.0), ("processed", pair.1)] {
            let attachment = XCTAttachment(image: image); attachment.name = "engine-same-frame-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let landscapeBefore = camera.preview
        let landscapePhoto = try await captureInMemory()
        try compareFraming(landscapeBefore, landscapePhoto.preview, label: "landscape")
        attachVisibleView("landscape")
        dumpOriginalMetadata(originalCaptureData, label: "landscape")
        let finalAttachment = XCTAttachment(image: landscapePhoto.preview)
        finalAttachment.name = "front-final-landscape"; finalAttachment.lifetime = .keepAlways; add(finalAttachment)
        if let preview = camera.preview {
            let attachment = XCTAttachment(image: preview)
            attachment.name = "front-preview-landscape"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let landscapeDimensions = try dimensions(landscapePhoto)
        print("FRONT-PHOTO-ASPECT encoded-landscape-pixels=\(landscapeDimensions.0)x\(landscapeDimensions.1)")
        let landscapeAngle = await withCheckedContinuation { c in camera.frontPhotoCaptureRotationForTesting { c.resume(returning: $0) } }
        let outputLandscape = CaptureOrientation.frontPhotoLandscape(sensorLandscape: true, captureAngle: landscapeAngle)
        XCTAssertEqual(landscapeDimensions.0 > landscapeDimensions.1, outputLandscape)
        XCTAssertEqual(Double(landscapeDimensions.0) / Double(landscapeDimensions.1), outputLandscape ? 4.0 / 3.0 : 3.0 / 4.0,
                       accuracy: 0.01, "Standard landscape photos must use a 4:3 output aspect ratio")
        XCTAssertGreaterThan(landscapeDimensions.0 * landscapeDimensions.1, 10_000_000,
                             "Landscape framing should preserve the full front-camera still resolution instead of cropping portrait pixels")
        let sorted = durations.sorted()
        print("FRONT-PHOTO-ASPECT device=iPhone physical cycles=\(durations.count) first-frame-seconds=\(durations) median=\(sorted[sorted.count / 2]); measured from model action to first matching rendered-frame publication, not display FPS")
    }

    @MainActor func testFrontAspectChoiceIsPhotoOnlyAndWideToggleRemainsAvailable() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldKind = model.captureKind, oldFormat = model.photoFormat, oldRatio = model.ratio
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCaptureKind(.photo); model.photoFormat = oldFormat; model.ratio = oldRatio
            model.setCaptureKind(oldKind); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        model.setCaptureKind(.photo)
        func settle() async {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<500 {
                if camera.ready && camera.preview != nil && !camera.videoConfiguring && model.focalTransitionImage == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func waitForAspectAvailability(_ expected: Bool) async -> Bool {
            for _ in 0..<500 {
                if camera.frontPhotoAspectRatioSwitchAvailable == expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return camera.frontPhotoAspectRatioSwitchAvailable == expected
        }
        await settle()
        if model.currentPosition != .front { model.flipCamera() }
        await settle()
        let initialAvailability = await waitForAspectAvailability(true)
        XCTAssertTrue(initialAvailability)
        for lens in camera.lenses.filter({ $0.device.position == .front }) {
            model.selectFocalLength(lens); await settle()
            let lensAvailability = await waitForAspectAvailability(true)
            XCTAssertTrue(lensAvailability, "Aspect control should not interfere with front wide framing")
        }
        model.setCaptureKind(.video); await settle()
        let videoAvailability = await waitForAspectAvailability(false)
        XCTAssertFalse(camera.frontPhotoAspectRatioSwitchAvailable, "Photo aspect toggle is unavailable in video mode")
        XCTAssertTrue(videoAvailability)
        model.setCaptureKind(.photo); await settle()
        let restoredAvailability = await waitForAspectAvailability(true)
        XCTAssertTrue(restoredAvailability)
        XCTAssertTrue(camera.ready)
        XCTAssertNotNil(camera.preview)
    }
    #endif
}
