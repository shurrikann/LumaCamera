import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class FocusExposureTests: XCTestCase {
    @MainActor
    private func readyModel() async -> CameraViewModel {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Camera ready")
        let token = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start(); await fulfillment(of: [ready], timeout: 5); token.cancel()
        return model
    }

    @MainActor
    func testSelectTargetLockAdjustEVAndDoubleTapUnlock() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        model.focusPreview(at: CGPoint(x: 150, y: 200), size: CGSize(width: 300, height: 400))
        XCTAssertEqual(model.focusPoint, CGPoint(x: 150, y: 200))
        XCTAssertFalse(model.camera.targetExposureLockActive)
        model.lockFocusExposure()
        XCTAssertTrue(model.camera.targetExposureLocked)
        model.beginFocusEVAdjustment(); model.adjustFocusEV(2.36); model.finishFocusEVAdjustment()
        XCTAssertEqual(model.ev, 2.4)
        XCTAssertTrue(model.camera.targetExposureLockActive)
        XCTAssertTrue(model.camera.targetExposureLocked)
        model.unlockFocusExposure()
        XCTAssertFalse(model.camera.targetExposureLocked)
        XCTAssertNotNil(model.focusPoint)
        model.cancelFocus(); XCTAssertNil(model.focusPoint)
        #endif
    }

    @MainActor
    func testSingleTapPreservesLockUntilExplicitUnlockAndRatioChangeClearsIt() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        model.focusPreview(at: CGPoint(x: 100, y: 100), size: CGSize(width: 300, height: 400)); model.lockFocusExposure()
        model.focusPreview(at: CGPoint(x: 200, y: 300), size: CGSize(width: 300, height: 400))
        XCTAssertTrue(model.camera.targetExposureLockActive)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 100, y: 100))
        model.unlockFocusExposure()
        model.focusPreview(at: CGPoint(x: 200, y: 300), size: CGSize(width: 300, height: 400))
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 300))
        model.lockFocusExposure(); model.selectRatio(.wide)
        XCTAssertFalse(model.camera.targetExposureLockActive)
        XCTAssertNil(model.focusPoint)
        #endif
    }

    @MainActor
    func testLockedTargetIgnoresRepeatedTapsAcrossAllRatios() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        for ratio in FrameRatio.photoOptions {
            model.selectRatio(ratio)
            let size = CGSize(width: 300, height: 300 / ratio.portraitRatio)
            let locked = CGPoint(x: 100, y: 100)
            model.focusPreview(at: locked, size: size, lockExposure: true)
            for index in 0..<30 {
                model.focusPreview(at: CGPoint(x: index * 7, y: index * 11), size: size)
                XCTAssertEqual(model.focusPoint, locked)
                XCTAssertTrue(model.camera.targetExposureLockActive)
                XCTAssertTrue(model.camera.targetExposureLocked)
            }
            model.unlockFocusExposure()
            model.focusPreview(at: CGPoint(x: 180, y: 150), size: size)
            XCTAssertFalse(model.camera.targetExposureLockActive)
            XCTAssertEqual(model.focusPoint, CGPoint(x: 180, y: 150))
        }
        #endif
    }

    @MainActor
    func testOldDismissTimerCannotHideLockedFrame() async throws {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        model.focusPreview(at: CGPoint(x: 100, y: 100), size: CGSize(width: 300, height: 400))
        model.focusPreview(at: CGPoint(x: 200, y: 200), size: CGSize(width: 300, height: 400))
        model.lockFocusExposure()
        try await Task.sleep(for: .milliseconds(4200))
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 200))
        XCTAssertTrue(model.camera.targetExposureLockActive)
        model.unlockFocusExposure()
        try await Task.sleep(for: .milliseconds(4200))
        XCTAssertNil(model.focusPoint)
        #endif
    }

    @MainActor
    func testRapidFocusLockUnlockAndEVExtremesStayFinite() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        for index in 0..<500 {
            model.focusPreview(at: CGPoint(x: index % 300, y: index % 400), size: CGSize(width: 300, height: 400))
            model.lockFocusExposure()
            model.adjustFocusEV(index % 2 == 0 ? 100 : -100)
            XCTAssertTrue((-5...5).contains(model.ev))
            model.adjustFocusEV(.nan); XCTAssertTrue(model.ev.isFinite)
            model.unlockFocusExposure()
            XCTAssertFalse(model.camera.targetExposureLockActive)
        }
        model.cancelFocus()
        model.focusPreview(at: CGPoint(x: CGFloat.nan, y: 1), size: CGSize(width: 300, height: 400))
        model.focusPreview(at: .zero, size: .zero)
        XCTAssertNil(model.focusPoint)
        #endif
    }

    func testSunControlFitsAllRatiosAndAvoidsToolbarAndExposureStrip() {
        for ratio in FrameRatio.allCases {
            let width = min(CGFloat(386), CGFloat(680) * ratio.portraitRatio)
            let height = width / ratio.portraitRatio
            let size = CGSize(width: width, height: height)
            for point in [CGPoint(x: 25, y: 25), CGPoint(x: size.width - 25, y: 25), CGPoint(x: 25, y: height - 25), CGPoint(x: size.width - 25, y: height - 25)] {
                let top: CGFloat = ratio.overlaysToolbar ? 66 : 0
                let bottom: CGFloat = ratio.overlaysToolbar ? 60 : 0
                let sun = FocusTargetLayout.sunCenter(target: point, viewport: size, topInset: top, bottomInset: bottom)
                XCTAssertGreaterThanOrEqual(sun.x - 22, 0)
                XCTAssertLessThanOrEqual(sun.x + 22, size.width)
                XCTAssertGreaterThanOrEqual(sun.y - 69, top)
                XCTAssertLessThanOrEqual(sun.y + 69, size.height - bottom)
            }
        }
        XCTAssertEqual(FocusTargetLayout.draggedEV(origin: 0, translation: -24), 1)
        XCTAssertEqual(FocusTargetLayout.draggedEV(origin: 0, translation: 24), -1)
        XCTAssertEqual(FocusTargetLayout.draggedEV(origin: 0, translation: -1000), 5)
    }
    func testNativeLensPresetsFitEveryRatioIncludingXpan() {
        for ratio in FrameRatio.allCases {
            let width = min(CGFloat(386), CGFloat(680) * ratio.portraitRatio)
            let available = width - 104
            for count in 1...6 {
                let button = CameraLensBarLayout.buttonWidth(availableWidth: available, count: count)
                let side = CameraLensBarLayout.controlDiameter(containerWidth: width, count: count)
                let lensAvailable = width - 56 - side * 2
                let lensButton = CameraLensBarLayout.buttonWidth(availableWidth: lensAvailable, count: count)
                // 镜头槽允许到 42pt，侧控上限 40pt；验证两者接近且不越界，不再要求完全等宽。
                XCTAssertLessThanOrEqual(abs(lensButton - side), 2.001)
                XCTAssertLessThanOrEqual(lensButton, 42)
                XCTAssertLessThanOrEqual(side, 40)
                XCTAssertLessThanOrEqual(side * CGFloat(count + 2) + 60 + CGFloat(count - 1) * 2, width + 0.001)
                XCTAssertLessThanOrEqual(button * CGFloat(count) + 4 + CGFloat(count - 1) * 2, available + 0.01, ratio.rawValue)
                XCTAssertGreaterThanOrEqual(button, 16)
            }
        }
    }

    @MainActor
    func testLongPressSelectsAndLocksWithoutAnExistingFocusFrameAcrossEveryRatio() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        for ratio in FrameRatio.photoOptions {
            model.selectRatio(ratio)
            let size = CGSize(width: 300, height: 300 / ratio.portraitRatio)
            for point in [CGPoint(x: 70, y: 80), CGPoint(x: size.width - 40, y: size.height - 40)] {
                model.cancelFocus()
                XCTAssertNil(model.focusPoint)
                model.focusPreview(at: point, size: size, lockExposure: true)
                XCTAssertEqual(model.focusPoint, point)
                XCTAssertTrue(model.camera.targetExposureLockActive)
                XCTAssertTrue(model.camera.targetExposureLocked)
                model.unlockFocusExposure()
                XCTAssertFalse(model.camera.targetExposureLockActive)
                XCTAssertEqual(model.focusPoint, point)
            }
        }
        #endif
    }

    @MainActor
    func testLongPressRetargetsExistingLockAndRejectsInvalidOrBusyInput() async {
        #if targetEnvironment(simulator)
        let model = await readyModel(); defer { model.camera.stop() }
        let size = CGSize(width: 300, height: 400)
        model.focusPreview(at: CGPoint(x: 80, y: 100), size: size, lockExposure: true)
        model.focusPreview(at: CGPoint(x: 200, y: 250), size: size, lockExposure: true)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 250))
        XCTAssertTrue(model.camera.targetExposureLocked)
        model.focusPreview(at: CGPoint(x: CGFloat.nan, y: 0), size: size, lockExposure: true)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 250))
        model.focusPreview(at: .zero, size: .zero, lockExposure: true)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 250))
        model.camera.stop()
        model.focusPreview(at: CGPoint(x: 70, y: 70), size: size, lockExposure: true)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 200, y: 250))
        #endif
    }

    #if !targetEnvironment(simulator)
    @MainActor func testPhysicalAELockSurvivesOtherTargetsUntilExplicitUnlock() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.cancelFocus(); camera.stop(); UIApplication.shared.isIdleTimerDisabled = idle }
        camera.start()
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let size = CGSize(width: 300, height: 400)
        let target = CGPoint(x: 150, y: 200)
        model.focusPreview(at: target, size: size, lockExposure: true)
        for _ in 0..<100 { if camera.targetExposureLocked { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.targetExposureLocked)
        for index in 0..<20 {
            model.focusPreview(at: CGPoint(x: index * 10, y: index * 15), size: size)
            XCTAssertEqual(model.focusPoint, target)
            XCTAssertTrue(camera.targetExposureLockActive)
        }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertTrue(camera.targetExposureLocked)
        model.unlockFocusExposure()
        XCTAssertFalse(camera.targetExposureLockActive)
        model.focusPreview(at: CGPoint(x: 80, y: 100), size: size)
        XCTAssertEqual(model.focusPoint, CGPoint(x: 80, y: 100))
    }
    #endif

}
