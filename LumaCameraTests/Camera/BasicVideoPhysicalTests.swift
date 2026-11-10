import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class BasicVideoPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 有限张数按真实编码帧停止，两次录制均完整解码；不向系统相册保存。
    @MainActor func testFiniteTimeLapseActuallyStopsAtAcceptedFrameLimitTwice() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer { camera.stopVideoRecording(); model.setCameraActive(false); camera.onVideoRecorded = callback; UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ label:String,_ predicate:() -> Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); model.setMode(.manual)
        try await wait("视频规格") { camera.ready && !camera.videoConfiguring }
        for cycle in 0..<2 {
            result = nil
            camera.startVideoRecording(aspect:.wide,timeLapseEnabled:true,timeLapseInterval:1,timeLapseFrameLimit:3)
            try await wait("有限张数未自动停止") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result?.get()); defer { try? FileManager.default.removeItem(at:url) }
            let asset = AVURLAsset(url:url), reader = try AVAssetReader(asset:asset)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            XCTAssertEqual(reader.status,.completed); XCTAssertEqual(count,3)
            let audioTracks = try await asset.loadTracks(withMediaType:.audio)
            XCTAssertTrue(audioTracks.isEmpty)
            print("TIMELAPSE-FINITE cycle=\(cycle) decodedFrames=\(count) autoStopped=true")
        }
    }

    @MainActor func testTimeLapseRecordingCreatesSparseSilentMovie() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldCallback = camera.onVideoRecorded
        let oldKind = model.captureKind, oldMode = model.mode
        let oldCodec = model.videoCodec, oldProRes = model.proResSpecification
        let oldResolution = model.videoResolution, oldFrameRate = model.videoFrameRate
        let oldColor = model.videoColorSpace, oldRatio = model.videoRatio
        let oldTimeLapse = model.timeLapseEnabled, oldPreset = model.selectedTimeLapsePreset
        let oldOpenGate = model.videoOpenGateEnabled
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        var result: Result<URL, Error>?
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy { camera.stopVideoRecording() }
            camera.onVideoRecorded = oldCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            if model.timeLapseEnabled { model.toggleTimeLapseMode() }
            model.setCaptureKind(.photo)
            model.videoCodec = oldCodec; model.proResSpecification = oldProRes
            model.videoResolution = oldResolution; model.videoFrameRate = oldFrameRate
            model.videoColorSpace = oldColor; model.videoRatio = oldRatio
            model.videoOpenGateEnabled = oldOpenGate
            model.setCaptureKind(oldKind)
            model.setMode(oldMode)
            model.restoreTimeLapseStateForTesting(enabled: oldTimeLapse, preset: oldPreset)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
        }

        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.video)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        let settings = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr, codec: .hevc)
        model.videoCodec = .hevc; model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.videoColorSpace = .sdr; model.videoRatio = .ratio16x9
        model.videoOpenGateEnabled = false
        guard model.supportsVideoColorSpace(.sdr) else { throw XCTSkip("当前物理镜头没有可用的 HEVC SDR 视频路由") }
        camera.setVideoSettings(settings)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        XCTAssertEqual(camera.videoSettings, settings)

        if model.timeLapseEnabled { model.toggleTimeLapseMode() }
        model.toggleTimeLapseMode()
        model.selectTimeLapsePreset(.people)
        XCTAssertTrue(model.timeLapseEnabled)
        XCTAssertEqual(model.selectedTimeLapsePreset, .people)

        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<300 {
            if !camera.videoConfiguring && model.videoSubmodePreparing == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"延时实录",timeout:15)
        XCTAssertTrue(model.videoShutterEnabled, "延时规格就绪后快门必须可用")
        let began = CACurrentMediaTime()
        model.toggleVideoRecording()
        for _ in 0..<400 {
            if camera.videoRecording || result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(camera.videoRecording, camera.message ?? "延时视频未开始")
        try await Task.sleep(for: .milliseconds(2_200))
        model.toggleVideoRecording()
        for _ in 0..<500 {
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let url = try XCTUnwrap(result?.get())
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "延时摄影不写入音频轨道")
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 3.0 / 30.0 - 0.001)
        XCTAssertLessThan(duration, 0.45, "约 2.2 秒采集时间应编码成不到半秒的 30 fps 延时片段")
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(nominalFrameRate, 30, accuracy: 0.1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        XCTAssertTrue(reader.canAdd(output)); reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "延时视频无法解码")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "延时视频读取不完整")
        XCTAssertEqual(frames, 3, "1秒间隔在0、1、2秒采样")
        XCTAssertEqual(duration, Double(frames)/30, accuracy: 0.002)
        print("VIDEO-TIMELAPSE preset=people interval=1s capture=2.2s elapsed=\(CACurrentMediaTime()-began)s duration=\(duration)s frames=\(frames) fps=30 audio=0")
    }

    @MainActor func testRepeatedVideoRecordingsAndPhotoModeReturn() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let previousCallback = camera.onVideoRecorded
        let previousPhotoCallback = camera.onCaptureCompleted
        let previousMode = model.mode
        let previousKind = model.captureKind
        let previousPosition = model.currentPosition
        let idle = UIApplication.shared.isIdleTimerDisabled
        let originalHapticsPermission = AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording
        // Reproduce the system's default suppression instead of inheriting a
        // permission enabled by a previously running test or capture session.
        try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(false)
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        var photoCaptured = false
        camera.onVideoRecorded = { result = $0 }
        camera.onCaptureCompleted = { photoCaptured = $0 != nil }
        defer {
            camera.onVideoRecorded = previousCallback
            camera.onCaptureCompleted = previousPhotoCallback
            if model.captureKind != previousKind { model.setCaptureKind(previousKind) }
            if model.currentPosition != previousPosition { model.flipCamera() }
            model.setMode(previousMode)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(originalHapticsPermission)
        }
        model.setCameraActive(true)
        for _ in 0..<200 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.video)
        for _ in 0..<50 { if model.captureKind == .video { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.captureKind, .video)
        try await Task.sleep(for: .milliseconds(450))
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let began = CACurrentMediaTime()
            for _ in 0..<150 {
                if camera.liveAudioConnected && !camera.videoConfiguring && AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("VIDEO-HAPTICS audioReady=\(camera.liveAudioConnected) permission=\(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording) wait=\(CACurrentMediaTime()-began)")
            XCTAssertTrue(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording,
                          "Video preview with microphone input must allow level and button haptics")
        }
        if let window = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.windows.first(where: \.isKeyWindow) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Basic-Video-Camera-Layout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        for index in 0..<3 {
            result = nil
            let readyBegan=CACurrentMediaTime()
            print("VIDEO-BASIC-BEFORE-READY cycle=\(index) switch=\(model.captureKindSwitching) ready=\(camera.ready) configuring=\(camera.videoConfiguring) shutter=\(model.videoShutterEnabled)")
            for _ in 0..<250 {
                if model.videoShutterEnabled { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertTrue(model.videoShutterEnabled,"拍摄模式与相机路线实际就绪后再点录制")
            print("VIDEO-BASIC-READY cycle=\(index) waitSeconds=\(CACurrentMediaTime()-readyBegan)")
            let previousFrame = camera.preview
            let start = CACurrentMediaTime()
            model.toggleVideoRecording()
            for _ in 0..<200 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "Movie output did not start")
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                XCTAssertTrue(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording,
                              "Recording must retain the system haptics permission")
            }
            for _ in 0..<100 { if camera.preview != nil && camera.preview !== previousFrame { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(camera.preview !== previousFrame, "Live viewfinder must keep updating while recording")
            let startLatency = CACurrentMediaTime() - start
            try await Task.sleep(for: .seconds(1))
            model.toggleVideoRecording()
            // Repeated stop and mode taps must not start another recording.
            model.toggleVideoRecording()
            model.setCaptureKind(.photo)
            for _ in 0..<250 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let url = try XCTUnwrap(result?.get())
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video)
            XCTAssertFalse(video.isEmpty)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                XCTAssertFalse(audio.isEmpty, "Microphone permission is granted, so the movie needs an audio track")
            }
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 0.3)
            let dimensions = try await video.first?.load(.naturalSize)
            if let dimensions {
                XCTAssertEqual(max(dimensions.width, dimensions.height) / min(dimensions.width, dimensions.height), 16.0 / 9.0, accuracy: 0.04)
            }
            let fps = try await video.first?.load(.nominalFrameRate) ?? 0
            XCTAssertGreaterThanOrEqual(fps, 24)
            print("VIDEO-BASIC cycle=\(index) start=\(startLatency) duration=\(duration) dimensions=\(String(describing: dimensions)) fps=\(fps) audio=\(audio.count) bytes=\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
            XCTAssertEqual(model.captureKind, .video)
            XCTAssertFalse(camera.videoRecording)
            XCTAssertFalse(camera.videoBusy)
        }
        result = nil
        model.flipCamera()
        for _ in 0..<200 {
            if camera.ready && model.currentPosition != previousPosition && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotEqual(model.currentPosition, previousPosition)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            XCTAssertTrue(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording)
        }
        model.toggleVideoRecording()
        for _ in 0..<200 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.videoRecording)
        try await Task.sleep(for: .seconds(1))
        model.toggleVideoRecording()
        for _ in 0..<250 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let frontURL = try XCTUnwrap(result?.get())
        defer { try? FileManager.default.removeItem(at: frontURL) }
        let frontTracks = try await AVURLAsset(url: frontURL).loadTracks(withMediaType: .video)
        XCTAssertFalse(frontTracks.isEmpty)
        model.flipCamera()
        for _ in 0..<200 { if camera.ready && model.currentPosition == previousPosition { break }; try await Task.sleep(for: .milliseconds(25)) }
        model.setCaptureKind(.photo)
        XCTAssertEqual(model.captureKind, .photo)
        for _ in 0..<200 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        XCTAssertNotNil(camera.preview)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            XCTAssertTrue(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording,
                          "Leaving video mode must not leave recording haptics disabled")
        }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
        for _ in 0..<300 { if photoCaptured { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(photoCaptured, "Photo capture must still work after video mode exits")
    }
    #endif
}

