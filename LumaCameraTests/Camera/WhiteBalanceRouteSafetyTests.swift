import XCTest
import UIKit
import AVFoundation
@testable import LumaCamera

final class WhiteBalanceRouteSafetyTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testStaleCustomWhiteBalanceDuringRouteChangesDoesNotCrashVirtualCamera() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let oldMode = model.mode, oldWB = model.manualWB, oldKelvin = model.wb, oldTint = model.whiteBalanceTint
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.manualWB = oldWB; model.wb = oldKelvin; model.whiteBalanceTint = oldTint
            model.setMode(oldMode); model.applyWhiteBalance(); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
        // 本用例验证后置虚拟多摄；前一项前置测试留下的路线不满足该前提。
        let rear = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        model.selectFocalLength(rear)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 {
            if camera.ready && camera.selectedLens == rear.id && model.focalTransitionImage == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<3 {
            model.setMode(.manual)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.manualWB = true; model.wb = 4700; model.whiteBalanceTint = 12; model.applyWhiteBalance()
            model.setMode(.auto)
            // Reproduce an already queued manual-WB event reaching the virtual route.
            camera.setWhiteBalance(kelvin: 5200, tint: 20)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let snapshot = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
            let state = try XCTUnwrap(snapshot)
            XCTAssertTrue(state.virtual)
            XCTAssertEqual(state.whiteBalanceMode, .continuousAutoWhiteBalance)
            XCTAssertTrue(camera.ready)
        }
    }
    #endif
}
