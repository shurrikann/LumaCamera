import XCTest
import AVFoundation
@testable import LumaCamera

#if !targetEnvironment(simulator)
final class SlowMotionPhotoReturnZoomTests: XCTestCase {
    @MainActor func testSlowMotionToPhotoFocalAndZoomWheel() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true)
        for _ in 0..<500 { if camera.ready && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.photo)
        for _ in 0..<500 { if model.captureKind == .photo && camera.ready && !model.captureKindSwitching { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.video)
        for _ in 0..<600 { if model.captureKind == .video && camera.ready && !camera.videoConfiguring && !model.captureKindSwitching { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.videoCodec = .hevc; model.videoColorSpace = .sdr
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        if let wide = camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 && $0.device.deviceType == .builtInWideAngleCamera }) {
            camera.selectLens(wide)
            for _ in 0..<500 { if camera.selectedLens == wide.id && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        }
        model.toggleSlowMotionMode()
        for _ in 0..<700 { if model.slowMotionEnabled && !model.isPreparingSubmode && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.slowMotionEnabled, camera.message ?? "")
        let stateBefore = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
        print("SLOWMOTION-RETURN before kind=\(model.captureKind) state=\(stateBefore)")
        model.setCaptureKind(.photo)
        for _ in 0..<1000 { if model.captureKind == .photo && camera.ready && !model.captureKindSwitching && !camera.videoConfiguring && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.captureKind, .photo, camera.message ?? "")
        XCTAssertTrue(camera.ready, camera.message ?? "")
        let stateAfter = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
        print("SLOWMOTION-RETURN after \(stateAfter)")
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .seconds(2))

        // Focal taps: first transition after return, then repeated toggles.
        for attempt in 0..<4 {
            let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - (attempt.isMultiple(of: 2) ? 2 : 1)) < 0.01 })
            let startFrame = camera.previewFrameTimeForTesting
            let tapStart = CACurrentMediaTime()
            model.selectFocalLength(lens)
            var selectedAt: Double?, doneAt: Double?
            for _ in 0..<700 {
                let now = CACurrentMediaTime()
                if selectedAt == nil, camera.selectedLens == lens.id { selectedAt = now }
                if selectedAt != nil, model.focalTransitionImage == nil, !camera.videoConfiguring, camera.ready { doneAt = now; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            print("SLOWMOTION-RETURN tap\(attempt) zoom=\(lens.displayZoom) select=\(selectedAt.map { $0 - tapStart } ?? -1) done=\(doneAt.map { $0 - tapStart } ?? -1) frameDelta=\(camera.previewFrameTimeForTesting - startFrame)")
        }

        // Zoom wheel drag
        model.openZoomDial()
        let wheelPreviewStart = camera.previewFrameTimeForTesting
        let zoomStart = camera.currentZoom
        var maxGap = 0.0, last = CACurrentMediaTime(), maxLag = 0.0
        var samples: [String] = []
        let dragStart = CACurrentMediaTime()
        for step in 0..<60 {
            let requested = zoomStart + CGFloat(step) * 0.05
            model.dragZoomDial(translation: -CGFloat(step) * 2, width: 300)
            let now = CACurrentMediaTime(); maxGap = max(maxGap, now - last); last = now
            maxLag = max(maxLag, abs(camera.currentZoom - requested))
            if step % 15 == 0 { samples.append(String(format: "%.2f", camera.currentZoom)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.finishZoomDrag()
        try await Task.sleep(for: .milliseconds(300))
        let zoomLine = "SLOWMOTION-RETURN wheel elapsed=\(CACurrentMediaTime()-dragStart) start=\(zoomStart) end=\(camera.currentZoom) maxGap=\(maxGap) maxLag=\(maxLag) samples=\(samples)"
        print(zoomLine)
        print("SLOWMOTION-RETURN previewBefore=\(wheelPreviewStart) previewAfter=\(camera.previewFrameTimeForTesting)")
        model.endZoomDial(); model.setCameraActive(false)
    }
}
#endif
