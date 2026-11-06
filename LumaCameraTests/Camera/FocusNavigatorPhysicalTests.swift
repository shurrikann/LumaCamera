import XCTest
import AVFoundation
import UIKit
import SwiftUI
import ImageIO
@testable import LumaCamera

private struct FocusNavigatorTestHost: View {
    @ObservedObject var model: CameraViewModel
    let angle: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(model: model).viewfinderContent(controlAngle: angle)
                CameraView(model: model).fixedCameraControls(width: geometry.size.width)
            }
        }.environment(\.captureControlAngle, angle).preferredColorScheme(.dark)
    }
}

final class FocusNavigatorPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testNavigationZoomSurvivesCaptureAndExitInAutomaticAndManualModes() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,callback=camera.onCaptureCompleted,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer {
            model.preferences.focusAssist=false;camera.onCaptureCompleted=callback;model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()
        }
        func wait(_ label:String,_ condition:()->Bool) async throws {
            let end=CACurrentMediaTime()+25
            while CACurrentMediaTime()<end {if condition(){return};try await Task.sleep(for:.milliseconds(25))}
            XCTFail(label+" "+(camera.message ?? camera.focusNavigatorUnavailableReason ?? ""));throw CancellationError()
        }
        func photoFocalLength() async throws -> Double {
            var result:CapturedPhoto?
            camera.onCaptureCompleted={result=$0}
            camera.capture(flashMode:.off,options:PhotoOptions())
            try await wait("导航倍率照片没有交付"){result != nil && !camera.capturing}
            let data=try XCTUnwrap(result?.resources.first?.data)
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif=try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
            let focal=try XCTUnwrap(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber).doubleValue
            print("FOCUS-NAV-ZOOM-FILE logical=\(camera.currentZoom) equivalentMM=\(focal) digitalZoom=\(String(describing:exif[kCGImagePropertyExifDigitalZoomRatio as String]))")
            return focal
        }
        model.setCameraActive(true);try await wait("启动"){camera.ready}
        for manual in [false,true] {
            model.preferences.focusAssist=false;model.setMode(manual ? .manual:.auto)
            camera.setContinuousZoom(8)
            try await Task.sleep(for:.milliseconds(500))
            await withCheckedContinuation{c in camera.afterPendingSessionTasks{c.resume()}}
            try await wait("普通8倍就绪"){camera.ready && !camera.shutterBusy && abs(camera.currentZoom-8)<0.01}
            let reference=try await photoFocalLength()
            model.preferences.focusAssist=true
            try await wait("进入8倍导航"){camera.focusNavigatorActive && camera.focusNavigatorImage != nil}
            camera.setContinuousZoom(16)
            try await Task.sleep(for:.milliseconds(500))
            let state:[String:String]=await withCheckedContinuation{c in camera.focusNavigatorStateForTesting{c.resume(returning:$0)}}
            XCTAssertEqual(try XCTUnwrap(Double(state["zoom"] ?? "")),4,accuracy:0.01)
            let enlarged=try await photoFocalLength()
            XCTAssertEqual(enlarged/reference,2,accuracy:0.1,"导航内改变倍率后，成片不能退回进入导航时的倍率")
            try await wait("拍照后导航恢复"){camera.focusNavigatorActive && camera.focusNavigatorImage != nil}
            camera.setContinuousZoom(16)
            try await Task.sleep(for:.milliseconds(300))
            model.preferences.focusAssist=false
            try await wait("退出导航"){!camera.focusNavigatorActive && camera.focusNavigatorImage == nil}
            let actual:CGFloat=await withCheckedContinuation{c in camera.zoomStateForTesting{zoom,_,_ in c.resume(returning:zoom)}}
            XCTAssertEqual(actual,16,accuracy:0.01,"退出导航必须保留用户最新倍率")
            print("FOCUS-NAV-ZOOM-RESTORE manual=\(manual) referenceMM=\(reference) enlargedMM=\(enlarged) restoredLogical=\(actual)")
        }
    }

    @MainActor func testPhotoNavigatorThresholdCaptureAndVideoExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldPreference = model.preferences.focusAssist, idle = UIApplication.shared.isIdleTimerDisabled
        let callback = camera.onCaptureCompleted, videoCallback = camera.onVideoRecorded
        let audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var files: [URL] = []
        defer {
            model.preferences.focusAssist = oldPreference; model.setCameraActive(false)
            camera.onCaptureCompleted = callback; camera.onVideoRecorded = videoCallback
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 18
            while CACurrentMediaTime() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(30)) }
            let state: [String: String] = await withCheckedContinuation { c in camera.focusNavigatorStateForTesting { c.resume(returning: $0) } }
            XCTFail("\(label) reason=\(camera.focusNavigatorUnavailableReason ?? "nil") message=\(camera.message ?? "nil") state=\(state)")
            throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.preferences.focusAssist = true
        camera.setContinuousZoom(7.9)
        try await Task.sleep(for: .milliseconds(350)); XCTAssertNil(camera.focusNavigatorImage)
        let began = CACurrentMediaTime()
        camera.setContinuousZoom(8)
        try await wait("照片8倍导航") { camera.focusNavigatorActive && camera.focusNavigatorImage != nil }
        var enterSeconds=[CACurrentMediaTime()-began],exitSeconds=[Double]()
        let state: [String: String] = await withCheckedContinuation { c in camera.focusNavigatorStateForTesting { c.resume(returning: $0) } }
        print("FOCUS-NAV-PHOTO enter=\(CACurrentMediaTime()-began) state=\(state) image=\(camera.focusNavigatorImage!.size)")
        XCTAssertGreaterThanOrEqual(Double(state["zoom"] ?? "") ?? 0, 1.9)
        XCTAssertLessThanOrEqual(Double(state["hardwareCost"] ?? "") ?? 2, 1)
        XCTAssertLessThanOrEqual(Double(state["pressureCost"] ?? "") ?? 2, 1)
        var photo: CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0 }
        camera.capture(flashMode: .off, options: PhotoOptions())
        try await wait("导航中实际拍照") { photo != nil && !camera.capturing }
        XCTAssertFalse(photo?.resources.isEmpty ?? true)
        try await wait("拍照后导航恢复") { camera.focusNavigatorImage != nil && camera.focusNavigatorActive }
        for _ in 0..<3 {
            let exitBegan=CACurrentMediaTime()
            camera.setContinuousZoom(7.9)
            try await wait("低于8倍退出") { !camera.focusNavigatorActive && camera.focusNavigatorImage == nil }
            exitSeconds.append(CACurrentMediaTime()-exitBegan)
            let enterBegan=CACurrentMediaTime()
            camera.setContinuousZoom(8)
            try await wait("再次进入") { camera.focusNavigatorImage != nil }
            enterSeconds.append(CACurrentMediaTime()-enterBegan)
        }
        print("FOCUS-NAV-THRESHOLD-PERF enters=\(enterSeconds) exits=\(exitSeconds) includesZoomDebounceAndFirstImage=true notFPS=true")
        model.setCaptureKind(.video)
        try await wait("视频就绪") { camera.ready && !camera.videoConfiguring }
        try await wait("视频不启用导航") { !camera.focusNavigatorActive && camera.focusNavigatorImage == nil }
        try await wait("导航退出后录像按钮未就绪"){model.videoShutterEnabled}
        var recorded:Result<URL,Error>?
        camera.onVideoRecorded={recorded=$0}
        model.toggleVideoRecording()
        try await wait("导航退出后未开始录像"){camera.videoRecording}
        try await Task.sleep(for:.milliseconds(650))
        model.toggleVideoRecording()
        try await wait("导航退出后录像未完成"){recorded != nil && !camera.videoBusy}
        let url=try XCTUnwrap(recorded).get();files.append(url)
        let tracks=try await AVURLAsset(url:url).loadTracks(withMediaType:.video)
        let track=try XCTUnwrap(tracks.first)
        let fps=try await track.load(.nominalFrameRate)
        XCTAssertGreaterThanOrEqual(fps,24)
        print("FOCUS-NAV-VIDEO-RECOVERY fps=\(fps) recordedAfterNavigation=true noPhotosWrites=true")
        model.setCaptureKind(.photo)
        try await wait("回拍照") { camera.ready && !camera.videoConfiguring }
        camera.setContinuousZoom(8); model.refreshFocusNavigatorPreference()
        try await wait("回拍照导航恢复") { camera.focusNavigatorImage != nil }
        model.preferences.focusAssist = false
        try await wait("关闭恢复") { !camera.focusNavigatorActive && camera.focusNavigatorImage == nil }
        XCTAssertTrue(camera.ready)
    }
    @MainActor func testManualCaptureMetadataAndMovableNavigatorLayout() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, histogram = model.showHistogram
        let originalCallback = camera.onCaptureCompleted, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: FocusNavigatorTestHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            model.preferences.focusAssist = false; model.showHistogram = histogram; model.setCameraActive(false)
            camera.onCaptureCompleted = originalCallback; UIApplication.shared.isIdleTimerDisabled = idle
            window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey(); audit.finish()
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
            XCTFail(label + " " + (camera.focusNavigatorUnavailableReason ?? camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("普通相机") { camera.ready }
        model.preferences.focusAssist = true; camera.setContinuousZoom(8)
        try await wait("导航") { camera.focusNavigatorImage != nil }
        model.setMode(.manual)
        model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0 / 120); model.applyExposure()
        try await wait("M挡导航") { camera.focusNavigatorActive && camera.focusNavigatorImage != nil }
        for format in [PhotoFileFormat.jpeg, .heif] {
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0 }
            var options = PhotoOptions(); options.format = format
            camera.capture(flashMode: .off, options: options)
            try await wait("M挡出片") { result != nil && !camera.capturing }
            let captured = try XCTUnwrap(result), data = try XCTUnwrap(captured.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let iso = try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue)
            let seconds = try XCTUnwrap((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue)
            XCTAssertEqual(iso, 200, accuracy: 3); XCTAssertEqual(seconds, 1.0 / 120, accuracy: 0.0005)
            print("FOCUS-NAV-METADATA format=\(format) iso=\(iso) seconds=\(seconds) resources=\(captured.resources.count)")
            try await wait("出片后导航") { camera.focusNavigatorImage != nil }
        }
        model.setMode(.auto); model.showHistogram = true
        var positions = 0, layouts = 0
        let began = CACurrentMediaTime()
        for ratio in FrameRatio.photoOptions {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(200))
            for angle in [0.0, 90.0, -90.0, 180.0] {
                host.rootView = FocusNavigatorTestHost(model: model, angle: angle)
                try await Task.sleep(for: .milliseconds(250))
                for x in [-1.0, 0.0, 1.0] { for y in [-1.0, 0.0, 1.0] {
                    model.moveFocusNavigator(from: model.focusNavigatorRect, translation: CGSize(width: x, height: y))
                    let rect = model.focusNavigatorRect, preview = model.previewFrameForTesting
                    let projected = CGRect(x: preview.minX + rect.minX * preview.width, y: preview.minY + rect.minY * preview.height,
                        width: rect.width * preview.width, height: rect.height * preview.height)
                    XCTAssertTrue(preview.insetBy(dx: -1, dy: -1).contains(projected))
                    XCTAssertEqual(projected.width / projected.height, 0.75, accuracy: 0.01, "ratio=\(ratio) angle=\(angle) preview=\(preview) rect=\(rect)")
                    for key in ["mode", "tools", "lenses", "histogram"] {
                        if let obstacle = model.captureButtonFramesForTesting[key] {
                            XCTAssertFalse(projected.intersects(obstacle.insetBy(dx: -5, dy: -5)))
                            if key == "tools" {
                                XCTAssertFalse(projected.intersects(obstacle.offsetBy(dx: 0, dy: CameraControlLayout.upperButtonOffset(diameter: obstacle.height)).insetBy(dx: -5, dy: -5)))
                            }
                        }
                    }
                    positions += 1
                } }
                layouts += 1
            }
        }
        let state: [String: String] = await withCheckedContinuation { c in camera.focusNavigatorStateForTesting { c.resume(returning: $0) } }
        print("FOCUS-NAV-LAYOUT layouts=\(layouts) positions=\(positions) wall=\(CACurrentMediaTime()-began) stats=\(state)")
        host.rootView = FocusNavigatorTestHost(model: model, angle: 0)
        try await Task.sleep(for: .milliseconds(250))
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: shot); attachment.name = "Photo-focus-navigation"; attachment.lifetime = .keepAlways; add(attachment)
        model.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true); try await wait("后台返回导航") { camera.ready && camera.focusNavigatorImage != nil }
        for _ in 0..<15 { model.preferences.focusAssist.toggle() }
        model.preferences.focusAssist = false
        try await wait("快速开关最终关闭") { !camera.focusNavigatorActive && camera.focusNavigatorImage == nil }
    }
    @MainActor func testLiveAndRawPhotoPipelineRestoresAfterNavigation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onCaptureCompleted, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.preferences.focusAssist = false; camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 30
            while CACurrentMediaTime() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(30)) }
            XCTFail(label + " " + (camera.focusNavigatorUnavailableReason ?? camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("相机") { camera.ready }
        model.preferences.focusAssist = true; camera.setContinuousZoom(8)
        try await wait("8倍") { camera.focusNavigatorImage != nil }
        for live in [true, false] {
            var photo: CapturedPhoto?
            camera.onCaptureCompleted = { photo = $0 }
            var options = PhotoOptions(); options.format = live ? .heif : .raw
            if live { options.live = true }
            if !live && !camera.availablePhotoFormats.contains(.raw) { print("FOCUS-NAV-RAW skipped-current-native-route"); continue }
            camera.capture(flashMode: .off, options: options)
            try await wait("原生照片资源") { photo != nil && !camera.capturing }
            let captured = try XCTUnwrap(photo)
            if live { XCTAssertTrue(captured.resources.contains { $0.pairedVideo }, "Live动态资源应保留") }
            else { XCTAssertTrue(captured.resources.contains { $0.filename.lowercased().hasSuffix("dng") }) }
            print("FOCUS-NAV-NATIVE live=\(live) files=\(captured.resources.map(\.filename))")
            try await wait("资源采集后恢复") { camera.focusNavigatorImage != nil }
        }
        model.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
    }
    #endif
}
