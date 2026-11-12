import XCTest
import Combine
import AVFoundation
import UIKit
@testable import LumaCamera

final class FocusLockModeTests: XCTestCase {
    func testModePreferenceMigratesAndPersistsWithoutChangingOtherPreferences() throws {
        let old = Data("{\"silentShutter\":true,\"recordLocation\":true}".utf8)
        let migrated = try JSONDecoder().decode(CapturePreferences.self, from: old)
        XCTAssertEqual(migrated.focusLockMode, .exposure); XCTAssertTrue(migrated.silentShutter); XCTAssertTrue(migrated.recordLocation)
        for mode in FocusLockMode.allCases {
            var value = migrated; value.focusLockMode = mode
            let decoded = try JSONDecoder().decode(CapturePreferences.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
        }
    }

    func testLockPickerFitsAllPreviewRatiosAndCorners() {
        for ratio in FrameRatio.allCases {
            let size = CGSize(width: min(386, 680 * ratio.portraitRatio), height: min(680, 386 / ratio.portraitRatio))
            for point in [CGPoint(x: 25, y: 25), CGPoint(x: size.width - 25, y: size.height - 25)] {
                let rect = FocusTargetLayout.lockPicker(target: point, viewport: size, topInset: 66)
                XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxX, size.width); XCTAssertLessThanOrEqual(rect.maxY, size.height)
            }
        }
    }

