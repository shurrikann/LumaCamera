import AVFoundation
import XCTest
@testable import LumaCamera

@MainActor final class AstroAlgorithmPipelinePhysicalTests: XCTestCase {
    func testFiniteMinuteUsesWallTimeAndCancellationCanRestart() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical capture and writer")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        defer { AstroModeDiagnostics.timelapse?.cancel(); model.selectTopLevelMode(.photo) }
        model.setCameraActive(true)
        try await wait { model.camera.ready && model.modeHandoffTarget == nil }
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro && model.modeHandoffTarget == nil }
        AstroModeDiagnostics.submode?.wrappedValue = .timelapse
        let engine = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        try await wait { engine.ownsCaptureRoute && AstroModeDiagnostics.previewReady }
        engine.manualSettings.isoAutomatic = true
        engine.intervalSeconds = 5; engine.manualSettings.fusionExposureSeconds = 2; engine.durationMinutes = 1
        for _ in 0..<4 {
            engine.begin(); try await Task.sleep(for:.milliseconds(100)); engine.cancel()
            try await Task.sleep(for:.milliseconds(300))
            XCTAssertFalse(engine.isRecording); XCTAssertFalse(engine.isFinishing)
            XCTAssertEqual(engine.capturedFrames,0)
        }
        let start = CACurrentMediaTime()
        engine.begin()
        try await wait(timeout:90) { !engine.isRecording || engine.error != nil }
        let elapsed = CACurrentMediaTime()-start
        try await wait(timeout:20) { !engine.isFinishing }
        XCTAssertNil(engine.error)
        let sampling = try XCTUnwrap(engine.samplingEndedAt) - XCTUnwrap(engine.samplingStartedAt)
        XCTAssertGreaterThanOrEqual(sampling,59.5); XCTAssertLessThan(sampling,63)
        XCTAssertGreaterThanOrEqual(elapsed,59); XCTAssertLessThan(elapsed,78)
        XCTAssertGreaterThanOrEqual(engine.capturedFrames,10); XCTAssertLessThanOrEqual(engine.capturedFrames,13)
        let store = AstroRecoveryStore.shared
        store.reload()
        try await wait { store.items.contains { $0.kind == "星空延时" && $0.phase == "ready" } }
        let item = try XCTUnwrap(store.items.last { $0.kind == "星空延时" && $0.phase == "ready" })
        let url = try XCTUnwrap(store.journal.url(for:item)), asset = AVURLAsset(url:url)
        let reader = try AVAssetReader(asset:asset)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        let track = try XCTUnwrap(tracks.first)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var pts = [Double]()
        while let sample = output.copyNextSampleBuffer() { pts.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        XCTAssertEqual(reader.status,.completed); XCTAssertEqual(pts.count,engine.capturedFrames)
        for pair in zip(pts,pts.dropFirst()) { XCTAssertGreaterThan(pair.1,pair.0) }
        print("ASTRO-FINITE interval=5 fusion=2 minutes=1 wallSeconds=\(elapsed) samplingSeconds=\(sampling) outputFrames=\(pts.count) pts=\(pts) cancelRestart=4 PhotosWrites=0")
        store.discard(item.id)
        #endif
    }
    private func wait(timeout:Double = 20,_ condition:()->Bool) async throws {
        let deadline = CACurrentMediaTime()+timeout
        while !condition(), CACurrentMediaTime()<deadline { try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertTrue(condition()); if !condition() { throw CancellationError() }
    }
}
