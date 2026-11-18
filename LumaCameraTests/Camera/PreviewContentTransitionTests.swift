import XCTest
import SwiftUI
import AVFoundation
import ReplayKit
@testable import LumaCamera

@MainActor final class PreviewContentTransitionTests: XCTestCase {
    private func image(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    func testFrameAspectFreshnessRapidReplacementCancelAndReducedMotion() async throws {
        let state = PreviewContentTransition(), old = image(120,160)
        state.begin(old, aspect: 1, reducingMotion: false)
        XCTAssertTrue(state.awaitingFrame); XCTAssertEqual(state.blur,3); XCTAssertEqual(state.opacity,1)
        state.receive(old); XCTAssertTrue(state.awaitingFrame)
        state.receive(image(120,160)); XCTAssertTrue(state.awaitingFrame)
        state.receive(image(100,100), publishedAt: 0); XCTAssertTrue(state.awaitingFrame)
        state.receive(image(100,100)); XCTAssertFalse(state.awaitingFrame)
        let latest = image(160,90)
        state.begin(latest, aspect: 16/9, reducingMotion: true)
        XCTAssertEqual(state.blur,0)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertTrue(state.image === latest,"The previous cleanup must not remove a newer cover")
        state.finish(); try await Task.sleep(for: .milliseconds(120)); XCTAssertNil(state.image)
        let start = CACurrentMediaTime()
        for _ in 0..<1000 { state.begin(old, reducingMotion: true); state.cancel() }
        XCTAssertNil(state.image); XCTAssertFalse(state.awaitingFrame)
        try await Task.sleep(for: .milliseconds(230)); XCTAssertNil(state.image)
        state.begin(old, waitsForFrame: false, reducingMotion: true)
        try await Task.sleep(for: .milliseconds(200)); XCTAssertNil(state.image)
        print("PREVIEW-TRANSITION lifecycle n=1000 seconds=\(CACurrentMediaTime()-start) CPU+intentional waits, no FPS claim")
    }
    func testAdaptiveZoomRampRateIsFiniteBoundedAndDistanceAware() {
        for origin: CGFloat in [0.5,1,2,4,10,40] { for target: CGFloat in [0.5,1,2,4,10,40] {
            let rate = ContinuousZoomPolicy.animatedRampRate(current: origin,target: target)
            XCTAssertTrue(rate.isFinite); XCTAssertGreaterThanOrEqual(rate,4); XCTAssertLessThanOrEqual(rate,96)
            XCTAssertLessThanOrEqual(Double(abs(log2(target/origin)))/Double(rate),0.081)
        } }
        XCTAssertEqual(ContinuousZoomPolicy.animatedRampRate(current:.nan,target:1),4)
    }
    #if !targetEnvironment(simulator)
    func testVisiblePhotoRatiosStarSubmodesAndRatioTransitions() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.selectTopLevelMode(.photo); model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        try await wait { model.camera.ready && model.camera.preview != nil && model.focalTransitionImage == nil && model.modeHandoffTarget == nil }
        let transition = try XCTUnwrap(model.previewContentTransitionForTesting)
        var timings = [Double](), drawTimes = [Double]()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow))
        let shutter = try XCTUnwrap(model.captureButtonFramesForTesting["shutter"])
        let modes = try XCTUnwrap(model.captureButtonFramesForTesting["functions"])
        for ratio in FrameRatio.photoOptions+FrameRatio.photoOptions.reversed() where ratio != model.ratio {
            let start = CACurrentMediaTime()
            model.selectRatio(ratio)
            try await wait { transition.image != nil }
            XCTAssertTrue(transition.blur == 0 || transition.blur == 3)
            let draw = CACurrentMediaTime()
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates:true) }
            drawTimes.append((CACurrentMediaTime()-draw)*1000)
            if timings.count < 3 { let a=XCTAttachment(image:snapshot);a.name="Preview-Blur-Ratio-"+ratio.rawValue;a.lifetime = .keepAlways;add(a) }
            try await wait { transition.image == nil }
            timings.append(CACurrentMediaTime()-start)
            XCTAssertFalse(transition.didTimeOut, "Ratio transition must release on a real fresh preview, not its safety timer")
            XCTAssertLessThan(timings.last!, 0.8)
            XCTAssertEqual(model.captureButtonFramesForTesting["shutter"],shutter)
            XCTAssertEqual(model.captureButtonFramesForTesting["functions"],modes)
        }
        // Automatic physical-lens notifications never create the new content cover.
        for _ in 0..<30 { model.camera.onAutomaticLensChange?() }
        XCTAssertNil(transition.image); XCTAssertNil(model.focalTransitionImage)
        for ratio in FrameRatio.photoOptions { model.selectRatio(ratio) }
        try await wait { transition.image == nil }
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro && model.modeHandoffTarget == nil && AstroModeDiagnostics.previewReady }
        for mode in [AstroCaptureMode.trails,.timelapse,.photo,.trails,.photo] {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await wait { AstroModeDiagnostics.previewTransition?.image != nil }
            try await wait { AstroModeDiagnostics.previewReady && AstroModeDiagnostics.previewTransition?.image == nil }
            XCTAssertFalse(AstroModeDiagnostics.previewTransition?.didTimeOut ?? true)
        }
        for ratio in ["1:1","16:9","4:3"] {
            AstroModeDiagnostics.ratioSelection?.wrappedValue = ratio
            try await wait { AstroModeDiagnostics.previewTransition?.image != nil }
            try await wait { AstroModeDiagnostics.previewTransition?.image == nil }
        }
        print("PREVIEW-TRANSITION real photoRatioSamples=\(timings.count) seconds=\(timings) draw_ms=\(drawTimes) starSubmodes=5 starRatios=3 rapidRatios=\(FrameRatio.photoOptions.count) automaticNotifications=30 PhotosWrites=0")
    }
    func testFixedHalfSecondFocalZoomUsesWheelRouteWithoutReverseSteps() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true); model.setMode(.auto)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.focalZoomAnimation.cancel(); UIApplication.shared.isIdleTimerDisabled = idle }
        try await wait { camera.ready && camera.preview != nil }
        var durations = [Double]()
        for (origin,target): (CGFloat,CGFloat) in [(1,2),(2,1),(1,4),(4,1),(1,8),(8,1),(1,4),(4,1)] {
            camera.setContinuousZoom(origin)
            try await Task.sleep(for: .milliseconds(300))
            let routeBefore = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            let start = CACurrentMediaTime()
            model.transitionToFocalZoom(target)
            var samples = [CGFloat]()
            repeat {
                try await Task.sleep(for: .milliseconds(25))
                let actual = await withCheckedContinuation { c in camera.zoomStateForTesting { z,_,_ in c.resume(returning:z) } }
                samples.append(actual)
            } while model.focalZoomAnimation.isRunning
            durations.append(CACurrentMediaTime()-start)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let final = await withCheckedContinuation { c in camera.zoomStateForTesting { z,_,_ in c.resume(returning:z) } }
            XCTAssertEqual(final,target,accuracy:0.05)
            XCTAssertNil(model.focalTransitionImage)
            XCTAssertGreaterThan(samples.filter { abs($0-origin)>0.03 && abs($0-target)>0.03 }.count,3)
            for (before,after) in zip(samples,samples.dropFirst()) {
                if target > origin { XCTAssertGreaterThanOrEqual(after,before-0.04) }
                else { XCTAssertLessThanOrEqual(after,before+0.04) }
            }
            XCTAssertGreaterThan(durations.last!,0.45); XCTAssertLessThan(durations.last!,0.7)
            let frames = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= start }
            print("FIXED-FOCAL from=\(origin) to=\(target) seconds=\(durations.last!) hardware=\(samples) previewFrames=\(frames.count) before=\(routeBefore)")
        }
        // Repeated taps and leaving the camera cancel the old trajectory.
        for target: CGFloat in [4,1,8,2,1] {
            model.transitionToFocalZoom(target)
            try await Task.sleep(for:.milliseconds(45))
        }
        try await wait { !model.focalZoomAnimation.isRunning }
        model.transitionToFocalZoom(4); model.setCameraActive(false)
        XCTAssertFalse(model.focalZoomAnimation.isRunning)
        model.setCameraActive(true)
        print("FIXED-FOCAL n=8 durations=\(durations) rapidRetargets=5 backgroundCancel=true PhotosWrites=0")
    }
    func testActualFocalButtonScreenRecordingWithoutResettingSavedSettings() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_RUN_FOCAL_SCREEN_TEST"] == "1" else {
            throw XCTSkip("Coordinated actual-screen diagnosis only")
        }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        model.setCameraActive(true)
        try await wait { camera.ready && camera.preview != nil }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        print("FOCAL-SCREEN actual startup resolution=\(model.photoResolution) mode=\(model.mode) top=\(model.topLevelMode) format=\(model.photoFormat) live=\(model.capturesLivePhoto) fixed=\(model.fixedHighResolutionFocalsOnly)")
        let recorder = RPScreenRecorder.shared(), frames = AstroHandoffScreenFrames()
        recorder.isMicrophoneEnabled = false
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
            recorder.startCapture(handler: { sample,type,_ in if type == .video { frames.receive(sample) } }) { error in
                if let error { c.resume(throwing:error) } else { c.resume() }
            }
        }
        defer { if recorder.isRecording { recorder.stopCapture { _ in } } }
        try await Task.sleep(for:.milliseconds(400))
        frames.begin()
        for value: CGFloat in [1,4,1,2,1] {
            let lens = try XCTUnwrap(model.displayedFocalLenses.first { abs($0.displayZoom-value)<0.01 })
            print("FOCAL-SCREEN tap=\(value) clock=\(CACurrentMediaTime())")
            model.selectFocalLength(lens)
            try await Task.sleep(for:.milliseconds(850))
        }
        frames.end()
        await withCheckedContinuation { c in recorder.stopCapture { _ in c.resume() } }
        for (index,frame) in frames.images.enumerated() where index % 2 == 0 {
            let a = XCTAttachment(image:UIImage(cgImage:frame.image))
            a.name = String(format:"FocalScreen-%03d-%.3fs",index,frame.seconds)
            a.lifetime = .keepAlways; add(a)
        }
        print("FOCAL-SCREEN frames=\(frames.images.count) microphone=false PhotosWrites=0")
    }
    func testVideoAspectOptionsUseFreshFramesWithoutMovingShutter() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.selectTopLevelMode(.photo); model.setCameraActive(true)
        try await wait { model.camera.ready && model.camera.preview != nil && model.modeHandoffTarget == nil }
        model.requestCaptureKind(.video)
        try await wait { model.videoShutterEnabled && model.focalTransitionImage == nil }
        defer { model.requestCaptureKind(.photo); model.setCameraActive(true) }
        let transition = try XCTUnwrap(model.previewContentTransitionForTesting)
        try await wait { transition.image == nil }
        let shutter = try XCTUnwrap(model.captureButtonFramesForTesting["shutter"])
        var times = [Double]()
        for ratio in VideoRatio.aspectOptions where ratio != model.videoRatio {
            let start = CACurrentMediaTime()
            model.videoRatio = ratio
            try await wait { transition.image != nil || model.focalTransitionImage != nil }
            try await wait { transition.image == nil && model.focalTransitionImage == nil && model.videoShutterEnabled }
            XCTAssertFalse(transition.didTimeOut)
            XCTAssertEqual(model.captureButtonFramesForTesting["shutter"], shutter)
            times.append(CACurrentMediaTime()-start)
        }
        print("PREVIEW-TRANSITION videoAspectChanges=\(times.count) seconds=\(times) shutterFixed=true PhotosWrites=0")
    }
    private func wait(timeout: Double = 15, _ condition: () -> Bool) async throws {
        let limit = CACurrentMediaTime()+timeout
        while !condition(), CACurrentMediaTime()<limit { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(condition()); if !condition() { throw CancellationError() }
    }
    #endif
}