    #if targetEnvironment(simulator)
    @MainActor func testEveryLockModeProtectsTargetAndEVDoesNotReleaseAF() async throws {
        let service = SystemPhotoLibraryService(), camera = CameraEngine()
        let library = PhotoLibraryViewModel(service: service), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = CameraViewModel(camera: camera, library: library, gallery: GalleryViewModel(browser: service, library: library), preferencesStore: CapturePreferencesStore(defaults: defaults))
        camera.start(); defer { camera.stop() }
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        let point = CGPoint(x: 100, y: 150), size = CGSize(width: 300, height: 400)
        for ratio in FrameRatio.photoOptions {
            model.selectRatio(ratio)
            for mode in FocusLockMode.allCases {
                model.preferences.focusLockMode = mode
                model.preferences.exposureLockEnabled = mode.locksExposure
                model.preferences.focusTrackingState = mode == .tracking ? .continuous : (mode.locksFocus ? .locked : .off)
                model.focusPreview(at: point, size: size, lockExposure: true)
                if mode == .tracking {
                    XCTAssertTrue(model.subjectTrackingActive)
                    XCTAssertFalse(camera.targetLockActive)
                    model.endSubjectTracking()
                    continue
                }
                XCTAssertEqual(camera.targetExposureLockActive, mode.locksExposure)
                XCTAssertEqual(camera.targetFocusLockActive, mode.locksFocus)
                XCTAssertTrue(camera.targetLocked)
                model.focusPreview(at: CGPoint(x: 200, y: 220), size: size)
                XCTAssertEqual(model.focusPoint, point)
                model.adjustFocusEV(1)
                XCTAssertEqual(camera.targetFocusLockActive, mode.locksFocus)
                model.toggleFocusLockPicker(); XCTAssertTrue(model.focusLockPickerVisible)
                model.closePopups(); XCTAssertFalse(model.focusLockPickerVisible); XCTAssertTrue(camera.targetLocked)
                model.unlockFocusExposure()
                XCTAssertFalse(camera.targetLockActive); XCTAssertFalse(camera.targetLocked)
            }
        }
        model.preferences.focusLockMode = .focus
        model.preferences.exposureLockEnabled = false
        model.preferences.focusTrackingState = .locked
        model.focusPreview(at: point, size: size, lockExposure: true)
        model.selectFocusLockMode(.exposureAndFocus)
        XCTAssertTrue(camera.targetExposureLockActive); XCTAssertTrue(camera.targetFocusLockActive)
        for open in [{ model.openTools() }, { model.openFunctions() }, { model.openParameter(.iso) }, { model.toggleToolbarPanel(.ratio) }, { model.togglePanel(.film) }, { model.openZoomDial() }] {
            model.closePopups(); model.toggleFocusLockPicker(); XCTAssertTrue(model.focusLockPickerVisible)
            open(); XCTAssertFalse(model.focusLockPickerVisible)
        }
        model.cancelFocus(); XCTAssertFalse(camera.targetLockActive); XCTAssertNil(model.focusPoint)
    }
    @MainActor func testFirstReadyFrameLockSurvivesDeferredForegroundRestoration() async throws {
        let service = SystemPhotoLibraryService(), camera = CameraEngine()
        let library = PhotoLibraryViewModel(service: service), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = CameraViewModel(camera: camera, library: library, gallery: GalleryViewModel(browser: service, library: library), preferencesStore: CapturePreferencesStore(defaults: defaults))
        model.preferences.focusLockMode = .exposureAndFocus
        model.preferences.exposureLockEnabled = true
        model.preferences.focusTrackingState = .locked
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.focusPreview(at: CGPoint(x: 150, y: 200), size: CGSize(width: 300, height: 400), lockExposure: true)
        // Run the deferred restoration after a new user target, independent of event-loop timing.
        model.restoreDeviceParametersForTesting()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(camera.targetLocked)
        XCTAssertTrue(camera.targetFocusLocked); XCTAssertTrue(camera.targetExposureLocked)
    }
    #else
    @MainActor func testPhysicalAEAFAndCombinedLockWithEVAndManualExposureWithoutPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, preference = model.preferences.focusLockMode
        let aePreference = model.preferences.exposureLockEnabled
        let trackingPreference = model.preferences.focusTrackingState, ev = model.ev
        let manual = model.manualExposure, iso = model.iso, shutter = model.shutter
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.cancelFocus(); model.preferences.focusLockMode = preference
            model.preferences.exposureLockEnabled = aePreference
            model.preferences.focusTrackingState = trackingPreference
            model.setMode(mode); model.ev = ev; model.iso = iso; model.shutter = shutter; model.manualExposure = manual; model.applyExposure()
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.setMode(.auto)
        try await Task.sleep(for: .seconds(2))
        // A tap remains continuous AF, so a near target cannot strand single-shot AF.
        model.cancelFocus()
        model.focusPreview(at: CGPoint(x: 150, y: 200), size: CGSize(width: 300, height: 400))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let tapped = await state(camera)
        XCTAssertEqual(tapped?.focusMode, .continuousAutoFocus)
        for mode in FocusLockMode.allCases {
            model.cancelFocus()
            // A new focus always starts as the default AE-only lock; switch to
            // the target mode through the same path as the AF picker.
            model.focusPreview(at: CGPoint(x: 150, y: 200), size: CGSize(width: 300, height: 400), lockExposure: true)
            for _ in 0..<120 { if camera.targetLocked { break }; try await Task.sleep(for: .milliseconds(30)) }
            model.selectFocusLockMode(mode)
            if mode == .tracking {
                XCTAssertTrue(model.subjectTrackingActive)
                XCTAssertFalse(camera.targetLockActive)
                model.endSubjectTracking()
                continue
            }
            for _ in 0..<120 { if camera.targetLocked { break }; try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertTrue(camera.targetLocked, mode.rawValue)
            let snapshot = await state(camera)
            let state = try XCTUnwrap(snapshot)
            XCTAssertEqual(state.exposureMode == .locked, mode.locksExposure)
            if mode.locksFocus { XCTAssertEqual(state.focusMode, .locked) }
            else { XCTAssertEqual(state.focusMode, .continuousAutoFocus) }
            model.adjustFocusEV(model.ev < 0.5 ? 1 : 0)
            for _ in 0..<120 { if camera.targetLocked { break }; try await Task.sleep(for: .milliseconds(30)) }
            let evSnapshot = await self.state(camera)
            let afterEV = try XCTUnwrap(evSnapshot)
            if mode.locksFocus { XCTAssertEqual(afterEV.focusMode, .locked) }
            model.unlockFocusExposure()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertFalse(camera.targetLockActive)
        }
        model.setMode(.manual)
        try await Task.sleep(for: .seconds(2))
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0 / 125); model.applyExposure()
        try await Task.sleep(for: .milliseconds(500))
        model.focusPreview(at: CGPoint(x: 150, y: 200), size: CGSize(width: 300, height: 400), lockExposure: true)
        for _ in 0..<120 { if camera.targetLocked { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.selectFocusLockMode(.exposureAndFocus)
        // Editing exposure before the settling callback must not orphan the pending AF lock.
        model.iso = 800; model.shutter = log2(1.0 / 250); model.applyExposure()
        for _ in 0..<120 { if camera.targetLocked { break }; try await Task.sleep(for: .milliseconds(30)) }
        // setExposureModeCustom completes asynchronously after the session-queue write.
        // AF can settle first; verify the actual requested exposure instead of sampling too early.
        var manualSnapshot = await state(camera)
        for _ in 0..<100 {
            if let actual = manualSnapshot, abs(Double(actual.iso) - 800) < 5, abs(actual.seconds - 1.0 / 250) < 0.001 { break }
            try await Task.sleep(for: .milliseconds(30))
            manualSnapshot = await state(camera)
        }
        let manualState = try XCTUnwrap(manualSnapshot)
        XCTAssertEqual(Double(manualState.requestedISO ?? 0), 800, accuracy: 5)
        XCTAssertTrue(camera.targetLocked)
        XCTAssertEqual(manualState.exposureMode, .custom)
        XCTAssertEqual(Double(manualState.iso), 800, accuracy: 5)
        XCTAssertEqual(manualState.seconds, 1.0 / 250, accuracy: 0.001)
        XCTAssertEqual(manualState.focusMode, .locked)
    }
    @MainActor private func state(_ camera: CameraEngine) async -> CameraEngine.ExposureColorState? {
        await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
    }
    #endif
}
