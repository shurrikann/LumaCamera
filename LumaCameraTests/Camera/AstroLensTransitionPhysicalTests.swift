import AVFoundation
import XCTest
@testable import LumaCamera

@MainActor final class AstroLensTransitionPhysicalTests: XCTestCase {
    func testRepeatedThreeLensSwitchesRapidRequestsAndExit() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical camera input switching")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        try await wait { model.camera.ready && model.modeHandoffTarget == nil }
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro && model.modeHandoffTarget == nil }
        let session = model.camera.astroSharedCaptureSession.session
        let stops = AstroLensStopCount()
        let observation = session.observe(\.isRunning,options:[.new]) { _, value in if value.newValue == false { stops.add() } }
        defer { observation.invalidate() }
        let route: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera,.builtInWideAngleCamera,.builtInTelephotoCamera,.builtInWideAngleCamera]
        for mode in AstroCaptureMode.allCases {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await wait { AstroModeDiagnostics.previewReady && self.owns(mode) }
            var samples = [Double](), settled = [Double](), handoffs = [Double]()
            for _ in 0..<2 { for target in route {
                let previous = frames(mode)?.snapshot, start = CACurrentMediaTime()
                let selection = try XCTUnwrap(AstroModeDiagnostics.lensSelection)
                selection.wrappedValue = target
                try await wait { self.type(mode) == target && self.frames(mode)?.snapshot != nil
                    && self.frames(mode)?.snapshot !== previous && (self.frames(mode)?.metrics.count ?? 0) >= 2 }
                let elapsed = CACurrentMediaTime()-start
                let device = try XCTUnwrap((session.inputs.first as? AVCaptureDeviceInput)?.device)
                XCTAssertEqual(device.deviceType,target)
                try await wait { abs(CMTimeGetSeconds(device.exposureDuration)-1.0/15) < 0.003 }
                settled.append(CACurrentMediaTime()-start)
                try await wait { !AstroModeDiagnostics.lensTransitionActive }
                handoffs.append(CACurrentMediaTime()-start)
                XCTAssertEqual(CMTimeGetSeconds(device.exposureDuration),1.0/15,accuracy:0.003)
                XCTAssertEqual(device.videoZoomFactor,1,accuracy:0.001)
                XCTAssertTrue(session.isRunning); XCTAssertTrue(owns(mode))
                samples.append(elapsed)
            } }
            let selection = try XCTUnwrap(AstroModeDiagnostics.lensSelection)
            for target in route { selection.wrappedValue = target; try await Task.sleep(for:.milliseconds(35)) }
            try await wait { self.type(mode) == .builtInWideAngleCamera && !AstroModeDiagnostics.lensTransitionActive }
            print("ASTRO-LENS mode=\(mode.rawValue) samples=8 seconds=\(samples) exposureSettledSeconds=\(settled) handoffSeconds=\(handoffs) rapid=4 preview=1/15 zoom=1; request to new proxy frames/cover release, not display FPS")
        }
        // A known front-only device type must fail rather than silently select another rear lens.
        let video = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        let outputIDs = session.outputs.map(ObjectIdentifier.init)
        XCTAssertNil(AVCaptureDevice.default(.builtInTrueDepthCamera,for:.video,position:.back))
        video.switchLens(to:.builtInTrueDepthCamera)
        try await wait { !video.switchingLens && video.error != nil }
        XCTAssertEqual(video.activeDeviceType,.builtInWideAngleCamera)
        XCTAssertEqual((session.inputs.first as? AVCaptureDeviceInput)?.device.deviceType,.builtInWideAngleCamera)
        XCTAssertEqual(session.outputs.map(ObjectIdentifier.init),outputIDs)
        try await wait { (self.frames(.timelapse)?.metrics.count ?? 0) >= 2 }
        AstroModeDiagnostics.lensSelection?.wrappedValue = .builtInUltraWideCamera
        try await Task.sleep(for:.milliseconds(40))
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) {
            let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
            }
            let attachment = XCTAttachment(image:shot)
            attachment.name = "Astro-Lens-Local-Handoff"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await wait { self.type(.timelapse) == .builtInUltraWideCamera && !AstroModeDiagnostics.lensTransitionActive }
        XCTAssertNil(video.error)
        print("ASTRO-LENS failureRollback=true outputsRetained=true recoverySwitch=true")
        for mode in [AstroCaptureMode.photo,.trails,.timelapse,.photo] {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await wait { self.owns(mode) && AstroModeDiagnostics.previewReady && self.type(mode) == .builtInUltraWideCamera }
            XCTAssertEqual((session.inputs.first as? AVCaptureDeviceInput)?.device.deviceType,.builtInUltraWideCamera)
        }
        print("ASTRO-LENS submodeReturns=4 stalePreviewReady=false")
        XCTAssertEqual(stops.value,0)
        AstroModeDiagnostics.lensSelection?.wrappedValue = .builtInTelephotoCamera
        model.selectTopLevelMode(.photo)
        try await wait { model.topLevelMode == .photo && model.camera.ready && model.modeHandoffTarget == nil }
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertFalse(AstroModeDiagnostics.photo?.ownsCaptureRoute ?? false)
        XCTAssertFalse(AstroModeDiagnostics.trails?.ownsCaptureRoute ?? false)
        XCTAssertFalse(AstroModeDiagnostics.timelapse?.ownsCaptureRoute ?? false)
        print("ASTRO-LENS sessionStops=\(stops.value) switches=24 rapidRequests=12 exitDuringSwitch=true PhotosWrites=0")
        #endif
    }
    func testEachPhysicalLensStillCapturesRawTrailsAndTimelapse() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical RAW and one-second source exposures")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        try await wait { model.camera.ready && model.modeHandoffTarget == nil }
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro && model.modeHandoffTarget == nil }
        for mode in AstroCaptureMode.allCases {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await wait { self.owns(mode) && AstroModeDiagnostics.previewReady }
            for target in [AVCaptureDevice.DeviceType.builtInUltraWideCamera,.builtInWideAngleCamera,.builtInTelephotoCamera] {
                try await wait { self.owns(mode) && (self.frames(mode)?.metrics.count ?? 0) >= 2 }
                let selection = try XCTUnwrap(AstroModeDiagnostics.lensSelection)
                selection.wrappedValue = target
                try await wait { self.type(mode) == target && !AstroModeDiagnostics.lensTransitionActive }
                let started = CACurrentMediaTime()
                switch mode {
                case .photo:
                    let engine = try XCTUnwrap(AstroModeDiagnostics.photo)
                    engine.manualSettings.photoShutterSeconds = 1.0/15; engine.frameCount = 2
                    engine.begin()
                    selection.wrappedValue = target == .builtInWideAngleCamera ? .builtInTelephotoCamera : .builtInWideAngleCamera
                    XCTAssertEqual(selection.wrappedValue,target,"Capture must ignore a lens change")
                    try await wait(timeout:30) { engine.result != nil || engine.error != nil }
                    XCTAssertNil(engine.error); XCTAssertEqual(engine.capturedFrames,2)
                    let image = try XCTUnwrap(engine.result?.cgImage)
                    XCTAssertEqual(image.width*image.height,4032*3024)
                    engine.reset()
                case .trails:
                    let engine = try XCTUnwrap(AstroModeDiagnostics.trails)
                    engine.captureDurationSeconds = 1; engine.autoSaveOnFinish = false
                    engine.begin()
                    selection.wrappedValue = target == .builtInWideAngleCamera ? .builtInTelephotoCamera : .builtInWideAngleCamera
                    XCTAssertEqual(selection.wrappedValue,target)
                    try await wait(timeout:30) { engine.result != nil || engine.error != nil }
                    XCTAssertNil(engine.error); XCTAssertGreaterThan(engine.capturedCount,0)
                    let image = try XCTUnwrap(engine.result?.cgImage)
                    XCTAssertGreaterThanOrEqual(image.width*image.height,3840*2160)
                    engine.reset()
                case .timelapse:
                    let engine = try XCTUnwrap(AstroModeDiagnostics.timelapse)
                    engine.intervalSeconds = 1; engine.manualSettings.fusionExposureSeconds = 1; engine.durationMinutes = nil
                    engine.begin()
                    selection.wrappedValue = target == .builtInWideAngleCamera ? .builtInTelephotoCamera : .builtInWideAngleCamera
                    XCTAssertEqual(selection.wrappedValue,target)
                    try await wait(timeout:30) { engine.capturedFrames >= 2 || engine.error != nil }
                    XCTAssertNil(engine.error)
                    engine.finishVerification()
                    try await wait(timeout:20) { !engine.isFinishing }
                    XCTAssertNil(engine.error); XCTAssertTrue(engine.status.contains("验证通过"))
                }
                print("ASTRO-LENS-CAPTURE mode=\(mode.rawValue) device=\(target.rawValue) seconds=\(CACurrentMediaTime()-started) busyLensChangeIgnored=true PhotosWrites=0")
            }
        }
        #endif
    }

    private func frames(_ mode:AstroCaptureMode)->AstroPreviewFrameStore? {
        switch mode { case .photo: AstroModeDiagnostics.photo?.previewFrames
        case .trails: AstroModeDiagnostics.trails?.previewFrames
        case .timelapse: AstroModeDiagnostics.timelapse?.previewFrames }
    }
    private func type(_ mode:AstroCaptureMode)->AVCaptureDevice.DeviceType? {
        switch mode { case .photo: AstroModeDiagnostics.photo?.activeDeviceType
        case .trails: AstroModeDiagnostics.trails?.activeDeviceType
        case .timelapse: AstroModeDiagnostics.timelapse?.activeDeviceType }
    }
    private func owns(_ mode:AstroCaptureMode)->Bool {
        switch mode { case .photo: AstroModeDiagnostics.photo?.ownsCaptureRoute ?? false
        case .trails: AstroModeDiagnostics.trails?.ownsCaptureRoute ?? false
        case .timelapse: AstroModeDiagnostics.timelapse?.ownsCaptureRoute ?? false }
    }
    private func wait(timeout:Double=15,_ condition:()->Bool) async throws {
        let deadline=CACurrentMediaTime()+timeout
        while !condition(),CACurrentMediaTime()<deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(condition()); if !condition() { throw CancellationError() }
    }
}
private final class AstroLensStopCount: @unchecked Sendable {
    private let lock=NSLock(); private var count=0
    func add(){lock.lock();count += 1;lock.unlock()}
    var value:Int {lock.lock();defer{lock.unlock()};return count}
}