/// 全量硬件回归复用实际可见的唯一引擎，清理上一用例的内存规格；不创建第二会话。
@MainActor enum FullDeviceRegressionFixture {
    /// 会话队列完成不代表主线程的模式切换与按钮状态已更新。
    /// 以真实UI的启用条件开拍，准备时间和录制启动时间分开记录。
    @discardableResult static func waitForVideoShutter(_ model:CameraViewModel, label:String,
        timeout:TimeInterval = 8,file:StaticString = #filePath,line:UInt = #line) async throws -> TimeInterval {
        let started=CACurrentMediaTime()
        let initial="switch=\(model.captureKindSwitching) ready=\(model.camera.ready) configuring=\(model.camera.videoConfiguring) enabled=\(model.videoShutterEnabled)"
        while !model.videoShutterEnabled,CACurrentMediaTime()-started<timeout {
            try await Task.sleep(for:.milliseconds(20))
        }
        guard model.videoShutterEnabled else {
            XCTFail("\(label)快门未就绪：\(initial)；当前switch=\(model.captureKindSwitching) ready=\(model.camera.ready) configuring=\(model.camera.videoConfiguring) busy=\(model.camera.videoBusy) pendingPhotos=\(model.camera.pendingPhotoCount) message=\(model.camera.message ?? "nil")",file:file,line:line)
            throw CancellationError()
        }
        let elapsed=CACurrentMediaTime()-started
        print("VIDEO-SHUTTER-READY label=\(label) seconds=\(elapsed) initial=[\(initial)]")
        return elapsed
    }

