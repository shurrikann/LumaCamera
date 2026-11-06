import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class ModeSwitchLatencyTests: XCTestCase {
    @MainActor func testModeSwitchFrameAndOverlayLatencyOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Measures real camera route replacement")
        #else
        let model=try await FullDeviceRegressionFixture.makeFreshModel()
        let camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer {model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle}
        let ready=expectation(description:"Ready")
        let token=camera.$ready.filter{$0}.first().sink{_ in ready.fulfill()}
        model.setCameraActive(true);await fulfillment(of:[ready],timeout:15);token.cancel()
        for _ in 0..<50 {if camera.preview != nil {break};try await Task.sleep(for:.milliseconds(50))}
        // Use the same remembered manual state in both baseline and optimized runs.
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0 / 125)
        model.manualWB = false; model.manualFocus = false
        model.applyExposure(); model.applyWhiteBalance()
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(400))
        for index in 0..<8 {
            let mode:CameraShootingMode=index % 2 == 0 ? .manual : .auto
            let start=CACurrentMediaTime()
            let previousSwitchID = camera.userSwitchFrameID
            var clearedPreview = false
            var firstFrame:Double?
            var previous=start
            var maximumGap=0.0
            let frames=camera.$preview.dropFirst().sink{image in
                let now=CACurrentMediaTime()
                if image == nil {clearedPreview=true}
                else {
                    maximumGap=max(maximumGap,now-previous);previous=now
                    if camera.userSwitchFrameID != previousSwitchID && firstFrame == nil {firstFrame=now-start}
                }
            }
            model.setMode(mode)
            for _ in 0..<200 {
                if firstFrame != nil && model.focalTransitionImage == nil {break}
                try await Task.sleep(for:.milliseconds(10))
            }
            frames.cancel()
            print("MODE-LATENCY \(index) \(mode) frame=\(firstFrame ?? -1) overlay=\(CACurrentMediaTime()-start) maxGap=\(maximumGap)")
            XCTAssertNotNil(firstFrame,"Live frames must resume after route change")
            XCTAssertFalse(clearedPreview, "切换期间应保留旧预览，不能清空闪黑")
            XCTAssertNil(model.focalTransitionImage)
            XCTAssertTrue(camera.ready)
            try await Task.sleep(for:.milliseconds(100))
        }
        #endif
    }
}
