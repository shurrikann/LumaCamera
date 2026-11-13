import AVFoundation
import UIKit
import XCTest
import ImageIO
@testable import LumaCamera

final class VideoModeTransitionTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let previousCallback = camera.onVideoRecorded
        let previousKind = model.captureKind
        let previousPosition = model.currentPosition
        let previousMode = model.mode
        let previousFormat = model.photoFormat
        let previousHDR = model.hdr
        let previousLive = model.livePhotoEnabled
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        var result: Result<URL, Error>?
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = previousCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            if model.captureKind != .photo { model.setCaptureKind(.photo) }
            if model.currentPosition != previousPosition { model.flipCamera() }
            model.photoFormat = previousFormat
            model.hdr = previousHDR
            if previousLive && !model.livePhotoEnabled && model.livePhotoAvailable { model.toggleLivePhoto() }
            model.setMode(previousMode)
            if previousKind == .video { model.setCaptureKind(.video) }
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = previousIdle
        }

        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        if model.captureKind != .photo {
            model.setCaptureKind(.photo)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
        if model.currentPosition != .back { model.flipCamera() }
        for _ in 0..<400 { if camera.ready && model.currentPosition == .back { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setMode(.auto)
        model.photoFormat = .jpeg
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        camera.selectLens(main)
        for _ in 0..<300 { if camera.ready && model.focalTransitionImage == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let photoRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(photoRoute.contains("virtual=true"), photoRoute)

        model.setCaptureKind(.video)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let videoRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(videoRoute.contains("video=true"), videoRoute)
        XCTAssertTrue(videoRoute.contains("virtual=true"), videoRoute)
        XCTAssertEqual(try XCTUnwrap(zoomValue(videoRoute)), try XCTUnwrap(zoomValue(photoRoute)), accuracy: 0.005,
                       "Entering video must preserve the selected focal length: \(videoRoute)")
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"automatic-video-route")
        model.toggleVideoRecording()
        for _ in 0..<300 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.videoRecording, camera.message ?? "A-mode video recording did not start")
        try await Task.sleep(for: .milliseconds(700))
        camera.stopVideoRecording()
        for _ in 0..<300 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let recording = try XCTUnwrap(result?.get())
        try? FileManager.default.removeItem(at: recording)
        result = nil

        model.setCaptureKind(.photo)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let switchedAt = CACurrentMediaTime()
        for _ in 0..<300 { if camera.previewFrameTimeForTesting > switchedAt { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(camera.previewFrameTimeForTesting, switchedAt)
        let restoredRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        print("AUTO-VIDEO-ROUTE photo=\(photoRoute) video=\(videoRoute) restored=\(restoredRoute)")
        XCTAssertTrue(restoredRoute.contains("video=false"), restoredRoute)
        XCTAssertTrue(restoredRoute.contains("virtual=true"), restoredRoute)
        XCTAssertTrue(restoredRoute.contains("switching=auto"), restoredRoute)
        XCTAssertEqual(try XCTUnwrap(zoomValue(restoredRoute)), try XCTUnwrap(zoomValue(photoRoute)), accuracy: 0.005,
                       "Returning to photos must preserve the selected focal length: \(restoredRoute)")
        XCTAssertEqual(try XCTUnwrap(formatSignature(restoredRoute)), try XCTUnwrap(formatSignature(photoRoute)),
                       "Photo active format must be restored after video. before=\(photoRoute), after=\(restoredRoute), message=\(camera.message ?? "none")")
        let fallbackTypes = await withCheckedContinuation { c in camera.automaticFallbackTypesForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(fallbackTypes.contains(.builtInWideAngleCamera), "A mode needs the main camera as an automatic candidate")
        let candidates = await withCheckedContinuation { c in camera.automaticConstituentTypesForTesting { members, supported in c.resume(returning: (members, supported)) } }
        XCTAssertTrue(candidates.0.contains(.builtInUltraWideCamera), "系统虚拟多摄仍包含超广角")
        XCTAssertEqual(Set(fallbackTypes), Set(candidates.1), "保留系统声明支持的完整 fallback 集合")
        XCTAssertEqual(model.mode, .auto)

        var routes = ["photo=\(photoRoute)", "video=\(videoRoute)", "restored=\(restoredRoute)"]
        for target in [2.0, 4.0, 8.0, 1.0] {
            guard let lens = camera.lenses.first(where: { $0.device.position == .back && abs(Double($0.displayZoom) - target) < 0.01 }) else { continue }
            camera.selectLens(lens)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for kind in [CameraViewModel.CaptureKind.video, .photo] {
                model.setCaptureKind(kind)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let committedAt = CACurrentMediaTime()
                for _ in 0..<200 {
                    if camera.previewFrameTimeForTesting > committedAt { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(camera.previewFrameTimeForTesting, committedAt)
                let route = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
                XCTAssertTrue(route.contains("virtual=true"), route)
                XCTAssertTrue(route.contains("switching=auto"), route)
                XCTAssertEqual(try XCTUnwrap(zoomValue(route)), target, accuracy: 0.005, route)
                routes.append("target=\(target) kind=\(kind) \(route)")
            }
        }
        model.setCaptureKind(.video)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.setContinuousZoom(3)
        try await Task.sleep(for: .milliseconds(250))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCaptureKind(.photo)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let changedInVideo = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(try XCTUnwrap(zoomValue(changedInVideo)), 3, accuracy: 0.005,
                       "A deliberate zoom change made in video must survive returning to photos: \(changedInVideo)")
        routes.append("changed-in-video=\(changedInVideo)")
        camera.setContinuousZoom(1)
        try await Task.sleep(for: .milliseconds(250))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        // Cancel superseded requests while the session queue is still processing them.
        for _ in 0..<20 { model.setCaptureKind(.video); model.setCaptureKind(.photo) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let cancelledRoute = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        XCTAssertTrue(cancelledRoute.contains("video=false"), cancelledRoute)
        XCTAssertTrue(cancelledRoute.contains("switching=auto"), cancelledRoute)
        XCTAssertEqual(try XCTUnwrap(zoomValue(cancelledRoute)), 1, accuracy: 0.005, cancelledRoute)
        routes.append("rapid-cancel=\(cancelledRoute)")
        let evidence = XCTAttachment(string: routes.joined(separator: "\n"))
        evidence.name = "automatic-video-photo-routes"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor func testCinematicPreviewAndPhotoHDRRecoverOnVideoRoundTrip() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真机电影输出和照片 HDR 能力")
        #else
        guard #available(iOS 26.0, *) else { throw XCTSkip("需要系统电影采集 API") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        let saves = model.library.pendingSaveCount
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCaptureKind(.photo)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
            XCTAssertEqual(model.library.pendingSaveCount, saves)
            audit.finish()
        }
        func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
            let deadline = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < deadline {
                if predicate() { return true }
                try await Task.sleep(for: .milliseconds(25))
            }
            return false
        }
        func photoRoute() async -> String? {
            await withCheckedContinuation { continuation in
                camera.automaticRouteSnapshotForTesting { continuation.resume(returning: $0) }
            }
        }
        model.setCameraActive(true)
        let initialReady = try await waitUntil {
            camera.ready && camera.preview != nil && camera.supportsHEIFHDR
                && !camera.videoConfiguring && !model.captureKindSwitching
        }
        XCTAssertTrue(initialReady, camera.message ?? "初始 HEIF HDR 路线未就绪")
        guard initialReady else { return }
        // 复用同一相机会话时，上一用例的退出视频请求可能仍在队列中；等它落定再开始本轮。
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        guard model.currentPosition == .back, model.mode == .auto else {
            XCTFail("需要后置 A 挡基线"); return
        }
        model.photoFormat = .heif
        model.hdr = true
        let initialRoute = await photoRoute()
        var samples: [(Double, Double)] = []
        for index in 0..<3 {
            model.setCaptureKind(.video)
            if index == 1 {
                let ready = try await waitUntil { !model.captureKindSwitching && !camera.videoConfiguring }
                XCTAssertTrue(ready)
            }
            let started = CACurrentMediaTime()
            model.toggleCinematicVideoMode()
            if index != 2 {
                let cinematicReady = try await waitUntil {
                    camera.cinematicVideoCaptureActive && !model.isPreparingSubmode
                        && camera.previewFrameTimeForTesting > started
                }
                XCTAssertTrue(cinematicReady, camera.message ?? "电影模式未交付新预览帧")
                let firstFrameTime = camera.previewFrameTimeForTesting
                let firstCount = await withCheckedContinuation { c in camera.recordingFrameCountForTesting { c.resume(returning: $0) } }
                try await Task.sleep(for: .milliseconds(2400))
                let lastCount = await withCheckedContinuation { c in camera.recordingFrameCountForTesting { c.resume(returning: $0) } }
                let state = await withCheckedContinuation { c in camera.videoSubmodeStateForTesting { c.resume(returning: $0) } }
                print("CINEMATIC-PREVIEW trial=\(index) recordingFrames=\(lastCount - firstCount) \(state)")
                // recordingOutput 计数在未开录时不一定代表预览；预览必须持续更新。
                XCTAssertGreaterThan(camera.previewFrameTimeForTesting, firstFrameTime, "电影预览应持续更新")
            }
            let cinematicTime = CACurrentMediaTime() - started
            let returning = CACurrentMediaTime()
            model.setCaptureKind(.photo)
            let photoReady = try await waitUntil {
                model.captureKind == .photo && !model.captureKindSwitching && !model.isPreparingSubmode
                    && !model.photoStateRestorePendingForTesting
                    && model.photoFormat == .heif && model.hdr
                    && camera.ready && camera.previewFrameTimeForTesting > returning && camera.supportsHEIFHDR
            }
            XCTAssertTrue(photoReady, camera.message ?? "返回后未恢复照片帧或 HDR 能力")
            guard photoReady else { return }
            let restoredRoute = await photoRoute()
            func routeInput(_ value: String?) -> String? {
                value?.split(separator: " ").first(where: { $0.hasPrefix("input=") }).map(String.init)
            }
            XCTAssertEqual(routeInput(restoredRoute), routeInput(initialRoute))
            XCTAssertEqual(model.photoFormat, .heif)
            XCTAssertTrue(model.hdr)
            XCTAssertFalse(camera.cinematicVideoCaptureActive)
            samples.append((cinematicTime, CACurrentMediaTime() - returning))
        }
        print("CINEMATIC-PHOTO-ROUNDTRIP samples=\(samples) includesPreviewObservation=true noPhotoWrites=true")
        #endif
    }

    @MainActor func testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let callback = camera.onVideoRecorded, photoCallback = camera.onCaptureCompleted
        let tracing = camera.photoPhaseTracingForTesting
        camera.photoPhaseTracingForTesting = true
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        let format = model.photoFormat
        let hdr = model.hdr
        let mode = model.mode
        let videoRatio = model.videoRatio
        model.videoRatio = .ratio16x9
        var result: Result<URL, Error>?, restoredPhoto: CapturedPhoto?
        camera.onCaptureCompleted = { restoredPhoto = $0 }
        let saves = model.library.pendingSaveCount
        camera.onVideoRecorded = { result = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.photoPhaseTracingForTesting = tracing
            camera.onVideoRecorded = callback; camera.onCaptureCompleted = photoCallback
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            model.setCaptureKind(.photo)
            if model.livePhotoEnabled { model.toggleLivePhoto() }
            model.photoFormat = format; model.hdr = hdr; model.setMode(mode)
            model.videoRatio = videoRatio
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.photo)
        var returnTimes: [Double] = []
        var captureTimes: [Double] = []
        // 反向再走一轮，覆盖视频保持 M 挡而照片返回 A 挡的独立状态。
        for variant in ["live", "hdr", "manual", "manual", "hdr", "live"] {
            if model.livePhotoEnabled { model.toggleLivePhoto() }
            model.hdr = false
            model.setMode(variant == "manual" ? .manual : .auto)
            model.photoFormat = variant == "hdr" ? .heif : .jpeg
            if variant == "manual" {
                // A slow still exposure catches a stale video frame-rate cap on route restoration.
                model.manualExposure = true; model.iso = 200; model.shutter = log2(0.5)
                model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 12
                model.manualFocus = true; model.focus = 0.65
                model.restoreDeviceParametersForTesting()
            }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            if variant == "live" {
                XCTAssertTrue(model.livePhotoAvailable)
                model.toggleLivePhoto()
            } else if variant == "hdr" {
                for _ in 0..<300 { if camera.supportsHEIFHDR { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(camera.supportsHEIFHDR)
                model.hdr = true
            }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(500))
            model.setCaptureKind(.video)
            if variant == "manual" { model.setMode(.manual) }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<400 {
                if model.videoShutterEnabled { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(model.videoShutterEnabled, "Video shutter must become ready for \(variant)")
            model.toggleVideoRecording()
            for _ in 0..<300 { if camera.videoRecording { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(camera.videoRecording, "variant=\(variant): \(camera.message ?? "No first frame")")
            try await snapshotControls(name: "VideoControls-Recording-" + variant)
            try await Task.sleep(for: .milliseconds(600))
            camera.stopVideoRecording()
            for _ in 0..<300 { if result != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let url = try XCTUnwrap(result?.get())
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(max(size.width, size.height), 1920, "\(variant) must restore the video preset")
            XCTAssertEqual(min(size.width, size.height), 1080)
            try? FileManager.default.removeItem(at: url)
            result = nil
            try await snapshotControls(name: "VideoControls-Stopped-" + variant)
            let returningAt = CACurrentMediaTime()
            model.requestCaptureKind(.photo)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let finished = CACurrentMediaTime()
            for _ in 0..<300 { if camera.previewFrameTimeForTesting > finished { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting, finished)
            XCTAssertEqual(model.mode, variant == "manual" ? .manual : .auto)
            if variant == "manual" {
                XCTAssertTrue(model.manualExposure)
                XCTAssertEqual(model.iso, 200, accuracy: 1)
                XCTAssertEqual(model.shutter, log2(0.5), accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(camera.shutterRange.upperBound, log2(0.5) - 0.001,
                    "Photo shutter range must return beyond the video's 1/fps exposure cap")
                // 先等实际快门和ISO都匹配，不能仅因视频端恰好也为ISO200就接受旧曝光读数。
                for _ in 0..<300 {
                    if let readings = camera.readings, abs(readings.iso - 200) < 5,
                       abs(readings.seconds - 0.5) < 0.002 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(try XCTUnwrap(camera.readings).iso, 200, accuracy: 5)
                let exposure = await withCheckedContinuation { c in
                    camera.exposureColorState { c.resume(returning: $0) }
                }
                let actualState = try XCTUnwrap(exposure)
                XCTAssertEqual(actualState.exposureMode, .custom)
                XCTAssertEqual(actualState.focusMode, .locked)
                XCTAssertEqual(Double(actualState.lensPosition), 0.65, accuracy: 0.03)
                XCTAssertEqual(actualState.whiteBalanceMode, .locked)
                XCTAssertTrue(model.manualFocus); XCTAssertTrue(model.manualWB)
                XCTAssertEqual(model.wb,5200); XCTAssertEqual(model.whiteBalanceTint,12)
                let actualSeconds = try XCTUnwrap(camera.readings).seconds
                print("PHOTO-EXPOSURE-RESTORE requested=0.5 actual=\(actualSeconds) activeMaximum=\(exposure?.activeMaximumExposureSeconds ?? .nan) minFrame=\(exposure?.activeMinFrameSeconds ?? .nan) maxFrame=\(exposure?.activeMaxFrameSeconds ?? .nan)")
                XCTAssertEqual(log2(actualSeconds), log2(0.5), accuracy: 0.08,
                    "Restored exposure state: custom=\(String(describing: exposure?.engineCustom)), requested=\(String(describing: exposure?.requestedSeconds)), exposureMode=\(String(describing: exposure?.exposureMode)), previewAssist=\(String(describing: exposure?.previewExposureAssistEnabled)), slowAssist=\(String(describing: exposure?.slowShutterPreviewOptimizationRequested)), activeMaximum=\(String(describing: exposure?.activeMaximumExposureSeconds)), formatMaximum=\(String(describing: exposure?.maximumExposureSeconds)), minFrame=\(String(describing: exposure?.activeMinFrameSeconds)), maxFrame=\(String(describing: exposure?.activeMaxFrameSeconds)), actual=\(actualSeconds)")
            }
            if variant == "live" { XCTAssertTrue(model.livePhotoEnabled); XCTAssertTrue(model.capturesLivePhoto) }
            if variant == "hdr" {
                XCTAssertTrue(model.hdr)
                XCTAssertTrue(model.photoOptions.hdr)
                XCTAssertFalse(camera.hdrPreviewActive, "当前产品 HDR 只作用于成片，取景保持 SDR")
            }
            returnTimes.append(CACurrentMediaTime() - returningAt)
            // 必须实际拍回该种照片，不能仅检查开关文字或预览状态。
            // 首帧早于照片状态恢复完成；按真实快门的启用条件等切换落定。
            for _ in 0..<1000 {
                if model.captureKind == .photo && !model.isPreparingTransition
                    && !model.photoStateRestorePendingForTesting && camera.ready
                    && !camera.highResolutionPhotoConfiguring && !camera.shutterBusy
                    && camera.hasCaptureCapacity(for: model.photoOptions) && model.library.canAcceptNewCapture { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.captureKind, .photo)
            XCTAssertFalse(model.isPreparingTransition)
            XCTAssertFalse(model.photoStateRestorePendingForTesting)
            restoredPhoto = nil
            let captureStarted = CACurrentMediaTime()
            model.takePhoto()
            for _ in 0..<1500 { if restoredPhoto != nil || camera.message != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
            let savedPhoto = try XCTUnwrap(restoredPhoto,camera.message ?? "视频返回后照片未完成")
            captureTimes.append(CACurrentMediaTime() - captureStarted)
            let resource = try XCTUnwrap(savedPhoto.resources.first { !$0.pairedVideo })
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
            let tags = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(tags[kCGImagePropertyExifDictionary as String] as? [String:Any])
            // 系统 HDR/Live 路径可保留传感器 orientation=6；6 与横向像素尺寸配套时显示仍是正确竖向。
            let orientation = (tags[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
            let pixelWidth = (tags[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? -1
            let pixelHeight = (tags[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? -1
            print("PHOTO-ORIENTATION variant=\(variant) orientation=\(String(describing: orientation)) size=\(pixelWidth)x\(pixelHeight)")
            // 横拍像素允许 1/3（设备方向可能是 180° 横拿）；竖拍只允许 1/6。
            let allowedOrientations = pixelWidth >= pixelHeight ? [1, 3] : [1, 6]
            XCTAssertTrue(allowedOrientations.contains(orientation ?? -1), "unexpected orientation \(String(describing: orientation)) size=\(pixelWidth)x\(pixelHeight)")
            if variant == "live" {
                XCTAssertEqual(savedPhoto.resources.count,2)
                XCTAssertEqual(savedPhoto.resources.filter(\.pairedVideo).count,1)
                // 不能仅凭资源数量通过；真实 MOV 必须有可解码视频和 Live 时间标记。
                let movie = try XCTUnwrap(savedPhoto.resources.first(where: \.pairedVideo))
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try movie.data.write(to: temporary)
                let liveAsset = AVURLAsset(url: temporary)
                let liveTracks = try await liveAsset.loadTracks(withMediaType: .video)
                let liveTrack = try XCTUnwrap(liveTracks.first, "Live 动态资源缺少画面轨道")
                let markers = try await liveAsset.loadTracks(withMediaType: .metadata)
                XCTAssertFalse(markers.isEmpty, "Live 时间标记必须保留")
                let reader = try AVAssetReader(asset: liveAsset)
                let frames = AVAssetReaderTrackOutput(track: liveTrack,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(frames)
                XCTAssertTrue(reader.startReading())
                var decodedFrames = 0
                while frames.copyNextSampleBuffer() != nil { decodedFrames += 1 }
                XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
                XCTAssertGreaterThan(decodedFrames, 0)
                print("LIVE-ROUNDTRIP-DECODE frames=\(decodedFrames) bytes=\(movie.data.count)")
            } else { XCTAssertFalse(savedPhoto.resources.contains(where: \.pairedVideo)) }
            if variant == "hdr" {
                HDRImageAssertions.assertHDR(source, "视频返回 HDR 照片")
            }
            if variant == "manual" {
                XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue),0.5,accuracy:0.002)
                XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue),200,accuracy:5)
            }
            let tasks = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning:($0,$1,$2,$3)) } }
            XCTAssertEqual(tasks.0,0); XCTAssertEqual(tasks.1,0); XCTAssertEqual(tasks.2,0); XCTAssertEqual(tasks.3,0)
            XCTAssertEqual(model.library.pendingSaveCount,saves)
            print("VIDEO-RETURN-PHOTO variant=\(variant) resources=\(savedPhoto.resources.count) depth=\(tags[kCGImagePropertyDepth as String] ?? "nil") restoredSeconds=\(returnTimes.last ?? 0) EXIF=\(exif[kCGImagePropertyExifExposureTime as String] ?? "nil") tasks=0")
            print("VIDEO-ROUNDTRIP variant=\(variant) size=\(size) mode=\(model.mode) live=\(model.livePhotoEnabled) hdr=\(camera.hdrPreviewActive)")
        }
        // 请求尚在配置时立即反向，最后状态必须回到照片且继续发布新帧。
        for _ in 0..<10 { model.setCaptureKind(.video); model.setCaptureKind(.photo) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertEqual(model.captureKind,.photo)
        XCTAssertTrue(model.livePhotoEnabled)
        let now = CACurrentMediaTime()
        for _ in 0..<300 { if camera.ready && camera.previewFrameTimeForTesting > now { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertGreaterThan(camera.previewFrameTimeForTesting,now)
        print("VIDEO-RETURN-SUMMARY samples=\(returnTimes.count) times=\(returnTimes) captureTimes=\(captureTimes) rapidRoundTrips=10 actualPhotoFiles=6")
    }

    @MainActor func testRepeatedModeTransitionPreviewLatency() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCaptureKind(.photo)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<400 {
            if camera.ready && camera.previewFrameTimeForTesting > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.photo)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .seconds(1))
        var observations: [String] = []
        for cycle in 0..<3 {
            for kind in [CameraViewModel.CaptureKind.video, .photo] {
                let start = CACurrentMediaTime()
                var lastFrame = camera.previewFrameTimeForTesting
                var maximumGap = 0.0
                model.setCaptureKind(kind)
                let configuredAt = await withCheckedContinuation { c in
                    camera.afterPendingSessionTasks { c.resume(returning: CACurrentMediaTime()) }
                }
                var resumedAt: Double?
                for _ in 0..<200 {
                    let frame = camera.previewFrameTimeForTesting
                    if frame > lastFrame {
                        maximumGap = max(maximumGap, frame-lastFrame)
                        lastFrame = frame
                        if frame >= configuredAt { resumedAt = frame; break }
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertNotNil(resumedAt, "Preview must resume after switching to \(kind)")
                let observation = "VIDEO-TRANSITION cycle=\(cycle) kind=\(kind) configure=\(configuredAt-start) resumed=\((resumedAt ?? CACurrentMediaTime())-start) gap=\(maximumGap)"
                observations.append(observation)
                print(observation)
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        let evidence = XCTAttachment(string: observations.joined(separator: "\n"))
        evidence.name = "video-photo-transition-latency"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
    #endif

    @MainActor private func snapshotControls(name: String) async throws {
        // Device publishes precede SwiftUI's next render. Capture the settled
        // 0.22-second transition rather than the previous control state.
        try await Task.sleep(for: .milliseconds(400))
        guard let window = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.windows.first(where: \.isKeyWindow) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func zoomValue(_ route: String) -> Double? {
        guard let range = route.range(of: "zoom=") else { return nil }
        return Double(route[range.upperBound...].prefix { $0 != " " })
    }

    private func formatSignature(_ route: String) -> String? {
        guard let range = route.range(of: "format=") else { return nil }
        return String(route[range.upperBound...].prefix { $0 != " " })
    }
    /// 照片 HDR 进入视频/电影再返回，不能被视频能力表覆盖成 SDR。
    @MainActor func testCinematicRoundTripRestoresHDRSelection() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
            if model.captureKind != .photo { model.setCaptureKind(.photo) }
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        if model.captureKind != .photo { model.setCaptureKind(.photo) }
        model.setMode(.auto)
        if model.currentPosition != .back { model.flipCamera() }
        model.photoFormat = .heif
        model.hdr = true
        for _ in 0..<300 { if camera.supportsHEIFHDR && model.photoFormat == .heif && model.hdr { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.supportsHEIFHDR)
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.photoFormat, .heif)

        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "cinematic-hdr-video")
        model.toggleCinematicVideoMode()
        for _ in 0..<600 { if model.cinematicVideoEnabled && camera.cinematicVideoCaptureActive && model.videoSubmodePreparing == nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.cinematicVideoEnabled)
        XCTAssertTrue(camera.cinematicVideoCaptureActive)

        model.setCaptureKind(.photo)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 {
            if !model.photoStateRestorePendingForTesting && camera.availablePhotoFormats.contains(.heif) && model.hdr { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.supportsHEIFHDR, "返回照片后 HEIF HDR 能力未恢复")
        XCTAssertEqual(model.photoFormat, .heif)
        XCTAssertTrue(model.hdr, "照片 → 视频 → 电影 → 照片后 HDR 选择丢失")
    }

    @MainActor func testTransientVideoRuntimeErrorRetriesInsteadOfExitingPhoto() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "视频重试起点", timeout: 20)
        XCTAssertEqual(model.captureKind, .video)
        let error = NSError(domain: AVFoundationErrorDomain, code: -11819)
        camera.simulateRuntimeStopForTesting(error: error)
        for _ in 0..<500 {
            if camera.ready, !camera.recoveringSession, !camera.videoConfiguring,
               camera.previewFrameTimeForTesting > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.captureKind, .video, camera.message ?? "瞬时错误不应把用户踢回照片")
        XCTAssertTrue(camera.ready)
        XCTAssertFalse(camera.recoveringSession)
        print("VIDEO-RUNTIME-RETRY kind=\(model.captureKind) ready=\(camera.ready) message=\(camera.message ?? "nil")")
    }

    @MainActor func testTwoSeparatedTransientVideoErrorsEachGetRetry() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "两次瞬时错误起点", timeout: 20)
        let error = NSError(domain: AVFoundationErrorDomain, code: -11819)
        for attempt in 0..<2 {
            camera.simulateRuntimeStopForTesting(error: error)
            for _ in 0..<600 {
                if camera.ready, !camera.recoveringSession, !camera.videoConfiguring { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "瞬时错误恢复\(attempt)", timeout: 20)
            XCTAssertEqual(model.captureKind, .video, "第\(attempt + 1)次独立瞬时错误不应退出视频: \(camera.message ?? "nil")")
            XCTAssertNil(camera.message)
        }
        print("VIDEO-RUNTIME-RETRY separatedErrors=2 kind=\(model.captureKind)")
    }

}
