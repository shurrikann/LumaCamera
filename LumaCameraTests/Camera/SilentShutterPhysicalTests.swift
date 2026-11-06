import XCTest
import UIKit
import ImageIO
@testable import LumaCamera

final class SilentShutterPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, oldMode = model.mode, oldPreferences = model.preferences
        let oldFormat = model.photoFormat, oldHDR = model.hdr
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = callback; model.preferences = oldPreferences
            model.photoFormat = oldFormat; model.hdr = oldHDR
            model.setMode(oldMode); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            audit.finish()
        }
        model.setCameraActive(true); model.setMode(.auto)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        camera.selectLens(wide)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        try await Task.sleep(for:.milliseconds(500))
        let cases: [(PhotoFileFormat, Bool, Bool)] = [(.jpeg,false,false),(.jpeg,true,false),(.heif,true,false),(.raw,true,false),(.rawJPEG,true,false),(.heifPro,true,false),(.tiff,true,false),(.heif,true,true),(.jpeg,true,true),(.jpeg,false,false)]
        var times: [Double] = []
        for (format, silent, live) in cases {
            model.hdr = false; model.photoFormat = format
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<300 {
                if camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 { break }
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertTrue(camera.ready); XCTAssertFalse(camera.shutterBusy); XCTAssertEqual(camera.pendingPhotoCount,0)
            try await Task.sleep(for:.milliseconds(150))
            let done = expectation(description:"Shutter sound capture \(format.rawValue)")
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; done.fulfill() }
            model.preferences.silentShutter = silent
            var options = model.photoOptions
            options.format = format; options.hdr = false; options.live = live; options.resolution = .standard
            let began = CACurrentMediaTime()
            camera.capture(flashMode:.off,options:options)
            XCTAssertEqual(camera.pendingPhotoCount,1,"Capture must be accepted before waiting for completion")
            await fulfillment(of:[done],timeout:45)
            let photo = try XCTUnwrap(result,camera.message ?? "Capture failed")
            times.append(CACurrentMediaTime() - began)
            let resource = try XCTUnwrap(photo.resources.first { !$0.pairedVideo })
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            XCTAssertNotNil(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
            XCTAssertEqual(photo.resources.contains(where: \.pairedVideo), live, "Live不能静默退化成普通照片")
            let tasks = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning: ($0,$1,$2,$3)) } }
            XCTAssertEqual(tasks.0,0); XCTAssertEqual(tasks.1,0); XCTAssertEqual(tasks.2,0); XCTAssertEqual(tasks.3,0)
            let state = await withCheckedContinuation { c in camera.shutterSoundStateForTesting { c.resume(returning:$0) } }
            let actual = try XCTUnwrap(state)
            XCTAssertEqual(actual.requested,silent)
            XCTAssertEqual(actual.enabled,silent && actual.supported)
            print("SILENT-SHUTTER format=\(format.rawValue) live=\(live) requested=\(silent) supported=\(actual.supported) enabled=\(actual.enabled) seconds=\(times.last ?? 0) resources=\(photo.resources.count) tasks=0")
        }
        print("SILENT-SHUTTER-SUMMARY samples=\(times.count) sorted=\(times.sorted())")
    }

    /// 夜景后续批次也必须沿用快门按下时的静音快照，不能只处理普通单张入口。
    @MainActor func testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, batchCallback = camera.onNightBatchSubmittedForTesting
        let idle = UIApplication.shared.isIdleTimerDisabled, preferences = model.preferences
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = callback; camera.onNightBatchSubmittedForTesting = batchCallback
            camera.nightExposureIndexForTesting = nil; camera.nightMotionForTesting = nil
            model.preferences = preferences; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        model.setCameraActive(true); model.setMode(.auto)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        if model.currentPosition != .back { model.flipCamera() }
        for _ in 0..<300 { if camera.ready && model.currentPosition == .back { break }; try await Task.sleep(for:.milliseconds(20)) }
        model.photoFormat = .jpeg; model.hdr = false
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.nightExposureIndexForTesting = 128; camera.nightMotionForTesting = .stable
        var batches: [Int] = [], states: [(Bool,Bool,Bool)] = []
        camera.onNightBatchSubmittedForTesting = { batch in
            batches.append(batch)
            // 组内后续批次沿用快门快照；中途改偏好只影响下一组照片。
            if batch == 3 { model.preferences.silentShutter = false }
            camera.shutterSoundStateForTesting { value in
                if let value { states.append((value.requested,value.supported,value.enabled)) }
            }
        }
        let done = expectation(description: "静音夜景真实6帧")
        var photo: CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0; done.fulfill() }
        model.preferences.silentShutter = true
        var options = model.photoOptions; options.nightMode = true; options.shootingType = "夜景"
        let began = CACurrentMediaTime()
        camera.capture(flashMode:.off, options:options)
        await fulfillment(of:[done],timeout:40)
        let result = try XCTUnwrap(photo,camera.message ?? "静音夜景未出片")
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        // 状态查询经会话队列再回主线程，最终出片并不保证诊断快照已交付。
        for _ in 0..<100 { if states.count == batches.count { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(batches,[3,6]); XCTAssertEqual(states.count,2)
        for state in states {
            XCTAssertTrue(state.0)
            XCTAssertEqual(state.2,state.1,"系统支持时夜景每批也必须启用静音")
        }
        XCTAssertTrue(result.diagnostics?.isNightComposite == true)
        let tasks = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning: ($0,$1,$2,$3)) } }
        XCTAssertEqual(tasks.0,0); XCTAssertEqual(tasks.1,0); XCTAssertEqual(tasks.2,0); XCTAssertEqual(tasks.3,0)
        XCTAssertFalse(model.preferences.silentShutter)
        print("SILENT-NIGHT batches=\(batches) states=\(states) seconds=\(CACurrentMediaTime()-began) tasks=0 sceneInjected=true midCapturePreferenceChanged=true")
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running)
        let previous = camera.preview, resumeTime = CACurrentMediaTime()
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview !== previous && camera.previewFrameTimeForTesting > resumeTime { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(camera.ready); XCTAssertTrue(camera.preview !== previous)
        XCTAssertGreaterThan(camera.previewFrameTimeForTesting,resumeTime)
        XCTAssertFalse(model.photoOptions.silentShutter)
    }
    #endif
}
