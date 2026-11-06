import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class CameraReadingsSafetyTests: XCTestCase {
    @MainActor
    func testExactReportedNaNShutterCrashAndNumericExtremesAreSafe() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        for value in [Double.nan, .infinity, -.infinity, 0, -1, -.greatestFiniteMagnitude] {
            XCTAssertEqual(model.shutterText(value), "—")
            XCTAssertEqual(CameraNumericText.integer(value), "—")
        }
        XCTAssertEqual(model.shutterText(1.0 / 125), "1/125")
        XCTAssertEqual(model.shutterText(2), "2.0s")
        XCTAssertEqual(model.shutterText(.leastNonzeroMagnitude), "—")
        XCTAssertEqual(CameraNumericText.integer(.greatestFiniteMagnitude), "—")
        XCTAssertEqual(CameraNumericText.integer(Double(Int.max)), "—")
        XCTAssertEqual(CameraNumericText.integer(640), "640")
        for parameter in [CameraParameter.iso, .shutter, .wb, .tint, .focus, .ev] {
            model.parameter = parameter
            for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
                switch parameter {
                case .iso: model.iso = value
                case .shutter: model.shutter = value
                case .wb: model.wb = value
                case .tint: model.whiteBalanceTint = value
                case .focus: model.focus = value
                case .ev: model.ev = value
                }
                XCTAssertFalse(model.parameterDisplay.isEmpty)
            }
        }
    }

    func testTransientInvalidReadingsAreDiscardedAndUnknownWhiteBalanceIsNotInvented() {
        let bad: [Double] = [.nan, .infinity, -.infinity, -1, 0]
        for value in bad {
            XCTAssertNil(CameraReadings(iso: 100, seconds: value, kelvin: 5000, focus: 0.5).validated)
            XCTAssertNil(CameraReadings(iso: value, seconds: 0.01, kelvin: 5000, focus: 0.5).validated)
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 2] {
            XCTAssertNil(CameraReadings(iso: 100, seconds: 0.01, kelvin: 5000, focus: value).validated)
        }
        let valid = CameraReadings(iso: 100, seconds: 0.01, kelvin: .nan, focus: 0.5).validated
        XCTAssertNotNil(valid)
        XCTAssertEqual(valid?.kelvin, 0)
    }

    func testLateFramesFromOldLensOrStoppedCameraCannotPublishReadings() {
        let valid = CameraReadings(iso: 100, seconds: 0.01, kelvin: 5000, focus: 0.5)
        for generation in UInt64(1)...2000 {
            XCTAssertNil(valid.forDisplay(frameGeneration: generation - 1, currentGeneration: generation, running: true))
            XCTAssertNil(valid.forDisplay(frameGeneration: generation, currentGeneration: generation, running: false))
            XCTAssertNotNil(valid.forDisplay(frameGeneration: generation, currentGeneration: generation, running: true))
            let invalid = CameraReadings(iso: 100, seconds: .nan, kelvin: 5000, focus: 0.5)
            XCTAssertNil(invalid.forDisplay(frameGeneration: generation, currentGeneration: generation, running: true))
        }
    }

    @MainActor
    func testInvalidParameterInputIsIgnoredBeforeChangingManualSettings() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        for parameter in [CameraParameter.iso, .shutter, .wb, .tint, .focus, .ev] {
            model.parameter = parameter
            let previous = model.parameterBinding.wrappedValue
            for value in [Double.nan, .infinity, -.infinity] {
                model.parameterBinding.wrappedValue = value
                XCTAssertEqual(model.parameterBinding.wrappedValue, previous)
            }
        }
    }

    @MainActor
    func testRapidManualLensModeAndLifecycleChangesKeepReadoutFormattingSafe() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        for i in 0..<500 {
            model.setMode(.manual)
            model.manualExposure = true; model.manualWB = i % 2 == 0; model.manualFocus = i % 3 == 0
            model.iso = 640; model.shutter = log2(1.0 / 30)
            model.didChangeLensDevice("lens-\(i % 3)", isoRange: 25...1600, shutterRange: -12...0)
            model.setMode(.auto)
            model.setCameraActive(i % 2 == 0)
            XCTAssertEqual(model.shutterText(i % 2 == 0 ? .nan : .infinity), "—")
            for parameter in [CameraParameter.iso, .shutter, .wb, .tint, .focus, .ev] {
                model.parameter = parameter
                XCTAssertFalse(model.parameterDisplay.isEmpty)
            }
        }
        model.setCameraActive(false)
        let drained = expectation(description: "Queued camera work finishes")
        model.camera.afterPendingSessionTasks { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 10)
    }
}

