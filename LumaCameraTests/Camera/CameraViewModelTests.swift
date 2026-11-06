import XCTest
import Combine
@testable import LumaCamera

final class CameraViewModelTests: XCTestCase {
    @MainActor
    func testVideoModeReturnsToPhotoRatioAndRememberedManualSettings() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualExposure = true
        model.iso = 640
        model.ratio = .standard
        model.setCaptureKind(.video)
        XCTAssertEqual(model.captureKind, .video)
        XCTAssertEqual(model.mode, .auto)
        XCTAssertEqual(model.ratio, .wide)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original)
        model.setCaptureKind(.photo)
        XCTAssertEqual(model.captureKind, .photo)
        XCTAssertEqual(model.mode, .manual)
        XCTAssertEqual(model.ratio, .standard)
        XCTAssertTrue(model.manualExposure)
        XCTAssertEqual(model.iso, 640)
    }
    @MainActor
    func testManualValuesAndSwitchesRestoreAfterAutomaticMode() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.iso = 640; model.shutter = log2(1.0 / 30)
        model.wb = 4200; model.whiteBalanceTint = -23; model.focus = 0.72; model.ev = -0.7
        model.manualExposure = true; model.manualWB = true; model.manualFocus = true
        for _ in 0..<3 {
            model.setMode(.auto)
            XCTAssertFalse(model.manualExposure)
            XCTAssertFalse(model.manualWB)
            XCTAssertFalse(model.manualFocus)
            model.ev = 1.2 // A-mode compensation must not overwrite M-mode settings.
            model.setMode(.manual)
            XCTAssertEqual(model.iso, 640)
            XCTAssertEqual(model.shutter, log2(1.0 / 30))
            XCTAssertEqual(model.whiteBalanceTint, -23)
            XCTAssertTrue(model.parameterIsManual(.tint))
            XCTAssertEqual(model.wb, 4200)
            XCTAssertEqual(model.focus, 0.72)
            XCTAssertEqual(model.ev, -0.7)
            XCTAssertTrue(model.parameterIsManual(.iso))
            XCTAssertTrue(model.parameterIsManual(.shutter))
            XCTAssertTrue(model.parameterIsManual(.wb))
            XCTAssertTrue(model.parameterIsManual(.focus))
        }
        model.setMode(.auto)
        XCTAssertEqual(model.ev, 1.2)
    }

    @MainActor
    func testChangingRememberedManualParameterToAutoReplacesItsSavedState() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualExposure = true; model.manualWB = true; model.manualFocus = true
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertTrue(model.manualExposure)
        model.parameter = .iso; model.activateParameterAuto()
        model.parameter = .wb; model.activateParameterAuto()
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertFalse(model.parameterIsManual(.iso))
        XCTAssertFalse(model.parameterIsManual(.shutter))
        XCTAssertFalse(model.parameterIsManual(.wb))
        XCTAssertTrue(model.parameterIsManual(.focus))
        model.focus = 0.3
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertEqual(model.focus, 0.3)
    }

    @MainActor
    func testExposureAutoSelectionSurvivesRepeatedModeSwitches() {
        for parameter in [CameraParameter.shutter, .iso] {
            let model = AppDependencies.makeCameraModel(automaticallySave: false)
            model.mode = .manual
            model.manualExposure = true
            model.iso = 640
            model.shutter = log2(1.0 / 30)
            model.parameter = parameter
            model.activateParameterAuto()
            for _ in 0..<3 {
                model.setMode(.auto)
                model.setMode(.manual)
                XCTAssertTrue(model.parameterAutomatic)
                XCTAssertFalse(model.parameterIsManual(.shutter))
                XCTAssertFalse(model.parameterIsManual(.iso))
                XCTAssertFalse(model.manualExposure)
            }
            // Values can remain for the next explicit adjustment without making their controls manual.
            XCTAssertEqual(model.iso, 640)
            XCTAssertEqual(model.shutter, log2(1.0 / 30))
        }
    }

    @MainActor
    func testEnteringManualModeDoesNotOverrideAutomaticWhiteBalanceOrFocus() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualWB = true; model.manualFocus = true
        model.parameter = .wb; model.activateParameterAuto()
        model.parameter = .focus; model.activateParameterAuto()
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertFalse(model.parameterIsManual(.wb))
        XCTAssertFalse(model.parameterIsManual(.focus))
        model.resetParameters()
        XCTAssertFalse(model.manualExposure)
        XCTAssertFalse(model.manualWB)
        XCTAssertFalse(model.manualFocus)
    }

    @MainActor
    func testManualParameterIndicatorsTrackEachIndependentAutomaticSwitch() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualExposure = true; model.manualWB = false; model.manualFocus = true
        XCTAssertTrue(model.parameterIsManual(.shutter))
        XCTAssertTrue(model.parameterIsManual(.iso))
        XCTAssertFalse(model.parameterIsManual(.wb))
        XCTAssertTrue(model.parameterIsManual(.focus))
        XCTAssertFalse(model.parameterIsManual(.ev))
        model.parameter = .focus; model.activateParameterAuto()
        XCTAssertFalse(model.parameterIsManual(.focus))
        model.mode = .auto
        XCTAssertFalse(model.parameterIsManual(.iso))
    }

    @MainActor
    func testSwitchToAutomaticResetsManualControlsAndClosesPanel() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.manualExposure = true
        model.manualWB = true
        model.manualFocus = true
        model.panel = .manual
        model.setMode(.auto)
        XCTAssertEqual(model.mode, .auto)
        XCTAssertFalse(model.manualExposure)
        XCTAssertFalse(model.manualWB)
        XCTAssertFalse(model.manualFocus)
        XCTAssertNil(model.panel)
    }

    @MainActor
    func testOpeningToolsReplacesOtherPanels() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.togglePanel(.film)
        XCTAssertEqual(model.panel, .film)
        model.openFunctions()
        XCTAssertTrue(model.functions)
        XCTAssertNil(model.panel)
        model.openTools()
        XCTAssertTrue(model.tools)
        XCTAssertFalse(model.functions)
        model.closePopups()
        XCTAssertFalse(model.popupVisible)
    }

    @MainActor
    func testPagerUpdateDefersPublicationAndIgnoresObsoleteSelection() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.updateToolPageFromPager(1)
        XCTAssertEqual(model.toolPage, 0)
        model.updateToolPageFromPager(0)
        let flushed = expectation(description: "Pager queue drained")
        DispatchQueue.main.async { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        XCTAssertEqual(model.toolPage, 0)
        let updated = expectation(description: "Pager selection changed")
        let subscription = model.$toolPage.filter { $0 == 1 }.first().sink { _ in updated.fulfill() }
        model.updateToolPageFromPager(1)
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(model.toolPage, 1)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testManualSettingsSurviveSwitchingPhysicalLensAndModeRoundTrip() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.iso = 640; model.shutter = log2(1.0 / 30)
        model.wb = 4200; model.whiteBalanceTint = -23; model.focus = 0.72; model.ev = -0.7
        model.manualExposure = true; model.manualWB = true; model.manualFocus = true
        for id in ["wide", "telephoto", "ultrawide", "wide"] {
            model.didChangeLensDevice(id, isoRange: 25...1600, shutterRange: -12...0)
            XCTAssertEqual(model.mode, .manual)
            XCTAssertEqual(model.iso, 640)
            XCTAssertEqual(model.shutter, log2(1.0 / 30))
            XCTAssertEqual(model.whiteBalanceTint, -23)
            XCTAssertTrue(model.parameterIsManual(.tint))
            XCTAssertEqual(model.wb, 4200); XCTAssertEqual(model.focus, 0.72); XCTAssertEqual(model.ev, -0.7)
            XCTAssertTrue(model.parameterIsManual(.iso))
            XCTAssertTrue(model.parameterIsManual(.shutter))
            XCTAssertTrue(model.parameterIsManual(.wb))
            XCTAssertTrue(model.parameterIsManual(.focus))
        }
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertEqual(model.iso, 640)
        XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualWB); XCTAssertTrue(model.manualFocus)
    }

    @MainActor
    func testLensChangeClampsExposureWithoutResettingManualChoicesOrEV() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.iso = 3200; model.shutter = log2(2)
        model.wb = 5300; model.focus = 0.4; model.ev = 1.3
        model.manualExposure = true; model.manualWB = true; model.manualFocus = false
        model.didChangeLensDevice("telephoto", isoRange: 50...1200, shutterRange: -12 ... -1)
        XCTAssertEqual(model.iso, 1200); XCTAssertEqual(model.shutter, -1)
        XCTAssertEqual(model.wb, 5300); XCTAssertEqual(model.focus, 0.4); XCTAssertEqual(model.ev, 1.3)
        XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualWB); XCTAssertFalse(model.manualFocus)
        model.iso = 10; model.shutter = -20
        model.didChangeLensDevice("ultrawide", isoRange: 80...1000, shutterRange: -10...0)
        XCTAssertEqual(model.iso, 80); XCTAssertEqual(model.shutter, -10)
        XCTAssertTrue(model.manualExposure)
    }

    @MainActor
    func testMixedAutomaticChoicesSurviveRepeatedLensChanges() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualExposure = true; model.manualWB = true; model.manualFocus = true
        model.parameter = .iso; model.activateParameterAuto()
        model.parameter = .focus; model.activateParameterAuto()
        model.ev = -1.7; model.wb = 4700
        for i in 0..<500 {
            model.didChangeLensDevice("lens-\(i % 3)", isoRange: 25...1600, shutterRange: -12...0)
            XCTAssertFalse(model.manualExposure); XCTAssertFalse(model.manualFocus)
            XCTAssertTrue(model.manualWB)
            XCTAssertEqual(model.ev, -1.7); XCTAssertEqual(model.wb, 4700)
        }
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertFalse(model.manualExposure); XCTAssertFalse(model.manualFocus); XCTAssertTrue(model.manualWB)
    }

    @MainActor
    func testEVSliderDefersPublicationCoalescesAndDropsObsoleteModeWrites() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        var values: [Double] = []
        let token = model.$ev.dropFirst().sink { values.append($0) }
        model.updateAutomaticEVFromSlider(model.ev)
        XCTAssertTrue(values.isEmpty)
        model.updateAutomaticEVFromSlider(.nan)
        model.updateAutomaticEVFromSlider(.infinity)
        model.updateAutomaticEVFromSlider(1)
        model.updateAutomaticEVFromSlider(1.5)
        XCTAssertTrue(values.isEmpty)
        let first = expectation(description: "Slider update deferred")
        DispatchQueue.main.async { first.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(values, [1.5])
        model.updateAutomaticEVFromSlider(2)
        model.setMode(.manual)
        let manualEV = model.ev
        let second = expectation(description: "Obsolete slider update ignored")
        DispatchQueue.main.async { second.fulfill() }
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(model.ev, manualEV)
        token.cancel()
    }

    #if targetEnvironment(simulator)
    @MainActor
    func testLifecycleStartDefersPublishedChangesUntilAfterCallback() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Deferred camera start")
        let subscription = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.setCameraActive(true)
        XCTAssertFalse(model.camera.demo)
        XCTAssertFalse(model.camera.ready)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertTrue(model.camera.demo)
        model.camera.stop()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testObsoleteLifecycleStartDoesNotRunAfterDisappearance() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.countdown = 3
        model.setCameraActive(true)
        model.setCameraActive(false)
        XCTAssertEqual(model.countdown, 3)
        let flushed = expectation(description: "Lifecycle queue drained")
        DispatchQueue.main.async { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        XCTAssertFalse(model.camera.demo)
        XCTAssertFalse(model.camera.ready)
        XCTAssertNil(model.countdown)
    }

    @MainActor
    func testCancelledCountdownNeverCapturesPhoto() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Demo ready")
        let subscription = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        model.timerSeconds = 1
        model.takePhoto()
        XCTAssertEqual(model.countdown, 1)
        model.takePhoto()
        XCTAssertNil(model.countdown)
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertNil(model.library.lastPhoto)
        XCTAssertFalse(model.camera.capturing)
        model.camera.stop()
        withExtendedLifetime(subscription) {}
    }
    #endif
    @MainActor
    func testTintClampingInvalidValuesAndSharedAutomaticState() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.mode = .manual
        model.manualWB = true
        model.parameter = .tint
        model.parameterBinding.wrappedValue = 200
        XCTAssertEqual(model.whiteBalanceTint, 150)
        model.parameterBinding.wrappedValue = -200
        XCTAssertEqual(model.whiteBalanceTint, -150)
        model.parameterBinding.wrappedValue = .nan
        XCTAssertEqual(model.whiteBalanceTint, -150)
        model.activateParameterAuto()
        model.setMode(.auto); model.setMode(.manual)
        XCTAssertFalse(model.parameterIsManual(.tint))
        XCTAssertFalse(model.parameterIsManual(.wb))
    }
}
