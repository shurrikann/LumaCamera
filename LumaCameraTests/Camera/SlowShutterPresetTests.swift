import XCTest
import UIKit
@testable import LumaCamera

final class SlowShutterPresetTests: XCTestCase {
    /// 真实会话核对五种预设往返、通用时长、取消预设及快速切挡后的状态和恢复耗时。
    @MainActor func testSlowShutterModeRoundTripRestoresAutomaticPresetAndResetsManualDuration() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真机会话恢复与过渡检查")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCaptureKind(.photo); model.setMode(.auto)
        model.setCameraActive(true)
        func settled() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<400 {
                if camera.ready && !model.isPreparingSubmode && model.focalTransitionImage == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready); XCTAssertNotNil(camera.preview)
            XCTAssertFalse(model.isPreparingSubmode); XCTAssertNil(model.focalTransitionImage)
        }
        try await settled()
        if !model.slowShutterEnabled { model.toggleSlowShutterMode() }
        try await settled()
        XCTAssertTrue(model.slowShutterEnabled)
        var latencies: [Double] = []
        for preset in SlowShutterPreset.allCases {
            model.selectSlowShutterPreset(preset)
            XCTAssertEqual(model.selectedSlowShutterPreset, preset)
            let duration = try XCTUnwrap(model.availableSlowShutterDurations.last)
            model.selectSlowShutterDuration(duration)
            let start = CACurrentMediaTime()
            model.setMode(.manual); try await settled()
            XCTAssertNil(model.selectedSlowShutterPreset)
            XCTAssertEqual(model.slowShutterDuration, .s1)
            model.selectSlowShutterDuration(.s3)
            model.setMode(.manual) // 同挡位调用不重置用户刚设置的时长。
            XCTAssertEqual(model.slowShutterDuration, .s3)
            model.setMode(.auto); try await settled()
            XCTAssertEqual(model.selectedSlowShutterPreset, preset)
            XCTAssertEqual(model.slowShutterDuration, duration)
            latencies.append(CACurrentMediaTime() - start)
        }
        model.selectSlowShutterPreset(.starTrails) // 取消当前预设，不应再被 M→A 复活。
        XCTAssertNil(model.selectedSlowShutterPreset)
        model.selectSlowShutterDuration(.s5)
        model.setMode(.manual); try await settled()
        XCTAssertEqual(model.slowShutterDuration, .s1)
        model.selectSlowShutterDuration(.s3)
        model.setMode(.auto); try await settled()
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertEqual(model.slowShutterDuration, .s1)
        model.selectSlowShutterPreset(.lightTrails)
        for _ in 0..<10 { model.setMode(.manual); model.setMode(.auto) }
        try await settled()
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
        XCTAssertEqual(model.slowShutterDuration, .s15)
        model.toggleSlowShutterMode(); model.toggleSlowShutterMode()
        try await settled()
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertEqual(model.slowShutterDuration, .s1)
        XCTAssertEqual(camera.pendingPhotoCount, 0)
        print("SLOW-AM-RESTORE presets=5 roundTripConfigurationSeconds=\(latencies) rapidRoundTrips=10 cancelledPreset=cleared reentry=1s pending=0; includes queue/overlay wait, not screen FPS")
        #endif
    }

    func testPresetRangesAndSuggestionsAreValidAndClampToHardware() throws {
        let cameraShutter = log2(1.0 / 16.0)...log2(1.0)
        let cameraISO = 32.0...12000.0

        XCTAssertEqual(SlowShutterPreset.allCases.count, 5)
        for preset in SlowShutterPreset.allCases {
            XCTAssertLessThan(preset.shutterSeconds.lowerBound, preset.shutterSeconds.upperBound)
            XCTAssertTrue(preset.shutterSeconds.contains(preset.suggestedShutterSeconds))
            XCTAssertTrue(preset.suggestedISORange.contains(preset.suggestedISO))

            let shutterRange = try XCTUnwrap(preset.shutterRange(limitedTo: cameraShutter))
            let isoRange = try XCTUnwrap(preset.isoRange(limitedTo: cameraISO))
            XCTAssertGreaterThanOrEqual(shutterRange.lowerBound, cameraShutter.lowerBound)
            XCTAssertLessThanOrEqual(shutterRange.upperBound, cameraShutter.upperBound)
            XCTAssertGreaterThanOrEqual(isoRange.lowerBound, cameraISO.lowerBound)
            XCTAssertLessThanOrEqual(isoRange.upperBound, cameraISO.upperBound)
        }
    }

    func testPresetIsUnsupportedWhenHardwareCannotFitIt() {
        let shortShutter = log2(1.0 / 500.0)...log2(1.0 / 10.0)
        let iso = 50.0...800.0
        // 自适应在较亮环境允许短快门，星轨不再因不能单帧曝光半秒而禁用。
        XCTAssertNotNil(SlowShutterPreset.starTrails.shutterRange(limitedTo: shortShutter))
        XCTAssertTrue(SlowShutterPreset.starTrails.supports(hardwareShutter: shortShutter, hardwareISO: iso))
        XCTAssertTrue(SlowShutterPreset.panning.supports(hardwareShutter: shortShutter, hardwareISO: iso))
        XCTAssertEqual(SlowShutterPreset.panning.shutterSeconds.lowerBound, 0.000001, accuracy: 0.0000001)
        XCTAssertFalse(SlowShutterPreset.panning.supports(hardwareShutter:log2(0.5)...0,hardwareISO:iso))
    }

    @MainActor func testMKeepsSlowModeButClearsAndHidesPreset() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        #endif
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<750 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route")
        model.setMode(.manual)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        model.toggleSlowShutterMode()
        for _ in 0..<500 {
            if model.slowShutterEnabled && !model.isPreparingSubmode && model.camera.ready { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(model.slowShutterEnabled)
        XCTAssertEqual(model.mode, .auto)
        model.selectSlowShutterPreset(.lightTrails)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
        model.setMode(.manual)
        XCTAssertTrue(model.slowShutterEnabled)
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertEqual(model.mode, .manual)
        model.setMode(.auto)
        XCTAssertTrue(model.slowShutterEnabled)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
    }

    @MainActor func testMShutterSliderUsesHardwareRangeAfterClearingAutomaticPreset() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<750 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route")
        model.toggleSlowShutterMode()
        try XCTSkipUnless(model.slowShutterEnabled, "Slow shutter unavailable")
        model.selectSlowShutterPreset(.panning)
        XCTAssertEqual(model.selectedSlowShutterPreset, .panning)
        model.setMode(.manual)
        model.parameter = .shutter
        XCTAssertNil(model.selectedSlowShutterPreset,"M挡按现有产品规则清除并隐藏自动预设")
        XCTAssertEqual(model.parameterRange.lowerBound, model.camera.shutterRange.lowerBound, accuracy: 0.0001)
        XCTAssertEqual(model.parameterRange.upperBound, model.camera.shutterRange.upperBound, accuracy: 0.0001)
    }

    @MainActor func testSelectingSamePresetAgainTurnsItOff() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<750 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route")
        model.toggleSlowShutterMode()
        try XCTSkipUnless(model.slowShutterEnabled, "Slow shutter unavailable")
        model.selectSlowShutterPreset(.lightTrails)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
        model.selectSlowShutterPreset(.lightTrails)
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertTrue(model.slowShutterEnabled)
    }

    func testManualISORangeUsesPresetSuggestionAndHardwareIntersection() {
        let hardware = 32.0...12000.0
        XCTAssertEqual(SlowShutterPreset.silkyWater.manualISORange(limitedTo: hardware), 50...200)
        XCTAssertEqual(SlowShutterPreset.starTrails.manualISORange(limitedTo: hardware), 100...800)
        XCTAssertEqual(SlowShutterPreset.panning.manualISORange(limitedTo: 32.0...400.0), 50...400)
    }

    func testPreviewOptimizationOnlyActivatesWhenSlowShutterWouldExceedPreviewCadence() {
        XCTAssertFalse(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: 1.0 / 60.0, presetMaximumSeconds: 1.0))
        XCTAssertFalse(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: 1.0 / 30.0, presetMaximumSeconds: 1.0))
        XCTAssertFalse(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: 1.0 / 15.0, presetMaximumSeconds: 1.0 / 30.0))
        XCTAssertTrue(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: 1.0 / 15.0, presetMaximumSeconds: 1.0 / 15.0))
        XCTAssertTrue(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: 1.0 / 15.0, presetMaximumSeconds: 1.0))
        XCTAssertFalse(SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
            currentExposureSeconds: .infinity, presetMaximumSeconds: 1.0))
        XCTAssertFalse(SlowShutterPreviewPolicy.manualExposureNeedsAssist(
            slowShutterEnabled: false, requestedExposureSeconds: 1.0 / 8.0))
        XCTAssertFalse(SlowShutterPreviewPolicy.manualExposureNeedsAssist(
            slowShutterEnabled: true, requestedExposureSeconds: 1.0 / 30.0))
        XCTAssertTrue(SlowShutterPreviewPolicy.manualExposureNeedsAssist(
            slowShutterEnabled: true, requestedExposureSeconds: 1.0 / 15.0))
        XCTAssertTrue(SlowShutterPreviewPolicy.manualExposureNeedsAssist(
            slowShutterEnabled: true, requestedExposureSeconds: 1.0 / 8.0))
    }

    func testLongPresetNamesUseTwoLinesAndShortNamesRemainSingleLine() {
        XCTAssertEqual(SlowShutterPreset.motionBlur.title.split(separator: "\n").count, 2)
        XCTAssertEqual(SlowShutterPreset.panning.title.split(separator: "\n").count, 2)
        XCTAssertFalse(SlowShutterPreset.lightTrails.title.contains("\n"))
        XCTAssertFalse(SlowShutterPreset.silkyWater.title.contains("\n"))
        XCTAssertFalse(SlowShutterPreset.starTrails.title.contains("\n"))
    }

    func testPresetCellsAlignWithFiveLensButtonSlots() {
        for width in [220.0, 280.0, 340.0, 390.0] {
            let presetWidth = SlowShutterPresetLayout.buttonWidth(availableWidth: width)
            let focalWidth = CameraLensBarLayout.buttonWidth(availableWidth: width, count: 5)
            XCTAssertEqual(presetWidth, Double(focalWidth), accuracy: 0.001)
        }
    }

    @MainActor
    func testSelectingPresetsConstrainsManualExposureAndRepeatedTogglingClearsState() throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route; range/support logic is covered above")
        model.mode = .manual

        for _ in 0..<6 {
            model.toggleSlowShutterMode()
            XCTAssertTrue(model.slowShutterEnabled)
            for preset in SlowShutterPreset.allCases {
                model.selectSlowShutterPreset(preset)
                XCTAssertEqual(model.selectedSlowShutterPreset, preset)
                XCTAssertFalse(model.manualExposure, "选择预设保留M挡自动曝光状态")
                XCTAssertEqual(model.parameter, .shutter)
                XCTAssertTrue(model.slowShutterShutterRange.contains(model.shutter))
                XCTAssertTrue(model.slowShutterISORange.contains(model.iso))
            }
            model.toggleSlowShutterMode()
            XCTAssertFalse(model.slowShutterEnabled)
            XCTAssertNil(model.selectedSlowShutterPreset)
            XCTAssertEqual(model.slowShutterShutterRange, model.camera.shutterRange)
            XCTAssertEqual(model.slowShutterISORange, model.camera.isoRange)
        }
    }

    @MainActor
    func testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice() async throws {
        // 预设已迁到顶部；仍核对焦段固定，但不再要求与底部焦段逐槽对齐。
        try await PresetToolbarChecks.slow(test: self, extended: true)
    }

    @MainActor
    func testAutomaticModeKeepsApertureModeAndPresetOnlyCapsAutomaticExposure() throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route; A-mode cap policy is covered by the model tests")
        XCTAssertEqual(model.mode, .auto)
        model.toggleSlowShutterMode()
        model.selectSlowShutterPreset(.lightTrails)
        XCTAssertEqual(model.mode, .auto)
        XCTAssertFalse(model.manualExposure)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)

        model.toggleSlowShutterMode()
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertEqual(model.mode, .auto)
    }

    @MainActor
    func testSlowShutterAllowsSwitchingRearLenses() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the app's live rear camera routes")
        #else
        // 先清理上一用例的媒体/子模块状态，避免未成功开启慢门就误报切镜丢失。
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let previousKind = model.captureKind
        let previousEnabled = model.slowShutterEnabled
        let previousPreset = model.selectedSlowShutterPreset
        let previousLensID = camera.selectedLens
        defer {
            if camera.selectedLens != previousLensID,
               let previousLens = camera.lenses.first(where: { $0.id == previousLensID }) {
                model.selectFocalLength(previousLens)
            }
            if model.slowShutterEnabled != previousEnabled { model.toggleSlowShutterMode() }
            if previousEnabled, let previousPreset { model.selectSlowShutterPreset(previousPreset) }
            if model.captureKind != previousKind { model.setCaptureKind(previousKind) }
        }
        model.setCaptureKind(.photo)
        if !camera.ready { model.setCameraActive(true) }
        let readyDeadline = CACurrentMediaTime() + 15
        while !camera.ready, CACurrentMediaTime() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard camera.ready else { XCTFail("Live camera did not become ready"); return }
        if !model.slowShutterEnabled { model.toggleSlowShutterMode() }
        for _ in 0..<500 {
            if model.slowShutterEnabled && model.photoSubmodePreparing == nil && camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.slowShutterEnabled, camera.message ?? "慢门必须实际启用")
        model.selectSlowShutterPreset(.lightTrails)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
        let rear = camera.lenses.filter { $0.device.position == .back }
        guard rear.count >= 2 else { throw XCTSkip("Need at least two rear focal slots") }
        let original = try XCTUnwrap(rear.first(where: { $0.id == camera.selectedLens }))
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        var latencies: [Double] = []
        // A 挡虚拟多摄和 M 挡物理输入都走真实切镜；等待新路由帧，避免只读到提前发布的 selectedLens。
        for mode in [CameraShootingMode.auto] {
            model.setMode(mode)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<500 {
                if camera.ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            for preset in [SlowShutterPreset.lightTrails, .silkyWater] {
                if model.selectedSlowShutterPreset != preset { model.selectSlowShutterPreset(preset) }
                XCTAssertEqual(model.selectedSlowShutterPreset, preset)
                for target in rear + [original] {
                    guard camera.selectedLens != target.id else { continue }
                    XCTAssertTrue(model.canSelectFocalLength(target))
                    let frame = camera.userSwitchFrameID, began = CACurrentMediaTime()
                    model.selectFocalLength(target)
                    for _ in 0..<500 {
                        if camera.selectedLens == target.id && camera.ready && camera.userSwitchFrameID != frame { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    latencies.append(CACurrentMediaTime() - began)
                    // 给异步能力回报留出一次调度，检查最终状态，而不是瞬时保留值。
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(camera.selectedLens, target.id)
                    XCTAssertNotEqual(camera.userSwitchFrameID, frame)
                    XCTAssertTrue(camera.ready)
                    XCTAssertTrue(model.slowShutterEnabled)
                    XCTAssertEqual(model.selectedSlowShutterPreset, preset)
                    XCTAssertEqual(model.mode, mode)
                }
            }
        }
        // A/M 独立：M 默认 1s，无预设；回 A 恢复此前选择的流水预设。
        model.setMode(.manual)
        XCTAssertTrue(model.slowShutterEnabled); XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertEqual(model.slowShutterDuration, .s1)
        model.setMode(.auto)
        XCTAssertTrue(model.slowShutterEnabled); XCTAssertEqual(model.selectedSlowShutterPreset, .silkyWater)
        // 结束模式再重进时不沿用旧预设；只有真实切镜需要保持当前已选预设。
        model.toggleSlowShutterMode()
        XCTAssertFalse(model.slowShutterEnabled)
        XCTAssertNil(model.selectedSlowShutterPreset)
        model.toggleSlowShutterMode()
        XCTAssertTrue(model.slowShutterEnabled)
        XCTAssertNil(model.selectedSlowShutterPreset)
        print("PRESET-LENS samples=\(latencies.count) seconds=\(latencies) modes=A,M presets=lightTrails,silkyWater noPhotosWrites=true; invocation-to-fresh-route-publication with 20ms polling, not display FPS")
        #endif
    }
}