/// Executes AVFoundation on the connected device; no photos are captured or deleted.
final class PhysicalCameraSwitchingTests: XCTestCase {
    @MainActor
    private func drain(_ camera: CameraEngine) async {
        for _ in 0..<2 {
            let done = expectation(description: "Session configuration completed")
            camera.afterPendingSessionTasks { done.fulfill() }
            await fulfillment(of: [done], timeout: 15)
        }
    }

    #if !targetEnvironment(simulator)
    /// 后置/旧前置传感器预览保留原画面，由视图裁切；新前置动态传感器先按所选画幅裁切。
    /// 两条路线都必须等新帧，不能拿切镜前的 UIImage 证明切镜后的宽高正确。
    @MainActor private func assertFreshPreview(_ camera: CameraEngine, model: CameraViewModel,
                                               after time: Double, previous: UIImage?) async throws {
        var matched = false
        for _ in 0..<250 {
            if camera.ready, camera.previewFrameTimeForTesting > time,
               let image = camera.preview, image !== previous,
               camera.readings?.validated != nil {
                let nativeFront = model.currentPosition == .front && camera.frontPhotoAspectRatioSwitchAvailable
                let ratio = nativeFront
                    ? (camera.frontPhotoLandscapeEnabled ? model.ratio.landscapeRatio : model.ratio.portraitRatio)
                    : FrameRatio.standard.portraitRatio
                // 两轴各允许一个像素的整数边界外扩；用同一比例折算，不能把高瘦画幅的宽轴取整放大误报。
                if abs(image.size.width - image.size.height * ratio) <= 1 + ratio {
                    matched = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(matched, "新预览必须匹配当前构图：position=\(model.currentPosition) ratio=\(model.ratio) landscape=\(camera.frontPhotoLandscapeEnabled) image=\(String(describing: camera.preview?.size))")
        let image = try XCTUnwrap(camera.preview)
        XCTAssertEqual(image.size.width, 900, accuracy: 1)
        XCTAssertEqual(image.imageOrientation, .up)
    }

    /// 七种画幅下 M→A 不应改变画幅；前置主动横幅/竖幅都合法，切回后置恢复竖向预览。
    @MainActor func testManualToAutomaticPreviewMatchesAllPhotoRatiosAndFrontFraming() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        await drain(camera)
        for _ in 0..<250 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        if model.currentPosition != .back { model.flipCamera(); await drain(camera) }
        var samples: [Double] = []
        for ratio in FrameRatio.photoOptions {
            model.ratio = ratio
            model.setMode(.manual); await drain(camera)
            let previous = camera.preview, began = CACurrentMediaTime()
            model.setMode(.auto); await drain(camera)
            try await assertFreshPreview(camera, model: model, after: began, previous: previous)
            XCTAssertEqual(model.ratio, ratio)
            XCTAssertEqual(model.mode, .auto)
            samples.append(CACurrentMediaTime() - began)
        }
        model.flipCamera(); await drain(camera)
        XCTAssertEqual(model.currentPosition, .front)
        let framingOptions = camera.frontPhotoAspectRatioSwitchAvailable ? [false, true, false, true] : [false]
        var checks = 0
        for landscape in framingOptions {
            if camera.frontPhotoAspectRatioSwitchAvailable { camera.setFrontPhotoLandscapeEnabled(landscape) }
            await drain(camera)
            for ratio in FrameRatio.photoOptions {
                model.ratio = ratio
                model.setMode(.manual); await drain(camera)
                let previous = camera.preview, began = CACurrentMediaTime()
                model.setMode(.auto); await drain(camera)
                try await assertFreshPreview(camera, model: model, after: began, previous: previous)
                XCTAssertEqual(model.ratio, ratio)
                checks += 1
            }
        }
        let previous = camera.preview, began = CACurrentMediaTime()
        model.flipCamera(); await drain(camera)
        try await assertFreshPreview(camera, model: model, after: began, previous: previous)
        XCTAssertEqual(model.currentPosition, .back)
        let sorted = samples.sorted()
        print("MODE-PREVIEW-SIZE rearSamples=\(samples.count) frontChecks=\(checks) rearMedian=\(sorted[sorted.count / 2]) rearMax=\(sorted.last ?? 0) ratios=\(FrameRatio.photoOptions.count)")
        model.setCameraActive(false)
        await Task.yield(); await drain(camera)
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running)
    }
    #endif

    @MainActor
    func testManualPresetsThenAutomaticModeOnPhysicalCamera() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical camera inputs")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let idleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let audit = SessionRuntimeErrorAudit()
        defer {
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idleTimerDisabled
            audit.finish()
        }
        let camera = model.camera
        let started = expectation(description: "Physical camera ready")
        let token = camera.$ready.filter { $0 }.first().sink { _ in started.fulfill() }
        model.setCameraActive(true)
        await fulfillment(of: [started], timeout: 15)
        token.cancel()
        XCTAssertTrue(camera.ready)
        let presets = camera.lenses.filter { $0.device.position == .back }
        XCTAssertFalse(presets.isEmpty)
        for _ in 0..<3 {
            model.setMode(.manual)
            await drain(camera)
            model.manualExposure = true; model.manualWB = true
            model.iso = 400; model.shutter = log2(1.0 / 125); model.wb = 4800
            model.whiteBalanceTint = 18
            model.applyExposure(); model.applyWhiteBalance()
            for lens in presets + presets.reversed() {
                model.selectFocalLength(lens)
                // Repeated taps while the camera is switching must be safely ignored.
                model.selectFocalLength(lens)
                await drain(camera)
                XCTAssertTrue(camera.ready, camera.message ?? "Camera must remain ready after lens change")
                let hdrChecked = expectation(description: "Manual lens keeps SDR preview")
                camera.exposureColorState { state in
                    if let state { XCTAssertFalse(state.hdr); XCTAssertFalse(state.automaticHDR) }
                    else { XCTFail("Missing manual device") }
                    hdrChecked.fulfill()
                }
                await fulfillment(of: [hdrChecked], timeout: 5)
                XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualWB)
                XCTAssertEqual(model.whiteBalanceTint, 18)
                XCTAssertFalse(model.shutterText(pow(2, model.shutter)).isEmpty)
            }
            model.setMode(.auto)
            await drain(camera)
            for _ in 0..<50 {
                if camera.readings?.validated != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let readings = try XCTUnwrap(camera.readings, "Live camera readings must resume after returning to A")
            XCTAssertNotNil(readings.validated)
            XCTAssertNotEqual(model.shutterText(readings.seconds), "—")
            XCTAssertNotNil(camera.preview)
            XCTAssertEqual(model.mode, .auto)
            XCTAssertTrue(camera.ready)
        }
        // 前置动态画幅可以是横幅；按当前构图核对尺寸，不能把合法横幅当作侧转错误。
        for _ in 0..<6 {
            let previous = camera.preview, requestedAt = CACurrentMediaTime()
            model.flipCamera()
            await drain(camera)
            for _ in 0..<50 {
                if camera.preview != nil, camera.readings?.validated != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(camera.ready)
            try await assertFreshPreview(camera, model: model, after: requestedAt, previous: previous)
            XCTAssertNotNil(camera.readings?.validated)
        }
        var histogramUpdates = 0
        let histogramToken = camera.$histogram.dropFirst().filter { !$0.isEmpty }.sink { _ in histogramUpdates += 1 }
        camera.enableHistogram(true)
        try await Task.sleep(for: .seconds(2))
        camera.enableHistogram(false)
        histogramToken.cancel()
        print("Histogram updates over 2 seconds: \(histogramUpdates)")
        XCTAssertGreaterThanOrEqual(histogramUpdates, 8, "Histogram must update faster than the previous 2.5 Hz")
        #endif
    }
}
