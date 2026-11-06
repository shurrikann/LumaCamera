import AVFoundation
import XCTest
import UIKit
import ImageIO
@testable import LumaCamera

final class NightCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldReady = camera.ready
        let oldCaptureKind = model.captureKind
        let oldMode = model.mode
        let oldFormat = model.photoFormat
        let oldResolution = model.photoResolution
        let oldHDR = model.hdr
        let oldLive = model.livePhotoEnabled
        let oldTimer = model.timerSeconds
        let oldFlash = model.flashMode
        let oldNight = model.nightModeEnabled
        let oldBurst = model.burstModeEnabled
        let oldCallback = camera.onCaptureCompleted
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        let oldLensID = camera.selectedLens
        let oldZoom = camera.currentZoom
        let originalPendingSaveCount = model.library.pendingSaveCount
        UIApplication.shared.isIdleTimerDisabled = true

        defer {
            camera.onCaptureCompleted = oldCallback
            model.updateLook()
            if model.nightModeEnabled != oldNight { model.toggleNightMode() }
            if model.burstModeEnabled != oldBurst { model.toggleBurstMode() }
            if model.captureKind != oldCaptureKind { model.setCaptureKind(oldCaptureKind) }
            if model.mode != oldMode { model.setMode(oldMode) }
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.hdr = oldHDR
            if model.livePhotoEnabled != oldLive { model.toggleLivePhoto() }
            model.timerSeconds = oldTimer
            model.flashMode = oldFlash
            if let oldLens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(oldLens)
                camera.setContinuousZoom(oldZoom)
            }
            model.setCameraActive(false)
            Task { @MainActor in model.setCameraActive(oldReady) }
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera did not become ready")
        if model.captureKind != .photo { model.setCaptureKind(.photo) }
        if model.mode != .auto { model.setMode(.auto) }
        model.photoFormat = .jpeg
        model.photoResolution = .standard
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.timerSeconds = 0
        model.flashMode = .off
        if model.burstModeEnabled { model.toggleBurstMode() }
        if let mainLens = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }),
           camera.selectedLens != mainLens.id || abs(camera.currentZoom - 1) > 0.02 {
            camera.selectLens(mainLens)
        }
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<200 {
            if camera.ready && camera.selectedLens == camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })?.id { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        if !model.nightModeEnabled { model.toggleNightMode() }
        XCTAssertTrue(model.nightModeEnabled)
        XCTAssertNil(model.nightUnavailableReason, model.nightUnavailableReason ?? "Night capture is unavailable")
        // 独立于用户当前滤镜，保证原片/融合对照不混入已有调色。
        camera.updateLook(CaptureLook(), photoFormat: .jpeg)
        for _ in 0..<3 {
            model.toggleNightMode()
            try await Task.sleep(for: .milliseconds(25))
            model.toggleNightMode()
            try await Task.sleep(for: .milliseconds(25))
        }
        print("NIGHT-GATE actual-triggered=\(model.nightIndicatorIsTriggered); capture test explicitly forces bracket independently of gate")
        var forcedNightCaptureOptions = model.photoOptions
        // This test exercises the physical bracket/merge path independently from
        // the low-light gate, whose thresholds are covered by deterministic tests.
        forcedNightCaptureOptions.nightMode = true
        XCTAssertTrue(NightCapturePolicy.supports(format: forcedNightCaptureOptions.format,
                                                  resolution: forcedNightCaptureOptions.resolution,
                                                  live: forcedNightCaptureOptions.live,
                                                  hdr: forcedNightCaptureOptions.hdr,
                                                  timerSeconds: model.timerSeconds,
                                                  manualMode: model.mode == .manual,
                                                  flashMode: model.flashMode,
                                                  maximumBracketedCapturePhotoCount: NightCapturePolicy.frameCount))

        let oldOriginalCallback = camera.onOriginalProcessedPhotoForTesting
        defer { camera.onOriginalProcessedPhotoForTesting = oldOriginalCallback }
        var originalData: Data?
        camera.onOriginalProcessedPhotoForTesting = { originalData = $0 }
        var captures: [CapturedPhoto] = []
        var elapsed: [TimeInterval] = []
        camera.onCaptureCompleted = { if let photo = $0 { captures.append(photo) } }
        for index in 0..<3 {
            forcedNightCaptureOptions.format = index == 2 ? .heif : .jpeg
            originalData = nil
            let started = CACurrentMediaTime()
            let completed = expectation(description: "Night bracket \(index + 1) completes")
            var latestCapture: CapturedPhoto?
            camera.onCaptureCompleted = { photo in
                latestCapture = photo
                if let photo { captures.append(photo) }
                completed.fulfill()
            }
            camera.capture(flashMode: .off, options: forcedNightCaptureOptions)
            await fulfillment(of: [completed], timeout: 45)
            elapsed.append(CACurrentMediaTime() - started)

            let photo = try XCTUnwrap(latestCapture, camera.message ?? "Night capture returned no photo")
            if let originalData {
                let originalAttachment = XCTAttachment(data: originalData, uniformTypeIdentifier: "public.image")
                originalAttachment.name = "Night-middle-reference-\(index)"
                originalAttachment.lifetime = .keepAlways
                add(originalAttachment)
            }
            let resource = try XCTUnwrap(photo.resources.first)
            let outputAttachment = XCTAttachment(data: resource.data, uniformTypeIdentifier: "public.image")
            outputAttachment.name = "Night-optimized-output-\(index)"
            outputAttachment.lifetime = .keepAlways
            add(outputAttachment)
            if let originalData {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(originalData as CFData, nil))
                let output = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
                let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let outputProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
                let sourceEXIF = try XCTUnwrap(sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                let outputEXIF = try XCTUnwrap(outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFocalLength] {
                    XCTAssertEqual(try XCTUnwrap(outputEXIF[key] as? NSNumber).doubleValue, try XCTUnwrap(sourceEXIF[key] as? NSNumber).doubleValue, accuracy: 0.000001)
                }
                XCTAssertEqual(outputEXIF[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], sourceEXIF[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])
                print("NIGHT-EXIF format=\(forcedNightCaptureOptions.format) sourceExposure=\(String(describing: sourceEXIF[kCGImagePropertyExifExposureTime])) outputExposure=\(String(describing: outputEXIF[kCGImagePropertyExifExposureTime])) iso=\(String(describing: outputEXIF[kCGImagePropertyExifISOSpeedRatings]))")
            }
            XCTAssertFalse(photo.resources.isEmpty)
            XCTAssertGreaterThan(photo.resources[0].data.count, 0)
            XCTAssertGreaterThan(photo.preview.size.width, 0)
            XCTAssertGreaterThan(photo.preview.size.height, 0)
            let mergeRow = photo.diagnostics?.rows.first { $0.title == "夜景曝光合成" }?.value
            let mergedCount = mergeRow.flatMap { Int($0.split(separator: " ").first ?? "") }
            let fused = mergedCount.map { (2...9).contains($0) } ?? false
            XCTAssertTrue(fused || mergeRow == "帧对齐不足，使用中间曝光单帧" || mergeRow == "曝光帧不完整，使用可用单帧")
            XCTAssertEqual(photo.diagnostics?.isNightComposite, fused)
            for _ in 0..<250 {
                if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse(camera.shutterBusy)
        }

        XCTAssertEqual(captures.count, 3)
        XCTAssertEqual(model.library.pendingSaveCount, originalPendingSaveCount, "Physical diagnostic captures must not enter the Photos save queue")
        let sorted = elapsed.sorted()
        let median = sorted[sorted.count / 2]
        let mergeStates = captures.map { photo in
            photo.diagnostics?.rows.first { $0.title == "夜景曝光合成" }?.value ?? "missing"
        }
        print("NIGHT-CAPTURE device=physical samples=3 end-to-end-callback-seconds=\(elapsed) median=\(median) merge-states=\(mergeStates); latency includes capture, decode, registration and merge, not shutter exposure alone")
        XCTAssertTrue(camera.ready, "Repeated bracket capture must leave the camera ready")
    }
    @MainActor func testNightRapidToggleAndReturnKeepOrdinaryPhotoPath() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
        let callback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = callback
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<600 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Night return did not settle: \(camera.message ?? "no message")")
        }
        model.setCameraActive(true)
        try await wait { camera.ready && camera.preview != nil }
        model.setCaptureKind(.photo); model.setMode(.auto)
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.flashMode = .off; model.timerSeconds = 0
        for _ in 0..<4 {
            model.toggleNightMode()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(model.nightModeEnabled)
            model.toggleNightMode()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertFalse(model.nightModeEnabled)
        }
        model.setCameraActive(false)
        try await wait { !camera.ready }
        model.setCameraActive(true)
        try await wait { camera.ready && camera.preview != nil }
        let done = expectation(description: "Ordinary photo after leaving night")
        var photo: CapturedPhoto?
        let pending = model.library.pendingSaveCount
        camera.onCaptureCompleted = { photo = $0; done.fulfill() }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
        await fulfillment(of: [done], timeout: 30)
        XCTAssertFalse(try XCTUnwrap(photo).diagnostics?.isNightComposite ?? true)
        XCTAssertFalse(photo?.diagnostics?.rows.contains { $0.title == "夜景曝光合成" } ?? true)
        try await wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
        XCTAssertEqual(model.library.pendingSaveCount, pending)
        XCTAssertTrue(camera.ready)
        print("NIGHT-STABILITY toggles=4 active-return=1 ordinary-capture=1 pending-saves-unchanged=true")
    }
    #endif
}
