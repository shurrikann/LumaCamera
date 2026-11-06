import XCTest
import UIKit
@testable import LumaCamera
final class ManualFocalSpeedPhysicalTests:XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRepeatedManualFocalChangesDeliverFreshFramesWithoutLosingExposure() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, oldISO=model.iso, oldShutter=model.shutter, manual=model.manualExposure
        let idle=UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled=true
        defer { model.iso=oldISO; model.shutter=oldShutter; model.manualExposure=manual; model.setMode(mode); model.applyExposure(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled=idle }
        model.setCameraActive(true); model.setMode(.manual)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.manualExposure=true; model.iso=400; model.shutter=log2(1.0/125); model.applyExposure()
        for pass in 0..<2 {
            for anchor:CGFloat in [0.5,1,2,4,8,1] {
                let lens=try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-anchor)<0.01 })
                let before=camera.preview, start=ProcessInfo.processInfo.systemUptime
                model.selectFocalLength(lens)
                for _ in 0..<600 {
                    if camera.ready && camera.selectedLens == lens.id && camera.preview != nil && camera.preview !== before { break }
                    try await Task.sleep(for:.milliseconds(5))
                }
                let elapsed=ProcessInfo.processInfo.systemUptime-start
                print("M-FOCAL-SPEED pass=\(pass) anchor=\(anchor) freshSeconds=\(elapsed)")
                XCTAssertLessThan(elapsed,1.5)
                XCTAssertTrue(camera.ready); XCTAssertEqual(camera.selectedLens,lens.id)
                XCTAssertTrue(model.manualExposure)
                // Let the intentionally animated focal overlay finish before the next tap.
                for _ in 0..<80 { if model.focalTransitionImage == nil { break }; try await Task.sleep(for:.milliseconds(10)) }
            }
        }
    }
    @MainActor func testAutoManualSwitchRevealsFreshFramesWithoutWaitingForAnOverlayTimeout() async throws {
        let model=try XCTUnwrap(AppDependencies.runningAppCameraModel), camera=model.camera
        let mode=model.mode, idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled=idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        for next in [CameraShootingMode.manual,.auto,.manual,.auto,.manual,.auto] {
            if model.mode == next { continue }
            let before=camera.preview, start=ProcessInfo.processInfo.systemUptime
            model.setMode(next)
            for _ in 0..<400 {
                if camera.ready && camera.preview != nil && camera.preview !== before && model.focalTransitionImage == nil { break }
                try await Task.sleep(for:.milliseconds(5))
            }
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            print("A-M-SPEED destination=\(next) visibleSeconds=\(elapsed)")
            // Hardware route startup varies; still reject the previous 2–3 second hold.
            XCTAssertLessThan(elapsed,1.5)
            XCTAssertNil(model.focalTransitionImage)
            try await Task.sleep(for:.milliseconds(100))
        }
    }
    #endif
}
