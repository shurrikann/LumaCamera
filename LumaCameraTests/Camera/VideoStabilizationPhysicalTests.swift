import XCTest
import AVFoundation
@testable import LumaCamera

@MainActor final class VideoStabilizationPhysicalTests: XCTestCase {
    private func state(_ camera: CameraEngine) async throws -> CameraEngine.VideoStabilizationState {
        let value = await withCheckedContinuation { c in camera.videoStabilizationStateForTesting { c.resume(returning: $0) } }
        return try XCTUnwrap(value)
    }
    func testOriginalDefaultStateDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_STABILIZATION_BASELINE"] == "1" else { throw XCTSkip("Explicit original-state diagnostic") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true); defer { model.setCameraActive(false) }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"原始防抖",timeout:20)
        let s = try await state(camera)
        print("STABILIZATION_BASELINE recordSupported=\(s.recordingSupported) preferred=\(String(describing:s.recordingPreferred)) active=\(String(describing:s.recordingActive)) previewSupported=\(s.previewSupported) preferred=\(String(describing:s.previewPreferred)) active=\(String(describing:s.previewActive))")
        XCTAssertEqual(s.recordingPreferred,0); XCTAssertEqual(s.recordingActive,0)
    }
    func testSupportedRoutesKeepStabilizationAcrossSettingsAndPhotoReturn() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        defer { model.closePopups(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        model.setCaptureKind(.video); model.setMode(.manual)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"防抖矩阵",timeout:20)
        if model.currentPosition != .back { model.flipCamera(); try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"后置",timeout:20) }
        var costs = [Double](), samples = 0
        for focal: CGFloat in [1,0.5,4] {
            camera.setVideoSettings(.init())
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"默认规格",timeout:20)
            guard let lens = model.displayedFocalLenses.first(where:{ abs($0.displayZoom-focal)<0.01 }) else { continue }
            model.selectFocalLength(lens)
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"镜头",timeout:20)
            for requested in [VideoCaptureSettings(), .init(resolution:.uhd4K,frameRate:.fps60), .init(resolution:.uhd4K,frameRate:.fps120)] {
                guard camera.supportedVideoSettings.contains(requested) else { continue }
                let began = CACurrentMediaTime()
                camera.setVideoSettings(requested)
                try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"规格",timeout:20)
                try await Task.sleep(for:.milliseconds(250))
                let s = try await state(camera)
                XCTAssertEqual(camera.videoSettings,requested)
                XCTAssertEqual(s.minimumFrameSeconds,1/Double(requested.frameRate.rawValue),accuracy:0.0001)
                XCTAssertEqual(s.maximumFrameSeconds,s.minimumFrameSeconds,accuracy:0.0001)
                if s.recordingSupported { XCTAssertTrue([1,2].contains(s.recordingPreferred ?? 0)); XCTAssertNotEqual(s.recordingActive,0) }
                if s.previewSupported { XCTAssertTrue([1,2].contains(s.previewPreferred ?? 0)); XCTAssertNotEqual(s.previewActive,0) }
                costs.append((CACurrentMediaTime()-began)*1000); samples += 1
                print("STABILIZATION_ROUTE focal=\(focal) spec=\(requested) format=\(s.format) record=\(String(describing:s.recordingActive)) preview=\(String(describing:s.previewActive)) supported=\(s.recordingSupported)/\(s.previewSupported)")
            }
        }
        for _ in 0..<6 {
            model.setCaptureKind(.photo)
            try await PresetToolbarChecks.wait("照片返回") { camera.ready && !camera.videoConfiguring }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let s = try await state(camera)
            if s.previewSupported { XCTAssertTrue(s.previewPreferred == 0 || s.previewPreferred == 4) }
            model.setCaptureKind(.video)
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"重进视频",timeout:20)
            let v = try await state(camera)
            if v.recordingSupported { XCTAssertTrue([1,2].contains(v.recordingPreferred ?? 0)); XCTAssertNotEqual(v.recordingActive,0) }
        }
        model.setCaptureKind(.photo); model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"快速切换",timeout:20)
        XCTAssertGreaterThan(samples,0)
        print("STABILIZATION_PERF samples=\(samples) configurationReadyMS=\(costs) includes250msSettle=true roundTrips=6 notDisplayFPS=true")
    }
    func testCinematicTimeLapseAndSlowMotionUseStabilization() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        var result: Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer { camera.stopVideoRecording(); model.setCameraActive(false); camera.onVideoRecorded = callback; UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        model.setCaptureKind(.video); model.setMode(.auto)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"子模式",timeout:20)
        if model.currentPosition != .back { model.flipCamera(); try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"后置",timeout:20) }
        var summaries = [String]()
        for name in ["cinematic","timeLapse","slowMotion"] {
            let began = CACurrentMediaTime()
            switch name {
            case "cinematic": model.toggleCinematicVideoMode()
            case "timeLapse": model.toggleTimeLapseMode()
            default: model.toggleSlowMotionMode()
            }
            try await PresetToolbarChecks.wait("子模式开启") {
                model.videoSubmodePreparing == nil && (name == "cinematic" ? model.cinematicVideoEnabled : name == "timeLapse" ? model.timeLapseEnabled : model.slowMotionEnabled)
            }
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:name,timeout:25)
            if name == "cinematic" { XCTAssertTrue(camera.cinematicVideoCaptureActive) }
            let s = try await state(camera), settings = camera.videoSettings
            XCTAssertTrue(s.recordingSupported)
            XCTAssertTrue([1,2].contains(s.recordingActive ?? 0))
            XCTAssertEqual(s.recordingActive,s.recordingPreferred)
            if s.previewSupported { XCTAssertTrue([1,2].contains(s.previewActive ?? 0)) }
            result = nil; model.toggleVideoRecording()
            try await PresetToolbarChecks.wait("子模式开拍") { camera.videoRecording || result != nil }
            XCTAssertTrue(camera.videoRecording)
            try await Task.sleep(for:.seconds(name == "timeLapse" ? 4 : 2))
            let during = try await state(camera)
            XCTAssertEqual(during.recordingActive,s.recordingActive)
            camera.stopVideoRecording()
            try await PresetToolbarChecks.wait("子模式成片") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result?.get()); defer { try? FileManager.default.removeItem(at:url) }
            let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video), track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading()); var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(count,name == "timeLapse" ? 1 : 20)
            let row = "STABILIZATION_SUBMODE name=\(name) settings=\(settings) record=\(String(describing:during.recordingActive)) preview=\(String(describing:during.previewActive)) decoded=\(count) elapsed=\(CACurrentMediaTime()-began) noPhotosWrites=true"
            print(row); summaries.append(row)
            switch name {
            case "cinematic": model.toggleCinematicVideoMode()
            case "timeLapse": model.toggleTimeLapseMode()
            default: model.toggleSlowMotionMode()
            }
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"退出子模式",timeout:25)
        }
        XCTAssertEqual(summaries.count,3)
    }

    func testUserHandheldStabilizedMovie() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_STABILIZATION_HANDHELD"] == "1" else { throw XCTSkip("Requires user-held phone") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        var result: Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer { camera.stopVideoRecording(); model.setCameraActive(false); camera.onVideoRecorded = callback; UIApplication.shared.isIdleTimerDisabled = idle }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        model.setCaptureKind(.video); model.setMode(.auto)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"手持",timeout:20)
        if model.currentPosition != .back { model.flipCamera(); try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"后置",timeout:20) }
        camera.setVideoSettings(.init())
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"规格",timeout:20)
        if let lens = model.displayedFocalLenses.first(where:{abs($0.displayZoom-1)<0.01}), camera.selectedLens != lens.id {
            model.selectFocalLength(lens)
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"1倍",timeout:20)
        }
        camera.setContinuousZoom(1)
        try await Task.sleep(for:.milliseconds(300))
        camera.startVideoRecording(aspect:.wide)
        try await PresetToolbarChecks.wait("开始手持录像") { camera.videoRecording || result != nil }
        XCTAssertTrue(camera.videoRecording)
        try await Task.sleep(for:.seconds(10))
        let s = try await state(camera)
        XCTAssertEqual(s.recordingActive,2)
        camera.stopVideoRecording()
        try await PresetToolbarChecks.wait("手持录像完成") { result != nil && !camera.videoBusy }
        let url = try XCTUnwrap(result?.get()); defer { try? FileManager.default.removeItem(at:url) }
        let movie = XCTAttachment(contentsOfFile:url); movie.name = "Handheld-1080p30-1x-cinematic-stabilization"; movie.lifetime = .keepAlways; add(movie)
        let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video), track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0, last:Double?, gaps = [Double]()
        while let frame = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(frame).seconds
            if let last { gaps.append(pts-last) }; last = pts; count += 1
        }
        XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(count,250)
        print("STABILIZATION_HANDHELD decoded=\(count) maxPTSGap=\(gaps.max() ?? 0) active=\(String(describing:s.recordingActive)) noPhotosWrites=true noShakeReductionPercentageClaim=true")
    }

    func testStabilizedRealMoviesFrontRearAndManualDecode() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        var result: Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer { camera.stopVideoRecording(); model.closePopups(); model.setCameraActive(false); camera.onVideoRecorded = callback; UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        model.setCaptureKind(.video)
        for (front,mode) in [(false,CameraShootingMode.auto),(false,.manual),(true,.auto)] {
            model.setMode(mode)
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"录像",timeout:20)
            if (model.currentPosition == .front) != front { model.flipCamera(); try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"前后摄",timeout:20) }
            camera.setVideoSettings(.init())
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"默认规格",timeout:20)
            let before = try await state(camera)
            result = nil
            let began = CACurrentMediaTime()
            camera.startVideoRecording(aspect:.wide)
            try await PresetToolbarChecks.wait("开拍") { camera.videoRecording || result != nil }
            XCTAssertTrue(camera.videoRecording)
            let startMS = (CACurrentMediaTime()-began)*1000
            try await Task.sleep(for:.seconds(2))
            let during = try await state(camera)
            XCTAssertEqual(during.device,before.device); XCTAssertEqual(during.format,before.format)
            if during.recordingSupported { XCTAssertNotEqual(during.recordingActive,0) }
            camera.stopVideoRecording()
            try await PresetToolbarChecks.wait("停止") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result?.get()); defer { try? FileManager.default.removeItem(at:url) }
            let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video), track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0, gaps = [Double](), last:Double?
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if let last { gaps.append(pts-last) }; last = pts; count += 1
            }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(count,20)
            XCTAssertTrue(gaps.allSatisfy{$0>0})
            print("STABILIZATION_MOVIE front=\(front) mode=\(mode) active=\(String(describing:during.recordingActive)) decoded=\(count) maxPTSGap=\(gaps.max() ?? 0) startMS=\(startMS) noPhotosWrites=true")
        }
    }
}
