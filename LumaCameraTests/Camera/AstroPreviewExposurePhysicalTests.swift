import AVFoundation
import XCTest
@testable import LumaCamera

@MainActor final class AstroPreviewExposurePhysicalTests: XCTestCase {
    func testIdlePreviewCaptureProtectionRestorationAndLensChanges() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical cameras")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.setCameraActive(false)
        let photo = AstroPhotoEngine()
        let trails = AstroTrailsEngine()
        let time = AstroTimelapseEngine()
        photo.frameCount = 2
        trails.captureDurationSeconds = 2
        trails.autoSaveOnFinish = false
        time.durationMinutes = nil
        time.intervalSeconds = 1
        let rigs = [
            Rig(name: "RAW", session: photo.session, start: photo.start, stop: photo.stop,
                settings: { photo.manualSettings = $0 }, refresh: photo.refreshPreviewSettings,
                pause: photo.setPreviewPaused, lens: photo.switchLens,
                begin: photo.begin, cancel: photo.cancel, finish: {},
                completed: { photo.result != nil }, error: { photo.error }, captureSeconds: 0.5),
            Rig(name: "trails", session: trails.session, start: trails.start, stop: trails.stop,
                settings: { trails.manualSettings = $0 }, refresh: trails.refreshPreviewSettings,
                pause: trails.setPreviewPaused, lens: trails.switchLens,
                begin: trails.begin, cancel: trails.cancel, finish: {},
                completed: { trails.result != nil }, error: { trails.error }, captureSeconds: 1),
            Rig(name: "timelapse", session: time.session, start: time.start, stop: time.stop,
                settings: { time.manualSettings = $0 }, refresh: time.refreshPreviewSettings,
                pause: time.setPreviewPaused, lens: time.switchLens,
                begin: time.begin, cancel: time.cancel, finish: time.finishVerification,
                completed: { time.capturedFrames >= 2 }, error: { time.error }, captureSeconds: 1)
        ]
        defer { photo.stop(); trails.stop(); time.stop(); model.setCameraActive(false) }
        var latencies = [Double]()
        for rig in rigs {
            var settings = AstroManualSettings()
            settings.photoShutterSeconds = 0.5; settings.iso = 400
            settings.isoAutomatic = false
            rig.settings(settings)
            rig.refresh() // Reproduce the UI refresh arriving before start().
            let start = CACurrentMediaTime()
            rig.start()
            try await wait("\(rig.name) initial preview", rig: rig) { self.previewIsFixed(rig) }
            latencies.append(CACurrentMediaTime() - start)
            for i in 0..<30 {
                settings.photoShutterSeconds = i.isMultiple(of: 2) ? 1 : 0.5
                settings.fusionExposureSeconds = i % 30 + 1
                rig.settings(settings); rig.refresh()
            }
            try await wait("\(rig.name) rapid idle changes", rig: rig) { self.previewIsFixed(rig) }
            rig.pause(true)
            try await wait("pause", rig: rig) { !rig.session.isRunning }
            rig.pause(false)
            try await wait("resume", rig: rig) { self.previewIsFixed(rig) }
            settings.photoShutterSeconds = rig.captureSeconds
            settings.fusionExposureSeconds = 1
            rig.settings(settings)
            rig.begin()
            for _ in 0..<30 { rig.refresh() } // Includes capture preparation.
            try await wait("\(rig.name) capture exposure", rig: rig) {
                self.exposure(rig).map { abs($0 - rig.captureSeconds) < 0.01 } ?? false
            }
            rig.refresh()
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(try XCTUnwrap(exposure(rig)), rig.captureSeconds, accuracy: 0.01)
            try await wait("\(rig.name) real acquisition", rig: rig, timeout: 30) { rig.completed() }
            rig.finish() // Video finalizes to a temporary file, never Photos.
            let restore = CACurrentMediaTime()
            try await wait("\(rig.name) completion restoration", rig: rig) { self.previewIsFixed(rig) }
            let restored = CACurrentMediaTime() - restore
            latencies.append(restored)
            if rig.name != "RAW" { XCTAssertLessThan(restored, 3.5, "Long-exposure recovery budget") }
            if rig.name == "trails" { XCTAssertTrue(trails.status.hasPrefix("星轨完成")) }
            if rig.name == "timelapse" { XCTAssertNotEqual(time.status, "对准星空，保持手机稳定") }
            for _ in 0..<(rig.name == "RAW" ? 1 : 3) {
                rig.begin()
                try await wait("\(rig.name) capture before cancel", rig: rig) {
                    self.exposure(rig).map { abs($0 - rig.captureSeconds) < 0.01 } ?? false
                }
                rig.cancel()
                let cancelled = CACurrentMediaTime()
                try await wait("\(rig.name) cancel restoration", rig: rig) { self.previewIsFixed(rig) }
                let elapsed = CACurrentMediaTime() - cancelled
                latencies.append(elapsed)
                if rig.name != "RAW" { XCTAssertLessThan(elapsed, 3.5, "Long-exposure recovery budget") }
                if rig.name == "trails" { XCTAssertEqual(trails.status, "已取消") }
                if rig.name == "timelapse" { XCTAssertEqual(time.status, "已取消") }
            }
            // Allow an already submitted native RAW callback to finish before teardown.
            try await Task.sleep(for: .milliseconds(700))
            for lens in [AVCaptureDevice.DeviceType.builtInTelephotoCamera, .builtInUltraWideCamera, .builtInWideAngleCamera] {
                guard AVCaptureDevice.default(lens, for: .video, position: .back) != nil else { continue }
                rig.lens(lens)
                try await wait("\(rig.name) lens \(lens.rawValue)", rig: rig) {
                    self.device(rig)?.deviceType == lens && self.previewIsFixed(rig)
                }
            }
            XCTAssertNil(rig.error())
            print("ASTRO-PREVIEW \(rig.name) idleRefreshes=30 captureRefreshes=31 exposure=1/15 frameDuration=1/15 captureSeconds=\(rig.captureSeconds) pauseResume=1 lensChanges=3")
            rig.stop()
            try await wait("stop", rig: rig) { !rig.session.isRunning }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("ASTRO-PREVIEW settleSeconds samples=\(latencies.count) values=\(latencies); poll interval=20ms, includes session start/restore; not display FPS")
        #endif
    }

