import AVFoundation
import ImageIO
import XCTest
@testable import LumaCamera

@MainActor final class AstroFiveFixesPhysicalTests: XCTestCase {
    func testAutoISOMeteringLocksCaptureShutterAndEV() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical camera")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let engine = AstroPhotoEngine()
        var stopped = false
        defer { if !stopped { engine.stop() }; model.setCameraActive(false) }
        engine.manualSettings.isoAutomatic = true; engine.manualSettings.exposureBias = 1
        engine.manualSettings.photoShutterSeconds = 0.5; engine.frameCount = 2
        engine.start(); try await wait { engine.session.isRunning }
        let device = try XCTUnwrap((engine.session.inputs.first as? AVCaptureDeviceInput)?.device)
        var samples = [Double]()
        for _ in 0..<3 {
            engine.begin()
            try await wait(timeout: 30) { engine.result != nil || engine.error != nil }
            XCTAssertNotNil(engine.result); XCTAssertNil(engine.error)
            let reading = try XCTUnwrap(engine.lastExposureReading)
            let expected = engine.manualSettings.captureExposure(meteredISO: reading.iso,
                meteredSeconds: reading.seconds, requestedSeconds: 0.5,
                meteredOffset: reading.offset, meteredBias: reading.bias,
                isoRange: Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO),
                minimumSeconds: CMTimeGetSeconds(device.activeFormat.minExposureDuration))
            XCTAssertEqual(reading.appliedISO, expected.iso, accuracy: 0.01)
            XCTAssertEqual(reading.appliedSeconds, expected.seconds, accuracy: 0.000001)
            XCTAssertEqual(reading.sensorISO, expected.iso, accuracy: max(1, expected.iso * 0.01))
            XCTAssertEqual(reading.sensorSeconds, expected.seconds, accuracy: 0.002)
            XCTAssertEqual(engine.capturedFrames, 2)
            samples.append(reading.elapsed)
            engine.save(); try await wait(timeout: 20) { !engine.isSaving }
            let store = AstroRecoveryStore.shared
            store.reload(); try await wait { store.items.contains { $0.kind == "星空照片" && $0.phase == "ready" } }
            let item = try XCTUnwrap(store.items.last { $0.kind == "星空照片" && $0.phase == "ready" })
            let file = try XCTUnwrap(store.journal.url(for: item))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let iso = try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue)
            let exposure = try XCTUnwrap((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue)
            XCTAssertEqual(iso, expected.iso, accuracy: max(2, expected.iso * 0.12))
            XCTAssertEqual(exposure, expected.seconds, accuracy: max(0.00025, expected.seconds * 0.03))
            print("ASTRO-AUTO-ISO meteredISO=\(reading.iso) time=\(reading.seconds) offset=\(reading.offset) nativeBias=\(reading.bias) targetISO=\(expected.iso) appliedSeconds=\(reading.appliedSeconds) sensorISO=\(reading.sensorISO) fileISO=\(iso) fileTime=\(exposure) settled=\(reading.settled) PhotosWrites=0")
            store.discard(item.id)
            try await Task.sleep(for: .milliseconds(300))
        }
        print("ASTRO-AUTO-METER samples=3 seconds=\(samples)")
        // Cancel while metering, then immediately start a different capture.
        engine.begin(); engine.cancel(); engine.manualSettings.isoAutomatic = false
        engine.begin(); try await wait(timeout: 30) { engine.result != nil || engine.error != nil }
        XCTAssertNotNil(engine.result); XCTAssertNil(engine.error)
        engine.stop(); try await wait { !engine.session.isRunning }; stopped = true
        try await Task.sleep(for: .milliseconds(250))
        #endif
    }

    /// Run on its own: the user backgrounds and returns to the visible App.
    func testSystemBackgroundSavesVisibleStarCaptureAndColdReloadsIt() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical device and user background transition")
        #else
        guard ProcessInfo.processInfo.environment["LUMA_RUN_BACKGROUND_RECOVERY_TEST"] == "1" else {
            throw XCTSkip("Requires coordinated user background transition")
        }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let lifecycle = AstroBackgroundTestState()
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lifecycle.sawBackground = true }
        }
        let returned = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if lifecycle.sawBackground { lifecycle.sawReturn = true } }
        }
        defer {
            NotificationCenter.default.removeObserver(observer); NotificationCenter.default.removeObserver(returned)
            model.selectTopLevelMode(.photo)
        }
        try await wait(timeout: 20) { model.camera.ready }
        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.submode != nil }
        AstroModeDiagnostics.submode?.wrappedValue = .trails
        let engine = try XCTUnwrap(AstroModeDiagnostics.trails)
        try await wait { engine.session.isRunning && engine.ownsCaptureRoute && engine.previewFrames.metrics.count >= 2 }
        XCTAssertTrue(engine.session === model.camera.astroSharedCaptureSession.session)
        engine.captureDurationSeconds = nil
        engine.begin(); try await wait(timeout: 20) { engine.capturedCount >= 2 }
        print("ASTRO-BG-READY return to Home for 5 seconds then reopen LumaCamera; diagnostics only")
        try await wait(timeout: 150) { lifecycle.sawBackground && lifecycle.sawReturn }
        try await wait(timeout: 20) { !engine.isCapturing && !engine.isSaving && AstroModeDiagnostics.previewReady && engine.ownsCaptureRoute }
        let device = try XCTUnwrap((engine.session.inputs.first as? AVCaptureDeviceInput)?.device)
        try await wait { abs(CMTimeGetSeconds(device.exposureDuration) - 1.0 / 15) < 0.003 }
        let cold = AstroRecoveryStore(journal: AstroRecoveryJournal(root: AstroRecoveryJournal.shared.root))
        cold.reload(); try await wait { cold.items.contains { $0.kind == "星轨" && $0.phase == "ready" } }
        let item = try XCTUnwrap(cold.items.last { $0.kind == "星轨" && $0.phase == "ready" })
        let file = try XCTUnwrap(cold.journal.url(for: item))
        XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertFalse(engine.isCapturing); XCTAssertNil(engine.error)
        print("ASTRO-BG-RESTORED actualBackground=true returned=true previewReady=true sharedSession=true exposure=1/15 phase=\(item.phase) frames=\(item.options.frameCount) file=\(file.lastPathComponent) PhotosWrites=0")
        try await Task.sleep(for: .seconds(4))
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) {
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: shot); attachment.name = "Astro-Recovery-After-Actual-Background"; attachment.lifetime = .keepAlways; add(attachment)
        }
        #endif
    }
    func testRepeatedZeroFrameStopsDoNotResurrectCapture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical cameras")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let engine = AstroTrailsEngine()
        engine.autoSaveOnFinish = false; engine.captureDurationSeconds = 1
        var stopped = false
        defer { if !stopped { engine.stop() }; model.setCameraActive(false) }
        engine.start(); try await wait { engine.session.isRunning }
        var samples = [Double]()
        for _ in 0..<8 {
            let start = CACurrentMediaTime()
            engine.begin(); engine.stopAndSave()
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertFalse(engine.isCapturing); XCTAssertEqual(engine.capturedCount, 0)
            XCTAssertNil(engine.result); XCTAssertNil(engine.error)
            samples.append(CACurrentMediaTime() - start)
        }
        engine.begin()
        try await wait(timeout: 20) { engine.result != nil || engine.error != nil }
        XCTAssertNotNil(engine.result); XCTAssertNil(engine.error)
        print("ASTRO-ZERO-STOP cycles=8 stateChecksAfter180ms seconds=\(samples) subsequentCapture=true PhotosWrites=0")
        engine.stop(); try await wait { !engine.session.isRunning }; stopped = true
        try await Task.sleep(for: .milliseconds(250))
        #endif
    }

    func testNativeRAWExposureAndFocalMetadataSurviveDurableSave() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical RAW")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let engine = AstroPhotoEngine()
        var stopped = false
        defer { if !stopped { engine.stop() }; model.setCameraActive(false) }
        engine.outputOptions.format = .jpg
        engine.manualSettings.isoAutomatic = false
        engine.manualSettings.iso = 400; engine.manualSettings.exposureBias = 1
        engine.manualSettings.photoShutterSeconds = 1.0 / 15; engine.frameCount = 2
        engine.start(); try await wait { engine.session.isRunning }
        engine.begin(); try await wait(timeout: 30) { engine.result != nil || engine.error != nil }
        XCTAssertNil(engine.error); XCTAssertNotNil(engine.result)
        engine.save(); try await wait(timeout: 20) { !engine.isSaving }
        let store = AstroRecoveryStore.shared
        store.reload(); try await wait { store.items.contains { $0.kind == "星空照片" && $0.phase == "ready" } }
        let item = try XCTUnwrap(store.items.last { $0.kind == "星空照片" && $0.phase == "ready" })
        let file = try XCTUnwrap(store.journal.url(for: item))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let iso = try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue)
        let exposure = try XCTUnwrap((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue)
        let focal = try XCTUnwrap((exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue)
        XCTAssertEqual(iso, 800, accuracy: 20)
        XCTAssertEqual(exposure, 1.0 / 15, accuracy: 0.005)
        XCTAssertGreaterThan(focal, 0); XCTAssertLessThan(focal, 20)
        XCTAssertEqual((exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, 24)
        print("ASTRO-RAW-FILE ISO=\(iso) shutter=\(exposure) actualFocalMM=\(focal) equivalent=24 file=\(file.lastPathComponent) PhotosWrites=0")
        engine.stop(); try await wait { !engine.session.isRunning }; stopped = true
        try await Task.sleep(for: .milliseconds(250))
        #endif
    }

    func testPhotoWorkerCancellationRestartAndMainActorResponsiveness() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical RAW")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let engine = AstroPhotoEngine()
        defer { engine.stop(); model.setCameraActive(false) }
        engine.autoSaveOnFinish = false
        engine.frameCount = 2
        engine.manualSettings.isoAutomatic = true
        engine.manualSettings.photoShutterSeconds = 1.0 / 15
        engine.start(); try await wait { engine.session.isRunning }
        for _ in 0..<3 {
            engine.begin(); engine.cancel()
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertFalse(engine.isCapturing); XCTAssertNil(engine.result)
        }
        var gaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { break }
                let now = CACurrentMediaTime(); gaps.append((now - previous) * 1000); previous = now
            }
        }
        defer { heartbeat.cancel() }
        let began = CACurrentMediaTime()
        engine.begin()
        try await wait(timeout: 60) { engine.result != nil || engine.error != nil }
        heartbeat.cancel()
        XCTAssertNil(engine.error); XCTAssertNotNil(engine.result)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertGreaterThanOrEqual(engine.capturedFrames, 1)
        XCTAssertGreaterThan(gaps.count, 10)
        print("ASTRO-PHOTO-WORKER nativePixels=\(engine.result?.size ?? .zero) accepted=\(engine.capturedFrames) wallSeconds=\(CACurrentMediaTime() - began) heartbeatSamples=\(gaps.count) maxMainActorGapMs=\(gaps.max() ?? 0) cancelRestart=3 PhotosWrites=0; heartbeat is not FPS")
        engine.cancel()
        #endif
    }

    func testTemporalWorkersKeepUIResponsiveAndStopAfterRepeatedCancel() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical video buffers")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let trails = AstroTrailsEngine(), time = AstroTimelapseEngine()
        defer { trails.stop(); time.stop(); model.setCameraActive(false) }
        var gaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { break }
                let now = CACurrentMediaTime(); gaps.append((now-previous)*1000); previous = now
            }
        }
        defer { heartbeat.cancel() }
        trails.autoSaveOnFinish = false; trails.captureDurationSeconds = 3
        trails.start(); try await wait { trails.session.isRunning && !trails.switchingLens }
        for _ in 0..<3 {
            trails.begin(); trails.cancel(); try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(trails.isCapturing); XCTAssertNil(trails.result)
        }
        let began = CACurrentMediaTime()
        trails.begin(); try await wait(timeout: 40) { trails.result != nil || trails.error != nil }
        XCTAssertNil(trails.error); XCTAssertNotNil(trails.result); XCTAssertFalse(trails.isCapturing)
        print("ASTRO-TRAIL-WORKER frames=\(trails.capturedCount) wall=\(CACurrentMediaTime()-began) heartbeatSamples=\(gaps.count) maxMainActorGapMs=\(gaps.max() ?? 0) cancelRestart=3")
        trails.cancel(); trails.stop(); try await wait { !trails.session.isRunning }
        gaps = []
        time.intervalSeconds = 1; time.manualSettings.fusionExposureSeconds = 1; time.durationMinutes = nil
        time.start(); try await wait { time.session.isRunning && !time.switchingLens }
        for _ in 0..<3 {
            time.begin(); time.cancel(); try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(time.isRecording); XCTAssertFalse(time.isFinishing)
        }
        time.begin(); try await wait(timeout: 40) { time.capturedFrames >= 3 || time.error != nil }
        XCTAssertNil(time.error)
        let stopped = CACurrentMediaTime()
        time.stopAndSave(); time.stop(); try await wait(timeout: 20) { !time.isFinishing }
        XCTAssertNil(time.error); XCTAssertGreaterThanOrEqual(time.capturedFrames, 3)
        XCTAssertGreaterThan(gaps.count, 10)
        print("ASTRO-TIME-WORKER frames=\(time.capturedFrames) stopSeconds=\(CACurrentMediaTime()-stopped) heartbeatSamples=\(gaps.count) maxMainActorGapMs=\(gaps.max() ?? 0) cancelRestart=3 PhotosWrites=0; heartbeat is not FPS")
        #endif
    }

    func testReleasingCameraRouteDoesNotCancelQueuedStillResults() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical RAW and video buffers")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let photo = AstroPhotoEngine(), trails = AstroTrailsEngine()
        defer { photo.stop(); trails.stop(); model.setCameraActive(false) }
        photo.autoSaveOnFinish = false; photo.frameCount = 10
        photo.manualSettings.photoShutterSeconds = 1.0/15
        photo.start(); try await wait { photo.session.isRunning && !photo.switchingLens }
        photo.begin(); try await wait(timeout: 30) { photo.capturedFrames >= 1 || photo.error != nil }
        XCTAssertNil(photo.error)
        photo.interruptAndSave(); photo.stop()
        try await wait(timeout: 30) { photo.result != nil && !photo.isSaving || photo.error != nil }
        XCTAssertNotNil(photo.result); XCTAssertNil(photo.error)
        try await wait { !photo.session.isRunning }
        trails.autoSaveOnFinish = false; trails.captureDurationSeconds = 30
        trails.start(); try await wait { trails.session.isRunning && !trails.switchingLens }
        trails.begin(); try await wait(timeout: 30) { trails.capturedCount >= 1 || trails.error != nil }
        XCTAssertNil(trails.error)
        trails.stopAndSave(); trails.stop()
        try await wait(timeout: 30) { trails.result != nil || trails.error != nil }
        XCTAssertNotNil(trails.result); XCTAssertNil(trails.error)
        print("ASTRO-ROUTE-RELEASE photoAccepted=\(photo.capturedFrames) trailAccepted=\(trails.capturedCount) queuedFinals=2 PhotosWrites=0")
        #endif
    }

    func testRealTimelapseDurableFileCanBeLoadedByColdRecoveryStore() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical video")
        #else
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let engine = AstroTimelapseEngine()
        var stopped = false
        defer { if !stopped { engine.stop() }; model.setCameraActive(false) }
        engine.intervalSeconds = 1; engine.durationMinutes = nil
        engine.start(); try await wait { engine.session.isRunning }
        engine.begin(); try await wait(timeout: 20) { engine.capturedFrames >= 3 || engine.error != nil }
        XCTAssertNil(engine.error)
        engine.stopAndSave(manual: true)
        try await wait(timeout: 20) { !engine.isFinishing }
        XCTAssertNil(engine.error)
        let cold = AstroRecoveryStore(journal: AstroRecoveryJournal(root: AstroRecoveryJournal.shared.root))
        cold.reload(); try await wait { cold.items.contains { $0.kind == "星空延时" && $0.phase == "ready" } }
        let item = try XCTUnwrap(cold.items.last { $0.kind == "星空延时" && $0.phase == "ready" })
        let file = try XCTUnwrap(cold.journal.url(for: item))
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertEqual(size, CGSize(width: 2160, height: 3840))
        print("ASTRO-REAL-RECOVERY seconds=\(duration.seconds) size=\(size) frames=\(engine.capturedFrames) PhotosWrites=0")
        engine.stop(); try await wait { !engine.session.isRunning }; stopped = true
        try await Task.sleep(for: .milliseconds(250))
        #endif
    }

    private func wait(timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
        if !condition() { throw CancellationError() }
    }
}

@MainActor private final class AstroBackgroundTestState {
    var sawBackground = false
    var sawReturn = false
}
