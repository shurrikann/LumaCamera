import XCTest
import SwiftUI
import AVFoundation
import Vision
@testable import LumaCamera

private struct FrontVideoCenteringHost: View {
    @ObservedObject var model: CameraViewModel
    let angle: Double
    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraView(model:model).viewfinderContent(controlAngle:angle)
                CameraView(model:model).fixedCameraControls(width:geo.size.width)
            }
        }.environment(\.captureControlAngle,angle).preferredColorScheme(.dark)
    }
}

final class FrontVideoCenteringPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testCenterStagePersonPortraitRecording() async throws {
        try await checkPersonRecording(landscape: false)
    }
    @MainActor func testCenterStagePersonLandscapeRecording() async throws {
        try await checkPersonRecording(landscape: true)
    }
    /// 真实姿态与人物样本单独验收，检测到人脸仅证明方向/样本有效，不代替跟随观感。
    @MainActor private func checkPersonRecording(landscape: Bool) async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        var file:URL?, result:Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if let file { try? FileManager.default.removeItem(at:file) }; audit.finish()
        }
        func wait(_ label:String, _ predicate:() -> Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }
        try await wait("真实手持方向") { landscape ? UIDevice.current.orientation.isLandscape : UIDevice.current.orientation == .portrait }
        model.updateFrontFramingForOrientation(isLandscape:landscape)
        try await wait("方向取景就绪") { camera.ready && !camera.videoConfiguring }
        model.toggleFrontVideoCentering(); try await wait("系统激活") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"center-person-\(landscape)")
        let start = CACurrentMediaTime()
        model.toggleVideoRecording(); try await wait("开始录制") { camera.videoRecording }
        print("CENTER-PERSON-START landscape=\(landscape) pose=\(UIDevice.current.orientation.rawValue)")
        for _ in 0..<24 {
            try await Task.sleep(for:.milliseconds(500)); XCTAssertTrue(camera.frontVideoCenteringActive)
        }
        model.toggleVideoRecording(); try await wait("停止完成") { result != nil && !camera.videoBusy }
        let url = try XCTUnwrap(result?.get()); file = url
        let asset = AVURLAsset(url:url), generator = AVAssetImageGenerator(asset:asset)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        let track = try XCTUnwrap(tracks.first)
        let encoded = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let display = CGRect(origin:.zero,size:encoded).applying(transform).standardized.size
        print("CENTER-PERSON-DIRECTION landscape=\(landscape) encoded=\(encoded) transform=\(transform) display=\(display)")
        XCTAssertEqual(display.width > display.height,landscape,"方向必须符合真实握持，不能仅以能播放作为通过")
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:640,height:640)
        var faces = 0, centers:[String] = []
        for second in [1,3,5,7,9,11] {
            let sample = try await generator.image(at:CMTime(value:Int64(second),timescale:1))
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage:sample.image,orientation:.up).perform([request])
            if let face = request.results?.max(by:{ $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }) {
                faces += 1; let box = face.boundingBox
                centers.append("\(second)s:(\(box.midX),\(box.midY)),size:(\(box.width),\(box.height))")
            }
            let a = XCTAttachment(image:UIImage(cgImage:sample.image)); a.name = "Center-person-\(landscape)-\(second)s"; a.lifetime = .keepAlways; add(a)
        }
        XCTAssertGreaterThan(faces,0,"需要实际人物样本，不能将无人物场景算作跟随验收")
        let times = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= start }
        let gaps = zip(times,times.dropFirst()).map { $1-$0 }
        print("CENTER-PERSON-END landscape=\(landscape) faces=\(faces)/6 centers=\(centers) published=\(times.count) maxPublicationGap=\(gaps.max() ?? 0) pose=\(UIDevice.current.orientation.rawValue)")
    }

    /// 规格切换、快速取消与后台恢复使用真实会话；预览发布间隔不当作屏幕帧率。
    @MainActor func testCenterStageCapabilitiesFallbackAndRapidRecovery() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label:String, _ predicate:() -> Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }
        // 用不支持的4K/HDR请求核对开启时实际回退，而不是仅在UI禁选。
        model.videoResolution = .uhd4K; model.videoColorSpace = .hdr
        try await wait("原规格完成") { camera.ready && !camera.videoConfiguring }
        model.toggleFrontVideoCentering()
        try await wait("回退并激活") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing && !camera.videoConfiguring }
        XCTAssertEqual(model.videoResolution,.hd1080); XCTAssertEqual(model.videoColorSpace,.sdr)
        XCTAssertFalse(model.supportsVideoResolution(.uhd4K)); XCTAssertFalse(model.supportsVideoFrameRate(.fps60))
        XCTAssertFalse(model.supportsVideoColorSpace(.hdr))
        let capabilities = camera.frontVideoCenteringSettings
        for value in capabilities {
            model.videoResolution = value.resolution; model.videoFrameRate = value.frameRate; model.videoColorSpace = value.colorSpace
            try await wait("规格生效") { camera.ready && !camera.videoConfiguring && camera.frontVideoCenteringActive
                && camera.videoSettings.baseSettings == value.baseSettings }
            let start = CACurrentMediaTime()
            try await Task.sleep(for:.milliseconds(400))
            let times = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= start }
            XCTAssertGreaterThan(times.count,3)
            let gaps = zip(times,times.dropFirst()).map { $1-$0 }
            print("CENTER-SPEC \(value.resolution) \(value.frameRate.rawValue) \(value.colorSpace) samples=\(times.count) maxPublicationGap=\(gaps.max() ?? 0)")
        }
        // 同一个可见控件连续轻点会被prepare门控；切镜与离开页面必须取消旧请求。
        for pass in 0..<3 {
            model.toggleFrontVideoCentering()
            try await wait("关闭") { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringPreparing }
            model.toggleFrontVideoCentering()
            XCTAssertFalse(model.videoShutterEnabled)
            model.toggleVideoRecording(); XCTAssertFalse(camera.videoBusy)
            model.toggleFrontVideoCentering()
            try await wait("重复点击稳定") { camera.ready && camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            if pass == 0 {
                model.setCameraActive(false); try await Task.sleep(for:.milliseconds(300)); model.setCameraActive(true)
                try await wait("后台恢复居中") { camera.ready && camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            } else if pass == 1 {
                model.flipCamera(); try await wait("后置取消") { camera.ready && model.currentPosition == .back && !camera.frontVideoCenteringActive }
                XCTAssertFalse(model.frontVideoCenteringRequested)
                model.flipCamera(); try await wait("返回前置") { camera.ready && model.currentPosition == .front }
                XCTAssertFalse(camera.frontVideoCenteringActive)
                model.toggleFrontVideoCentering(); try await wait("再次开启") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            }
        }
        print("CENTER-STABILITY capabilityCount=\(capabilities.count) cycles=3")
    }

    @MainActor func testOfficialCenterStageVideoFramingExclusionsAndRecording() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView:FrontVideoCenteringHost(model:model,angle:0))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        var files:[URL] = [], result:Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.setCameraActive(false)
            window.isHidden = true; window.rootViewController = nil; old?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle; files.forEach { try? FileManager.default.removeItem(at:$0) }; audit.finish()
        }
        func state() async -> [String:String] { await withCheckedContinuation { c in camera.frontVideoCenteringStateForTesting { c.resume(returning:$0) } } }
        func wait(_ label:String,_ predicate:() -> Bool) async throws {
            let deadline = CACurrentMediaTime()+15
            while CACurrentMediaTime()<deadline { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            print("CENTER-FAIL state=\(await state())")
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func snapshot(_ name:String) {
            let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let a = XCTAttachment(image:image); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && !camera.videoConfiguring && model.currentPosition == .front }
        print("CENTER-CAPABILITIES \(camera.frontVideoCenteringSettings)")
        print("CENTER-BEFORE \(await state())")
        try await wait("前置官方居中能力") { camera.frontVideoCenteringAvailable }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        var latencies:[Double] = []
        for pass in 0..<3 {
            let start = CACurrentMediaTime(); model.toggleFrontVideoCentering()
            try await wait("系统人物居中激活") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            latencies.append(CACurrentMediaTime()-start)
            print("CENTER-ENABLED pass=\(pass) seconds=\(latencies.last!) native=\(await state())")
            XCTAssertEqual(camera.selectedLens,wide.id); XCTAssertTrue(model.frontVideoCenteringRequested)
            let native = await state(); XCTAssertEqual(native["active"],"true"); XCTAssertEqual(native["depth"],"false")
            model.updateFrontFramingForOrientation(isLandscape:true)
            model.updateFrontFramingForOrientation(isLandscape:false)
            XCTAssertEqual(camera.selectedLens,wide.id); XCTAssertTrue(model.frontVideoCenteringRequested)
            if pass == 0 {
                for ratio in VideoRatio.aspectOptions {
                    model.selectVideoRatio(ratio); try await wait("比例后居中") { camera.frontVideoCenteringActive && !camera.videoConfiguring }
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    let region = await state()
                    let outputWidth = Double(region["outputWidth"] ?? "") ?? 0
                    let outputHeight = Double(region["outputHeight"] ?? "") ?? 0
                    XCTAssertGreaterThan(outputWidth,0); XCTAssertGreaterThan(outputHeight,0)
                    let expectedWidth = min(1,outputHeight * ratio.frameRatio.portraitRatio / outputWidth)
                    XCTAssertEqual(Double(region["roiWidth"] ?? "") ?? -1,Double(expectedWidth),accuracy:0.0001)
                    for angle in [0.0,90.0,-90.0,180.0] {
                        host.rootView = FrontVideoCenteringHost(model:model,angle:angle)
                        try await Task.sleep(for:.milliseconds(150))
                        try await wait("三按钮位置") { model.captureButtonFramesForTesting["frontVideoCentering"] != nil && model.captureButtonFramesForTesting["frontVideoWide"] != nil && model.captureButtonFramesForTesting["dualCaptureToggle"] != nil }
                        let center = try XCTUnwrap(model.captureButtonFramesForTesting["frontVideoCentering"])
                        let a = try XCTUnwrap(model.captureButtonFramesForTesting["frontVideoWide"]), b = try XCTUnwrap(model.captureButtonFramesForTesting["dualCaptureToggle"])
                        XCTAssertFalse(center.intersects(a)); XCTAssertFalse(center.intersects(b))
                        XCTAssertEqual(center.midY,a.midY,accuracy:1); XCTAssertEqual(center.midY,b.midY,accuracy:1)
                    }
                }
                snapshot("Front-video-center-three-buttons")
            }
            model.selectFocalLength(pass == 1 ? wide : standard)
            try await wait("手动宽窄退出") { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            let stopped = await state()
            XCTAssertEqual(Double(stopped["roiWidth"] ?? ""),1)
            XCTAssertEqual(Double(stopped["roiHeight"] ?? ""),1)
            XCTAssertFalse(model.frontVideoCenteringRequested)
        }
        host.rootView = FrontVideoCenteringHost(model:model,angle:0)
        model.selectVideoRatio(.ratio16x9)
        try await wait("画幅事务完成后允许点击") { camera.ready && !camera.videoConfiguring }
        model.toggleFrontVideoCentering()
        try await wait("再激活") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        XCTAssertFalse(model.supportsVideoOpenGate); XCTAssertFalse(model.canSelectProRes(.raw))
        for (mode,codec,color) in [(CameraShootingMode.auto,VideoCodec.hevc,VideoColorSpace.sdr),(.manual,.h264,.p3),(.auto,.proRes,.sdr)] {
            model.style = codec == .h264 ? (FilmStyle.availableStyles.first(where: { $0 != .original }) ?? .original) : .original
            model.videoCodec = codec; model.videoColorSpace = color
            try await wait("编码和色彩已应用") { camera.ready && !camera.videoConfiguring && camera.videoSettings.codec == codec && camera.videoSettings.colorSpace == color }
            model.setMode(mode); try await wait("A/M居中保持") { camera.ready && camera.frontVideoCenteringActive && !camera.videoConfiguring }
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"center-\(mode)-\(codec)")
            result = nil; model.toggleVideoRecording()
            try await wait("录像开始") { camera.videoRecording || result != nil }; XCTAssertTrue(camera.videoRecording)
            try await Task.sleep(for:.milliseconds(1200)); model.toggleVideoRecording()
            try await wait("录像完成") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result?.get()); files.append(url)
            let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first), reader = try AVAssetReader(asset:asset)
            let metadata = try await asset.load(.metadata)
            let info = try await metadata.first(where:{ $0.commonKey == .commonKeyDescription })?.load(.stringValue)
            XCTAssertTrue(info?.contains("Center Stage") == true)
            let out = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(out); XCTAssertTrue(reader.startReading())
            var frames = 0; while out.copyNextSampleBuffer() != nil { frames += 1 }
            XCTAssertGreaterThan(frames,10); XCTAssertEqual(reader.status,.completed)
            print("CENTER-RECORD mode=\(mode) codec=\(codec) color=\(color) frames=\(frames) size=\(try await track.load(.naturalSize)) native=\(await state())")
        }
        model.toggleDualCapture()
        try await wait("双拍退出居中") { camera.dualCaptureEnabled && !camera.dualCapturePreparing && !camera.frontVideoCenteringActive }
        let dualState = await state()
        XCTAssertFalse(model.frontVideoCenteringRequested); XCTAssertEqual(dualState["global"],"false")
        model.toggleDualCapture(); try await wait("退出双拍") { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }
        XCTAssertFalse(model.frontVideoCenteringRequested)
        model.toggleFrontVideoCentering(); try await wait("双拍后可重新开启") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        model.setCaptureKind(.photo); try await wait("照片清理") { camera.ready && !camera.frontVideoCenteringEnabled }
        XCTAssertFalse(model.frontVideoCenteringRequested)
        print("CENTER-TOGGLE latencies=\(latencies)")
    }
    #endif
}
