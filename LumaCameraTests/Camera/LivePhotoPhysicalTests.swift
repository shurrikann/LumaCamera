import XCTest
import AVFoundation
import Photos
import Combine
import UIKit
@testable import LumaCamera

final class LivePhotoPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testNativeJPEGAndHEIFLivePairsDecodeWithoutWritingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let oldCallback = camera.onCaptureCompleted, oldMode = model.mode
        let oldFormat = model.photoFormat, oldResolution = model.photoResolution, oldHDR = model.hdr
        let oldLive = model.livePhotoEnabled
        let oldLook = model.effectiveCaptureLook
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var captures: [CapturedPhoto] = []
        camera.onCaptureCompleted = { if let photo = $0 { captures.append(photo) } }
        defer {
            camera.onCaptureCompleted = oldCallback; camera.updateLook(oldLook)
            if model.livePhotoEnabled != oldLive { model.toggleLivePhoto() }
            model.photoFormat = oldFormat; model.photoResolution = oldResolution; model.hdr = oldHDR
            model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        model.setMode(.auto); model.setCameraActive(true)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
        let details=await withCheckedContinuation { c in camera.sessionDetailsForTesting { c.resume(returning:$0) } }
        print("LIVE-SESSION \(details) review=\(model.review) settings=\(model.settings)")
        print("LIVE-START state=\(UIApplication.shared.applicationState.rawValue) running=\(running) ready=\(camera.ready) recovery=\(camera.recoveringSession) failed=\(camera.recoveryFailed) message=\(camera.message ?? "none")")
        XCTAssertTrue(running); XCTAssertTrue(camera.ready)
        guard camera.ready else { return }
        // This regression covers rear native Live, independent of a prior test's camera.
        let rear = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        model.selectFocalLength(rear)
        for _ in 0..<200 { if camera.ready && camera.selectedLens == rear.id && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(camera.selectedLens,rear.id); XCTAssertTrue(camera.ready)
        guard camera.supportsLivePhoto else { XCTFail("Connected iPhone must expose native Live Photo capability"); return }
        for (index, format) in [PhotoFileFormat.jpeg, .heif].enumerated() {
            var look = CaptureLook()
            if index == 1 { look.style = .leicaM9; look.adjustments[.temperature] = 15; look.adjustments[.grainSize] = 12; look.ratio = .wide }
            model.photoFormat = format
            if !model.livePhotoEnabled { model.toggleLivePhoto() }
            camera.updateLook(look)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .seconds(3))
            let liveOptions = PhotoOptions(format: format, live: true)
            camera.capture(flashMode: .off, options: liveOptions)
            XCTAssertTrue(camera.shutterBusy)
            for _ in 0..<10 { camera.capture(flashMode: .off, options: liveOptions) }
            XCTAssertEqual(camera.pendingPhotoCount, 1)
            for _ in 0..<900 {
                if captures.count > index || camera.pendingPhotoCount == 0 { break }
                XCTAssertTrue(camera.shutterBusy, "Live must stay loading through movie capture and pairing")
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(camera.shutterBusy)
            XCTAssertEqual(captures.count, index + 1, camera.message ?? "Live failed")
            guard captures.count > index else { return }
            let photo = captures[index]
            XCTAssertEqual(photo.resources.count, 2)
            XCTAssertEqual(photo.resources.filter(\.pairedVideo).count, 1)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let urls = try photo.resources.map { resource in
                let url = directory.appendingPathComponent(resource.filename)
                try resource.data.write(to: url); return url
            }
            let done = expectation(description: "System recognizes paired Live Photo")
            var live: PHLivePhoto?
            let request = PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil,
                                             targetSize: CGSize(width: 600, height: 800), contentMode: .aspectFit) { result, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                live = result
                print("LIVE-VALIDATION format=\(format.rawValue) result=\(result != nil) info=\(info)")
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 20)
            PHLivePhoto.cancelRequest(withRequestID: request)
            XCTAssertNotNil(live, "System must accept still/video identifiers and timed metadata")
            print("LIVE-CAPTURE format=\(format.rawValue) bytes=\(photo.resources.map { $0.data.count })")
        }
        XCTAssertEqual(camera.pendingPhotoCount, 0)
    }

    @MainActor func testSmartCaptureDisablesAndForbidsLivePhoto() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false; model.setMode(.auto)
        if !model.livePhotoEnabled { model.toggleLivePhoto() }
        XCTAssertTrue(model.livePhotoEnabled)
        XCTAssertTrue(model.capturesLivePhoto)
        if !model.smartCaptureEnabled { model.toggleSmartCaptureMode() }
        XCTAssertTrue(model.smartCaptureEnabled)
        XCTAssertFalse(model.livePhotoEnabled, "进入智拍必须关闭 Live")
        XCTAssertFalse(model.capturesLivePhoto)
        XCTAssertFalse(model.canToggleLivePhoto, "智拍期间 Live 开关必须禁用")
        model.toggleLivePhoto()
        XCTAssertFalse(model.livePhotoEnabled, "智拍期间不能重新打开 Live")
        XCTAssertFalse(model.photoOptions.capturesLive)
        print("SMART-LIVE forbidden=true smart=\(model.smartCaptureEnabled) live=\(model.livePhotoEnabled)")
    }

    @MainActor func testRearLiveTogglePreserves24mmAnd35mmFraming() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live framing stability needs a physical camera")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldMode = model.mode, oldFormat = model.photoFormat, oldHDR = model.hdr
        let oldResolution = model.photoResolution, oldLive = model.livePhotoEnabled
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.livePhotoEnabled != oldLive, model.livePhotoAvailable { model.toggleLivePhoto() }
            model.photoFormat = oldFormat; model.hdr = oldHDR; model.photoResolution = oldResolution
            model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.photoFormat = .jpeg; model.hdr = false; model.photoResolution = .standard
        model.setMode(.auto); model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if model.currentPosition != .back { model.flipCamera() }
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil && model.currentPosition == .back { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<100 {
            if camera.supportsLivePhoto { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.supportsLivePhoto else { throw XCTSkip("Rear camera does not support Live Photo") }
        let oneX = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        if model.livePhotoEnabled { model.toggleLivePhoto() }

        func actualZoom() async -> CGFloat {
            await withCheckedContinuation { continuation in
                camera.zoomStateForTesting { zoom, _, _ in continuation.resume(returning: zoom) }
            }
        }
        func waitForZoom(_ expected: CGFloat, context: String) async throws {
            var stableReads = 0
            for _ in 0..<160 {
                await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
                let actual = await actualZoom()
                if camera.ready && camera.preview != nil && abs(actual - expected) < 0.025 {
                    stableReads += 1
                    if stableReads >= 3 { return }
                } else { stableReads = 0 }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("\(context): expected \(expected)×, got \(await actualZoom())×")
        }

        // Establish the 24 mm hardware state explicitly first. A prior test can
        // leave the logical focal control at 1× while its device zoom is stale.
        camera.setContinuousZoom(1)
        try await waitForZoom(1, context: "Set 24 mm before Live")
        model.toggleLivePhoto()
        XCTAssertTrue(model.livePhotoEnabled, "Live must enable for the 24 mm check")
        try await waitForZoom(1, context: "Enable Live at 24 mm")
        model.toggleLivePhoto()
        try await waitForZoom(1, context: "Disable Live at 24 mm")

        // In A mode tapping the selected 1× control toggles 24 mm ↔ 35 mm.
        model.selectFocalLength(oneX)
        try await waitForZoom(28.0 / 24.0, context: "Select 28 mm")
        let zoomBeforeLive = await actualZoom()
        model.toggleLivePhoto()
        XCTAssertTrue(model.livePhotoEnabled, "Live must enable for the 35 mm check")
        try await waitForZoom(zoomBeforeLive, context: "Enable Live at 35 mm")
        let zoomWithLive = await actualZoom()
        // Live 开启后重复点击当前 1×，实际硬件仍须在 24/35mm 间往返。
        for expected in [CGFloat(35.0 / 24.0), CGFloat(1), CGFloat(28.0 / 24.0), CGFloat(35.0 / 24.0)] {
            model.selectFocalLength(oneX)
            try await waitForZoom(expected, context: "Live enabled focal tap")
            XCTAssertTrue(model.livePhotoEnabled)
        }
        model.setMode(.manual)
        for _ in 0..<300 { if camera.ready && !model.captureKindSwitching { break }; try await Task.sleep(for: .milliseconds(20)) }
        // 先显式回到24mm，再验证Live下M挡同样可短按切换。
        camera.setContinuousZoom(1)
        try await waitForZoom(1, context: "M Live 24mm baseline")
        for expected in [CGFloat(28.0 / 24.0), CGFloat(35.0 / 24.0), CGFloat(1)] {
            model.selectFocalLength(oneX)
            try await waitForZoom(expected, context: "M Live focal tap")
            XCTAssertTrue(model.livePhotoEnabled)
        }
        print("REAR-LIVE-FRAMING 24mm=stable 28mm before=\(zoomBeforeLive) afterEnable=\(zoomWithLive) selected=\(camera.selectedLens)")
        model.toggleLivePhoto()
        // The M-mode loop above ends explicitly at 1×; disabling Live must not reset it.
        try await waitForZoom(1, context: "Disable Live after M cycle")
        #endif
    }

    @MainActor func testManualParametersSurviveRepeatedSessionStopsAndRestarts() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let mode = model.mode, iso = model.iso, shutter = model.shutter, wb = model.wb, tint = model.whiteBalanceTint, focus = model.focus
        let manual = model.manualExposure, manualWB = model.manualWB, manualFocus = model.manualFocus
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setMode(mode); model.iso = iso; model.shutter = shutter; model.wb = wb; model.whiteBalanceTint = tint; model.focus = focus
            model.manualExposure = manual; model.manualWB = manualWB; model.manualFocus = manualFocus
            model.applyExposure(); model.applyWhiteBalance(); camera.setFocus(position: manualFocus ? focus : nil)
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
        model.setMode(.manual)
        model.manualExposure = true; model.iso = min(600, camera.isoRange.upperBound)
        model.shutter = max(camera.shutterRange.lowerBound, min(log2(1.0 / 80), camera.shutterRange.upperBound))
        model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 12
        model.manualFocus = true; model.focus = 0.45
        for cycle in 0..<12 {
            model.setCameraActive(false)
            await Task.yield()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.setCameraActive(true)
            try await Task.sleep(for: .milliseconds(350))
            for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            // Ready means the session is running. Exposure commands settle asynchronously
            // on newly started sensors, particularly the telephoto sensor-crop route.
            var state: CameraEngine.ExposureColorState?
            let settlingStart = CACurrentMediaTime()
            for _ in 0..<100 {
                state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
                if let state, state.exposureMode == .custom,
                   abs(Double(state.iso) - model.iso) < 5,
                   abs(state.seconds - pow(2, model.shutter)) < 0.001 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            print("MANUAL-RESTORE-SETTLING cycle=\(cycle) seconds=\(CACurrentMediaTime()-settlingStart)")
            let actual = try XCTUnwrap(state)
            print("MANUAL-RESTORE cycle=\(cycle) iso=\(actual.iso) seconds=\(actual.seconds) color=\(actual.colorSpace.rawValue) hdr=\(actual.hdr) automaticHDR=\(actual.automaticHDR) engineM=\(actual.engineManual) engineCustom=\(actual.engineCustom) targetISO=\(String(describing:actual.requestedISO)) targetS=\(String(describing:actual.requestedSeconds)) virtual=\(actual.virtual) zoom=\(actual.physicalZoomFactor)")
            XCTAssertEqual(actual.exposureMode, .custom, "cycle \(cycle)")
            XCTAssertEqual(Double(actual.iso), model.iso, accuracy: 5, "cycle \(cycle)")
            XCTAssertEqual(actual.seconds, pow(2, model.shutter), accuracy: 0.001, "cycle \(cycle)")
            XCTAssertEqual(actual.whiteBalanceMode, .locked)
            XCTAssertEqual(actual.focusMode, .locked)
            XCTAssertEqual(actual.lensPosition, Float(model.focus), accuracy: 0.02)
            XCTAssertTrue(camera.ready)
        }
    }
    #endif
}
