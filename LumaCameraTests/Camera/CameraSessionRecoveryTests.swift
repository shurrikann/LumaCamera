import AVFoundation
import SwiftUI
import XCTest
import UIKit
@testable import LumaCamera

final class CameraSessionRecoveryTests: XCTestCase {
    @MainActor func testCameraPresentationPausesSessionAndResumesFreshFrames() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical capture sessions")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, session = model.camera.previewSession
        model.setCameraActive(true)
        defer { model.review = false; model.settings = false; model.selectTopLevelMode(.photo) }
        try await PresetToolbarChecks.wait("取景就绪") { camera.ready && camera.preview != nil }

        var samples: [String: [Double]] = [:]
        for mode in [CameraViewModel.TopLevelMode.photo, .video, .astro] {
            model.selectTopLevelMode(mode)
            try await PresetToolbarChecks.wait("模式就绪 \(mode)") {
                model.topLevelMode == mode && model.modeHandoffTarget == nil && session.isRunning
                    && (mode == .astro ? AstroModeDiagnostics.previewReady : camera.ready && !camera.videoConfiguring)
            }
            let astro = AstroModeDiagnostics.photo
            let frames = astro?.previewFrames
            for gallery in [true, false, true, false] {
                let label = "\(mode).\(gallery ? "gallery" : "settings")"
                let inputs = session.inputs.map(ObjectIdentifier.init)
                let outputs = session.outputs.map(ObjectIdentifier.init)
                if gallery { model.openLibrary() } else { model.presentSettings() }
                try await PresetToolbarChecks.wait("暂停 \(label)") { !session.isRunning }
                let stoppedFrame = camera.latestPreviewFrameTime
                let stoppedCount = frames?.metrics.count
                for phase in [ScenePhase.inactive, .active] {
                    model.updateCameraPresentation(isVisible: true, phase: phase)
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertFalse(session.isRunning, label)
                    XCTAssertFalse(camera.recoveringSession, label)
                    XCTAssertNil(camera.message, label)
                }
                XCTAssertEqual(camera.latestPreviewFrameTime, stoppedFrame, label)
                XCTAssertEqual(frames?.metrics.count, stoppedCount, label)
                let start = CACurrentMediaTime()
                if gallery { model.review = false } else { model.settings = false }
                try await PresetToolbarChecks.wait("恢复 \(label)") {
                    session.isRunning && (mode == .astro
                        ? (frames?.metrics.count ?? 0) > (stoppedCount ?? 0)
                        : camera.ready && camera.latestPreviewFrameTime > start)
                }
                XCTAssertEqual(session.inputs.map(ObjectIdentifier.init), inputs, label)
                XCTAssertEqual(session.outputs.map(ObjectIdentifier.init), outputs, label)
                XCTAssertFalse(camera.recoveryFailed)
                XCTAssertNil(camera.message, label)
                samples[label, default: []].append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(350))
            }
            // Dismiss during presentation and require a functioning preview again.
            model.presentSettings()
            try await Task.sleep(for: .milliseconds(80))
            let start = CACurrentMediaTime(), oldCount = frames?.metrics.count ?? 0
            model.settings = false
            try await PresetToolbarChecks.wait("快速关闭 \(mode)") {
                session.isRunning && (mode == .astro ? (frames?.metrics.count ?? 0) > oldCount
                    : camera.ready && camera.latestPreviewFrameTime > start)
            }
            try await Task.sleep(for: .milliseconds(350))
        }

        let submode = try XCTUnwrap(AstroModeDiagnostics.submode)
        for mode in [AstroCaptureMode.trails, .timelapse] {
            submode.wrappedValue = mode
            let frames = try XCTUnwrap(mode == .trails ? AstroModeDiagnostics.trails?.previewFrames
                : AstroModeDiagnostics.timelapse?.previewFrames)
            try await PresetToolbarChecks.wait("星空子模式 \(mode) 就绪") {
                AstroModeDiagnostics.previewReady && session.isRunning && frames.metrics.count >= 2
            }
            for gallery in [true, false] {
                let label = "\(mode).\(gallery ? "gallery" : "settings")"
                if gallery { model.openLibrary() } else { model.presentSettings() }
                try await PresetToolbarChecks.wait("暂停 \(label)") { !session.isRunning }
                let stoppedCount = frames.metrics.count
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(frames.metrics.count, stoppedCount, label)
                XCTAssertNil(camera.message, label)
                let start = CACurrentMediaTime()
                if gallery { model.review = false } else { model.settings = false }
                try await PresetToolbarChecks.wait("恢复 \(label)") {
                    session.isRunning && frames.metrics.count > stoppedCount
                }
                XCTAssertNil(camera.message, label)
                samples[label, default: []].append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        model.selectTopLevelMode(.photo)
        try await PresetToolbarChecks.wait("从星空返回照片") {
            model.topLevelMode == .photo && model.modeHandoffTarget == nil && camera.ready
        }
        print("CAMERA-COVER-PAUSE samplesMS=\(samples) rapidDismissals=3 PhotosWrites=0")
        #endif
    }

    @MainActor func testCinematicAndDualVideoPauseForCameraPresentation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires Cinematic and multicamera capture sessions")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, session = model.camera.previewSession
        model.setCameraActive(true)
        defer { model.review = false; model.settings = false; model.selectTopLevelMode(.photo) }
        try await PresetToolbarChecks.wait("照片就绪") { camera.ready }
        model.selectTopLevelMode(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "视频就绪")
        model.toggleCinematicVideoMode()
        try await PresetToolbarChecks.wait("电影模式就绪") {
            model.cinematicVideoEnabled && camera.cinematicVideoCaptureActive && model.videoShutterEnabled
        }
        let cinemaInput = session.inputs.map(ObjectIdentifier.init)
        var samples = [Double]()
        for gallery in [true, false] {
            if gallery { model.openLibrary() } else { model.presentSettings() }
            try await PresetToolbarChecks.wait("暂停电影会话") { !session.isRunning }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(session.isRunning)
            XCTAssertNil(camera.message)
            let start = CACurrentMediaTime()
            if gallery { model.review = false } else { model.settings = false }
            try await PresetToolbarChecks.wait("电影恢复出帧") {
                session.isRunning && camera.cinematicVideoCaptureActive && model.videoShutterEnabled
                    && camera.latestPreviewFrameTime > start
            }
            XCTAssertEqual(session.inputs.map(ObjectIdentifier.init), cinemaInput)
            XCTAssertNil(camera.message)
            samples.append((CACurrentMediaTime() - start) * 1000)
            try await Task.sleep(for: .milliseconds(350))
        }
        model.toggleCinematicVideoMode()
        try await PresetToolbarChecks.wait("普通视频就绪") {
            !model.cinematicVideoEnabled && !camera.cinematicVideoCaptureActive && model.videoShutterEnabled
        }
        model.toggleDualCapture()
        try await PresetToolbarChecks.wait("双摄就绪") { camera.dualCaptureEnabled && model.videoShutterEnabled }
        func dualState() async -> [String: String] {
            await withCheckedContinuation { result in camera.dualCaptureStateForTesting { result.resume(returning: $0) } }
        }
        let initial = await dualState()
        let source = try XCTUnwrap(initial["sourceID"])
        var dualSamples = [Double]()
        for gallery in [true, false] {
            if gallery { model.openLibrary() } else { model.presentSettings() }
            try await PresetToolbarChecks.wait("暂停双摄会话") { !camera.ready }
            try await Task.sleep(for: .milliseconds(300))
            let paused = await dualState()
            XCTAssertEqual(paused["dualRunning"], "false")
            XCTAssertEqual(paused["sourceID"], source)
            XCTAssertNil(camera.message)
            let start = CACurrentMediaTime()
            if gallery { model.review = false } else { model.settings = false }
            try await PresetToolbarChecks.wait("双摄恢复出帧") {
                camera.dualCaptureEnabled && model.videoShutterEnabled && camera.latestPreviewFrameTime > start
            }
            let resumed = await dualState()
            XCTAssertEqual(resumed["dualRunning"], "true")
            XCTAssertEqual(resumed["sourceID"], source)
            XCTAssertNil(camera.message)
            dualSamples.append((CACurrentMediaTime() - start) * 1000)
            try await Task.sleep(for: .milliseconds(350))
        }
        model.toggleDualCapture()
        try await PresetToolbarChecks.wait("退出双摄") { !camera.dualCaptureEnabled && model.videoShutterEnabled }
        print("CAMERA-COVER-VIDEO cinematicMS=\(samples) dualMS=\(dualSamples) PhotosWrites=0")
        #endif
    }

    @MainActor func testTemporaryInterruptionIsSilentAndEndedCannotRestartStoppedCamera() async throws {
        #if !targetEnvironment(simulator)
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        #else
        let camera = CameraEngine()
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("Session interruption recovery requires the simulator app to be foreground-active")
        }
        camera.start(); defer { camera.stop() }
        #endif
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        camera.simulateInterruptionForTesting(ended:false)
        for _ in 0..<50 { if camera.recoveringSession { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNil(camera.message); XCTAssertTrue(camera.recoveringSession)
        camera.simulateInterruptionForTesting(ended:true)
        for _ in 0..<300 { if camera.ready && !camera.recoveringSession { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertNil(camera.message)
        #if !targetEnvironment(simulator)
        model.setCameraActive(false)
        #endif
        camera.stop()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.simulateInterruptionForTesting(ended:true)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(camera.ready); XCTAssertFalse(camera.recoveringSession); XCTAssertNil(camera.message)
    }

    // Set TEST_RUNNER_LUMA_VERIFY_COVER_BACKGROUND=1 for xcodebuild and
    // background the app at each CAMERA-COVER-BACKGROUND-READY marker.
    @MainActor func testVisibleCoversStayPausedAcrossRealBackground() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical camera and an external foreground switch")
        #else
        guard ProcessInfo.processInfo.environment["LUMA_VERIFY_COVER_BACKGROUND"] == "1" else {
            throw XCTSkip("Requires coordinated background and foreground transitions")
        }
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, session = model.camera.previewSession
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            model.review = false; model.settings = false
            AstroModeDiagnostics.environmentSheet?.wrappedValue = false
            model.selectTopLevelMode(.photo)
        }
        let events = CoveredCameraLifecycleEvents()
        let center = NotificationCenter.default
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { events.entered += 1 }
            }
        let foreground = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { events.foreground += 1 }
            }
        defer { center.removeObserver(background); center.removeObserver(foreground) }
        model.setCameraActive(true)
        try await PresetToolbarChecks.wait("相机就绪") { camera.ready && session.isRunning }
        let target = ProcessInfo.processInfo.environment["LUMA_COVER_TARGET"]
        let modes: [(String, CameraViewModel.TopLevelMode)] = [("gallery", .photo), ("settings", .video), ("map", .astro)]
            .filter { target == nil || $0.0 == target }
        for (cover, mode) in modes {
            model.selectTopLevelMode(mode)
            try await PresetToolbarChecks.wait("入口就绪 \(cover)") {
                model.topLevelMode == mode && model.modeHandoffTarget == nil && session.isRunning
                    && (mode == .astro ? AstroModeDiagnostics.previewReady
                        : camera.ready && !camera.videoConfiguring && !model.captureKindSwitching)
            }
            if cover == "gallery" { model.openLibrary() }
            else if cover == "settings" { model.presentSettings() }
            else { try XCTUnwrap(AstroModeDiagnostics.environmentSheet).wrappedValue = true }
            try await PresetToolbarChecks.wait("打开后停采 \(cover)") { !session.isRunning }
            let dwellStart = CACurrentMediaTime()
            let requestedDwell = Double(ProcessInfo.processInfo.environment["LUMA_COVER_DWELL_SECONDS"] ?? "30") ?? 30
            let checks = Int(ceil(min(300, max(30, requestedDwell)) / 5))
            for _ in 0..<checks {
                try await Task.sleep(for: .seconds(5))
                XCTAssertFalse(session.isRunning, cover)
                XCTAssertNil(camera.message, cover)
            }
            let dwell = CACurrentMediaTime() - dwellStart
            let entered = events.entered, returned = events.foreground
            FileHandle.standardOutput.write(Data("CAMERA-COVER-BACKGROUND-READY \(cover)\n".utf8))
            let deadline = CACurrentMediaTime() + 300
            while (events.entered == entered || events.foreground == returned), CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard events.entered > entered, events.foreground > returned else {
                throw XCTSkip("未观察到用户完成 \(cover) 的真实后台／前台切换，不能判定恢复结果")
            }
            XCTAssertEqual(UIApplication.shared.applicationState, .active, cover)
            if cover == "map" {
                XCTAssertFalse(try XCTUnwrap(AstroModeDiagnostics.environmentSheet).wrappedValue)
            } else {
                XCTAssertTrue(cover == "gallery" ? model.review : model.settings)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(session.isRunning, cover)
            }
            let stoppedFrame = camera.latestPreviewFrameTime
            if cover == "gallery" { model.review = false }
            if cover == "settings" { model.settings = false }
            try await PresetToolbarChecks.wait("后台返回后恢复新帧 \(cover)") {
                session.isRunning && (mode == .astro
                    ? AstroModeDiagnostics.previewReady && (AstroModeDiagnostics.photo?.previewFrames.metrics.count ?? 0) >= 2
                    : camera.ready && camera.latestPreviewFrameTime > stoppedFrame)
            }
            XCTAssertNil(camera.message, cover)
            XCTAssertFalse(camera.recoveryFailed, cover)
            XCTAssertNil(AstroModeDiagnostics.photo?.error, cover)
            print("CAMERA-COVER-BACKGROUND-PASS \(cover) coveredSeconds=\(dwell) foregroundEvents=\(events.foreground) PhotosWrites=0")
        }
        model.selectTopLevelMode(.photo)
        try await PresetToolbarChecks.wait("返回普通拍照") { model.topLevelMode == .photo && camera.ready }
        #endif
    }

    #if !targetEnvironment(simulator)
    @MainActor func testRestartAfterInterruptedFrameGateDeliversFreshPreview() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        for _ in 0..<3 {
            let previous = camera.preview
            camera.simulateInterruptionForTesting(ended: false)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertFalse(camera.ready)
            // Re-entering the foreground must recover even without an ended notification.
            camera.start()
            for _ in 0..<300 {
                if camera.ready && camera.preview != nil && camera.preview !== previous { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertTrue(camera.preview !== previous)
            XCTAssertFalse(camera.recoveryFailed)
            XCTAssertNil(camera.message)
        }
    }
    @MainActor func testRuntimeRecoveryRestoresLiveFramesAndManualExposureWithoutWritingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, oldISO = model.iso, oldShutter = model.shutter, oldManual = model.manualExposure
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setMode(mode); model.iso = oldISO; model.shutter = oldShutter; model.manualExposure = oldManual; model.applyExposure()
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.manual); model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/125); model.applyExposure()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<4 {
            let previous = camera.preview
            camera.simulateRuntimeStopForTesting()
            try await Task.sleep(for:.milliseconds(100))
            for _ in 0..<300 {
                if camera.ready && !camera.recoveringSession && camera.preview != nil && camera.preview !== previous { break }
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertTrue(camera.ready); XCTAssertFalse(camera.recoveringSession); XCTAssertFalse(camera.recoveryFailed); XCTAssertNil(camera.message)
            var state: CameraEngine.ExposureColorState?
            for _ in 0..<100 {
                state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                if let state, abs(Double(state.iso)-400)<5, abs(state.seconds-1.0/125)<0.001 { break }
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertEqual(Double(try XCTUnwrap(state).iso),400,accuracy:5)
            XCTAssertEqual(try XCTUnwrap(state).seconds,1.0/125,accuracy:0.001)
        }
        model.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.simulateInterruptionForTesting(ended:true)
        try await Task.sleep(for:.milliseconds(150))
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
        XCTAssertFalse(running); XCTAssertFalse(camera.ready); XCTAssertNil(camera.message)
    }
    #endif
    /// 注入带真实 error key 的公开错误通知，只验证恢复契约，不冒充复现系统服务崩溃。
    @MainActor func testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        var durations: [Double] = []
        for code in [AVError.Code.unknown, .mediaServicesWereReset, .unknown, .mediaServicesWereReset] {
            let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12780)
            let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                userInfo: code == .unknown ? [NSUnderlyingErrorKey: underlying] : [:])
            let start = CACurrentMediaTime(), previousFrame = camera.previewFrameTimeForTesting
            camera.simulateRuntimeStopForTesting(error: error)
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<400 {
                if camera.ready && !camera.recoveringSession && camera.previewFrameTimeForTesting > previousFrame { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertFalse(camera.recoveryFailed)
            XCTAssertFalse(camera.recoveringSession)
            XCTAssertNil(camera.message)
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting, previousFrame)
            durations.append(CACurrentMediaTime() - start)
        }
        camera.simulateRuntimeStopForTesting(error: NSError(domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue))
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(500))
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running, "退出后迟到的服务错误不能重新启动相机")
        XCTAssertFalse(camera.ready)
        print("RUNTIME-RECOVERY-INJECTED samples=\(durations.count) p50=\(durations.sorted()[durations.count / 2]) max=\(durations.max() ?? 0) fresh-frame=true noPhotosWrites=true")
    }

    @MainActor func testLateRecoveryNotificationCannotCancelQueuedForegroundStart() async throws {
        #if targetEnvironment(simulator)
        let camera=CameraEngine()
        #else
        let model=try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(false)
        await Task.yield()
        let camera=model.camera
        #endif
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { camera.stop();UIApplication.shared.isIdleTimerDisabled=idle }
        camera.stop()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for pass in 0..<4 {
            let gate=DispatchSemaphore(value:0)
            camera.pauseSessionQueueForTesting(gate)
            camera.start()
            for _ in 0..<20 { camera.simulateInterruptionForTesting(ended:true) }
            XCTAssertFalse(camera.recoveringSession,"A queued foreground start must retain its lifecycle token")
            gate.signal()
            for _ in 0..<300 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertTrue(camera.ready);XCTAssertNotNil(camera.preview);XCTAssertFalse(camera.recoveryFailed)
            print("START-RECOVERY pass=\(pass) lateNotifications=20 ready=\(camera.ready)")
            camera.stop()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
    }

}

@MainActor private final class CoveredCameraLifecycleEvents {
    var entered = 0
    var foreground = 0
}
