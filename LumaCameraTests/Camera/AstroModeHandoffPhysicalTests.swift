import AVFoundation
import ReplayKit
import CoreImage
import SwiftUI
import XCTest
@testable import LumaCamera

@MainActor final class AstroModeHandoffPhysicalTests: XCTestCase {
    func testAstroButtonsRenderAboveEntrySnapshotBeforeLivePreview() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical-device compositing of glass controls")
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; originalWindow?.makeKey() }
        let bridge = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor(red: 0.26, green: 0.10, blue: 0.20, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let shared = AstroSharedCaptureSession(session: AVCaptureSession(),
            queue: DispatchQueue(label: "test.astroControls"))
        var samples = [Double]()
        for ratio in [FrameRatio.wide, .standard, .square] {
            let root = AstroModeView(onSelectMode: { _, _ in },
                handoffImage: bridge, handoffOpacity: 1, handoffBridgeFrame: scene.screen.bounds,
                onPreviewing: {}, onOpenSettings: {}, albumImage: nil, albumPendingCount: 0,
                onOpenLibrary: {}, externalCoverPresented: false, inheritedRatio: ratio,
                sharedSession: shared, watermarkSettings: .constant(PhotoWatermarkSettings()))
                .environment(\.scenePhase, .inactive)
                .preferredColorScheme(.dark)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            try await wait { AstroModeDiagnostics.toolbarButtonsFrame.width > 0
                && AstroModeDiagnostics.focalButtonsFrame.width > 0 && AstroModeDiagnostics.shutterFrame.width > 0
                && AstroModeDiagnostics.parameterButtonFrames.count == AstroParameter.allCases.count }
            XCTAssertFalse(shared.session.isRunning)
            XCTAssertFalse(AstroModeDiagnostics.previewReady)
            for _ in 0..<3 {
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                samples.append((CACurrentMediaTime() - start) * 1_000)
                let focal = AstroModeDiagnostics.focalButtonsFrame
                let focalContent = focal.insetBy(dx: max(0, (focal.width - 130) / 2), dy: 0)
                let regions = [AstroModeDiagnostics.toolbarButtonsFrame, focalContent,
                    AstroModeDiagnostics.shutterFrame] + Array(AstroModeDiagnostics.parameterButtonFrames.values)
                for region in regions {
                    XCTAssertGreaterThan(controlInkPixels(shot, in: region), 24, "\(ratio) \(region)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            window.rootViewController = nil
            try await Task.sleep(for: .milliseconds(100))
        }
        print("ASTRO-HANDOFF-CONTROLS ratios=3 snapshots=\(samples.count) snapshotMS=\(samples) livePreview=false PhotosWrites=0")
        #endif
    }

    func testAstroToolbarAlignmentAndTimelapseRecordingHUD() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical star preview")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        defer {
            AstroModeDiagnostics.timelapse?.cancel()
            model.camera.setVideoRecordingForTesting(false)
            model.selectTopLevelMode(.photo)
        }
        try await wait { model.camera.ready && model.captureButtonFramesForTesting["toolbar.settings"] != nil }
        let photoToolbar = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.settings"])
        print("ASTRO-RECORDING-HUD stage=photo y=\(photoToolbar.midY)")
        model.selectTopLevelMode(.video)
        try await wait { model.captureKind == .video && model.camera.ready && !model.captureKindSwitching
            && !model.camera.videoConfiguring && !model.isPreparingSubmode
            && model.captureButtonFramesForTesting["toolbar.videoColor"] != nil }
        let videoToolbar = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.videoColor"])
        XCTAssertEqual(photoToolbar.midY, videoToolbar.midY, accuracy: 0.5)
        print("ASTRO-RECORDING-HUD stage=video y=\(videoToolbar.midY)")
        XCTAssertEqual(model.videoRatio.frameRatio, .wide)
        model.camera.setVideoRecordingForTesting(true)
        try await wait { model.captureButtonFramesForTesting["recordingTimer"] != nil }
        let videoTimer = try XCTUnwrap(model.captureButtonFramesForTesting["recordingTimer"])
        model.camera.setVideoRecordingForTesting(false)

        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.previewReady && model.modeHandoffTarget == nil
            && AstroModeDiagnostics.toolbarButtonsFrame.height > 0 }
        print("ASTRO-RECORDING-HUD stage=astro y=\(AstroModeDiagnostics.toolbarButtonsFrame.midY)")
        let mode = try XCTUnwrap(AstroModeDiagnostics.submode)
        let ratio = try XCTUnwrap(AstroModeDiagnostics.ratioSelection)
        let cases: [(AstroCaptureMode, String)] = [(.photo, "4:3"), (.photo, "1:1"),
            (.photo, "16:9"), (.trails, "16:9"), (.timelapse, "16:9")]
        for (submode, aspect) in cases {
            mode.wrappedValue = submode
            ratio.wrappedValue = aspect
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(AstroModeDiagnostics.toolbarButtonsFrame.midY, photoToolbar.midY, accuracy: 0.5)
            XCTAssertEqual(AstroModeDiagnostics.toolbarButtonsFrame.midY, videoToolbar.midY, accuracy: 0.5)
        }

        let engine = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        let shutter = try XCTUnwrap(AstroModeDiagnostics.shutterAction)
        try await wait { AstroModeDiagnostics.previewReady && engine.ownsCaptureRoute }
        print("ASTRO-RECORDING-HUD stage=timelapseReady")
        let normalShutter = AstroModeDiagnostics.shutterFrame
        XCTAssertGreaterThan(normalShutter.width, 0)
        var timings = [Double]()
        for _ in 0..<2 {
            try await wait { engine.ownsCaptureRoute && engine.session.isRunning && !engine.switchingLens }
            let start = CACurrentMediaTime()
            shutter()
            try await wait { engine.isRecording && AstroModeDiagnostics.timelapseControlsHidden
                && AstroModeDiagnostics.recordingTimerSeconds != nil }
            print("ASTRO-RECORDING-HUD stage=timerShown")
            timings.append((CACurrentMediaTime() - start) * 1000)
            try await wait { (AstroModeDiagnostics.recordingTimerSeconds ?? 0) >= 1 }
            print("ASTRO-RECORDING-HUD stage=timerAdvanced")
            XCTAssertEqual(AstroModeDiagnostics.recordingTimerFrame.midX, videoTimer.midX, accuracy: 0.5)
            XCTAssertEqual(AstroModeDiagnostics.recordingTimerFrame.minY, videoTimer.minY, accuracy: 0.5)
            XCTAssertEqual(AstroModeDiagnostics.shutterFrame, normalShutter)
            XCTAssertTrue(AstroModeDiagnostics.shutterEnabled?() == true)
            AstroModeDiagnostics.toolbarTap?(3)
            XCTAssertFalse(model.settings)
            engine.cancel()
            try await wait { !AstroModeDiagnostics.timelapseControlsHidden
                && AstroModeDiagnostics.recordingTimerSeconds == nil }
            print("ASTRO-RECORDING-HUD stage=controlsRestored")
            XCTAssertEqual(AstroModeDiagnostics.shutterFrame, normalShutter)
        }
        print("ASTRO-RECORDING-HUD toolbarLayouts=\(cases.count) starts=\(timings.count) timerReadyMS=\(timings) photoY=\(photoToolbar.midY) videoY=\(videoToolbar.midY) PhotosWrites=0")
        model.selectTopLevelMode(.photo)
        try await wait { model.topLevelMode == .photo && model.modeHandoffTarget == nil }
        #endif
    }

    func testAstroParameterGlassMatchesAutomaticEVAcrossModesAndRatios() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical star preview")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setMode(.auto)
        model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo) }
        try await wait { model.camera.ready && model.captureButtonFramesForTesting["autoEVGlass"] != nil }
        let auto = try XCTUnwrap(model.captureButtonFramesForTesting["autoEVGlass"])
        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.previewReady && model.modeHandoffTarget == nil
            && AstroModeDiagnostics.parameterButtonFrames.count == AstroParameter.allCases.count }
        let mode = try XCTUnwrap(AstroModeDiagnostics.submode)
        let ratio = try XCTUnwrap(AstroModeDiagnostics.ratioSelection)
        let parameter = try XCTUnwrap(AstroModeDiagnostics.parameterSelection)
        let baselineY = AstroModeDiagnostics.parameterBarFrame.midY
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        let cases: [(AstroCaptureMode, String)] = [(.photo, "4:3"), (.photo, "1:1"), (.photo, "16:9"),
                                                  (.trails, "16:9"), (.timelapse, "16:9"), (.photo, "4:3")]
        var timings = [Double]()
        for (submode, aspect) in cases {
            mode.wrappedValue = submode
            ratio.wrappedValue = aspect
            try await Task.sleep(for: .milliseconds(250))
            let bar = AstroModeDiagnostics.parameterBarFrame
            XCTAssertEqual(bar.minX, auto.minX, accuracy: 0.5)
            XCTAssertEqual(bar.maxX, auto.maxX, accuracy: 0.5)
            XCTAssertEqual(bar.midY, baselineY, accuracy: 0.5)
            XCTAssertEqual(bar.height, auto.height, accuracy: 0.5)
            let width = bar.width / CGFloat(AstroParameter.allCases.count)
            for (index, item) in AstroParameter.allCases.enumerated() {
                let button = try XCTUnwrap(AstroModeDiagnostics.parameterButtonFrames[item])
                XCTAssertEqual(button.minX, bar.minX + width * CGFloat(index), accuracy: 0.5)
                XCTAssertEqual(button.width, width, accuracy: 0.5)
            }
            parameter.wrappedValue = .iso
            try await wait { AstroModeDiagnostics.parameterHeaderButtonFrame.width > 0 }
            parameter.wrappedValue = nil
            try await Task.sleep(for: .milliseconds(200))
            let start = CACurrentMediaTime()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertNotNil(image.cgImage)
            timings.append((CACurrentMediaTime() - start) * 1000)
        }
        print("ASTRO-PARAMETER-GLASS samples=\(timings.count) snapshotMilliseconds=\(timings)")
        model.selectTopLevelMode(.photo)
        try await wait { model.topLevelMode == .photo && model.modeHandoffTarget == nil }
        #endif
    }

    func testDefaultAutoISOAndRestoreAutoUsesMeteredReadout() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical star preview")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo) }
        try await wait { model.camera.ready && model.camera.preview != nil }
        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.previewReady && model.modeHandoffTarget == nil }
        let photo = try XCTUnwrap(AstroModeDiagnostics.photo)
        let trails = try XCTUnwrap(AstroModeDiagnostics.trails)
        let timelapse = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        let binding = try XCTUnwrap(AstroModeDiagnostics.parameterBinding)
        let parameterText = try XCTUnwrap(AstroModeDiagnostics.parameterText)
        let restoreAuto = try XCTUnwrap(AstroModeDiagnostics.restoreParameterAuto)
        XCTAssertTrue(photo.manualSettings.isoAutomatic)
        XCTAssertTrue(trails.manualSettings.isoAutomatic)
        XCTAssertTrue(timelapse.manualSettings.isoAutomatic)
        restoreAuto(.iso)
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(parameterText(.iso),CameraNumericText.integer(binding(.iso).wrappedValue))
        binding(.iso).wrappedValue = 800
        XCTAssertEqual(parameterText(.iso),"800")
        try await wait { !photo.manualSettings.isoAutomatic && photo.manualSettings.iso == 800 }
        restoreAuto(.iso)
        try await wait { photo.manualSettings.isoAutomatic }
        XCTAssertEqual(photo.manualSettings.iso,800)
        try await wait { parameterText(.iso) != "—" }
        XCTAssertEqual(parameterText(.iso),CameraNumericText.integer(binding(.iso).wrappedValue))
        print("ASTRO-DEFAULT-ISO modes=3 transitions=2 manual=800 live=\(parameterText(.iso)) PhotosWrites=0")
        model.selectTopLevelMode(.photo)
        try await wait { model.topLevelMode == .photo && model.modeHandoffTarget == nil }
        #endif
    }

    func testParameterPanelOccludesPreviewAndShutterControlsCapture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical preview and capture engines")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        defer { model.selectTopLevelMode(.photo) }
        try await wait { model.camera.ready && model.camera.preview != nil }
        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.previewReady && model.modeHandoffTarget == nil }
        let readings = await model.camera.astroSharedCaptureSession.readPreviewParameters()
        XCTAssertGreaterThan(try XCTUnwrap(readings).iso,0)
        let selection = try XCTUnwrap(AstroModeDiagnostics.parameterSelection)
        let binding = try XCTUnwrap(AstroModeDiagnostics.parameterBinding)
        let parameterText = try XCTUnwrap(AstroModeDiagnostics.parameterText)
        let restoreAuto = try XCTUnwrap(AstroModeDiagnostics.restoreParameterAuto)
        let photo = try XCTUnwrap(AstroModeDiagnostics.photo)
        let trails = try XCTUnwrap(AstroModeDiagnostics.trails)
        let timelapse = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        selection.wrappedValue = .iso
        restoreAuto(.iso)
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(parameterText(.iso),CameraNumericText.integer(binding(.iso).wrappedValue))
        binding(.iso).wrappedValue = 800
        XCTAssertEqual(parameterText(.iso),"800")
        binding(.wb).wrappedValue = 5500
        XCTAssertEqual(parameterText(.wb),"5500K")
        binding(.tint).wrappedValue = -20
        XCTAssertEqual(parameterText(.tint),"-20")
        XCTAssertEqual(binding(.wb).wrappedValue,5500)
        binding(.ev).wrappedValue = 1.2
        XCTAssertEqual(parameterText(.ev),"+1.2")
        binding(.shutter).wrappedValue = 0.2
        XCTAssertEqual(parameterText(.shutter),"1/5")
        selection.wrappedValue = nil
        try await Task.sleep(for:.milliseconds(250))
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        func isPreview(_ view: UIView?) -> Bool {
            var candidate = view
            while let view = candidate {
                if view.layer is AVCaptureVideoPreviewLayer { return true }
                candidate = view.superview
            }
            return false
        }
        let previewPoint = try XCTUnwrap(stride(from: 100, to: Int(window.bounds.midY), by: 15)
            .map { CGPoint(x:window.bounds.midX,y:CGFloat($0)) }
            .first { isPreview(window.hitTest($0,with:nil)) })
        var presentations = [Double]()
        for item in [AstroParameter.iso,.shutter,.ev,.iso,.shutter,.wb] {
            let start = CACurrentMediaTime()
            selection.wrappedValue = item
            try await wait { !isPreview(window.hitTest(previewPoint,with:nil)) }
            presentations.append((CACurrentMediaTime()-start)*1000)
            if item != .shutter {
                try await wait { AstroModeDiagnostics.parameterHeaderButtonFrame.width == 36 }
                let frame = AstroModeDiagnostics.parameterHeaderButtonFrame
                for x in [frame.minX+2,frame.midX,frame.maxX-2] {
                    let hit = window.hitTest(CGPoint(x:x,y:frame.midY),with:nil)
                    XCTAssertNotNil(hit)
                    XCTAssertFalse(isPreview(hit))
                }
            }
            selection.wrappedValue = nil
            try await wait { isPreview(window.hitTest(previewPoint,with:nil)) }
        }
        let shutter = try XCTUnwrap(AstroModeDiagnostics.shutterAction)
        let enabled = try XCTUnwrap(AstroModeDiagnostics.shutterEnabled)
        trails.autoSaveOnFinish = false
        // Stop each route before any exposure can finish, so no asset reaches Photos.
        for mode in AstroCaptureMode.allCases {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            // Yield across the previous submode's state before waiting for its replacement.
            try await Task.sleep(for:.milliseconds(100))
            try await wait { AstroModeDiagnostics.previewReady }
            XCTAssertTrue(enabled())
            shutter()
            XCTAssertTrue(photo.isCapturing || trails.isCapturing || timelapse.isRecording, mode.rawValue)
            XCTAssertTrue(enabled())
            shutter()
            try await wait { !photo.isCapturing && !trails.isCapturing && !timelapse.isRecording && !timelapse.isFinishing }
        }
        print("ASTRO_PARAMETER_SHUTTER presentations=\(presentations.count) blockDelayMS=\(presentations) captureRoutes=3 PhotosWrites=0")
        model.selectTopLevelMode(.photo)
        try await wait { model.topLevelMode == .photo && model.modeHandoffTarget == nil }
        #endif
    }

    func testVisiblePhotoVideoStarHandoffsAndRapidExit() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real camera sessions and preview-layer rendering")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        defer { model.cancelModeHandoff(); model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        model.setCameraActive(true)
        try await wait { model.camera.ready && model.camera.preview != nil && model.modeHandoffTarget == nil }
        let stops = AstroSessionStopCounter()
        let observation = model.camera.astroSharedCaptureSession.session.observe(\.isRunning, options: [.new]) { _, value in
            if value.newValue == false { stops.increment() }
        }
        defer { observation.invalidate() }
        var entering = [Double](), leaving = [Double]()
        for (index, ratio) in FrameRatio.allCases.enumerated() {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(160))
            let source = try XCTUnwrap(model.camera.preview)
            let start = CACurrentMediaTime()
            model.selectTopLevelMode(.astro)
            try await wait { model.topLevelMode == .astro }
            XCTAssertTrue(model.modeHandoffImage === source)
            try await wait { model.modeHandoffTarget == nil }
            XCTAssertFalse(model.modeHandoffTimedOut, "Must release on actual preview, not the timeout")
            entering.append(CACurrentMediaTime() - start)
            try await wait { AstroModeDiagnostics.photo?.previewFrames.snapshot != nil }
            if ratio == .wide || ratio == .standard || ratio == .square,
               let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) {
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                    window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                }
                let drawMS = (CACurrentMediaTime()-start)*1000
                try assertToolbarOutsideIsEmpty(shot,clip:AstroModeDiagnostics.toolbarClipFrame)
                let attachment = XCTAttachment(image:shot)
                attachment.name = "Astro-Toolbar-\(ratio.rawValue)"
                attachment.lifetime = .keepAlways; add(attachment)
                print("ASTRO-TOOLBAR-CLIP ratio=\(ratio.rawValue) snapshotMilliseconds=\(drawMS)")
            }
            XCTAssertTrue(AstroModeDiagnostics.photo?.session === model.camera.astroSharedCaptureSession.session)
            XCTAssertTrue(AstroModeDiagnostics.trails?.session === model.camera.astroSharedCaptureSession.session)
            XCTAssertTrue(AstroModeDiagnostics.timelapse?.session === model.camera.astroSharedCaptureSession.session)
            if index % 3 == 1 {
                print("SHARED-STAGE switching trails")
        AstroModeDiagnostics.submode?.wrappedValue = .trails
                try await wait { AstroModeDiagnostics.trails?.previewFrames.snapshot != nil && AstroModeDiagnostics.previewReady }
            } else if index % 3 == 2 {
                AstroModeDiagnostics.submode?.wrappedValue = .timelapse
                try await wait { AstroModeDiagnostics.timelapse?.previewFrames.snapshot != nil && AstroModeDiagnostics.previewReady }
            }
            let snapshot: UIImage?
            switch AstroModeDiagnostics.submode?.wrappedValue {
            case .trails: snapshot = AstroModeDiagnostics.trails?.previewFrames.snapshot
            case .timelapse: snapshot = AstroModeDiagnostics.timelapse?.previewFrames.snapshot
            default: snapshot = AstroModeDiagnostics.photo?.previewFrames.snapshot
            }
            let outgoing = try XCTUnwrap(snapshot)
            let stores = [AstroModeDiagnostics.photo?.previewFrames, AstroModeDiagnostics.trails?.previewFrames, AstroModeDiagnostics.timelapse?.previewFrames]
            for store in stores.compactMap({ $0 }) where store.metrics.count > 0 {
                let metrics = store.metrics
                print("ASTRO-HANDOFF-PROXY samples=\(metrics.count) meanMilliseconds=\(metrics.totalSeconds / Double(metrics.count) * 1000) maxMilliseconds=\(metrics.maximumSeconds * 1000) longestSide<=960 outputThrottle=4Hz; CI downsample+bitmap, not FPS")
            }
            XCTAssertLessThanOrEqual(max(outgoing.size.width, outgoing.size.height), 961)
            let target: CameraViewModel.TopLevelMode = index.isMultiple(of: 2) ? .video : .photo
            let back = CACurrentMediaTime()
            model.selectTopLevelMode(target, outgoingPreview: outgoing)
            XCTAssertTrue(model.modeHandoffImage === outgoing)
            try await wait { model.modeHandoffTarget == nil }
            XCTAssertFalse(model.modeHandoffTimedOut)
            XCTAssertEqual(model.topLevelMode, target)
            XCTAssertTrue(model.camera.ready)
            XCTAssertEqual(model.captureKind, target == .video ? .video : .photo)
            leaving.append(CACurrentMediaTime() - back)
        }
        // Exit before the delayed Astro startup. The abandoned engine must stay stopped.
        for index in 0..<3 {
            model.selectTopLevelMode(.astro)
            try await wait { AstroModeDiagnostics.photo != nil }
            let abandoned = try XCTUnwrap(AstroModeDiagnostics.photo)
            if index == 1 { abandoned.switchLens(to: .builtInUltraWideCamera) }
            try await Task.sleep(for: .milliseconds(60))
            model.selectTopLevelMode(.photo)
            try await wait { model.modeHandoffTarget == nil && model.camera.ready }
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertFalse(abandoned.ownsCaptureRoute)
            XCTAssertFalse(model.modeHandoffTimedOut)
        }
        model.selectTopLevelMode(.astro)
        model.cancelModeHandoff()
        XCTAssertNil(model.modeHandoffImage)
        model.selectTopLevelMode(.photo)
        try await wait { model.modeHandoffTarget == nil && model.camera.ready }
        XCTAssertEqual(stops.value, 0, "Mode handoff must keep the shared session running")
        print("ASTRO-MODE-HANDOFF sessionStops=\(stops.value) enterSamples=8 enterSeconds=\(entering) returnSamples=8 returnSeconds=\(leaving) ratios=8 starSubmodes=3 rapidExit=3 noTimeout=true PhotosWrites=0; request through actual-preview signal and fade cleanup, not display FPS")
        #endif
    }
    func testSharedSessionCapturesRawTrailsAndTimelapseThenRestoresNormal() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real shared capture hardware")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        defer { model.cancelModeHandoff(); model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        model.setCameraActive(true)
        try await wait { model.camera.ready && model.camera.preview != nil && model.modeHandoffTarget == nil }
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro && model.modeHandoffTarget == nil }
        let photo = try XCTUnwrap(AstroModeDiagnostics.photo)
        photo.manualSettings.isoAutomatic = true; photo.manualSettings.exposureBias = 1
        photo.manualSettings.photoShutterSeconds = 0.5; photo.frameCount = 2
        print("SHARED-STAGE RAW begin")
        photo.begin()
        try await wait(timeout: 30) { photo.result != nil || photo.error != nil }
        XCTAssertNil(photo.error); XCTAssertEqual(photo.capturedFrames, 2)
        let rawImage = try XCTUnwrap(photo.result?.cgImage)
        XCTAssertEqual(rawImage.width * rawImage.height, 4032 * 3024)
        print("SHARED-STAGE RAW complete")
        photo.save(); try await wait(timeout: 20) { !photo.isSaving }
        XCTAssertNil(photo.error)
        AstroModeDiagnostics.submode?.wrappedValue = .trails
        let trails = try XCTUnwrap(AstroModeDiagnostics.trails)
        try await wait { trails.ownsCaptureRoute && trails.previewFrames.snapshot != nil && AstroModeDiagnostics.previewReady }
        trails.autoSaveOnFinish = false; trails.captureDurationSeconds = 1
        trails.manualSettings.isoAutomatic = true; trails.manualSettings.exposureBias = 1
        print("SHARED-STAGE trails begin")
        trails.begin(); try await wait(timeout: 30) { trails.result != nil || trails.error != nil }
        XCTAssertNotNil(trails.result); XCTAssertNil(trails.error)
        print("SHARED-STAGE trails complete")
        let frameCount = trails.capturedCount
        AstroModeDiagnostics.submode?.wrappedValue = .timelapse
        let video = try XCTUnwrap(AstroModeDiagnostics.timelapse)
        try await wait { video.ownsCaptureRoute && video.previewFrames.snapshot != nil && AstroModeDiagnostics.previewReady }
        video.intervalSeconds = 1; video.durationMinutes = nil
        video.manualSettings.isoAutomatic = true; video.manualSettings.exposureBias = 1
        print("SHARED-STAGE timelapse begin")
        video.begin(); try await wait(timeout: 30) { video.capturedFrames >= 3 || video.error != nil }
        XCTAssertNil(video.error)
        print("SHARED-STAGE timelapse stop")
        video.stopAndSave(manual: true)
        try await wait(timeout: 20) { !video.isFinishing }
        XCTAssertNil(video.error)
        let store = AstroRecoveryStore.shared
        store.reload(); try await wait { store.items.contains { $0.kind == "星空延时" && $0.phase == "ready" } }
        let item = try XCTUnwrap(store.items.last { $0.kind == "星空延时" && $0.phase == "ready" })
        let file = try XCTUnwrap(store.journal.url(for: item))
        let asset = AVURLAsset(url: file), tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first), size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 2160, height: 3840))
        print("SHARED-STAGE return photo")
        model.selectTopLevelMode(.photo, outgoingPreview: video.previewFrames.snapshot)
        try await wait { model.topLevelMode == .photo && model.camera.ready && model.modeHandoffTarget == nil }
        XCTAssertFalse(model.modeHandoffTimedOut)
        let camera = model.camera, originalVideoCallback = model.camera.onVideoRecorded
        var movie: Result<URL, Error>?
        camera.onVideoRecorded = { movie = $0 }
        defer { camera.onVideoRecorded = originalVideoCallback }
        model.selectTopLevelMode(.video)
        try await wait { model.captureKind == .video && camera.ready && !camera.videoConfiguring && !model.captureKindSwitching }
        camera.startVideoRecording(aspect: .wide)
        try await wait { camera.videoRecording }
        try await Task.sleep(for: .milliseconds(1200))
        camera.stopVideoRecording()
        try await wait(timeout: 20) { movie != nil && !camera.videoBusy }
        let normalFile = try XCTUnwrap(movie?.get())
        defer { try? FileManager.default.removeItem(at: normalFile) }
        let normalAsset = AVURLAsset(url: normalFile), normalReader = try AVAssetReader(asset: normalAsset)
        let normalTracks = try await normalAsset.loadTracks(withMediaType: .video)
        let normalTrack = try XCTUnwrap(normalTracks.first)
        let normalOutput = AVAssetReaderTrackOutput(track: normalTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        normalReader.add(normalOutput); XCTAssertTrue(normalReader.startReading())
        var decoded = 0
        while normalOutput.copyNextSampleBuffer() != nil { decoded += 1 }
        XCTAssertEqual(normalReader.status, .completed); XCTAssertGreaterThan(decoded, 15)
        model.selectTopLevelMode(.photo)
        try await wait { model.captureKind == .photo && camera.ready && !model.captureKindSwitching }
        print("ASTRO-SHARED-NORMAL-VIDEO decodedFrames=\(decoded) PhotosWrites=0")
        print("ASTRO-SHARED-CAPTURE sameSession=true RAW=4032x3024 RAWFrames=2 trailsFrames=\(frameCount) timelapseFrames=\(video.capturedFrames) timelapse=2160x3840 autoISOEV=true returnPhoto=true PhotosWrites=0")
        #endif
    }

    func testEntryScreenFramesForHandoffDiagnosis() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real preview compositing")
        #else
        guard ProcessInfo.processInfo.environment["LUMA_RUN_SCREEN_HANDOFF_TEST"] == "1" else {
            throw XCTSkip("Requires coordinated on-device screen-recording permission")
        }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(true)
        defer { model.cancelModeHandoff(); model.selectTopLevelMode(.photo) }
        try await wait { model.camera.ready && model.camera.preview != nil }
        let recorder = RPScreenRecorder.shared(), frames = AstroHandoffScreenFrames()
        recorder.isMicrophoneEnabled = false
        defer { if recorder.isRecording { recorder.stopCapture { _ in } } }
        XCTAssertTrue(recorder.isAvailable)
        print("SCREEN-HANDOFF-PERMISSION allow the iOS App screen recording prompt; no audio or Photos writes")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { sample, type, _ in
                if type == .video { frames.receive(sample) }
            }) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await Task.sleep(for: .seconds(1))
        try await wait { model.camera.ready && model.camera.preview != nil }
        frames.begin()
        model.selectTopLevelMode(.astro)
        try await wait { model.topLevelMode == .astro }
        try await wait { model.modeHandoffTarget == nil }
        try await Task.sleep(for: .milliseconds(300))
        frames.end()
        await withCheckedContinuation { continuation in recorder.stopCapture { _ in continuation.resume() } }
        for (index, frame) in frames.images.enumerated() {
            let attachment = XCTAttachment(image: UIImage(cgImage: frame.image))
            attachment.name = String(format: "Screen-%03d-%.3fs", index, frame.seconds)
            attachment.lifetime = .keepAlways; add(attachment)
        }
        print("SCREEN-HANDOFF frames=\(frames.images.count) capture=actualScreen microphone=false PhotosWrites=0")
        #endif
    }

    private func controlInkPixels(_ image: UIImage, in region: CGRect) -> Int {
        let scale = image.scale
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale,
            width: region.width * scale, height: region.height * scale).integral
        guard let crop = image.cgImage?.cropping(to: pixels) else { return 0 }
        var rgba = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: rgba.count, by: 4).count { rgba[$0] > 175 && rgba[$0 + 1] > 70 }
    }

    private func assertToolbarOutsideIsEmpty(_ image: UIImage, clip: CGRect) throws {
        let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
        XCTAssertGreaterThan(clip.width,0)
        var pixels = [UInt8](repeating:0,count:w*h*4)
        let context = try XCTUnwrap(CGContext(data:&pixels,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
        let scale = image.scale
        let top = max(0,Int((clip.minY+3)*scale)), bottom = min(h,Int((clip.maxY-3)*scale))
        let left = max(0,Int((clip.minX-2)*scale)), right = min(w,Int((clip.maxX+2)*scale))
        var maximum = 0
        for y in top..<bottom {
            for x in 0..<w where x < left || x >= right {
                let i = (y*w+x)*4
                maximum = max(maximum,Int(pixels[i]),Int(pixels[i+1]),Int(pixels[i+2]))
            }
        }
        XCTAssertLessThanOrEqual(maximum,8,"Toolbar labels must stay inside the preview's horizontal sides")
    }

    private func wait(timeout: Double = 12, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
        if !condition() { throw CancellationError() }
    }
}

private final class AstroSessionStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class AstroHandoffScreenFrames: @unchecked Sendable {
    struct Frame { let image: CGImage; let seconds: Double }
    private let lock = NSLock(), context = CIContext(options: [.cacheIntermediates: false])
    private var started: Double?
    private var frames = [Frame]()
    var images: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
    func begin() { lock.lock(); started = ProcessInfo.processInfo.systemUptime; frames = []; lock.unlock() }
    func end() { lock.lock(); started = nil; lock.unlock() }
    func receive(_ sample: CMSampleBuffer) {
        lock.lock(); let start = started, count = frames.count; lock.unlock()
        guard let start, count < 180, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 480 / max(image.extent.width, image.extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(reduced, from: reduced.extent) else { return }
        let frame = Frame(image: cg, seconds: ProcessInfo.processInfo.systemUptime - start)
        lock.lock(); if started != nil { frames.append(frame) }; lock.unlock()
    }
}
