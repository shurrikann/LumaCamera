import XCTest
import UIKit
@testable import LumaCamera

final class ZoomWheelReopenPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testReopeningKeepsActualZoomAndAnchorAcrossBothModes() async throws {
        // 共享引擎先恢复照片基线；录像或未完成拍摄会按设计拒绝变焦，不能误报重开倍率异常。
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let mode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.endZoomDial(); model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        XCTAssertFalse(camera.capturing)
        XCTAssertFalse(camera.videoBusy)
        var reopenTimes: [Double] = []
        for next in [CameraShootingMode.auto, .manual] {
            model.setMode(next)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 4) < 0.01 })
            model.selectFocalLength(lens)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<200 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(camera.selectedLens, lens.id)
            camera.setContinuousZoom(6)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            try await Task.sleep(for: .milliseconds(250))
            let zoom = camera.currentZoom, anchor = camera.selectedLens, input = camera.activeCaptureDeviceID
            XCTAssertEqual(zoom, 6, accuracy: 0.02, "建立实际 6× 基线后才能验证重开")
            let actualBefore = await withCheckedContinuation { c in
                camera.zoomStateForTesting { value, _, _ in c.resume(returning: value) }
            }
            XCTAssertEqual(actualBefore, zoom, accuracy: 0.02)
            for _ in 0..<3 {
                let began = CACurrentMediaTime()
                model.openZoomDial()
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                XCTAssertEqual(camera.currentZoom, zoom, accuracy: 0.001)
                XCTAssertEqual(camera.selectedLens, anchor)
                XCTAssertEqual(camera.activeCaptureDeviceID, input)
                let actualReopened = await withCheckedContinuation { c in
                    camera.zoomStateForTesting { value, _, _ in c.resume(returning: value) }
                }
                XCTAssertTrue(model.zoomDialVisible)
                XCTAssertEqual(actualReopened, zoom, accuracy: 0.02, "重开不能只保留显示值，硬件倍率也须保持")
                reopenTimes.append(CACurrentMediaTime() - began)
                model.finishZoomDrag(); model.endZoomDial()
            }
            model.openZoomDial()
            model.dragZoomDial(translation: 10, width: 300)
            model.finishZoomDrag()
            XCTAssertLessThan(camera.currentZoom, zoom)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            let actualAfter = await withCheckedContinuation { c in
                camera.zoomStateForTesting { value, _, _ in c.resume(returning: value) }
            }
            XCTAssertEqual(actualAfter, camera.currentZoom, accuracy: 0.02)
            // 实际拖动改变倍率后再重开，不应跳回 4× 锚点或上一次 6× 起点。
            let dragged = camera.currentZoom
            model.endZoomDial()
            model.openZoomDial()
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            let actualAgain = await withCheckedContinuation { c in
                camera.zoomStateForTesting { value, _, _ in c.resume(returning: value) }
            }
            XCTAssertEqual(actualAgain, dragged, accuracy: 0.02)
            XCTAssertEqual(camera.selectedLens, anchor)
            model.endZoomDial()
        }
        print("ZOOM-REOPEN samples=\(reopenTimes.count) seconds=\(reopenTimes) actualHardware=true modes=A,M dragThenReopen=2; includes queue flush/readback, not animation latency or FPS")
    }
    #endif
}
