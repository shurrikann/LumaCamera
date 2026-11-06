import XCTest
import UIKit
import AVFoundation
@testable import LumaCamera
final class MacroOpticsDiagnosticTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRepeatedSceneChangesDoNotRestartCenteredContinuousFocusButRecenterTappedTarget() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldMode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true); model.setMode(.auto); model.unlockFocusExposure()
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<200 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        let measurementStart = CACurrentMediaTime()
        camera.focus(at: CGPoint(x: 0.5, y: 0.5))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let centered = await withCheckedContinuation { c in camera.repeatSceneFocusChangesForTesting(50) { c.resume(returning: ($0, $1, $2)) } }
        XCTAssertEqual(centered.0, 0, "An already continuous AF controller must not restart for each scene notification")
        XCTAssertTrue(centered.2)
        camera.focus(at: CGPoint(x: 0.2, y: 0.3))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let tapped = await withCheckedContinuation { c in camera.repeatSceneFocusChangesForTesting(50) { c.resume(returning: ($0, $1, $2)) } }
        XCTAssertEqual(tapped.0, 1, "The first real scene change must still release an old off-center target")
        XCTAssertEqual(tapped.1.x, 0.5, accuracy: 0.001); XCTAssertEqual(tapped.1.y, 0.5, accuracy: 0.001)
        XCTAssertTrue(tapped.2)
        let burstDuration = CACurrentMediaTime() - measurementStart
        // The removed policy used to schedule a one-shot AF restart after 1.2s.
        // Cross that deadline and verify that continuous AF remains in control.
        try await Task.sleep(for: .milliseconds(1700))
        let settled = await withCheckedContinuation { c in camera.repeatSceneFocusChangesForTesting(0) { c.resume(returning: ($0, $1, $2)) } }
        XCTAssertTrue(settled.2, "Scene changes must not leave a delayed single-shot focus scan")
        XCTAssertTrue(camera.ready); XCTAssertNotNil(camera.preview)
        print("SCENE-FOCUS centeredNotifications=50 reconfigurations=\(centered.0) offCenterNotifications=50 reconfigurations=\(tapped.0) burstSeconds=\(burstDuration) continuousAfter1_7s=\(settled.2)")
    }
    #endif
}