    private struct Rig {
        let name: String
        let session: AVCaptureSession
        let start: () -> Void, stop: () -> Void
        let settings: (AstroManualSettings) -> Void
        let refresh: () -> Void
        let pause: (Bool) -> Void
        let lens: (AVCaptureDevice.DeviceType) -> Void
        let begin: () -> Void, cancel: () -> Void, finish: () -> Void
        let completed: () -> Bool
        let error: () -> String?
        let captureSeconds: Double
    }
    private func device(_ rig: Rig) -> AVCaptureDevice? { (rig.session.inputs.first as? AVCaptureDeviceInput)?.device }
    private func exposure(_ rig: Rig) -> Double? { device(rig).map { CMTimeGetSeconds($0.exposureDuration) } }
    private func previewIsFixed(_ rig: Rig) -> Bool {
        guard rig.session.isRunning, let device = device(rig) else { return false }
        return device.exposureMode == .custom && abs(CMTimeGetSeconds(device.exposureDuration) - 1.0 / 15) < 0.003
            && abs(CMTimeGetSeconds(device.activeVideoMaxFrameDuration) - 1.0 / 15) < 0.003
    }
    private func wait(_ label: String, rig: Rig, timeout: Double = 12, condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline {
            if let error = rig.error() { XCTFail("\(label): \(error)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            XCTFail("\(label) timed out; exposure=\(String(describing: exposure(rig))) mode=\(device(rig)?.exposureMode.rawValue ?? -1) frame=\(device(rig).map { CMTimeGetSeconds($0.activeVideoMaxFrameDuration) } ?? -1)")
            throw CancellationError()
        }
    }
}
