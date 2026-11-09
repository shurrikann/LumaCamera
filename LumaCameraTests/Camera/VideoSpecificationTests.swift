@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

private final class CinematicOutputFrameProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "tests.cinematic-output-probe")
    private var count = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        count += 1
    }

    var receivedFrames: Int { queue.sync { count } }
}

private final class CinematicMovieFileProbe: NSObject, AVCaptureFileOutputRecordingDelegate {
    let finished: XCTestExpectation
    private(set) var error: Error?

    init(finished: XCTestExpectation) { self.finished = finished }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        self.error = error
        finished.fulfill()
    }
}

private final class RuntimeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storedValues }
    func append(_ value: String) { lock.lock(); storedValues.append(value); lock.unlock() }
}

final class VideoSpecificationTests: XCTestCase {
    func testLevelUsesAllFourUprightEdgesAndLandscapeFeedback() {
        for angle in [0.0, .pi / 2, -.pi / 2, .pi, -.pi] {
            XCTAssertTrue(CameraLevelReading(roll: angle).isLevel)
            XCTAssertEqual(CameraLevelReading(roll: angle + 0.12).tilt, 0.12, accuracy: 0.001)
            var gate = LevelHapticGate()
            XCTAssertFalse(gate.update(roll: CameraLevelReading(roll: angle + 0.1).tilt, time: 0, enabled: true))
            XCTAssertFalse(gate.update(roll: CameraLevelReading(roll: angle).tilt, time: 0.1, enabled: true))
            XCTAssertTrue(gate.update(roll: CameraLevelReading(roll: angle).tilt, time: 0.4, enabled: true))
        }
    }

