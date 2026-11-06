import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

final class AutomaticLensStabilityPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testExplicitFocalSwitchClearsPreviousMacroBadgeImmediately() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldMode = model.mode, oldFormat = model.photoFormat, oldHDR = model.hdr
        let oldLive = model.livePhotoEnabled, oldLensID = camera.selectedLens
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.setMacroActiveForTesting(false)
            model.photoFormat = oldFormat; model.hdr = oldHDR
            if oldLive && !model.livePhotoEnabled && model.livePhotoAvailable { model.toggleLivePhoto() }
            if let oldLens = camera.lenses.first(where: { $0.id == oldLensID }) { model.selectFocalLength(oldLens) }
            model.setMode(oldMode); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        let ultraWide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 0.5) < 0.01 })

        for _ in 0..<6 {
            camera.setMacroActiveForTesting(true)
            model.selectFocalLength(ultraWide)
            XCTAssertFalse(camera.macroActive, "A previous route's macro badge must clear as soon as the user selects another focal length")
            for _ in 0..<300 where !camera.ready { try await Task.sleep(for: .milliseconds(10)) }

            camera.setMacroActiveForTesting(true)
            model.selectFocalLength(main)
            XCTAssertFalse(camera.macroActive, "Switching back to the main camera must not carry the prior ultra-wide macro badge")
            for _ in 0..<300 where !camera.ready { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @MainActor func testAutomaticRouteRestoresAfterModeAndFrontSwitches() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let mode = model.mode, oldISO = model.iso, shutter = model.shutter, exposure = model.manualExposure
        let focus = model.focus, manualFocus = model.manualFocus, format = model.photoFormat, hdr = model.hdr
        let idle = UIApplication.shared.isIdleTimerDisabled, live = model.livePhotoEnabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { if live && !model.livePhotoEnabled && model.livePhotoAvailable { model.toggleLivePhoto() }; model.iso=oldISO;model.shutter=shutter;model.manualExposure=exposure;model.focus=focus;model.manualFocus=manualFocus;model.photoFormat=format;model.hdr=hdr;model.setMode(mode);model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle }
        model.photoFormat = .jpeg; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setCameraActive(true);model.setMode(.auto)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(20)) }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        model.selectFocalLength(main)
        for _ in 0..<300 { if camera.ready && model.focalTransitionImage == nil { break };try await Task.sleep(for:.milliseconds(10)) }
        for pass in 0..<4 {
            model.setMode(.manual)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.manualFocus = true; model.focus = pass % 2 == 0 ? 0.1 : 0.95
            camera.setFocus(position:model.focus)
            model.manualExposure = true; model.iso = 400;model.shutter=log2(1.0/125);model.applyExposure()
            try await Task.sleep(for:.milliseconds(400))
            let before = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            print("ROUTE-START pass=\(pass) before=\(before)")
            let start=CACurrentMediaTime()
            model.setMode(.auto)
            var last=""
            while CACurrentMediaTime()-start < 3 {
                let snapshot=await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
                if snapshot != last { print("ROUTE-SAMPLE pass=\(pass) t=\(CACurrentMediaTime()-start) macro=\(camera.macroActive) \(snapshot)");last=snapshot }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(camera.ready);XCTAssertNotNil(camera.preview)
            let route = await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { c.resume(returning:($0,$1,$2,$3)) } }
            XCTAssertTrue(route.0)
            XCTAssertEqual(route.1,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue)
            XCTAssertEqual(route.2,0)
            XCTAssertNotNil(route.3)
            let fallbackTypes = await withCheckedContinuation { c in camera.automaticFallbackTypesForTesting { c.resume(returning:$0) } }
            let candidates = await withCheckedContinuation { c in camera.automaticConstituentTypesForTesting { members, supported in c.resume(returning: (members, supported)) } }
            XCTAssertTrue(candidates.0.contains(.builtInUltraWideCamera), "虚拟多摄保留超广角成员")
            XCTAssertEqual(Set(fallbackTypes), Set(candidates.1), "保留系统支持的完整 fallback 集合")
        }
        for pass in 4..<6 {
            model.flipCamera()
            for _ in 0..<300 { if camera.ready && model.focalTransitionImage == nil { break };try await Task.sleep(for:.milliseconds(10)) }
            let start=CACurrentMediaTime();model.flipCamera()
            var last=""
            while CACurrentMediaTime()-start < 3 {
                let snapshot=await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
                if snapshot != last { print("ROUTE-SAMPLE pass=\(pass) t=\(CACurrentMediaTime()-start) macro=\(camera.macroActive) \(snapshot)");last=snapshot }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(camera.ready);XCTAssertNotNil(camera.preview)
            let route = await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { c.resume(returning:($0,$1,$2,$3)) } }
            XCTAssertTrue(route.0)
            XCTAssertEqual(route.1,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue)
            XCTAssertEqual(route.2,0)
            XCTAssertNotNil(route.3)
            let fallbackTypes = await withCheckedContinuation { c in camera.automaticFallbackTypesForTesting { c.resume(returning:$0) } }
            let candidates = await withCheckedContinuation { c in camera.automaticConstituentTypesForTesting { members, supported in c.resume(returning: (members, supported)) } }
            XCTAssertTrue(candidates.0.contains(.builtInUltraWideCamera), "虚拟多摄保留超广角成员")
            XCTAssertEqual(Set(fallbackTypes), Set(candidates.1), "保留系统支持的完整 fallback 集合")
        }
    }
    @MainActor func testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit=SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let mode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto)
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1) < 0.01 })
        model.selectFocalLength(wide)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(1000))
        func state() async -> (Bool,Int,UInt,String?) {
            await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { c.resume(returning:($0,$1,$2,$3)) } }
        }
        func assertSystemPolicy(_ value:(Bool,Int,UInt,String?),file:StaticString = #filePath,line:UInt = #line) {
            XCTAssertTrue(value.0,file:file,line:line)
            XCTAssertTrue([AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue,
                           AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.locked.rawValue].contains(value.1),file:file,line:line)
            XCTAssertEqual(value.2,0,file:file,line:line)
        }
        let initial = await state(); assertSystemPolicy(initial); XCTAssertNotNil(initial.3)
        let fallbackTypes = await withCheckedContinuation { c in camera.automaticFallbackTypesForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(fallbackTypes.contains(.builtInUltraWideCamera)); XCTAssertTrue(fallbackTypes.contains(.builtInWideAngleCamera))
        // Scene-dependent fallback selection remains delegated to the system after focus/EV changes.
        for index in 0..<8 {
            camera.focus(at:CGPoint(x:Double(index%3)/3+0.1,y:Double(index%2)/2+0.1))
            camera.setExposure(iso:nil,seconds:nil,bias:index%2 == 0 ? 0:0.5)
            try await Task.sleep(for:.milliseconds(150))
            let current = await state(); assertSystemPolicy(current)
        }
        for zoom:CGFloat in [0.5,1,2,4,8,40,1] {
            let started=CACurrentMediaTime()
            camera.setContinuousZoom(zoom)
            var actual:CGFloat = -1
            while CACurrentMediaTime()-started<3 {
                actual=await withCheckedContinuation{c in camera.zoomStateForTesting{value,_,_ in c.resume(returning:value)}}
                if abs(actual-zoom)<0.01,camera.previewFrameTimeForTesting>started {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertEqual(actual,zoom,accuracy:0.01,"不能只更新界面倍率")
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting,started)
            print("AUTO-LENS-ZOOM target=\(zoom) actual=\(actual) observedSeconds=\(CACurrentMediaTime()-started) includesHardwareAndNewPreview=true notFPS=true")
            let current = await state(); assertSystemPolicy(current)
            let types = await withCheckedContinuation { c in camera.automaticFallbackTypesForTesting { c.resume(returning: $0) } }
            XCTAssertEqual(Set(types), Set(fallbackTypes))
            XCTAssertEqual(camera.currentZoom,zoom,accuracy:0.01)
            XCTAssertLessThanOrEqual(camera.continuousZoomRange.lowerBound,0.5)
            XCTAssertGreaterThanOrEqual(camera.continuousZoomRange.upperBound,40)
        }
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let manual = await state(); XCTAssertFalse(manual.0)
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(700))
        let restored = await state(); assertSystemPolicy(restored)
        camera.stop()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let stopped = await state(); XCTAssertEqual(stopped.1,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue)
        camera.start()
        for _ in 0..<150 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        let resumed = await state(); assertSystemPolicy(resumed)
    }
    @MainActor func testExternalLockedStateCannotClampUserZoomOrBlockModeChanges() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        func behavior() async -> Int {
            await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { _,b,_,_ in c.resume(returning:b) } }
        }
        await withCheckedContinuation { c in camera.holdCurrentSceneLensForTesting { c.resume() } }
        let first = await behavior()
        XCTAssertEqual(first,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.locked.rawValue)
        try await Task.sleep(for:.seconds(1))
        let held = await behavior()
        XCTAssertEqual(held,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.locked.rawValue)
        XCTAssertLessThanOrEqual(camera.continuousZoomRange.lowerBound,0.5)
        camera.setContinuousZoom(0.5)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertEqual(camera.currentZoom,0.5,accuracy:0.01)
        // 0.5× 现在落到物理超广角，behavior 查询返回物理设备的 unsupported=0；
        // 这里验证用户缩放仍能继续到长焦，不把物理路由误判为锁定。
        XCTAssertEqual(camera.currentZoom,0.5,accuracy:0.01)
        camera.setContinuousZoom(8)
        for _ in 0..<200 { if camera.ready && abs(camera.currentZoom-8)<0.02 { break }; try await Task.sleep(for:.milliseconds(20)) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertEqual(camera.currentZoom,8,accuracy:0.02)
        await withCheckedContinuation { c in camera.holdCurrentSceneLensForTesting { c.resume() } }
        let previousPreview = camera.preview, switchStart = CACurrentMediaTime()
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        // A session-queue barrier precedes delivery of its first video frame.
        // Assert a fresh frame, rather than reading the intentionally cleared old one.
        for _ in 0..<150 {
            if camera.preview != nil && camera.preview !== previousPreview && model.focalTransitionImage == nil { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let manual = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        XCTAssertFalse(try XCTUnwrap(manual).virtual)
        XCTAssertNotNil(camera.preview)
        XCTAssertFalse(camera.preview === previousPreview)
        XCTAssertNil(model.focalTransitionImage)
        XCTAssertLessThan(CACurrentMediaTime()-switchStart,2.0)
    }
    #endif
}
