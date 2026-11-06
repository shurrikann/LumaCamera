import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class AutomaticZoomPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testAutomaticWheelChangesActualHardwareZoomThroughFortyAndKeepsFramesMoving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let mode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.endZoomDial(); model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true); model.setCaptureKind(.photo); model.setMode(.auto)
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false; model.ratio = .standard
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        // A 挡 0.5× 必须由虚拟多摄自动选超广角；先手动选定主摄会把路由钉在物理1×。
        camera.setContinuousZoom(1)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let initial = await withCheckedContinuation { c in camera.zoomStateForTesting { z,_,_ in c.resume(returning:z) } }
        XCTAssertEqual(initial, 1, accuracy: 0.02)
        for zoom: CGFloat in [0.5,1,2,4,8,20,40,4,1] {
            camera.setContinuousZoom(zoom)
            try await Task.sleep(for:.milliseconds(600))
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let actual = await withCheckedContinuation { c in camera.zoomStateForTesting { c.resume(returning:($0,$1,$2)) } }
            print("A-ZOOM requested=\(zoom) UI=\(camera.currentZoom) hardware=\(actual.0) available=\(actual.1) physicalCatalog=\(actual.2)")
            XCTAssertEqual(actual.0,zoom,accuracy:0.02,"Check hardware, not only displayed label")
            if zoom == 4 || zoom == 40, let preview = camera.preview {
                let attachment = XCTAttachment(image:preview)
                attachment.name = "Actual preview \(Int(zoom))x"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for _ in 0..<3 {
            camera.setContinuousZoom(1)
            try await Task.sleep(for:.milliseconds(150))
            await withCheckedContinuation { c in camera.holdCurrentSceneLensForTesting { c.resume() } }
            camera.setContinuousZoom(40)
            try await Task.sleep(for:.milliseconds(200))
            let actual = await withCheckedContinuation { c in camera.zoomStateForTesting { c.resume(returning:($0,$1,$2)) } }
            print("A-ZOOM-UNLOCK UI=\(camera.currentZoom) hardware=\(actual.0) available=\(actual.1)")
            XCTAssertEqual(actual.0,40,accuracy:0.02)
            XCTAssertEqual(camera.currentZoom,40,accuracy:0.02)
        }
        var times: [TimeInterval] = []
        let token = camera.$preview.dropFirst().compactMap { $0 }.sink { _ in times.append(ProcessInfo.processInfo.systemUptime) }
        defer { token.cancel() }
        model.beginZoomDial(at:1)
        for index in 0..<180 {
            model.dragZoomDial(translation:-CGFloat(index)*2, width:360)
            try await Task.sleep(for:.milliseconds(16))
        }
        model.finishZoomDrag()
        let target = camera.currentZoom
        try await Task.sleep(for:.milliseconds(200))
        let final = await withCheckedContinuation { c in camera.zoomStateForTesting { a,_,_ in c.resume(returning:a) } }
        XCTAssertEqual(final,target,accuracy:0.02)
        let gaps = zip(times.dropFirst(),times).map(-)
        print("A-ZOOM-SWEEP frames=\(times.count) maxGap=\(gaps.max() ?? 0)")
        XCTAssertGreaterThan(times.count,25)
        XCTAssertLessThan(gaps.max() ?? 0,0.7)
    }
    @MainActor func testPreviewPinchUpdatesActualLensZoomAndRecoversAcrossRepeatedGestures() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldMode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.finishPreviewPinchZoom(); model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true); model.setMode(.auto)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        camera.selectLens(wide)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for pinch in [[CGFloat(1.08), 1.2, 1.35], [CGFloat(1.15), 1.3, 1.0], [CGFloat(1.12), 1.25, 1.1]] {
            let origin = camera.currentZoom
            for scale in pinch {
                let expected = min(max(origin * scale, model.zoomRange.lowerBound), model.zoomRange.upperBound)
                model.updatePreviewPinchZoom(scale: scale)
                try await Task.sleep(for: .milliseconds(180))
                await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
                let hardware = await withCheckedContinuation { continuation in camera.zoomStateForTesting { zoom, _, _ in continuation.resume(returning: zoom) } }
                XCTAssertEqual(camera.currentZoom, expected, accuracy: 0.04, "Pinch scale must update the displayed continuous zoom")
                XCTAssertEqual(hardware, expected, accuracy: 0.08, "Pinch scale must reach the active physical or virtual camera")
                XCTAssertNotNil(camera.preview, "Preview must remain live throughout a pinch zoom")
            }
            model.finishPreviewPinchZoom()
        }
        XCTAssertFalse(model.previewPinchActive, "Ending every pinch must release gesture state")
    }

    @MainActor func testIdleAutomaticSessionKeepsSystemPolicyAndFreshPreviewWithoutAppLensTimers() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let mode = model.mode, callback = camera.onAutomaticLensChange
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var changes: [TimeInterval] = [], frames = 0
        camera.onAutomaticLensChange = { changes.append(ProcessInfo.processInfo.systemUptime) }
        let frameToken = camera.$preview.compactMap { $0 }.sink { _ in frames += 1 }
        defer {
            frameToken.cancel(); camera.onAutomaticLensChange = callback
            model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true); model.setMode(.auto)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        camera.setContinuousZoom(1)
        // Navigation and A/M transitions from the preceding test must finish
        // before measuring an idle scene; their overlays are intentionally animated.
        for _ in 0..<160 {
            if camera.ready && model.focalTransitionImage == nil && model.resumeTransitionImage == nil { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        XCTAssertNil(model.focalTransitionImage); XCTAssertNil(model.resumeTransitionImage)
        changes.removeAll(); frames = 0
        for _ in 0..<80 {
            let behavior = await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { _,b,_,_ in c.resume(returning:b) } }
            XCTAssertEqual(behavior,1,"App must not periodically force locked/auto changes")
            XCTAssertNil(model.focalTransitionImage); XCTAssertNil(model.resumeTransitionImage)
            try await Task.sleep(for:.milliseconds(200))
        }
        print("A-IDLE actualPrimaryChanges=\(changes.count) gaps=\(zip(changes.dropFirst(),changes).map(-)) previewFrames=\(frames)")
        XCTAssertGreaterThan(frames,40)
    }
    #endif
}