    func testUnsupportedFrameRateFallsBackWithinSameResolution() {
        let supported = [VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30), .init(resolution: .uhd4K, frameRate: .fps60)]
        XCTAssertEqual(VideoCaptureSettings.resolved(.init(resolution: .uhd4K, frameRate: .fps120), supported: supported)?.frameRate, .fps60)
        XCTAssertNil(VideoCaptureSettings.resolved(.init(), supported: []))
        XCTAssertEqual(VideoCaptureSettings().bitRate, 12_000_000)
        XCTAssertEqual(VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps60).bitRate, 67_882_250)
        let details = PhotoDetails(rows: [.init(title: "帧率", value: "60 fps"), .init(title: "时长", value: "1 秒"), .init(title: "输出格式", value: "HEVC"), .init(title: "码率", value: "24 Mbps"), .init(title: "音频", value: "AAC")])
        XCTAssertEqual(PhotoInfoPresentation(details: details, isVideo: true).parameterItems.map(\.value), ["60 fps", "1 秒", "HEVC", "24 Mbps"])
        XCTAssertEqual(PhotoInfoPresentation(details: details, isVideo: true).additionalRows.map(\.title), ["音频"])
    }

    #if !targetEnvironment(simulator)
    @MainActor func testOrdinaryFourThreeUsesNativeFourThreeFormat() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.videoCodec = .hevc; model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = .sdr
        model.setCaptureKind(.video)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<200 { if camera.ready && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        for ratio in [VideoRatio.ratio4x3, .square, .ratio16x9, .wide, .cinema] {
            model.selectVideoRatio(ratio)
            for _ in 0..<200 { if camera.ready && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
            var name = ""
            await withCheckedContinuation { c in camera.videoFormatStateForTesting { value, _, _, _ in name = value; c.resume() } }
            let dimensions = name.split(separator: "-").first?.split(separator: "x").compactMap { Int($0) } ?? []
            XCTAssertEqual(dimensions.count, 2, name)
            guard dimensions.count == 2 else { continue }
            let aspect = Double(dimensions[0]) / Double(dimensions[1])
            let expected = (ratio == .ratio4x3 || ratio == .square) ? 4.0 / 3.0 : 16.0 / 9.0
            XCTAssertEqual(aspect, expected, accuracy: 0.015, "\(ratio.rawValue) 格式选择错误: \(name)")
            XCTAssertGreaterThanOrEqual(dimensions[1], 1080, name)
            print("VIDEO-RATIO-SOURCE ratio=\(ratio.rawValue) name=\(name) aspect=\(aspect)")
        }
        model.videoResolution = .uhd4K; model.videoFrameRate = .fps30
        model.selectVideoRatio(.ratio4x3)
        for _ in 0..<300 { if camera.ready && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        var fourKName = ""
        await withCheckedContinuation { c in camera.videoFormatStateForTesting { value, _, _, _ in fourKName = value; c.resume() } }
        let fourK = fourKName.split(separator: "-").first?.split(separator: "x").compactMap { Int($0) } ?? []
        XCTAssertEqual(fourK.count, 2, fourKName)
        if fourK.count == 2 {
            let aspect = Double(fourK[0]) / Double(fourK[1])
            XCTAssertEqual(aspect, 4.0 / 3.0, accuracy: 0.015, "4K 4:3 必须使用原生 4:3 格式: \(fourKName)")
            XCTAssertGreaterThanOrEqual(fourK[1], 2160, fourKName)
            print("VIDEO-4K-4:3-SOURCE name=\(fourKName) aspect=\(aspect)")
        }
    }
    #endif

    func testOpenGateSwitchLimitsVideoRatiosAndPreviewCadenceFollowsSelectedRate() {
        XCTAssertEqual(VideoRatio.options(openGateEnabled: false), VideoRatio.aspectOptions)
        XCTAssertEqual(VideoRatio.options(openGateEnabled: true), [.ratio4x3, .square])
        XCTAssertFalse(VideoRatio.aspectOptions.contains(.openGate))

        for rate in [24, 25, 30, 50, 60] {
            let interval = LivePreviewCadence.minimumInterval(frameRate: rate)
            XCTAssertEqual(interval, 1.0 / Double(rate), accuracy: 0.000_001)
            XCTAssertFalse(LivePreviewCadence.accepts(time: 10 + interval - 0.002, lastFrameTime: 10, frameRate: rate))
            XCTAssertTrue(LivePreviewCadence.accepts(time: 10 + interval, lastFrameTime: 10, frameRate: rate))
        }
        XCTAssertEqual(LivePreviewCadence.minimumInterval(frameRate: 120), 1.0 / 60, accuracy: 0.000_001)
        XCTAssertEqual(LivePreviewCadence.minimumInterval(frameRate: 120, captureFrameRate: 120), 1.0 / 30, accuracy: 0.000_001)
        XCTAssertEqual(LivePreviewCadence.minimumInterval(frameRate: 30, captureFrameRate: 240), 1.0 / 30, accuracy: 0.000_001)
        XCTAssertEqual(LivePreviewCadence.minimumInterval(frameRate: nil), 1.0 / 30, accuracy: 0.000_001)
        XCTAssertFalse(LivePreviewCadence.accepts(time: .infinity, lastFrameTime: 0, frameRate: 30))
    }

    #if !targetEnvironment(simulator)
    @MainActor func testCinematicOutputGraphsAgainstAppleCapturePatternOnDevice() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Cinematic capture requires iOS 26 or later") }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        model.setCameraActive(false)
        await withCheckedContinuation { continuation in
            camera.afterPendingSessionTasks { continuation.resume() }
        }

        let device = try XCTUnwrap(AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back))
        let format = try XCTUnwrap(device.formats.first { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.isCinematicVideoCaptureSupported
                && size.width >= 1920 && size.height >= 1080
                && format.videoFrameRateRangeForCinematicVideo.map { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 } == true
                && format.supportedColorSpaces.contains(.sRGB)
        }, "Dual Wide camera exposes no compatible 1080p30 SDR Cinematic format")

        enum Graph {
            case appleMovie
            case oneVideoDataOutput
            case oneVideoDataOutputWithAudio
            case oneVideoDataOutputWithAudioAndMetadata
            case twoVideoDataOutputs
            case appTwoVideoDataOutputs
        }
        let graphs: [Graph] = [.appleMovie, .oneVideoDataOutput, .oneVideoDataOutputWithAudio,
                               .oneVideoDataOutputWithAudioAndMetadata, .twoVideoDataOutputs,
                               .appTwoVideoDataOutputs]
        let graphNames = ["AppleMovieFileOutput+Metadata+Photo", "VideoDataOutput+Metadata+Photo",
                          "Photo+VideoDataOutput+Audio(noMetadata)", "Photo+VideoDataOutput+Audio+Metadata",
                          "Photo+2xVideoDataOutput(noAudio)", "AppPhoto+2xVideoDataOutput+Audio"]
        var results: [String] = []
        for (index, graph) in graphs.enumerated() {
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeColorSpace = .sRGB
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw XCTSkip("Cannot attach Dual Wide input in direct graph test") }
            session.addInput(input)
            input.isCinematicVideoCaptureEnabled = true

            var added: [AVCaptureOutput] = []
            let photo = AVCapturePhotoOutput()
            let metadata = AVCaptureMetadataOutput()
            let videoA = AVCaptureVideoDataOutput()
            let videoB = AVCaptureVideoDataOutput()
            let audio = AVCaptureAudioDataOutput()
            let movie = AVCaptureMovieFileOutput()
            let frames = CinematicOutputFrameProbe()
            videoA.setSampleBufferDelegate(frames, queue: frames.queue)
            switch graph {
            case .appleMovie:
                added = [movie, metadata, photo]
            case .oneVideoDataOutput:
                added = [videoA, metadata, photo]
            case .oneVideoDataOutputWithAudio:
                added = [photo, videoA, audio]
            case .oneVideoDataOutputWithAudioAndMetadata:
                added = [photo, videoA, audio, metadata]
            case .twoVideoDataOutputs:
                added = [photo, videoA, videoB]
            case .appTwoVideoDataOutputs:
                added = [photo, videoA, videoB, audio]
            }
            var outputFailure: String?
            for output in added {
                guard session.canAddOutput(output) else {
                    outputFailure = "canAddOutput=false for \(type(of: output))"
                    break
                }
                session.addOutput(output)
            }
            if outputFailure == nil, let metadata = added.compactMap({ $0 as? AVCaptureMetadataOutput }).first {
                let required = metadata.requiredMetadataObjectTypesForCinematicVideoCapture
                if !required.allSatisfy(metadata.availableMetadataObjectTypes.contains) {
                    outputFailure = "required Cinematic metadata types unavailable"
                } else {
                    metadata.metadataObjectTypes = required
                }
            }
            session.commitConfiguration()

            let errorBox = RuntimeErrorBox()
            let token = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                object: session, queue: nil) { note in
                    errorBox.append(String(reflecting: note.userInfo?[AVCaptureSessionErrorKey] ?? note.userInfo ?? [:]))
                }
            if outputFailure == nil {
                let start = DispatchTime.now()
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        session.startRunning()
                        continuation.resume()
                    }
                }
                let startupMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                try await Task.sleep(for: .seconds(2))
                let earlyFrames = frames.receivedFrames
                if graph == .oneVideoDataOutput {
                    try await Task.sleep(for: .seconds(3))
                }
                results.append("\(graphNames[index]) running=\(session.isRunning) earlyFrames=\(earlyFrames) receivedFrames=\(frames.receivedFrames) scene=\(device.cinematicVideoCaptureSceneMonitoringStatuses) startMs=\(startupMs) runtimeErrors=\(errorBox.values)")
                if graph == .appleMovie, session.isRunning {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                    defer { try? FileManager.default.removeItem(at: url) }
                    let finished = expectation(description: "系统电影输出完成")
                    let recorder = CinematicMovieFileProbe(finished: finished)
                    movie.startRecording(to: url, recordingDelegate: recorder)
                    try await Task.sleep(for: .seconds(2))
                    movie.stopRecording()
                    await fulfillment(of: [finished], timeout: 8)
                    let asset = AVURLAsset(url: url)
                    let duration = try? await asset.load(.duration).seconds
                    let tracks = try? await asset.loadTracks(withMediaType: .video)
                    let rate = try? await tracks?.first?.load(.nominalFrameRate)
                    results.append("AppleMovieRecording duration=\(duration ?? 0) nominalFPS=\(rate ?? 0) error=\(String(describing: recorder.error))")
                }
            } else {
                results.append("\(graphNames[index]) running=false failure=\(outputFailure!)")
            }
            session.stopRunning()
            NotificationCenter.default.removeObserver(token)
        }
        let attachment = XCTAttachment(string: results.joined(separator: "\n"))
        attachment.name = "cinematic-output-graph-comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CINEMATIC-OUTPUT-GRAPH-COMPARISON\n\(results.joined(separator: "\n"))")
        XCTAssertTrue(results.first?.contains("running=true") == true, results.joined(separator: "\n"))
    }

    @MainActor func testSlowMotionAndCinematicRoutesOnDevice() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let oldKind = model.captureKind, oldMode = model.mode, oldPosition = model.currentPosition
        let oldLensID = camera.selectedLens, oldZoom = camera.currentZoom
        let oldResolution = model.videoResolution, oldRate = model.videoFrameRate
        let oldColor = model.videoColorSpace, oldCodec = model.videoCodec, oldRatio = model.videoRatio
        let oldVideoCallback = camera.onVideoRecorded
        var recordingResult: Result<URL, Error>?
        var temporaryMovie: URL?
        camera.onVideoRecorded = { recordingResult = $0 }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = oldVideoCallback
                }; camera.stopVideoRecording()
            } else { camera.onVideoRecorded = oldVideoCallback }
            if let temporaryMovie { try? FileManager.default.removeItem(at: temporaryMovie) }
            model.setCaptureKind(.video)
            if model.slowMotionEnabled { model.toggleSlowMotionMode() }
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
            model.videoOpenGateEnabled = false
            model.videoResolution = oldResolution; model.videoFrameRate = oldRate
            model.videoColorSpace = oldColor; model.videoCodec = oldCodec; model.videoRatio = oldRatio
            model.setCaptureKind(.photo)
            model.setMode(oldMode)
            if model.currentPosition != oldPosition { model.flipCamera() }
            if let lens = camera.lenses.first(where: { $0.id == oldLensID }) {
                camera.selectLens(lens); camera.setContinuousZoom(oldZoom)
            }
            model.setCaptureKind(oldKind)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready, camera.message ?? "Camera did not become ready")
        if model.captureKind != .photo { model.setCaptureKind(.photo) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<400 {
            if camera.ready && !camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if model.currentPosition != .back { model.flipCamera() }
        // 组合回归可能从前置开始；先等真实后置输入就绪，再切录像格式。
        // 不让“翻转镜头”和“进入视频”同时改动会话，污染后续电影性能/录制断言。
        for _ in 0..<400 {
            if camera.ready && model.currentPosition == .back && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready && model.currentPosition == .back)
        model.setMode(.auto)
        model.setCaptureKind(.video)
        model.videoCodec = .hevc; model.videoColorSpace = .sdr; model.videoOpenGateEnabled = false
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<400 { if camera.ready && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)

        // 对照物理镜头能力与应用扫描到的系统自动多摄路线，定位规格为何变成空列表。
        let physical = camera.lenses.filter { $0.device.position == .back }.map { lens -> String in
            let slow = VideoCaptureSettings.slowMotionCaptureRates(by: lens.device)
            let cinematic = VideoCaptureSettings.cinematicVideoSupported(by: lens.device)
            let flagged: [String]
            let inputSupport: Bool
            if #available(iOS 26.0, *) {
                flagged = lens.device.formats.filter(\.isCinematicVideoCaptureSupported).map { format in
                    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let r = format.videoFrameRateRangeForCinematicVideo.map { "\($0.minFrameRate)...\($0.maxFrameRate)" } ?? "nil"
                    return "\(d.width)x\(d.height) colors=\(format.supportedColorSpaces.map(\.rawValue)) fps=\(r)"
                }
                inputSupport = (try? AVCaptureDeviceInput(device: lens.device))?.isCinematicVideoCaptureSupported ?? false
            } else {
                flagged = []; inputSupport = false
            }
            return "physical lens=\(lens.id) type=\(lens.device.deviceType.rawValue) slowCaptureRates=\(slow.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" }) cinematic=\(cinematic.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" }) flaggedFormats=\(flagged) detachedInput=\(inputSupport)"
        }
        let discoveredDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInDualWideCamera, .builtInTripleCamera, .builtInDualCamera,
                          .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
                          .builtInTrueDepthCamera],
            mediaType: .video, position: .unspecified).devices
        let systemDeviceDetails: [String] = discoveredDevices.map { device in
            let flagged: [String]
            if #available(iOS 26.0, *) {
                flagged = device.formats.filter(\.isCinematicVideoCaptureSupported).map { format in
                    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let r = format.videoFrameRateRangeForCinematicVideo.map { "\($0.minFrameRate)...\($0.maxFrameRate)" } ?? "nil"
                    return "\(d.width)x\(d.height) colors=\(format.supportedColorSpaces.map(\.rawValue)) fps=\(r)"
                }
            } else { flagged = [] }
            let slow = VideoCaptureSettings.slowMotionCaptureRates(by: device)
            return "device position=\(device.position.rawValue) type=\(device.deviceType.rawValue) id=\(device.uniqueID) slowCapture=\(slow.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" }) cinematicFormats=\(flagged)"
        }
        let slowRoutes = await withCheckedContinuation { c in
            camera.compatibleVideoSubmodeRoutes(for: .slowMotion, position: .back, openGateEnabled: false) { c.resume(returning: $0) }
        }
        let cinematicRoutes = await withCheckedContinuation { c in
            camera.compatibleVideoSubmodeRoutes(for: .cinematic, position: .back, openGateEnabled: false) { c.resume(returning: $0) }
        }
        let formatState = await withCheckedContinuation { c in
            camera.videoFormatStateForTesting { name, minimum, maximum, ranges in
                c.resume(returning: "active=\(name) frameDuration=\(minimum)...\(maximum) fpsRanges=\(ranges)")
            }
        }
        let cinematicInputState = await withCheckedContinuation { c in
            camera.cinematicCaptureStateForTesting { supported, enabled in c.resume(returning: (supported, enabled)) }
        }
        let report = (physical + systemDeviceDetails + [
            "AUTO attachedInput=\(cinematicInputState)",
            "system=iOS \(UIDevice.current.systemVersion) model=\(UIDevice.current.model)",
            "AUTO slowRoutes=\(slowRoutes.map { "\($0.lensID):\($0.settings.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" })" })",
            "AUTO cinematicRoutes=\(cinematicRoutes.map { "\($0.lensID):\($0.settings.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" })" })",
            formatState
        ]).joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "slow-motion-cinematic-device-capabilities"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
        print("VIDEO-SUBMODE-DEVICE-CAPABILITIES\n\(report)")

        XCTAssertFalse(physical.isEmpty)
        XCTAssertTrue(physical.contains { $0.contains("slowCaptureRates=[") && !$0.contains("slowCaptureRates=[]") }, report)
        XCTAssertFalse(slowRoutes.isEmpty, "A-mode route must expose a compatible slow-motion route: \(report)")
        XCTAssertFalse(cinematicRoutes.isEmpty, "A-mode route must expose a compatible Cinematic route: \(report)")

        var slowMotionLatencies: [Double] = []
        for _ in 0..<2 {
            model.toggleSlowMotionMode()
            let start = CACurrentMediaTime()
            for _ in 0..<600 {
                if model.slowMotionEnabled && model.videoSubmodePreparing == nil && !camera.videoConfiguring
                    && camera.videoSettings.captureFrameRate == model.slowMotionCaptureFrameRateForSelection { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let state = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
            XCTAssertTrue(model.slowMotionEnabled, "\(camera.message ?? report) \(state)")
            XCTAssertEqual(camera.videoSettings.captureFrameRate, model.slowMotionCaptureFrameRateForSelection, state)
            slowMotionLatencies.append(CACurrentMediaTime() - start)
            model.toggleSlowMotionMode()
            for _ in 0..<600 {
                if !model.slowMotionEnabled && model.videoSubmodePreparing == nil && !camera.videoConfiguring
                    && camera.videoSettings.captureFrameRate == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.slowMotionEnabled, "Slow motion must turn off cleanly after repeated toggling")
        }

        var cinematicLatencies: [Double] = []
        var cinematicFirstFrameLatencies: [Double] = []
        var cinematicGraphRebuildCounts: [Int] = []
        for cycle in 0..<2 {
            await withCheckedContinuation { c in camera.resetRuntimeErrorCountForTesting { c.resume() } }
            let previousFrameID = camera.userSwitchFrameID
            let graphCountBefore = await withCheckedContinuation { c in
                camera.cinematicGraphRebuildCountForTestingSnapshot { c.resume(returning: $0) }
            }
            model.toggleCinematicVideoMode()
            let start = CACurrentMediaTime()
            for _ in 0..<600 {
                if model.cinematicVideoEnabled && model.videoSubmodePreparing == nil
                    && !camera.videoConfiguring && camera.cinematicVideoCaptureActive { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let state = await withCheckedContinuation { c in
                camera.cinematicCaptureStateForTesting { supported, enabled in c.resume(returning: (supported, enabled)) }
            }
            let routeState = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
            XCTAssertTrue(model.cinematicVideoEnabled, "\(camera.message ?? report) \(routeState)")
            XCTAssertTrue(state.0 && state.1, "The attached input must support and enable Cinematic: \(routeState)")
            cinematicLatencies.append(CACurrentMediaTime() - start)
            // 只统计最终路由的新帧；不能把模式布尔值变为 true 当作用户已看到新预览。
            for _ in 0..<600 {
                if model.cinematicVideoEnabled && model.videoSubmodePreparing == nil
                    && !camera.videoConfiguring && camera.preview != nil
                    && camera.userSwitchFrameID != previousFrameID { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(camera.preview, "Cinematic must resume preview")
            XCTAssertNotEqual(camera.userSwitchFrameID, previousFrameID, "Preview must contain a frame from the new configuration")
            cinematicFirstFrameLatencies.append(CACurrentMediaTime() - start)
            // 模式标志刚切换成功不代表会话稳定；等待硬件图运行后再核对运行错误。
            try await Task.sleep(for: .seconds(3))
            let stableRouteState = await withCheckedContinuation { c in
                camera.videoSubmodeStateForTesting { c.resume(returning: $0) }
            }
            XCTAssertTrue(stableRouteState.contains("running=true"), "Cinematic session stopped after activation: \(stableRouteState)")
            XCTAssertTrue(stableRouteState.contains("runtimeErrors=0"), "Cinematic emitted a runtime error: \(stableRouteState)")
            let graphCountAfter = await withCheckedContinuation { c in
                camera.cinematicGraphRebuildCountForTestingSnapshot { c.resume(returning: $0) }
            }
            cinematicGraphRebuildCounts.append(graphCountAfter - graphCountBefore)
            XCTAssertEqual(graphCountAfter - graphCountBefore, 1, "One user entry must configure the Cinematic pipeline only once")
            if cycle == 0 {
                // 相同规格的重复提交不应关闭/重开电影处理，也不应触发新一轮输出图重建。
                for _ in 0..<3 { camera.setVideoSettings(camera.videoSettings, cinematicVideo: true) }
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let graphCountAfterNoOp = await withCheckedContinuation { c in
                    camera.cinematicGraphRebuildCountForTestingSnapshot { c.resume(returning: $0) }
                }
                XCTAssertEqual(graphCountAfterNoOp, graphCountAfter)

                // 真实切换 4K24/4K30/1080p30 仍需重配格式，不能被去重优化吞掉。
                for settings in [VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps24),
                                 .init(resolution: .uhd4K, frameRate: .fps30), .init()] {
                    XCTAssertTrue(camera.cinematicVideoSettings.contains(settings))
                    camera.setVideoSettings(settings, cinematicVideo: true)
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    XCTAssertEqual(camera.videoSettings, settings)
                    XCTAssertTrue(camera.cinematicVideoCaptureActive)
                    let configured = CACurrentMediaTime()
                    for _ in 0..<300 { if camera.previewFrameTimeForTesting > configured { break }; try await Task.sleep(for:.milliseconds(20)) }
                    XCTAssertGreaterThan(camera.previewFrameTimeForTesting,configured)
                recordingResult = nil
                camera.startVideoRecording(aspect: .wide, cinematicVideo: true)
                for _ in 0..<400 {
                    if camera.videoRecording || recordingResult != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(camera.videoRecording, camera.message ?? "Cinematic recording did not start")
                try await Task.sleep(for: .milliseconds(800))
                camera.stopVideoRecording()
                for _ in 0..<500 {
                    if recordingResult != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let movie = try XCTUnwrap(recordingResult?.get(), "Cinematic movie did not finish")
                temporaryMovie = movie
                let asset = AVURLAsset(url: movie)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let duration = try await asset.load(.duration).seconds
                XCTAssertFalse(tracks.isEmpty)
                XCTAssertGreaterThan(duration, 0.5)
                let track = try XCTUnwrap(tracks.first)
                let size = try await track.load(.naturalSize)
                XCTAssertEqual(size,settings.resolution.dimensions)
                let reader = try AVAssetReader(asset:asset)
                let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                var frames = 0, firstPTS:Double?, lastPTS = -Double.infinity
                while let buffer = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    XCTAssertGreaterThan(pts,lastPTS); if firstPTS == nil { firstPTS = pts }; lastPTS = pts; frames += 1
                }
                XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,1)
                let fps = Double(frames-1)/(lastPTS-(firstPTS ?? lastPTS))
                XCTAssertEqual(fps,Double(settings.frameRate.rawValue),accuracy:1)
                print("CINEMATIC-FILE \(settings.resolution.title)/\(settings.frameRate.rawValue) frames=\(frames) ptsFPS=\(fps) duration=\(duration)")
                try FileManager.default.removeItem(at: movie)
                temporaryMovie = nil
                recordingResult = nil
                }
            }
            model.toggleCinematicVideoMode()
            for _ in 0..<600 {
                if !model.cinematicVideoEnabled && model.videoSubmodePreparing == nil
                    && !camera.videoConfiguring && !camera.cinematicVideoCaptureActive { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.cinematicVideoEnabled, "Cinematic must turn off cleanly after repeated toggling")
        }
        XCTAssertLessThan(slowMotionLatencies.max() ?? .infinity, 12, "Slow-motion route setup exceeded the 12 s budget")
        XCTAssertLessThan(cinematicLatencies.max() ?? .infinity, 12, "Cinematic route setup exceeded the 12 s budget")
        print("VIDEO-SUBMODE-LATENCY device=iPhone17Pro samples=2 slowMotion=\(slowMotionLatencies)s cinematic=\(cinematicLatencies)s; latency measures action-return-to-active capture configuration, not encoded-media frame cadence")
        let latencyReport = "CINEMATIC-FIRST-FRAME samples=2 seconds=\(cinematicFirstFrameLatencies) graphRebuilds=\(cinematicGraphRebuildCounts); entry-action return to final-route preview image publication, includes <=10ms polling and does not measure display scanout"
        let latencyAttachment = XCTAttachment(string: latencyReport)
        latencyAttachment.name = "Cinematic-switch-first-frame-latency"
        latencyAttachment.lifetime = .keepAlways
        add(latencyAttachment)
        print(latencyReport)
    }

    @MainActor func testUnsupportedRateCannotLeaveToolbarAndCaptureOutOfSync() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.setCaptureKind(.photo); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.video); model.setMode(.auto)
        model.videoResolution = .hd1080; model.videoFrameRate = .fps60
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let supported = camera.supportedVideoSettings
        guard !supported.isEmpty else { XCTFail("No supported capture format"); return }
        if !model.supportsVideoFrameRate(.fps120) {
            let actual = camera.videoSettings
            model.videoFrameRate = .fps120
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.videoSettings, actual)
            XCTAssertEqual(model.videoFrameRate, actual.frameRate)
            XCTAssertEqual(model.videoFrameRateText, String(actual.frameRate.rawValue))
        }
        for index in 0..<100 {
            model.videoResolution = VideoResolution.allCases[index % 3]
            model.videoFrameRate = VideoFrameRate.allCases[index % 6]
        }
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertEqual(camera.videoSettings, VideoCaptureSettings())
        XCTAssertEqual(model.videoFrameRate, .fps30); XCTAssertEqual(model.videoResolution, .hd1080)
        XCTAssertFalse(camera.videoConfiguring)
    }

    @MainActor func testRenderedVideoPreviewCadenceTracksSupportedRates() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.videoRatio = .ratio16x9; model.videoOpenGateEnabled = false
            model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        if model.currentPosition != .back {
            model.flipCamera()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
        XCTAssertEqual(model.currentPosition,.back)
        model.setMode(.auto)
        model.setCaptureKind(.video)
        model.videoResolution = .hd1080
        model.videoColorSpace = .sdr
        model.videoCodec = .hevc
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let supportedRates = VideoFrameRate.allCases.filter { rate in
            camera.supportedVideoSettings.contains { $0.resolution == .hd1080 && $0.frameRate == rate && $0.colorSpace == .sdr }
        }
        XCTAssertFalse(supportedRates.isEmpty)
        // 配置完成后还要核对真实设备帧周期，再等新帧；不把旧路由的发布样本混入测量。
        func verifyRoute(rate: VideoFrameRate) async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let now = CACurrentMediaTime()
            for _ in 0..<300 { if camera.previewFrameTimeForTesting > now { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting,now)
            XCTAssertEqual(camera.videoSettings.frameRate,rate)
            let value = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            let state = try XCTUnwrap(value)
            XCTAssertEqual(state.activeMinFrameSeconds,1 / Double(rate.rawValue),accuracy:0.00001)
            XCTAssertEqual(state.activeMaxFrameSeconds,1 / Double(rate.rawValue),accuracy:0.00001)
            try await Task.sleep(for:.milliseconds(200))
        }
        for rate in supportedRates {
            model.videoFrameRate = rate
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await verifyRoute(rate:rate)
            camera.resetPreviewPublicationTimesForTesting()
            try await Task.sleep(for: .milliseconds(1600))
            let times = camera.previewPublicationTimesForTestingSnapshot
            XCTAssertGreaterThan(times.count, 8, "No preview frames for selected \(rate.rawValue) fps")
            guard let first = times.first, let last = times.last, last > first else { continue }
            let measured = Double(times.count - 1) / (last - first)
            print("VIDEO-PREVIEW-CADENCE selected=\(rate.rawValue) delivered=\(times.count) measured=\(String(format: "%.1f", measured)) fps; includes main-queue publication cadence, not display scanout")
            XCTAssertLessThanOrEqual(measured, Double(rate.rawValue) * 1.15 + 2)
            if rate.rawValue <= 60 {
                XCTAssertGreaterThan(measured, Double(rate.rawValue) * 0.65,
                                     "Preview processing fell behind the selected \(rate.rawValue) fps mode")
            }
        }

        // The automatic virtual-multicam route may not advertise 120 fps even
        // when the selected physical camera supports it. Check the M route too.
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let supported120 = camera.supportedVideoSettings.filter { $0.frameRate == .fps120 && $0.colorSpace == .sdr }
        print("VIDEO-PREVIEW-120-SUPPORTED-M \(supported120.map { $0.resolution.title })")
        XCTAssertFalse(supported120.isEmpty, "M mode should expose the available 120 fps SDR route on iPhone 17 Pro")
        // 正向升到120后反向复查，覆盖先前30帧输入预算残留到高帧率的风险。
        for settings in supported120 + supported120.reversed() {
            model.videoFrameRate = .fps30
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.videoResolution = settings.resolution
            model.videoColorSpace = .sdr
            model.videoCodec = .hevc
            model.videoFrameRate = .fps120
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.videoSettings.resolution, settings.resolution)
            XCTAssertEqual(camera.videoSettings.frameRate, .fps120)
            try await verifyRoute(rate:.fps120)
            camera.resetPreviewPublicationTimesForTesting()
            try await Task.sleep(for: .milliseconds(2000))
            let times = camera.previewPublicationTimesForTestingSnapshot
            XCTAssertGreaterThan(times.count, 30, "No high-frame-rate preview frames")
            if let first = times.first, let last = times.last, last > first {
                let measured = Double(times.count - 1) / (last - first)
                let formattedMeasured = String(format: "%.1f", measured)
                print("VIDEO-PREVIEW-CADENCE selected=120 resolution=\(settings.resolution.title) delivered=\(times.count) measured=\(formattedMeasured) fps; includes main-queue publication cadence, not display scanout")
                XCTAssertLessThanOrEqual(measured, 140)
                XCTAssertGreaterThan(measured, 78, "120 fps preview processing fell below 65% of the selected rate")
            }
        }
        // 高频规格请求尚未处理时再反向选择，只应以最终30帧继续工作。
        for _ in 0..<5 {
            for rate in [VideoFrameRate.fps120,.fps24,.fps60,.fps25,.fps50,.fps30] { model.videoFrameRate = rate }
        }
        try await verifyRoute(rate:.fps30)
        camera.resetPreviewPublicationTimesForTesting()
        try await Task.sleep(for:.milliseconds(1200))
        let finalTimes = camera.previewPublicationTimesForTestingSnapshot
        let first = try XCTUnwrap(finalTimes.first), last = try XCTUnwrap(finalTimes.last)
        let finalRate = Double(finalTimes.count-1)/(last-first)
        XCTAssertEqual(finalRate,30,accuracy:4)
        model.setCameraActive(false)
        for _ in 0..<300 {
            let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
            if !running && !camera.ready { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let resumed = CACurrentMediaTime()
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.previewFrameTimeForTesting > resumed { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertGreaterThan(camera.previewFrameTimeForTesting,resumed)
        try await verifyRoute(rate:.fps30)
        print("VIDEO-PREVIEW-RECOVERY rapidRequests=30 finalMeasured=\(finalRate) mode=\(model.mode)")
    }

    @MainActor func testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        let callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }; camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.videoOpenGateEnabled = false
            model.videoRatio = .ratio16x9
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = .sdr; model.videoCodec = .hevc
            model.setCaptureKind(.photo); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setMode(.auto)
        model.videoCodec = .hevc; model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = .sdr
        model.setCaptureKind(.video)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<100 where !model.supportsVideoOpenGate { try await Task.sleep(for: .milliseconds(20)) }
        guard model.supportsVideoOpenGate else { throw XCTSkip("当前物理镜头的 1080p30 SDR 规格不提供 Open Gate") }

        // 当前交互要求先选择兼容画幅，再开启 Open Gate。
        model.selectVideoRatio(.ratio4x3)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setVideoOpenGateEnabled(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertTrue(model.videoOpenGateEnabled)
        XCTAssertTrue(model.supportsVideoRatio(.ratio4x3))
        XCTAssertTrue(model.supportsVideoRatio(.square))
        for ratio in VideoRatio.aspectOptions where !VideoRatio.openGateAspectOptions.contains(ratio) {
            XCTAssertFalse(model.supportsVideoRatio(ratio), "\(ratio.rawValue) must be disabled while Open Gate is on")
        }
        var formatName = ""
        await withCheckedContinuation { c in
            camera.videoFormatStateForTesting { name, _, _, _ in formatName = name; c.resume() }
        }
        let dimensions = formatName.split(separator: "-").first?.split(separator: "x").compactMap { Int($0) } ?? []
        XCTAssertEqual(dimensions.count, 2)
        XCTAssertTrue(OpenGateCapability.supportsNativeVideoDimensions(width: dimensions[0], height: dimensions[1]), formatName)

        XCTAssertFalse(model.supportsVideoCodec(.h264)); XCTAssertFalse(model.supportsVideoCodec(.proRes))
        print("OPEN-GATE-RATES \(camera.openGateVideoSettings.map { "\($0.resolution.title)/\($0.frameRate.rawValue)/\($0.colorSpace.rawValue)" })")
        for rate in VideoFrameRate.allCases {
            let available = camera.openGateVideoSettings.contains { $0.resolution == model.videoResolution && $0.frameRate == rate && $0.colorSpace == model.videoColorSpace }
            XCTAssertEqual(model.supportsVideoFrameRate(rate),available)
        }
        // 两轮实际输出后再反复取消开关，最终普通16:9仍需真实录制成功。
        for (index,ratio) in [VideoRatio.ratio4x3,.square,.ratio4x3,.square,.ratio16x9].enumerated() {
            if index == 2 {
                model.setVideoOpenGateEnabled(false)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                model.setVideoOpenGateEnabled(true)
            }
            if index == 4 {
                for _ in 0..<20 { model.setVideoOpenGateEnabled(false); model.setVideoOpenGateEnabled(true) }
                model.setVideoOpenGateEnabled(false)
            }
            model.selectVideoRatio(ratio)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            if index < 4 {
                await withCheckedContinuation { c in
                    camera.videoFormatStateForTesting { name, _, _, _ in formatName = name; c.resume() }
                }
                let currentDimensions = formatName.split(separator: "-").first?.split(separator: "x").compactMap { Int($0) } ?? []
                XCTAssertEqual(currentDimensions.count, 2)
                if currentDimensions.count == 2 {
                    XCTAssertTrue(OpenGateCapability.supportsNativeVideoDimensions(width: currentDimensions[0], height: currentDimensions[1]), formatName)
                }
            }
            result = nil
            camera.startVideoRecording(aspect: ratio.frameRatio)
            for _ in 0..<400 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "Open Gate recording did not start")
            try await Task.sleep(for: .milliseconds(1100))
            camera.stopVideoRecording()
            for _ in 0..<600 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let url = try XCTUnwrap(result?.get())
            let asset = AVURLAsset(url:url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let actual = Double(max(size.width, size.height) / min(size.width, size.height))
            let expected = ratio == .ratio4x3 ? 4.0 / 3.0 : ratio == .square ? 1.0 : 16.0/9.0
            XCTAssertEqual(actual, expected, accuracy: 0.015)
            if index < 4 {
                let dims = formatName.split(separator: "-").first?.split(separator: "x").compactMap { Int($0) } ?? []
                if dims.count == 2 {
                    let short = min(dims[0], dims[1]), long = max(dims[0], dims[1])
                    let expectedLong = ratio == .square ? short : long
                    XCTAssertEqual(Int(max(size.width, size.height)), expectedLong, "Open Gate 必须保留源格式的完整像素")
                    XCTAssertEqual(Int(min(size.width, size.height)), short)
                } else { XCTFail("无法读取实际采集格式：\(formatName)") }
            }
            let reader = try AVAssetReader(asset:asset)
            let decoded = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(decoded); XCTAssertTrue(reader.startReading())
            var frames = 0, firstPTS:Double?, lastPTS = -Double.infinity
            while let buffer = decoded.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                XCTAssertGreaterThan(pts,lastPTS); if firstPTS == nil { firstPTS = pts }; lastPTS = pts; frames += 1
            }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,1)
            let fps = Double(frames-1)/(lastPTS-(firstPTS ?? lastPTS))
            XCTAssertEqual(fps,30,accuracy:1)
            if index == 4 { XCTAssertFalse(model.videoOpenGateEnabled); XCTAssertEqual(size,VideoResolution.hd1080.dimensions) }
            print("VIDEO-OPEN-GATE-DECODE index=\(index) frames=\(frames) ptsFPS=\(fps) enabled=\(model.videoOpenGateEnabled)")
            print("VIDEO-OPEN-GATE ratio=\(ratio.rawValue) format=\(formatName) output=\(size)")
            try? FileManager.default.removeItem(at: url); result = nil
        }
        model.setVideoOpenGateEnabled(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertFalse(model.videoOpenGateEnabled)
        XCTAssertTrue(model.supportsVideoRatio(.cinema))
    }

    @MainActor func testHighFrameRateAndFrontCameraRestoreSupportedSpecifications() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        var results: [Result<URL,Error>] = []
        camera.onVideoRecorded = { results.append($0) }
        let saves = model.library.pendingSaveCount
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }
                camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            for result in results { if case .success(let url) = result { try? FileManager.default.removeItem(at:url) } }
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.setCaptureKind(.photo); model.setMode(.auto); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func waitFor(_ label:String,_ condition:()->Bool) async throws {
            for _ in 0..<400 { if condition() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label + ": " + (camera.message ?? "未就绪"))
            throw NSError(domain:"HighRatePhysicalTest",code:1)
        }
        model.setCameraActive(true)
        try await waitFor("相机启动") { camera.ready }
        if model.currentPosition != .back { model.flipCamera() }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCaptureKind(.video); model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        model.selectFocalLength(main)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let high = camera.supportedVideoSettings.filter { $0.frameRate == .fps120 && $0.colorSpace == .sdr }
        XCTAssertEqual(Set(high.map(\.resolution)),Set(VideoResolution.allCases),"主摄应提供三种120帧输出规格")
        var summaries: [String] = []
        func record(_ settings:VideoCaptureSettings,label:String) async throws {
            XCTAssertTrue(camera.supportedVideoSettings.contains(settings.baseSettings),"\(label) 的请求应由当前真实路由支持")
            model.videoResolution = settings.resolution; model.videoFrameRate = settings.frameRate
            model.videoColorSpace = .sdr; model.videoCodec = .hevc
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let configured = CACurrentMediaTime()
            try await waitFor("所选规格与新帧") { camera.videoSettings == settings && model.videoShutterEnabled && camera.previewFrameTimeForTesting > configured }
            let actual = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            let device = try XCTUnwrap(actual)
            XCTAssertEqual(device.activeMinFrameSeconds,1/Double(settings.frameRate.rawValue),accuracy:0.00001)
            XCTAssertEqual(device.activeMaxFrameSeconds,1/Double(settings.frameRate.rawValue),accuracy:0.00001)
            let count = results.count
            model.toggleVideoRecording()
            try await waitFor("录像开始") { camera.videoRecording || results.count > count }
            XCTAssertTrue(camera.videoRecording)
            try await Task.sleep(for:.milliseconds(800))
            camera.stopVideoRecording()
            try await waitFor("录像完成") { results.count > count && !camera.videoBusy }
            XCTAssertEqual(results.count,count+1)
            let url = try results[count].get()
            let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first)
            let fps = try await track.load(.nominalFrameRate), size = try await track.load(.naturalSize)
            XCTAssertEqual(size,settings.resolution.dimensions)
            XCTAssertEqual(Double(fps),Double(settings.frameRate.rawValue),accuracy:1)
            // 完整解码，按真实PTS计算采集节奏，不能仅相信轨道名义帧率。
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0, firstPTS:Double?, lastPTS = -Double.infinity
            while let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                XCTAssertTrue(pts.isFinite); XCTAssertGreaterThan(pts,lastPTS)
                if firstPTS == nil { firstPTS = pts }
                lastPTS = pts; frames += 1
            }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,1)
            let actualFPS = Double(frames-1)/(lastPTS - (firstPTS ?? lastPTS))
            XCTAssertEqual(actualFPS,Double(settings.frameRate.rawValue),accuracy:max(1,Double(settings.frameRate.rawValue)*0.05))
            XCTAssertEqual(model.library.pendingSaveCount,saves)
            let summary = "\(label) \(settings.resolution.title)/\(settings.frameRate.rawValue) frames=\(frames) nominal=\(fps) ptsFPS=\(actualFPS) device=\(device.deviceID)"
            summaries.append(summary); print("VIDEO-HIGH-FILE \(summary)")
        }
        for round in 0..<2 {
            for settings in high { try await record(settings,label:"rear-\(round)") }
            let beforeFront = CACurrentMediaTime()
            model.flipCamera()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await waitFor("前置新帧") { model.currentPosition == .front && camera.ready && camera.previewFrameTimeForTesting > beforeFront }
            for settings in [VideoCaptureSettings(),.init(resolution:.uhd4K,frameRate:.fps60)] {
                try await record(settings,label:"front-\(round)")
            }
            let beforeRear = CACurrentMediaTime()
            model.flipCamera()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await waitFor("后置恢复新帧") { model.currentPosition == .back && camera.ready && camera.previewFrameTimeForTesting > beforeRear }
            model.selectFocalLength(main)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertTrue(camera.supportedVideoSettings.contains { $0.frameRate == .fps120 && $0.colorSpace == .sdr })
        }
        let evidence = XCTAttachment(string:summaries.joined(separator:"\n"))
        evidence.name = "high-rate-front-actual-files"; evidence.lifetime = .keepAlways; add(evidence)
        print("VIDEO-HIGH-SUMMARY samples=\(summaries.count) rounds=2 callbacks=\(results.count)")
    }

    @MainActor func testAllSupportedVideoSpecificationsWriteMatchingTracks() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        let callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }
                camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.setCaptureKind(.photo); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<400 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setMode(.manual); model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.videoRatio = .ratio16x9
        model.setCaptureKind(.video)
        model.setMode(.manual) // 视频独立记忆挡位；进入后再选择 M，才能验证物理镜头的 120 帧规格。
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let supported = camera.supportedVideoSettings.filter { $0.colorSpace == .sdr }
        guard !supported.isEmpty else { XCTFail("No supported video format on the connected camera"); return }
        print("VIDEO-SPECS-SUPPORTED \(supported.map { "\($0.resolution.title)/\($0.frameRate.rawValue)" })")
        let began = CACurrentMediaTime()
        for settings in supported {
            camera.setVideoSettings(settings)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.videoSettings, settings)
            XCTAssertFalse(camera.videoConfiguring)
            let formatState = await withCheckedContinuation { c in camera.videoFormatStateForTesting { name, minimum, maximum, ranges in c.resume(returning: (name, minimum, maximum, ranges)) } }
            XCTAssertEqual(formatState.1, 1 / Double(settings.frameRate.rawValue), accuracy: 0.00001)
            XCTAssertEqual(formatState.2, 1 / Double(settings.frameRate.rawValue), accuracy: 0.00001)
            try await Task.sleep(for: .milliseconds(300))
            print("VIDEO-CADENCE requested=\(settings.frameRate.rawValue) state=\(formatState)")
            result = nil
            let frameBefore = camera.previewFrameTimeForTesting
            camera.startVideoRecording(aspect: .wide)
            for _ in 0..<400 { if camera.videoRecording || result != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "No first video frame")
            try await Task.sleep(for: .milliseconds(1200))
            camera.stopVideoRecording()
            for _ in 0..<700 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let url = try XCTUnwrap(result?.get())
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(size, settings.resolution.dimensions)
            XCTAssertEqual(Double(fps), Double(settings.frameRate.rawValue), accuracy: max(1.5, Double(settings.frameRate.rawValue) * 0.05))
            XCTAssertGreaterThan(duration, 1)
            // 规格矩阵也核对完整解码与实际时间戳，不能只依据文件名义帧率。
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0, firstPTS:Double?, lastPTS = -Double.infinity
            while let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                XCTAssertTrue(pts.isFinite); XCTAssertGreaterThan(pts,lastPTS)
                if firstPTS == nil { firstPTS = pts }; lastPTS = pts; frames += 1
            }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,1)
            let actualFPS = Double(frames-1)/(lastPTS-(firstPTS ?? lastPTS))
            XCTAssertEqual(actualFPS,Double(settings.frameRate.rawValue),accuracy:max(1,Double(settings.frameRate.rawValue)*0.05))
            print("VIDEO-SPEC-DECODE \(settings.resolution.title)/\(settings.frameRate.rawValue) frames=\(frames) ptsFPS=\(actualFPS)")
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting, frameBefore)
            let info = try await VideoDetailsReader.read(asset, filename: nil, date: nil, location: nil)
            XCTAssertEqual(info.rows.first { $0.title == "输出格式" }?.value, "HEVC")
            XCTAssertTrue(info.rows.contains { $0.title == "录制开始 ISO" })
            XCTAssertNotNil(info.capturedAt)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { XCTAssertFalse(audio.isEmpty) }
            print("VIDEO-SPEC \(settings.resolution.title)/\(settings.frameRate.rawValue) actual=\(size) fps=\(fps) duration=\(duration) audio=\(audio.count)")
            try? FileManager.default.removeItem(at: url); result = nil
        }
        print("VIDEO-SPECS-MATRIX count=\(supported.count) elapsed=\(CACurrentMediaTime()-began) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        // New requests should replace obsolete choices without blocking UI or recording.
        for index in 0..<100 { camera.setVideoSettings(supported[index % supported.count]) }
        camera.setVideoSettings(VideoCaptureSettings())
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertEqual(camera.videoSettings, VideoCaptureSettings())
        XCTAssertFalse(camera.videoConfiguring)
        let finalFrame = CACurrentMediaTime()
        for _ in 0..<300 { if camera.previewFrameTimeForTesting > finalFrame { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertGreaterThan(camera.previewFrameTimeForTesting,finalFrame)
    }
    #endif
}
