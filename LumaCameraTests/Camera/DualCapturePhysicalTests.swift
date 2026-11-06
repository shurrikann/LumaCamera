import XCTest
import AVFoundation
import UIKit
import CoreImage
import SwiftUI
@testable import LumaCamera

final class DualCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testSynchronizedFrontRearFramesAndSingleEncode() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(false)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(600))
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let completed = expectation(description: "双路同期帧及编码")
        let work = DispatchQueue(label: "test.dual.session"), frames = DispatchQueue(label: "test.dual.frames")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DualCapture-test.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        work.async {
            do {
                let source = try DualCaptureSource(frameQueue: frames, ratio: .wide, audio: true)
                let recorder = try MovieRecorder(url: url, sourceSize: source.outputSize, ratio: .wide,
                    mirrored: false, includeAudio: source.includesAudio, settings: VideoCaptureSettings(),
                    pixelFormat: kCVPixelFormatType_32BGRA)
                source.onVideo = { recorder.appendVideo($0) }
                source.onAudio = { recorder.appendAudio($0) }
                let start = CACurrentMediaTime()
                try source.start()
                print("DUAL-CAPTURE start=\(CACurrentMediaTime()-start) cost=\(source.session.hardwareCost) pressure=\(source.session.systemPressureCost) audio=\(source.includesAudio)")
                frames.asyncAfter(deadline: .now()+1.2) { source.swap() }
                work.asyncAfter(deadline: .now()+3) {
                    source.stop()
                    frames.async {
                        let times = source.renderDurations.sorted()
                        print("DUAL-CAPTURE frames=\(source.frameCount) dropped=\(source.droppedFrameCount) renderMedian=\(times.isEmpty ? -1 : times[times.count/2]) maxSkew=\(source.maximumPairSkew) writer=\(recorder.frameCountsForTesting)")
                        XCTAssertGreaterThan(source.frameCount, 45)
                        recorder.finish { _ in
                            work.async { source.release(); completed.fulfill() }
                        }
                    }
                }
            } catch { XCTFail(error.localizedDescription); completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 25)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
        XCTAssertGreaterThan(duration.seconds, 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var decoded = 0
        while output.copyNextSampleBuffer() != nil { decoded += 1 }
        XCTAssertGreaterThan(decoded, 40)
        print("DUAL-CAPTURE file=\(size) duration=\(duration.seconds) decoded=\(decoded) reader=\(reader.status.rawValue)")
    }
    @MainActor func testSavedDualCaptureColdModelDefaultsOffAndManualEntryStillWorks() async throws {
        let stopped = try await FullDeviceRegressionFixture.makeFreshModel()
        // 全新启动时镜头枚举也异步完成；先等普通会话就绪，再停止并建立冷启动存档模型。
        stopped.setCameraActive(true)
        let baselineEnd = CACurrentMediaTime() + 15
        while !stopped.camera.ready && CACurrentMediaTime() < baselineEnd { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(stopped.camera.ready)
        stopped.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in stopped.camera.afterPendingSessionTasks { c.resume() } }
        let front = try XCTUnwrap(stopped.camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        let name = "DualCapture-Cold-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = CapturePreferencesStore(defaults: defaults)
        var state = SavedCaptureState()
        state.video = true; state.lensID = front.id; state.dualCaptureEnabled = true
        state.dualCaptureFrontWide = true; state.dualInsetX = 0.1; state.dualInsetY = 0.55
        state.dualInsetLandscape = true; state.dualFrontWideBeforeLandscape = false
        store.saveCaptureState(state)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); defaults.removePersistentDomain(forName: name); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        let start = CACurrentMediaTime(), end = start + 20
        while CACurrentMediaTime() < end {
            if model.camera.ready && !model.camera.videoConfiguring && !model.startupCaptureRestorationPendingForTesting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.camera.dualCaptureEnabled, "旧存档也不能自动开启双拍")
        XCTAssertTrue(model.camera.ready)
        let initialSource: [String: String] = await withCheckedContinuation { c in model.camera.dualCaptureStateForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(initialSource.isEmpty)
        model.flushCaptureSettings(); XCTAssertEqual(store.loadCaptureState()?.dualCaptureEnabled, false)
        XCTAssertEqual(store.loadCaptureState()?.dualCaptureFrontWide, true)
        model.toggleDualCapture()
        let manualEnd = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < manualEnd {
            if model.camera.dualCaptureEnabled && model.camera.ready && !model.camera.dualCapturePreparing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.camera.dualCaptureEnabled)
        model.flushCaptureSettings(); XCTAssertEqual(store.loadCaptureState()?.dualCaptureEnabled, false)
        let actual: [String: String] = await withCheckedContinuation { c in model.camera.dualCaptureStateForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(actual["ordinaryRunning"], "false"); XCTAssertEqual(actual["frontMain"], "false")
        XCTAssertTrue(model.camera.dualCaptureFrontWide)
        XCTAssertTrue(model.camera.dualCaptureInsetLandscape)
        let expected = DualCaptureInsetLayout.resized(CGRect(x: 0.1, y: 0.55, width: 0.28, height: 0.28), landscape: true, ratio: 9.0 / 16)
        XCTAssertEqual(model.camera.dualCaptureInsetRect, expected)
        XCTAssertEqual(model.camera.dualCaptureInsetRect.width * (9.0 / 16) / model.camera.dualCaptureInsetRect.height, 16.0 / 9, accuracy: 0.001)
        model.toggleDualCaptureInsetAspect()
        let restoringEnd = CACurrentMediaTime() + 5
        while model.dualInsetAspectChanging && CACurrentMediaTime() < restoringEnd { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.camera.dualCaptureFrontWide)
        XCTAssertFalse(model.camera.dualCaptureInsetLandscape)
        model.flushCaptureSettings(); XCTAssertEqual(store.loadCaptureState()?.dualCaptureEnabled, false)
        model.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true)
        let resumeEnd = CACurrentMediaTime() + 12
        while !model.camera.ready && CACurrentMediaTime() < resumeEnd { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.camera.dualCaptureEnabled); XCTAssertTrue(model.camera.ready)
        if model.camera.dualCaptureEnabled {
            await withCheckedContinuation { c in model.camera.setDualCaptureEnabled(false) { _ in c.resume() } }
        }
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        print("DUAL-COLD elapsed=\(CACurrentMediaTime()-start) \(actual)")
    }

    @MainActor func testPortraitHeldDualCaptureOrientation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.onVideoRecorded = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 12
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw CancellationError()
        }
        model.setCameraActive(true); try await wait { camera.ready }
        model.setCaptureKind(.video); try await wait { camera.ready && !camera.videoConfiguring }
        let front = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        model.selectFocalLength(front); try await wait { camera.ready && model.currentPosition == .front }
        model.toggleDualCapture(); try await wait { camera.ready && camera.dualCaptureEnabled }
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        camera.startVideoRecording(aspect: .wide)
        try await wait { camera.videoRecording }
        try await Task.sleep(for: .milliseconds(650))
        model.swapDualCaptureCameras()
        try await Task.sleep(for: .milliseconds(650))
        camera.stopVideoRecording(); try await wait { result != nil }
        let url = try XCTUnwrap(result).get()
        defer { try? FileManager.default.removeItem(at: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        for seconds in [0.3, 1.0] {
            let cg = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "Dual-portrait-held-\(seconds)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        model.toggleDualCapture(); try await wait { !camera.dualCaptureEnabled && camera.ready }
    }

    @MainActor func testDualCaptureEntryLivesInShootingModes() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 12
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("相机未准备") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频未准备") { camera.ready && !camera.videoConfiguring }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: CameraView(model: model).environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        model.shootingModes = true
        try await Task.sleep(for: .milliseconds(500))
        let entry = try XCTUnwrap(model.captureButtonFramesForTesting["shootingMode.dualCapture"], "拍摄模式缺少同步双拍入口")
        XCTAssertFalse(entry.isEmpty)
        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(entry))
        model.toggleDualCapture()
        try await wait("双拍未开启") { camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        model.toggleDualCapture()
        try await wait("双拍未关闭") { camera.ready && !camera.dualCaptureEnabled }
        print("DUAL-ENTRY-SHOOTING-MODES enabled=true toggled=true")
    }

    @MainActor func testEngineDualCaptureRecordingSwapAndOrdinaryRecovery() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        let original = camera.onVideoRecorded
        var files: [URL] = []
        defer { camera.onVideoRecorded = original; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish(); files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let prior=scene.windows.first{$0.isKeyWindow}
        let host=UIHostingController(rootView:CameraView(model:model).environment(\.scenePhase,.active))
        let window=UIWindow(windowScene:scene);window.rootViewController=host;window.makeKeyAndVisible()
        defer{window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 15
            while CACurrentMediaTime() < end {
                if predicate() { return }; try await Task.sleep(for: .milliseconds(20))
            }
            let detail: String = await withCheckedContinuation { c in camera.frontFramingStateForTesting { c.resume(returning: $0) } }
            print("DUAL-FAIL \(label) \(detail)")
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true)
        try await wait("启动") { camera.ready }
        model.setCaptureKind(.video)
        try await wait("普通视频") { camera.ready && !camera.videoConfiguring }
        let front = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        model.selectFocalLength(front)
        try await wait("前置") { camera.ready && model.currentPosition == .front }
        model.videoResolution = .hd1080; model.videoFrameRate = .fps60
        try await wait("原规格") { !camera.videoConfiguring }
        for cycle in 0..<3 {
            let start = CACurrentMediaTime()
            model.toggleDualCapture()
            try await wait("双拍就绪") { camera.dualCaptureEnabled && camera.ready && !camera.dualCapturePreparing }
            let readyTime = CACurrentMediaTime() - start
            XCTAssertEqual(model.videoFrameRate, .fps60)
            XCTAssertTrue(model.supportsVideoFrameRate(.fps60)); XCTAssertFalse(model.supportsVideoColorSpace(.hdr))
            XCTAssertFalse(model.supportsVideoCodec(.proRes)); XCTAssertFalse(model.supportsVideoOpenGate)
            // 双拍主画面默认可能是后置，取当前主画面镜头而非固定前置。
            let mainFraming = camera.dualCaptureMainIsFront
                ? try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
                : try XCTUnwrap(camera.lenses.first { $0.device.position == .back && $0.displayZoom >= 0.999 })
            XCTAssertTrue(model.canSelectFocalLength(mainFraming))
            let image = try XCTUnwrap(camera.preview)
            XCTAssertEqual(image.size.width / image.size.height, 9.0 / 16, accuracy: 0.01)
            var result: Result<URL, Error>?
            camera.onVideoRecorded = { result = $0 }
            model.style = cycle == 1 ? .mono : .original
            model.intensity = 1
            camera.startVideoRecording(aspect: .wide, look: model.effectiveCaptureLook, lockWhiteBalance: cycle == 2)
            try await wait("双拍开始录制") { camera.videoRecording }
            for _ in 0..<6 { model.swapDualCaptureCameras(); try await Task.sleep(for: .milliseconds(80)) }
            try await Task.sleep(for: .milliseconds(900))
            camera.stopVideoRecording()
            try await wait("双拍完成") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result).get(); files.append(url)
            let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first), dimensions = try await track.load(.naturalSize)
            XCTAssertEqual(dimensions, CGSize(width: 1080, height: 1920))
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 0.8)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audio.isEmpty)
            let metadata = try await asset.load(.commonMetadata)
            var description = ""
            for item in metadata where item.commonKey == .commonKeyDescription {
                description += (try? await item.load(.stringValue)) ?? ""
            }
            XCTAssertTrue(description.contains("同步双拍"), "实际文件应包含双拍拍摄类型")
            if cycle == 1 {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                var decoded = 0, chroma = 0.0, samples = 0
                while let frame = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(frame) {
                    decoded += 1
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                        let row = CVPixelBufferGetBytesPerRow(buffer)
                        for y in stride(from: 60, to: 1860, by: 120) { for x in stride(from: 40, to: 1040, by: 80) {
                            let i = y * row + x * 4
                            chroma += Double(abs(Int(bytes[i])-Int(bytes[i+1])) + abs(Int(bytes[i+1])-Int(bytes[i+2])))
                            samples += 2
                        } }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                }
                XCTAssertEqual(reader.status, .completed)
                XCTAssertGreaterThan(decoded, 20); XCTAssertLessThan(chroma / Double(max(1,samples)), 12)
                print("DUAL-FILTER decoded=\(decoded) encodedMeanChroma=\(chroma / Double(max(1,samples)))")
            }
            if cycle == 0 {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                for seconds in [0.1, 0.8] {
                    let cg = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                    let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "Dual-encoded-\(seconds)"; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            let beforeStop = camera.previewFrameTimeForTesting
            let exit = CACurrentMediaTime()
            model.toggleDualCapture()
            try await wait("普通前置恢复") { !camera.dualCaptureEnabled && camera.ready && !camera.videoConfiguring && camera.previewFrameTimeForTesting > beforeStop }
            XCTAssertEqual(model.videoFrameRate, .fps60)
            XCTAssertEqual(model.currentPosition, .front)
            print("DUAL-ENGINE cycle=\(cycle) enter=\(readyTime) exit=\(CACurrentMediaTime()-exit) duration=\(duration) size=\(dimensions) audio=\(audio.count)")
        }
        model.style = .original
        // 在准备阶段立刻离开，再返回；重复点击不排队创建第二套采集图。
        model.toggleDualCapture(); model.toggleDualCapture()
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCameraActive(true)
        try await wait("准备中离开后未恢复") { camera.ready && !camera.dualCapturePreparing }
        if camera.dualCaptureEnabled {
            model.toggleDualCapture()
            try await wait("准备中取消后未回到普通视频") { camera.ready && !camera.dualCaptureEnabled }
        }
        // 取消与后台恢复不能同时唤醒普通相机会话。
        model.toggleDualCapture()
        try await wait("双拍再次就绪") { camera.dualCaptureEnabled && camera.ready }
        try await Task.sleep(for: .milliseconds(350))
        try await wait("双拍 inset 未发布") { model.captureButtonFramesForTesting["dualCaptureInset"] != nil }
        let inset = try XCTUnwrap(model.captureButtonFramesForTesting["dualCaptureInset"])
        XCTAssertTrue(model.previewFrameForTesting.insetBy(dx: -1, dy: -1).contains(inset))
        model.showsRecordingCapacity = true; model.showsAudioMeter = true
        try await wait("声音/容量面板显示后的小窗避让未完成") {
            guard let current=model.captureButtonFramesForTesting["dualCaptureInset"],
                  let hud=model.captureButtonFramesForTesting["videoHUD"] else {return false}
            return !current.intersects(hud.insetBy(dx:-5,dy:-5))
        }
        // HUD显示会触发小窗移动，不能拿显示前的旧CGRect检查显示后的布局。
        let insetAfterHUD=try XCTUnwrap(model.captureButtonFramesForTesting["dualCaptureInset"])
        let hud=try XCTUnwrap(model.captureButtonFramesForTesting["videoHUD"])
        XCTAssertFalse(hud.intersects(insetAfterHUD),"小窗与声音/容量HUD重叠")
        var burnState=[String:String]()
        for _ in 0..<100 {
            burnState=await withCheckedContinuation{c in camera.dualCaptureStateForTesting{c.resume(returning:$0)}}
            if abs((Double(burnState["insetX"] ?? "") ?? -1)-camera.dualCaptureInsetRect.minX)<0.001,
               abs((Double(burnState["insetY"] ?? "") ?? -1)-camera.dualCaptureInsetRect.minY)<0.001 {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(Double(burnState["insetX"] ?? "") ?? -1,camera.dualCaptureInsetRect.minX,accuracy:0.001)
        XCTAssertEqual(Double(burnState["insetY"] ?? "") ?? -1,camera.dualCaptureInsetRect.minY,accuracy:0.001)
        print("DUAL-HUD before=\(inset) after=\(insetAfterHUD) hud=\(hud) beforeOverlap=\(hud.intersects(inset)) afterOverlap=\(hud.intersects(insetAfterHUD)) encodedRectMatches=true")
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: shot); attachment.name = "Dual-camera-live-layout"; attachment.lifetime = .keepAlways; add(attachment)
        }
        model.showsRecordingCapacity = false; model.showsAudioMeter = false
        // 双拍当前由独立多路采集源管理曝光；普通 M 挡参数不会写入双拍源，
        // 这里验证主/小窗交换和引擎存活，不把普通照片的手动曝光当成双拍保证。
        for main in [false, true] {
            if main { model.swapDualCaptureCameras() }
            try await Task.sleep(for: .milliseconds(350))
            let state: [String: String] = await withCheckedContinuation { c in camera.dualCaptureStateForTesting { c.resume(returning: $0) } }
            XCTAssertEqual(state["ordinaryRunning"], "false"); XCTAssertEqual(state["dualRunning"], "true")
            XCTAssertEqual(state["frontMain"], "\(main)")
            print("DUAL-MANUAL \(state)")
        }
        for _ in 0..<12 { model.swapDualCaptureCameras() }
        model.setCameraActive(false)
        try await Task.sleep(for: .milliseconds(400))
        model.setCameraActive(true)
        try await wait("双拍后台恢复") { camera.ready && camera.dualCaptureEnabled }
        model.setCaptureKind(.photo)
        try await wait("退出双拍返回拍照") { model.captureKind == .photo && camera.ready && !camera.dualCaptureEnabled }
        XCTAssertNotNil(camera.preview)
        try await wait("双拍退出后前置照片画幅能力未恢复") { camera.frontPhotoAspectRatioSwitchAvailable }
        XCTAssertFalse(camera.recoveryFailed)
    }

    @MainActor func testRetiredSourceErrorCannotExitReplacementAndCurrentErrorRecoversRecording() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,callback=camera.onVideoRecorded,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        var files=[URL]()
        defer {
            camera.onVideoRecorded=callback;model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()
            files.forEach{try? FileManager.default.removeItem(at:$0)}
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<900 { if predicate(){return};try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? ""));throw CancellationError()
        }
        func state() async ->[String:String] {
            await withCheckedContinuation{c in camera.dualCaptureStateForTesting{c.resume(returning:$0)}}
        }
        model.setCameraActive(true);try await wait("相机启动"){camera.ready}
        model.setCaptureKind(.video);try await wait("视频准备"){camera.ready && !camera.videoConfiguring}
        let front=try XCTUnwrap(camera.lenses.first{$0.device.position == .front && $0.frontFraming == .standard})
        model.selectFocalLength(front);try await wait("前置准备"){camera.ready && model.currentPosition == .front}
        let ordinaryRate=model.videoFrameRate
        model.toggleDualCapture();try await wait("双摄准备"){camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing}
        var replacementTimes=[Double]()
        for cycle in 0..<3 {
            let before=await state()
            let oldID=try XCTUnwrap(before["sourceID"])
            let oldCallback:((String)->Void)?=await withCheckedContinuation{c in camera.dualCaptureErrorCallbackForTesting{c.resume(returning:$0)}}
            let oldHandler=try XCTUnwrap(oldCallback)
            let started=CACurrentMediaTime()
            model.videoFrameRate = model.videoFrameRate == .fps30 ? .fps60:.fps30
            var newID=oldID
            for _ in 0..<900 {
                newID=await state()["sourceID"] ?? oldID
                if newID != oldID && camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertNotEqual(newID,oldID,"必须实际替换双摄图，不能只修改UI规格")
            replacementTimes.append(CACurrentMediaTime()-started)
            camera.message=nil
            let frame=camera.previewFrameTimeForTesting
            oldHandler("测试：已退休双摄的迟到错误 \(cycle)")
            try await Task.sleep(for:.milliseconds(350))
            XCTAssertTrue(camera.dualCaptureEnabled,"旧双摄错误不能退出已经就绪的新双摄")
            XCTAssertNil(camera.message,"旧会话错误不能覆盖当前状态")
            guard camera.dualCaptureEnabled else {throw CancellationError()}
            let after=await state()
            XCTAssertEqual(after["sourceID"],newID)
            try await wait("新双摄仍应持续出帧"){camera.previewFrameTimeForTesting>frame && camera.ready}
        }
        var recorded:Result<URL,Error>?
        camera.onVideoRecorded={recorded=$0}
        camera.startVideoRecording(aspect:.wide)
        try await wait("当前双摄开始录制"){camera.videoRecording}
        try await Task.sleep(for:.milliseconds(500))
        let currentCallback:((String)->Void)?=await withCheckedContinuation{c in camera.dualCaptureErrorCallbackForTesting{c.resume(returning:$0)}}
        let handler=try XCTUnwrap(currentCallback)
        handler("测试：当前双摄错误")
        try await wait("当前错误需结束录像并恢复普通会话"){recorded != nil && !camera.videoBusy && !camera.dualCaptureEnabled && camera.ready && !camera.videoConfiguring}
        let url=try XCTUnwrap(recorded).get();files.append(url)
        XCTAssertEqual(camera.message,"测试：当前双摄错误")
        camera.message=nil
        XCTAssertEqual(model.videoFrameRate,ordinaryRate)
        XCTAssertEqual(camera.videoSettings.frameRate,ordinaryRate,"后端也必须恢复普通录像规格")
        let duration=try await AVURLAsset(url:url).load(.duration).seconds
        XCTAssertGreaterThan(duration,0.2)
        model.toggleDualCapture();try await wait("错误恢复后再次进入双摄"){camera.dualCaptureEnabled && camera.ready}
        model.toggleDualCapture();try await wait("再次退出恢复"){!camera.dualCaptureEnabled && camera.ready}
        recorded=nil
        camera.startVideoRecording(aspect:.wide)
        try await wait("退出双摄后普通录像开始"){camera.videoRecording}
        try await Task.sleep(for:.milliseconds(500));camera.stopVideoRecording()
        try await wait("退出双摄后普通录像完成"){recorded != nil && !camera.videoBusy}
        let ordinaryURL=try XCTUnwrap(recorded).get();files.append(ordinaryURL)
        let ordinaryAsset=AVURLAsset(url:ordinaryURL)
        let ordinaryTracks=try await ordinaryAsset.loadTracks(withMediaType:.video)
        let ordinaryTrack=try XCTUnwrap(ordinaryTracks.first)
        let ordinaryFPS=try await ordinaryTrack.load(.nominalFrameRate)
        XCTAssertEqual(Double(ordinaryFPS),Double(ordinaryRate.rawValue),accuracy:1)
        if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized {
            let audio=try await ordinaryAsset.loadTracks(withMediaType:.audio)
            XCTAssertFalse(audio.isEmpty)
        }
        var description=""
        for item in try await ordinaryAsset.load(.commonMetadata) where item.commonKey == .commonKeyDescription {
            description += (try? await item.load(.stringValue)) ?? ""
        }
        XCTAssertFalse(description.contains("同步双拍"),"普通录像文件不能残留双拍拍摄类型")
        print("DUAL-RETIRED-ERROR replacements=3 replacementSeconds=\(replacementTimes) staleIgnored=3 currentErrorRecordingSeconds=\(duration) ordinarySettingsRestored=\(model.videoFrameRate == ordinaryRate) ordinaryRecordedFPS=\(ordinaryFPS) injection=appErrorHandler noPhotosWrites=true")
    }
    #endif
}
