import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

@MainActor final class CinematicZoomPhysicalTests:XCTestCase {
    func testFixedButtonsWheelRangeActualCinematicRouteAndRecovery() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Cinematic需要iOS26") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(),camera = model.camera
        let callback = camera.onVideoRecorded,idle = UIApplication.shared.isIdleTimerDisabled,runtime = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var recorded:Result<URL,Error>?,files = [URL]()
        camera.onVideoRecorded = { recorded = $0 }
        defer { camera.onVideoRecorded = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish(); files.forEach { try? FileManager.default.removeItem(at:$0) } }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("会话就绪") { camera.ready && !camera.videoConfiguring && !camera.videoBusy && !model.isPreparingSubmode }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.videoCodec = .hevc; model.videoColorSpace = .sdr; try await settle()
        model.toggleCinematicVideoMode(); try await settle()
        XCTAssertTrue(model.cinematicVideoEnabled); XCTAssertTrue(camera.cinematicVideoCaptureActive)
        XCTAssertEqual(model.displayedFocalLenses.map(\.displayZoom),[1,2])
        let routeID = camera.activeCaptureDeviceID
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView:CinematicZoomHost(model:model,camera:camera))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        try await Task.sleep(for:.milliseconds(300))
        var durations = [Double]()
        for mode in [CameraShootingMode.auto,.manual] {
            model.setMode(mode); model.manualExposure = true; model.manualFocus = true; model.restoreDeviceParametersForTesting(); try await settle()
            XCTAssertEqual(model.displayedManualParameters,[.ev,.wb,.tint])
            model.openParameter(.shutter); XCTAssertNotEqual(model.panel,.manual)
            XCTAssertEqual(model.zoomRange,1...3)
            for target in [CGFloat(1),1.5,2,2.5,3,0.5,4,1] {
                model.endZoomDial(); model.openZoomDial(); XCTAssertTrue(model.zoomDialVisible)
                let start = CACurrentMediaTime(); camera.setContinuousZoom(target)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
                durations.append(CACurrentMediaTime()-start)
                let expected = min(3,max(1,target))
                let reading = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                let actual = try XCTUnwrap(reading)
                XCTAssertEqual(camera.currentZoom,expected,accuracy:0.01)
                XCTAssertEqual(actual.physicalZoomFactor,expected/0.5,accuracy:0.02)
                XCTAssertEqual(camera.activeCaptureDeviceID,routeID)
                let enabled = await withCheckedContinuation { c in camera.cinematicCaptureStateForTesting { c.resume(returning:$1) } }
                XCTAssertTrue(enabled)
                let hardware = await withCheckedContinuation { c in camera.smartCaptureHardwareStateForTesting { c.resume(returning:$0) } }
                XCTAssertFalse(try XCTUnwrap(hardware).customExposure,"隐藏ISO/快门期间应使用自动曝光")
                model.endZoomDial()
            }
            camera.setContinuousZoom(2)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
            for lens in model.displayedFocalLenses {
                model.selectFocalLength(lens); try await settle()
                XCTAssertEqual(camera.currentZoom,lens.displayZoom,accuracy:0.01)
                model.selectFocalLength(lens); try await settle()
                let expected:CGFloat = lens.displayZoom == 1 ? 28.0/24.0 : lens.displayZoom
                XCTAssertEqual(camera.currentZoom,expected,accuracy:0.01)
                XCTAssertEqual(model.focalButtonTitle(for:lens),lens.displayZoom == 1 ? "28mm" : lens.title)
                if lens.displayZoom == 1 {
                    model.selectFocalLength(lens); try await settle()
                    XCTAssertEqual(camera.currentZoom,35.0/24.0,accuracy:0.01)
                    XCTAssertEqual(model.focalButtonTitle(for:lens),"35mm")
                    model.selectFocalLength(lens); try await settle()
                    XCTAssertEqual(camera.currentZoom,1,accuracy:0.01)
                    XCTAssertEqual(model.focalButtonTitle(for:lens),"24mm")
                }
            }
        }
        model.openZoomDial(); model.dragZoomDial(translation:-10000,width:300)
        await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
        XCTAssertEqual(camera.currentZoom,3,accuracy:0.01)
        model.dragZoomDial(translation:10000,width:300)
        await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
        XCTAssertEqual(camera.currentZoom,1,accuracy:0.01); model.endZoomDial()
        for ratio in VideoRatio.aspectOptions { for angle in [0.0,90.0] {
            model.selectVideoRatio(ratio); try await settle()
            host.rootView = CinematicZoomHost(model:model,camera:camera,angle:angle)
            try await Task.sleep(for:.milliseconds(230))
            let bar = try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
            let ev = try XCTUnwrap(model.captureButtonFramesForTesting["parameter.EV"])
            let wb = try XCTUnwrap(model.captureButtonFramesForTesting["parameter.WB"])
            let tint = try XCTUnwrap(model.captureButtonFramesForTesting["parameter.TINT"])
            XCTAssertEqual(wb.midX,window.bounds.midX,accuracy:1)
            XCTAssertEqual(wb.midX-ev.midX,tint.midX-wb.midX,accuracy:1)
            for lens in model.displayedFocalLenses {
                let frame = try XCTUnwrap(model.captureButtonFramesForTesting["focal.\(lens.id)"])
                // 电影响应式画幅按钮宽度随屏幕比例/方向变化，验证保持紧凑且不越界，
                // 不再锁死旧的40pt常量。
                XCTAssertGreaterThanOrEqual(frame.width,36)
                XCTAssertLessThanOrEqual(frame.width,44)
                XCTAssertTrue(bar.insetBy(dx:-1,dy:-1).contains(frame))
            }
        } }
        let attachment = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) })
        attachment.name = "Cinematic-35mm-M-Parameters"; attachment.lifetime = .keepAlways; add(attachment)
        model.selectVideoRatio(.ratio16x9); try await settle()
        camera.setContinuousZoom(3); await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
        camera.startVideoRecording(aspect:.wide)
        try await wait("录像开始") { camera.videoRecording || recorded != nil }
        try await Task.sleep(for:.milliseconds(900)); camera.stopVideoRecording()
        try await wait("录像交付") { recorded != nil }
        let url = try XCTUnwrap(recorded).get(); files.append(url)
        let asset = AVURLAsset(url:url),tracks = try await asset.loadTracks(withMediaType:.video)
        let track = try XCTUnwrap(tracks.first),size = try await track.load(.naturalSize),fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(size,CGSize(width:1920,height:1080)); XCTAssertEqual(fps,30,accuracy:1)
        for _ in 0..<3 {
            model.toggleCinematicVideoMode(); try await settle()
            XCTAssertEqual(model.displayedManualParameters,CameraParameter.allCases)
            XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualFocus)
            model.toggleCinematicVideoMode(); try await settle()
            XCTAssertEqual(model.displayedManualParameters,[.ev,.wb,.tint])
            for target in 0..<20 { camera.setContinuousZoom(CGFloat(target%3+1)) }
            model.endZoomDial()
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }; try await settle()
        }
        model.toggleCinematicVideoMode(); try await settle(); model.setMode(.auto); try await settle()
        XCTAssertFalse(model.fixedCinematicFocalsOnly); XCTAssertGreaterThan(model.displayedFocalLenses.count,2)
        XCTAssertGreaterThan(model.zoomRange.upperBound,3)
        durations.sort(); print("CINEMATIC-ZOOM samples=\(durations.count) medianSeconds=\(durations[durations.count/2]) maxSeconds=\(durations.last!) includesQueueFlush=true layouts=10 actual1080p30File=true noPhotosWrites=true")
    }
}

private struct CinematicZoomHost:View {
    @ObservedObject var model:CameraViewModel
    @ObservedObject var camera:CameraEngine
    var angle = 0.0
    var body:some View {
        CameraView(model:model)
            .environment(\.scenePhase,.active)
            .environment(\.captureControlAngle,angle)
    }
}
