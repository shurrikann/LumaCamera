import XCTest
import AVFoundation
import Combine
import UIKit
import ImageIO
@testable import LumaCamera

final class PreviewExposureAssistPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 普通M挡长短曝光矩阵：与不启用辅助的真实文件对照，而不是只检查界面读数。
    @MainActor func testOrdinarySmoothPreviewLongAndShortExposureFiles() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), oldPreferences = model.preferences
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        camera.photoPhaseTracingForTesting = true
        defer {
            camera.photoPhaseTracingForTesting = false
            camera.onCaptureCompleted = callback; model.preferences = oldPreferences
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        func waitReady() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let deadline = CACurrentMediaTime()+20
            while CACurrentMediaTime()<deadline {
                if camera.ready && !camera.shutterBusy && camera.preview != nil && !model.isPreparingSubmode { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail(camera.message ?? "相机未就绪"); throw CancellationError()
        }
        model.setCameraActive(true); try await waitReady()
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(1200))
        if let main = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom-1)<0.01 }) {
            model.selectFocalLength(main)
        }
        try await waitReady()
        model.photoResolution = .standard; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        // 固定色温与焦点，避免开关辅助期间AE联动的AWB/AF变化污染像素对照。
        model.manualWB = true; model.wb = 5000; model.whiteBalanceTint = 0; model.applyWhiteBalance()
        model.manualFocus = true; camera.setFocus(position:model.camera.readings?.focus ?? 0.5)
        var durations = [Double]()
        var brightness = [String:Double]()
        for format in [PhotoFileFormat.jpeg,.heif] {
            for seconds in [0.5,1.0/125.0] {
                for assisted in [false,true] {
                    model.photoFormat = format; model.manualExposure = true
                    model.iso = 100; model.shutter = log2(seconds)
                    model.smoothPreview = assisted; model.applyExposure()
                    try await waitReady()
                    try await Task.sleep(for:.milliseconds(250))
                    let state = await awaitExposureState(camera)
                    let before = try XCTUnwrap(state)
                    XCTAssertEqual(try XCTUnwrap(before.requestedSeconds),seconds,accuracy:0.0001)
                    let done = expectation(description:"普通曝光成片")
                    var captured: CapturedPhoto?
                    camera.onCaptureCompleted = { captured = $0; done.fulfill() }
                    let start = CACurrentMediaTime()
                    var options = model.photoOptions
                    options.format = format; options.resolution = .standard
                    camera.capture(flashMode:.off,options:options)
                    await fulfillment(of:[done],timeout:30)
                    durations.append(CACurrentMediaTime()-start)
                    let photo = try XCTUnwrap(captured,camera.message ?? "未出片")
                    try verifyFileExposure(photo,iso:100,seconds:seconds)
                    let data = try XCTUnwrap(photo.resources.first?.data)
                    let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                    let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(imageSource,0,[
                        kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceThumbnailMaxPixelSize:64,
                        kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary))
                    let width = thumbnail.width, height = thumbnail.height
                    var pixels = [UInt8](repeating:0,count:width*height*4)
                    let mean: Double = try pixels.withUnsafeMutableBytes { buffer in
                        let bitmap = try XCTUnwrap(CGContext(data:buffer.baseAddress,width:width,height:height,
                            bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                        bitmap.draw(thumbnail,in:CGRect(x:0,y:0,width:width,height:height))
                        let bytes = buffer.bindMemory(to:UInt8.self)
                        var sum = 0.0
                        for offset in stride(from:0,to:bytes.count,by:4) {
                            sum += Double(bytes[offset])*0.2126+Double(bytes[offset+1])*0.7152+Double(bytes[offset+2])*0.0722
                        }
                        return sum/Double(width*height)/255
                    }
                    let key = "\(format)-\(seconds)"
                    if !assisted { brightness[key] = mean }
                    else { XCTAssertEqual(mean,try XCTUnwrap(brightness[key]),accuracy:0.06,"相同参数的辅助开关不应明显改变成片亮度") }
                    let attachment = XCTAttachment(image:try XCTUnwrap(UIImage(data:data)))
                    attachment.name = "Smooth-\(format)-\(seconds)-\(assisted)"; attachment.lifetime = .keepAlways
                    add(attachment)
                    print("SMOOTH-PIXEL format=\(format) seconds=\(seconds) assisted=\(assisted) sRGBMeanLuma=\(mean)")
                    print("SMOOTH-ORDINARY format=\(format) assisted=\(assisted) requestedISO=100 seconds=\(seconds) previewISO=\(before.iso) previewSeconds=\(before.seconds) actual=\(String(describing:photo.diagnostics?.parameters)) elapsed=\(durations.last!)")
                    try await waitReady()
                }
            }
        }
        print("SMOOTH-ORDINARY-PERF samples=\(durations.count) captureSeconds=\(durations) systemPhotosWrites=0")
    }

    @MainActor func testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldMode = model.mode
        let oldSlowShutterEnabled = model.slowShutterEnabled
        let oldSlowShutterPreset = model.selectedSlowShutterPreset
        let oldPreferences = model.preferences
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.slowShutterEnabled { model.toggleSlowShutterMode() }
            if oldSlowShutterEnabled {
                model.toggleSlowShutterMode()
                if let oldSlowShutterPreset { model.selectSlowShutterPreset(oldSlowShutterPreset) }
            }
            if model.mode != oldMode { model.setMode(oldMode) }
            model.preferences = oldPreferences
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.ready, camera.preview != nil else {
            XCTFail(camera.message ?? "Camera did not become ready")
            return
        }
        model.setMode(.auto)
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        model.toggleSlowShutterMode()
        model.selectSlowShutterPreset(.lightTrails)

        var configuredState: CameraEngine.ExposureColorState?
        for _ in 0..<150 {
            configuredState = await awaitExposureState(camera)
            if let configuredState, configuredState.slowShutterPreviewOptimizationRequested,
               configuredState.slowShutterAutomaticExposureMaximumSeconds != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let configured = try XCTUnwrap(configuredState)
        XCTAssertFalse(configured.engineManual)
        XCTAssertTrue(configured.slowShutterPreviewOptimizationRequested)
        XCTAssertEqual(try XCTUnwrap(configured.slowShutterAutomaticExposureMaximumSeconds), 1, accuracy: 0.001)

        // 固定输入验证 1/15 秒触发和真实 AE 上限，不把它冒充自然暗光触发测试。
        let didActivate = await withCheckedContinuation { continuation in
            camera.evaluateAutomaticSlowShutterPreviewForTesting(exposureSeconds: 1.0 / 15.0) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(didActivate, "A 挡自动预览优化应在曝光达到 1/15 秒时触发，预览上限为 1/30 秒")
        let optimizedSnapshot = await awaitExposureState(camera)
        let optimized = try XCTUnwrap(optimizedSnapshot)
        XCTAssertTrue(optimized.slowShutterAutoPreviewOptimizationActive)
        XCTAssertEqual(optimized.exposureMode, .continuousAutoExposure)
        XCTAssertLessThanOrEqual(optimized.activeMaximumExposureSeconds, (1.0 / 30.0) + 0.002)

        for _ in 0..<6 {
            model.toggleSlowShutterMode()
            model.toggleSlowShutterMode()
            model.selectSlowShutterPreset(.lightTrails)
        }
        model.toggleSlowShutterMode()
        let disabled = await awaitExposureState(camera)
        let restored = try XCTUnwrap(disabled)
        XCTAssertFalse(restored.slowShutterPreviewOptimizationRequested)
        XCTAssertFalse(restored.slowShutterAutoPreviewOptimizationActive)
        XCTAssertTrue(camera.ready, "Repeated slow-shutter toggles must not stop the live camera")
    }

    @MainActor func testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldPreferences = model.preferences
        let oldMode = model.mode
        let oldManualExposure = model.manualExposure
        let oldISO = model.iso
        let oldShutter = model.shutter
        let oldFormat = model.photoFormat
        let oldResolution = model.photoResolution
        let oldHDR = model.hdr
        let oldLive = model.livePhotoEnabled
        let oldSlowShutterEnabled = model.slowShutterEnabled
        let oldSlowShutterPreset = model.selectedSlowShutterPreset
        let oldCaptureCallback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCaptureCallback
            model.smoothPreview = oldPreferences.auxiliarySmoothPreview
            if model.slowShutterEnabled { model.toggleSlowShutterMode() }
            if oldSlowShutterEnabled {
                model.toggleSlowShutterMode()
                if let oldSlowShutterPreset { model.selectSlowShutterPreset(oldSlowShutterPreset) }
            }
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.hdr = oldHDR
            model.manualExposure = oldManualExposure
            model.iso = oldISO
            model.shutter = oldShutter
            model.applyExposure()
            if model.mode != oldMode { model.setMode(oldMode) }
            if oldLive != model.livePhotoEnabled { model.toggleLivePhoto() }
            model.preferences = oldPreferences
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.ready, camera.preview != nil else {
            XCTFail(camera.message ?? "Camera did not become ready")
            return
        }
        model.setMode(.manual)
        let mainLens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        let frameBeforeManualRoute = camera.previewFrameTimeForTesting
        model.selectFocalLength(mainLens)
        await withCheckedContinuation { continuation in
            camera.afterPendingSessionTasks { continuation.resume() }
        }
        for _ in 0..<500 {
            if camera.ready && camera.previewFrameTimeForTesting > frameBeforeManualRoute { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.ready, camera.previewFrameTimeForTesting > frameBeforeManualRoute else {
            XCTFail("The M-mode lens route did not deliver a fresh preview frame")
            return
        }
        model.photoFormat = .heif
        model.photoResolution = .standard
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.smoothPreview = false
        model.manualExposure = true
        model.iso = 400
        model.shutter = log2(1.0 / 15.0)
        model.applyExposure()

        var baselineState: CameraEngine.ExposureColorState?
        for _ in 0..<150 {
            baselineState = await awaitExposureState(camera)
            if let baselineState, baselineState.engineManual, baselineState.exposureMode == .custom,
               abs(Double(baselineState.iso) - 400) < 5, abs(baselineState.seconds - 1.0 / 15.0) < 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let baseline = try XCTUnwrap(baselineState)
        XCTAssertEqual(baseline.exposureMode, .custom)
        XCTAssertEqual(Double(baseline.iso), 400, accuracy: 5)
        XCTAssertEqual(baseline.seconds, 1.0 / 15.0, accuracy: 0.002)

        model.toggleSlowShutterMode()
        model.setMode(.manual)
        XCTAssertNil(model.selectedSlowShutterPreset)
        model.iso = 400
        model.shutter = log2(1.0 / 15.0)
        model.applyExposure()
        var assistedState: CameraEngine.ExposureColorState?
        for _ in 0..<150 {
            assistedState = await awaitExposureState(camera)
            if let assistedState, assistedState.slowShutterPreviewOptimizationRequested,
               assistedState.exposureMode == .continuousAutoExposure,
               assistedState.activeMaximumExposureSeconds <= (1.0 / 30.0) + 0.002,
               abs(Double(try XCTUnwrap(assistedState.requestedISO)) - 400) < 5,
               abs(try XCTUnwrap(assistedState.requestedSeconds) - 1.0 / 15.0) < 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let assisted = try XCTUnwrap(assistedState)
        XCTAssertFalse(assisted.previewExposureAssistEnabled, "The user preference remains off; slow shutter enables preview assistance automatically")
        XCTAssertTrue(assisted.slowShutterPreviewOptimizationRequested)
        XCTAssertTrue(assisted.exposureMode == .continuousAutoExposure)
        XCTAssertLessThanOrEqual(assisted.activeMaximumExposureSeconds, (1.0 / 30.0) + 0.002)
        XCTAssertEqual(Double(try XCTUnwrap(assisted.requestedISO)), 400, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(assisted.requestedSeconds), 1.0 / 15.0, accuracy: 0.002)

        camera.resetPreviewPublicationTimesForTesting()
        var previewSamples: [(count: Int, medianMilliseconds: Double)] = []
        for _ in 0..<3 { previewSamples.append(try await samplePreview(camera, duration: 1.0)) }
        XCTAssertTrue(previewSamples.allSatisfy { $0.count >= 12 }, "Preview publication cadence stalled under automatic slow-shutter assistance: \(previewSamples)")
        print("AUTO-SLOW-PREVIEW device=iPhone17Pro; samples=3x1s; publications=\(previewSamples); requestedStill=ISO400,1/15s; assistCap=\(assisted.activeMaximumExposureSeconds)s")

        let captureDone = expectation(description: "automatic slow-shutter preview still capture")
        var captured: CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0; captureDone.fulfill() }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .heif, resolution: .standard))
        await fulfillment(of: [captureDone], timeout: 30)
        let photo = try XCTUnwrap(captured, camera.message ?? "Capture failed")
        try verifyFileExposure(photo, iso: 400, seconds: 1.0 / 15.0)
        let taskState = await withCheckedContinuation { c in
            camera.photoTaskStateForTesting { c.resume(returning: ($0, $1, $2, $3)) }
        }
        XCTAssertEqual(taskState.0, 0); XCTAssertEqual(taskState.1, 0)
        XCTAssertEqual(taskState.2, 0); XCTAssertEqual(taskState.3, 0)
        let sampled = try XCTUnwrap(photo.diagnostics?.parameters)
        XCTAssertEqual(try XCTUnwrap(sampled.sampledISO), 400, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(sampled.sampledExposureSeconds), 1.0 / 15.0, accuracy: 0.002)

        for _ in 0..<150 {
            let state = await awaitExposureState(camera)
            if let state, state.slowShutterPreviewOptimizationRequested,
               state.exposureMode == .continuousAutoExposure,
               state.activeMaximumExposureSeconds <= (1.0 / 30.0) + 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let restoredSnapshot = await awaitExposureState(camera)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertTrue(restored.slowShutterPreviewOptimizationRequested)
        XCTAssertEqual(restored.exposureMode, .continuousAutoExposure, "Preview optimization must resume after capture")
        XCTAssertLessThanOrEqual(restored.activeMaximumExposureSeconds, (1.0 / 30.0) + 0.002)

        for _ in 0..<6 {
            model.toggleSlowShutterMode()
            XCTAssertFalse(model.slowShutterEnabled)
            model.toggleSlowShutterMode()
            model.setMode(.manual)
            model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/15); model.applyExposure()
            XCTAssertTrue(model.slowShutterEnabled)
        }
        // 六次重新选择 motionBlur 已将请求改为预设的 1/8 秒；退出应保留最后请求。
        let finalRequestedSeconds = pow(2, model.shutter)
        model.toggleSlowShutterMode()
        for _ in 0..<150 {
            let state = await awaitExposureState(camera)
            if let state, !state.slowShutterPreviewOptimizationRequested,
               state.exposureMode == .custom, abs(state.seconds - finalRequestedSeconds) < 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finalSnapshot = await awaitExposureState(camera)
        let finalState = try XCTUnwrap(finalSnapshot)
        XCTAssertFalse(finalState.slowShutterPreviewOptimizationRequested)
        XCTAssertEqual(finalState.exposureMode, .custom)
        XCTAssertEqual(finalState.seconds, finalRequestedSeconds, accuracy: 0.002)
        XCTAssertTrue(camera.ready, "Repeated slow-shutter toggles and capture must not stop the camera")
    }

    @MainActor func testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldPreferences = model.preferences
        let oldMode = model.mode
        let oldManualExposure = model.manualExposure
        let oldISO = model.iso
        let oldShutter = model.shutter
        let oldFormat = model.photoFormat
        let oldResolution = model.photoResolution
        let oldHDR = model.hdr
        let oldLive = model.livePhotoEnabled
        let oldCaptureCallback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCaptureCallback
            model.smoothPreview = oldPreferences.auxiliarySmoothPreview
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.hdr = oldHDR
            model.manualExposure = oldManualExposure
            model.iso = oldISO
            model.shutter = oldShutter
            if model.mode != oldMode { model.setMode(oldMode) }
            if oldLive != model.livePhotoEnabled { model.toggleLivePhoto() }
            model.preferences = oldPreferences
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.ready, camera.preview != nil else {
            XCTFail(camera.message ?? "Camera did not become ready")
            return
        }
        model.setMode(.manual)
        let mainLens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        let frameBeforeManualRoute = camera.previewFrameTimeForTesting
        model.selectFocalLength(mainLens)
        await withCheckedContinuation { continuation in
            camera.afterPendingSessionTasks { continuation.resume() }
        }
        for _ in 0..<500 {
            if camera.ready && camera.previewFrameTimeForTesting > frameBeforeManualRoute { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard camera.ready, camera.previewFrameTimeForTesting > frameBeforeManualRoute else {
            XCTFail("The M-mode lens route did not deliver a fresh preview frame")
            return
        }
        model.photoFormat = .jpeg
        model.photoResolution = .standard
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.manualExposure = true
        model.iso = 400
        model.shutter = log2(1.0 / 15.0)
        // 此处测“关闭辅助”的基线，不能依赖上一测试或用户的辅助偏好恰好为关闭。
        model.smoothPreview = false
        model.applyExposure()
        for _ in 0..<150 {
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
            if let state, state.engineManual, state.engineCustom, state.exposureMode == .custom,
               abs(Double(state.iso) - 400) < 5, abs(state.seconds - 1.0 / 15.0) < 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let baselineSnapshot = await awaitExposureState(camera)
        let baseline = try XCTUnwrap(baselineSnapshot)
        XCTAssertEqual(baseline.exposureMode, .custom)
        XCTAssertEqual(Double(baseline.iso), 400, accuracy: 5)
        XCTAssertEqual(baseline.seconds, 1.0 / 15.0, accuracy: 0.002)

        var baselineSamples: [(count: Int, medianMilliseconds: Double)] = []
        for _ in 0..<3 { baselineSamples.append(try await samplePreview(camera, duration: 1.0)) }

        model.smoothPreview = true
        var assisted: CameraEngine.ExposureColorState?
        for _ in 0..<150 {
            assisted = await awaitExposureState(camera)
            if let assisted, assisted.previewExposureAssistEnabled,
               assisted.exposureMode != .custom,
               assisted.activeMaximumExposureSeconds.isFinite,
               assisted.activeMaximumExposureSeconds <= (1.0 / 30.0) + 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let smoothState = try XCTUnwrap(assisted)
        XCTAssertTrue(smoothState.previewExposureAssistEnabled)
        XCTAssertEqual(smoothState.exposureMode, .continuousAutoExposure)
        XCTAssertLessThanOrEqual(smoothState.activeMaximumExposureSeconds, (1.0 / 30.0) + 0.002)
        XCTAssertEqual(Double(try XCTUnwrap(smoothState.requestedISO)), 400, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(smoothState.requestedSeconds), 1.0 / 15.0, accuracy: 0.002)

        camera.resetPreviewPublicationTimesForTesting()
        var assistedSamples: [(count: Int, medianMilliseconds: Double)] = []
        for _ in 0..<3 { assistedSamples.append(try await samplePreview(camera, duration: 1.0)) }
        XCTAssertTrue(assistedSamples.allSatisfy { $0.count >= 12 }, "App preview publications stalled while assist was enabled: \(assistedSamples)")
        print("SMOOTH-PREVIEW cadence=app-preview-publications/second baseline_n=3 baseline=\(baselineSamples) assisted_n=3 assisted=\(assistedSamples) cap=\(smoothState.activeMaximumExposureSeconds)s")

        let captureDone = expectation(description: "manual exposure photo with smooth preview")
        var captured: CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0; captureDone.fulfill() }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg, resolution: .standard))
        await fulfillment(of: [captureDone], timeout: 30)
        let photo = try XCTUnwrap(captured, camera.message ?? "Capture failed")
        try verifyFileExposure(photo, iso: 400, seconds: 1.0 / 15.0)
        let taskState = await withCheckedContinuation { c in
            camera.photoTaskStateForTesting { c.resume(returning: ($0, $1, $2, $3)) }
        }
        XCTAssertEqual(taskState.0, 0); XCTAssertEqual(taskState.1, 0)
        XCTAssertEqual(taskState.2, 0); XCTAssertEqual(taskState.3, 0)
        let sampled = try XCTUnwrap(photo.diagnostics?.parameters)
        XCTAssertEqual(try XCTUnwrap(sampled.sampledISO), 400, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(sampled.sampledExposureSeconds), 1.0 / 15.0, accuracy: 0.002)
        print("SMOOTH-PREVIEW-CAPTURE requestedISO=400 actualISO=\(sampled.sampledISO ?? -1) requestedSeconds=\(1.0 / 15.0) actualSeconds=\(sampled.sampledExposureSeconds ?? -1) format=JPG; in-memory only")

        for _ in 0..<150 {
            let state = await awaitExposureState(camera)
            if let state, state.previewExposureAssistEnabled,
               state.exposureMode == .continuousAutoExposure,
               state.activeMaximumExposureSeconds <= (1.0 / 30.0) + 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let restoredSnapshot = await awaitExposureState(camera)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.exposureMode, .continuousAutoExposure, "Preview policy must resume after the still capture")
        XCTAssertLessThanOrEqual(restored.activeMaximumExposureSeconds, (1.0 / 30.0) + 0.002)

        for index in 0..<20 { model.smoothPreview = index.isMultiple(of: 2) }
        model.smoothPreview = true
        let finalAssistSnapshot = await awaitExposureState(camera)
        let finalAssist = try XCTUnwrap(finalAssistSnapshot)
        XCTAssertTrue(finalAssist.previewExposureAssistEnabled)
        XCTAssertEqual(finalAssist.exposureMode, .continuousAutoExposure)
        // 已接受的静态请求保留其曝光；用户中途关闭辅助后，收尾必须尊重最新偏好。
        let disabledDuringCaptureDone = expectation(description: "拍摄中关闭预览辅助")
        var disabledDuringCapturePhoto: CapturedPhoto?
        camera.onCaptureCompleted = { disabledDuringCapturePhoto = $0; disabledDuringCaptureDone.fulfill() }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg, resolution: .standard))
        model.smoothPreview = false
        await fulfillment(of: [disabledDuringCaptureDone], timeout: 30)
        let finalPhoto = try XCTUnwrap(disabledDuringCapturePhoto, camera.message ?? "拍摄中关闭辅助后未出片")
        try verifyFileExposure(finalPhoto, iso: 400, seconds: 1.0 / 15.0)
        for _ in 0..<150 {
            let state = await awaitExposureState(camera)
            if let state, !state.previewExposureAssistEnabled, state.exposureMode == .custom,
               abs(Double(state.iso) - 400) < 5, abs(state.seconds - 1.0 / 15.0) < 0.002 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let manualRestoredSnapshot = await awaitExposureState(camera)
        let manualRestored = try XCTUnwrap(manualRestoredSnapshot)
        XCTAssertFalse(manualRestored.previewExposureAssistEnabled)
        XCTAssertEqual(manualRestored.exposureMode, .custom)
        XCTAssertEqual(Double(manualRestored.iso), 400, accuracy: 5)
        XCTAssertEqual(manualRestored.seconds, 1.0 / 15.0, accuracy: 0.002)
        XCTAssertTrue(camera.ready, "Rapid toggles and capture must not stop the camera")
    }

    /// 预览偏好持续开启时切到视频，M 挡真实曝光仍应由视频参数控制；返回照片再恢复短曝光预览。
    @MainActor func testSmoothPreviewRemainsPhotoOnlyAcrossVideoAndLifecycleChanges() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        let callback = camera.onVideoRecorded
        var recorded: Result<URL, Error>?
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onVideoRecorded = { recorded = $0 }
        defer {
            if camera.videoBusy { camera.stopVideoRecording() }
            if case .success(let url) = recorded { try? FileManager.default.removeItem(at: url) }
            camera.onVideoRecorded = callback
            model.smoothPreview = false; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        model.setCameraActive(true)
        try await waitForState(camera) { _ in camera.ready && camera.preview != nil }
        if model.currentPosition != .back { model.flipCamera(); try await waitForState(camera) { _ in camera.ready } }
        model.setMode(.manual)
        try await waitForState(camera) { $0.engineManual && camera.ready }
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0 / 15)
        model.smoothPreview = true; model.applyExposure()
        try await waitForState(camera) { $0.exposureMode == .continuousAutoExposure && $0.previewExposureAssistEnabled }
        model.setCaptureKind(.video); model.setMode(.manual)
        try await waitForState(camera) { $0.engineManual && camera.ready && model.videoShutterEnabled }
        model.iso = 400; model.shutter = log2(1.0 / 125); model.manualExposure = true; model.applyExposure()
        try await waitForState(camera, label: "video-custom-exposure") {
            $0.exposureMode == .custom && abs(Double($0.iso) - 400) < 5 && abs($0.seconds - 1.0 / 125) < 0.001
        }
        XCTAssertTrue(model.smoothPreview, "视频不清除照片预览辅助偏好")
        model.toggleVideoRecording()
        for _ in 0..<200 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.videoRecording)
        let duringSnapshot = await awaitExposureState(camera)
        let during = try XCTUnwrap(duringSnapshot)
        XCTAssertEqual(during.exposureMode, .custom)
        XCTAssertEqual(Double(during.iso), 400, accuracy: 5)
        XCTAssertEqual(during.seconds, 1.0 / 125, accuracy: 0.001)
        print("PREVIEW-ASSIST-VIDEO requestISO=400 requestSeconds=\(1.0 / 125) actualISO=\(during.iso) actualSeconds=\(during.seconds) custom=\(during.exposureMode == .custom)")
        try await Task.sleep(for: .milliseconds(500))
        camera.stopVideoRecording()
        for _ in 0..<250 { if recorded != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        if case .success(let url) = recorded {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            XCTAssertFalse(tracks.isEmpty)
        } else { XCTFail("视频模式实际录制未完成") }
        model.setCaptureKind(.photo)
        try await waitForState(camera) { $0.exposureMode == .continuousAutoExposure && $0.previewExposureAssistEnabled && camera.ready }
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(200))
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running)
        model.setCameraActive(true)
        try await waitForState(camera) { $0.exposureMode == .continuousAutoExposure && $0.previewExposureAssistEnabled && camera.ready }
        model.smoothPreview = false
        try await waitForState(camera) {
            $0.exposureMode == .custom && !$0.previewExposureAssistEnabled
                && abs(Double($0.iso) - 400) < 5 && abs($0.seconds - 1.0 / 15) < 0.002
        }
    }

    /// 显式等待实际硬件状态，不以 UI 记忆的参数代替摄像头当前模式。
    @MainActor private func waitForState(_ camera: CameraEngine, label: String = "preview-state",
                                        predicate: (CameraEngine.ExposureColorState) -> Bool) async throws {
        for _ in 0..<300 {
            if let state = await awaitExposureState(camera), predicate(state) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let final = await awaitExposureState(camera)
        print("PREVIEW-ASSIST-FAILED label=\(label) ready=\(camera.ready) state=\(String(describing: final))")
        XCTFail("预览辅助硬件状态未在 6 秒内达到目标：\(label)")
        throw NSError(domain: "PreviewAssist", code: 1)
    }

    /// 从即将保存的编码资源直接读取 EXIF，不能用应用诊断快照替代系统照片可见的参数。
    private func verifyFileExposure(_ photo: CapturedPhoto, iso: Double, seconds: Double) throws {
        let data = try XCTUnwrap(photo.resources.first?.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let fileISO = try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue)
        let fileSeconds = try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double)
        XCTAssertEqual(fileISO, iso, accuracy: 5)
        XCTAssertEqual(fileSeconds, seconds, accuracy: 0.002)
        print("PREVIEW-ASSIST-FILE EXIF_ISO=\(fileISO) EXIF_ExposureTime=\(fileSeconds) requestedISO=\(iso) requestedSeconds=\(seconds)")
    }

    @MainActor private func awaitExposureState(_ camera: CameraEngine) async -> CameraEngine.ExposureColorState? {
        await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
    }

    @MainActor private func samplePreview(_ camera: CameraEngine, duration: TimeInterval) async throws -> (count: Int, medianMilliseconds: Double) {
        camera.resetPreviewPublicationTimesForTesting()
        try await Task.sleep(for: .seconds(duration))
        let times = camera.previewPublicationTimesForTestingSnapshot
        let intervals = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }.filter { $0.isFinite && $0 > 0 }.sorted()
        return (times.count, intervals.isEmpty ? .nan : intervals[intervals.count / 2])
    }
    #endif
}
