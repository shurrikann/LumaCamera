import XCTest
import AVFoundation
import ImageIO
@testable import LumaCamera

/// 未开拍的预设恢复：独立存档/引擎模拟进程重建，不写用户偏好或系统相册。
final class SlowShutterLifecyclePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testAllIdlePresetsRestoreIntoResponsiveCamera() async throws {
        let visible=try await FullDeviceRegressionFixture.makeFreshModel()
        visible.setCameraActive(false)
        await withCheckedContinuation { c in visible.camera.afterPendingSessionTasks { c.resume() } }
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle;audit.finish() }
        var durations=[Double]()
        for preset in SlowShutterPreset.allCases {
            let name="SlowIdleRestore-"+UUID().uuidString
            let defaults=try XCTUnwrap(UserDefaults(suiteName:name))
            defer { defaults.removePersistentDomain(forName:name) }
            let store=CapturePreferencesStore(defaults:defaults)
            var saved=SavedCaptureState()
            if let raw=ProcessInfo.processInfo.environment["LUMA_IDLE_RESTORE_STATE"] {
                saved=try JSONDecoder().decode(SavedCaptureState.self,from:Data(raw.utf8))
            }
            saved.slowShutter=true
            saved.slowShutterPreset=preset.rawValue;saved.slowShutterDuration=preset.defaultCaptureDuration.rawValue
            store.saveCaptureState(saved)
            if let raw=ProcessInfo.processInfo.environment["LUMA_IDLE_RESTORE_PREFERENCES"] {
                store.save(try JSONDecoder().decode(CapturePreferences.self,from:Data(raw.utf8)))
            }
            let began=CACurrentMediaTime()
            print("SLOW-IDLE-COLD begin preset=\(preset.rawValue)")
            let model=AppDependencies.makeCameraModel(automaticallySave:false,filterSettings:FilterSettingsStore(defaults:nil),preferencesStore:store),camera=model.camera
            defer { model.setCameraActive(false) }
            model.setCameraActive(true)
            try await wait("冷启动相机",camera:camera) { camera.ready && camera.preview != nil && !model.isPreparingSubmode && !model.startupCaptureRestorationPendingForTesting }
            print("SLOW-IDLE-COLD ready preset=\(preset.rawValue) seconds=\(CACurrentMediaTime()-began) format=\(model.photoFormat.rawValue) zoom=\(camera.currentZoom)")
            // 等恢复任务及实际后续帧，不能把首个ready当作所有存档已应用。
            let frame=camera.previewFrameTimeForTesting
            try await wait("恢复后新预览",camera:camera) { camera.previewFrameTimeForTesting>frame+0.2 }
            XCTAssertTrue(model.slowShutterEnabled);XCTAssertEqual(model.selectedSlowShutterPreset,preset)
            XCTAssertTrue(model.canEditSlowShutterDuration)
            model.toggleToolbarPanel(.slowShutterDuration)
            XCTAssertEqual(model.toolbarPanel,.slowShutterDuration)
            model.closePopups();XCTAssertNil(model.toolbarPanel)
            let restored=await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            XCTAssertTrue(try XCTUnwrap(restored).slowShutterPreviewOptimizationRequested)
            XCTAssertNotNil(restored?.slowShutterAutomaticExposureMaximumSeconds)
            model.toggleSlowShutterMode();XCTAssertFalse(model.slowShutterEnabled)
            var photo:CapturedPhoto?
            camera.onCaptureCompleted={photo=$0}
            try await wait("退出预设快门",camera:camera) { camera.ready && !camera.shutterBusy && camera.canCapture() }
            model.takePhoto()
            try await wait("普通拍摄",camera:camera) {photo != nil && camera.pendingPhotoCount == 0}
            let data=try XCTUnwrap(photo?.resources.first?.data)
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let props=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            XCTAssertGreaterThan((props[kCGImagePropertyPixelWidth] as? Int ?? 0)*(props[kCGImagePropertyPixelHeight] as? Int ?? 0),model.ratio == .wide ? 8_000_000 : 10_000_000)
            durations.append(CACurrentMediaTime()-began)
            model.setCameraActive(false)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks {c.resume()} }
            print("SLOW-IDLE-COLD end preset=\(preset.rawValue) wall=\(durations.last!) pending=\(camera.pendingPhotoCount) newFrame=true popup=true ordinaryPhoto=true")
        }
        print("SLOW-IDLE-COLD samples=\(durations.count) fullFlowSeconds=\(durations) notFPS=true noPhotosWrites=true")
    }

    @MainActor func testIdlePresetsRepeatedAndRapidSessionReturn() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer {model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()}
        model.photoFormat = .heifPro;model.ratio = .wide;model.setCameraActive(true)
        try await wait("相机",camera:camera){camera.ready && camera.preview != nil}
        model.toggleSlowShutterMode()
        try await wait("慢门",camera:camera){model.slowShutterEnabled && !model.isPreparingSubmode && camera.ready}
        var times=[Double]()
        for preset in SlowShutterPreset.allCases {
            model.selectSlowShutterPreset(preset)
            for _ in 0..<2 {
                model.setCameraActive(false)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks {c.resume()} }
                let began=CACurrentMediaTime()
                model.setCameraActive(true)
                try await wait("预设恢复",camera:camera){camera.ready && camera.previewFrameTimeForTesting>began && !camera.recoveringSession}
                XCTAssertTrue(model.slowShutterEnabled);XCTAssertEqual(model.selectedSlowShutterPreset,preset)
                XCTAssertTrue(model.canEditSlowShutterDuration);XCTAssertEqual(camera.pendingPhotoCount,0)
                model.toggleToolbarPanel(.slowShutterDuration);XCTAssertEqual(model.toolbarPanel,.slowShutterDuration)
                model.closePopups();XCTAssertNil(model.toolbarPanel)
                times.append(CACurrentMediaTime()-began)
            }
            for _ in 0..<4 {model.setCameraActive(false);model.setCameraActive(true)}
            let began=CACurrentMediaTime()
            try await wait("快速恢复",camera:camera){camera.ready && camera.previewFrameTimeForTesting>began && !camera.recoveringSession}
            XCTAssertEqual(model.selectedSlowShutterPreset,preset)
            XCTAssertNil(model.toolbarPanel)
        }
        print("SLOW-IDLE-RETURN normalSamples=\(times.count) recoverySeconds=\(times) rapidInactiveActivePairs=20 presets=5 pending=\(camera.pendingPhotoCount) notRealOSSuspension=true notFPS=true")
    }

    @MainActor func testActualBackgroundReturnWithIdleLightTrailsPreset() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_REAL_BACKGROUND_QA"] == "1" else {
            throw XCTSkip("仅显式交互复验：需要用户退主屏并返回点击")
        }
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer { model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish() }
        model.photoFormat = .heifPro;model.ratio = .wide
        model.setCameraActive(true)
        try await wait("前台相机",camera:camera){camera.ready && camera.preview != nil}
        camera.setContinuousZoom(2)
        model.toggleSlowShutterMode()
        try await wait("慢门就绪",camera:camera){model.slowShutterEnabled && !model.isPreparingSubmode && camera.ready}
        model.selectSlowShutterPreset(.lightTrails)
        var backgroundAt:Double?,returnedAt:Double?
        let background=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main){_ in
            MainActor.assumeIsolated {backgroundAt=CACurrentMediaTime();print("SLOW-IDLE-REAL enteredBackground=true")}
        }
        let foreground=NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main){_ in
            MainActor.assumeIsolated {if backgroundAt != nil {returnedAt=CACurrentMediaTime()}}
        }
        defer {NotificationCenter.default.removeObserver(background);NotificationCenter.default.removeObserver(foreground)}
        print("SLOW-IDLE-REAL READY preset=lightTrails format=HEIFPro zoom=2 awaitingUserBackground=true")
        let deadline=CACurrentMediaTime()+600
        while returnedAt == nil && CACurrentMediaTime()<deadline {try await Task.sleep(for:.milliseconds(100))}
        let returned=try XCTUnwrap(returnedAt,"需要实际退到主屏再返回")
        let backgroundTime=returned-(try XCTUnwrap(backgroundAt))
        try await wait("后台返回新预览",camera:camera){camera.ready && camera.previewFrameTimeForTesting>returned && !camera.recoveringSession}
        XCTAssertTrue(model.slowShutterEnabled);XCTAssertEqual(model.selectedSlowShutterPreset,.lightTrails)
        XCTAssertTrue(model.canEditSlowShutterDuration);XCTAssertEqual(camera.pendingPhotoCount,0)
        print("SLOW-IDLE-REAL RETURN backgroundSeconds=\(backgroundTime) newFrameSeconds=\(CACurrentMediaTime()-returned) awaitingActualDurationButton=true")
        // 返回后由真实触摸打开顶部时长，区分模型可更新与页面实际可点击。
        let inputDeadline=CACurrentMediaTime()+120
        while model.toolbarPanel != .slowShutterDuration && CACurrentMediaTime()<inputDeadline {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(model.toolbarPanel,.slowShutterDuration,"返回后需真实点击顶部时长")
        print("SLOW-IDLE-REAL END realButtonOpened=\(model.toolbarPanel == .slowShutterDuration) pending=\(camera.pendingPhotoCount) noCaptureStarted=true")
    }

    @MainActor private func wait(_ label:String,camera:CameraEngine,_ condition:()->Bool) async throws {
        let deadline=CACurrentMediaTime()+15
        while CACurrentMediaTime()<deadline {
            if condition(){return}
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTFail(label+" ready=\(camera.ready) recovering=\(camera.recoveringSession) pending=\(camera.pendingPhotoCount) message=\(camera.message ?? "nil")")
        throw CancellationError()
    }
    #endif
}