    /// 不和可见 App 共享模型，避免前序 UI 用例残留的窗口/子模块状态污染。
    static func makeIsolatedModel() async throws -> CameraViewModel {
        if let running = AppDependencies.runningAppCameraModel {
            running.setCameraActive(false)
            for _ in 0..<200 {
                let alive = await withCheckedContinuation { c in running.camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
                if !alive { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        for _ in 0..<400 { if model.camera.ready && model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        return model
    }

    static func makeFreshModel() async throws -> CameraViewModel {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(false)
        if model.camera.videoBusy { model.camera.stopVideoRecording() }
        await Task.yield()
        // 上一个用例可能刚停止录像/切换；给输出拆除和会话停止留更长时间，避免污染下一个基线。
        for _ in 0..<500 {
            let running = await withCheckedContinuation { c in model.camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
            if !running && !model.camera.ready && !model.camera.videoBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let running = await withCheckedContinuation { c in model.camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        if running || model.camera.ready {
            // 再发一次失活请求，覆盖上一个用例末尾排队的 start。
            model.setCameraActive(false)
            await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(300))
        }
        let finalRunning = await withCheckedContinuation { c in model.camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(finalRunning, "建立测试基线前必须真正停止会话")
        model.resetCaptureStateForTesting()
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        return model
    }
}


/// 不能只检查“自动恢复后测试通过”：真实系统运行错误也必须使定向用例失败。
/// 监听所有本进程会话，包含意外创建的第二个引擎；不含缺少 error key 的通知。
@MainActor final class SessionRuntimeErrorAudit {
    private var observer: NSObjectProtocol?
    private var errors: [String] = []
    init() {
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError else { return }
            MainActor.assumeIsolated {
                self?.errors.append("\(error.domain)/\(error.code): \(error.localizedDescription)")
            }
        }
    }
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        XCTAssertTrue(errors.isEmpty, "相机会话产生运行错误，即使后来自动恢复也不能忽略：\(errors)", file: file, line: line)
    }
}
