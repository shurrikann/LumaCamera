import XCTest
import SwiftUI
import AVFoundation
import CoreImage
@testable import LumaCamera

private struct VideoApertureHost: View {
    @ObservedObject var model: CameraViewModel
    let angle: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                CameraView(model: model).viewfinderContent(controlAngle: angle)
                CameraView(model: model).fixedCameraControls(width: geo.size.width)
                if model.shootingModes { CameraView(model: model).shootingModesPanel.padding(.bottom, 18) }
            }
        }.environment(\.captureControlAngle, angle).preferredColorScheme(.dark)
    }
}

final class VideoVirtualAperturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testVideoEntryLayoutRecordingAndRecovery() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        model.preferences.focusAssist = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: VideoApertureHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        var files: [URL] = [], result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.setFilterParameterEditing(false); model.setCameraActive(false)
            window.isHidden = true; window.rootViewController = nil; old?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle; files.forEach { try? FileManager.default.removeItem(at: $0) }; audit.finish()
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        func screenshot(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let a = XCTAttachment(image: image); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        model.setCameraActive(true); try await wait("相机") { camera.ready }
        model.setCaptureKind(.video)
        try await wait("视频") { camera.ready && !camera.videoConfiguring }
        model.flipCamera()
        try await wait("前置进入") { camera.ready && !camera.videoConfiguring && model.currentPosition == .front }
        model.toggleVirtualAperture()
        try await wait("星芒自动选择主摄") { camera.ready && !camera.videoConfiguring && model.currentPosition == .back }
        // ready和镜头ID先发布，主线程再按新位置提交look；等真正应用，不能读取切镜中间快照。
        let lookWaitStart = CACurrentMediaTime()
        var appliedLook = CaptureLook()
        while CACurrentMediaTime() - lookWaitStart < 5 {
            appliedLook = await withCheckedContinuation { c in camera.captureLookForTesting { c.resume(returning: $0) } }
            if appliedLook.virtualAperture == 5.6 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(appliedLook.virtualAperture, 5.6)
        print("VIDEO-APERTURE-APPLIED-LOOK wait=\(CACurrentMediaTime()-lookWaitStart)")
        try await wait("星芒启用") { model.virtualApertureEnabled && camera.ready && !camera.videoConfiguring }
        XCTAssertEqual(model.effectiveCaptureLook.virtualAperture, 5.6)
        XCTAssertEqual(model.shootingModeButtonSymbol, "camera.aperture")
        XCTAssertFalse(model.supportsVideoColorSpace(.hdr)); XCTAssertFalse(model.supportsVideoColorSpace(.appleLog))
        XCTAssertFalse(model.canSelectProRes(.raw)); XCTAssertFalse(model.canSelectProRes(.rawHQ))
        XCTAssertEqual(ShootingModePanelLayout.panelHeight(for: 4), 158)
        model.shootingModes = true; try await Task.sleep(for: .milliseconds(300)); screenshot("Video-aperture-menu-four-options")
        model.shootingModes = false
        for ratio in VideoRatio.aspectOptions {
            model.selectVideoRatio(ratio)
            try await wait("比例") { camera.ready && !camera.videoConfiguring }
            for angle in [0.0,90.0,-90.0,180.0] {
                host.rootView = VideoApertureHost(model: model, angle: angle)
                try await Task.sleep(for: .milliseconds(150))
                try await wait("滑块布局位置") {
                    model.captureButtonFramesForTesting["videoVirtualApertureButton"] != nil
                        && model.captureButtonFramesForTesting["focalBarBackground"] != nil
                }
                let button = try XCTUnwrap(model.captureButtonFramesForTesting["videoVirtualApertureButton"])
                let focal = try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
                XCTAssertGreaterThan(button.width, 0); XCTAssertGreaterThan(button.height, 0)
                XCTAssertGreaterThan(focal.width, 0); XCTAssertGreaterThan(focal.height, 0)
                XCTAssertTrue(window.bounds.contains(button), "\(ratio) angle=\(angle) aperture button outside window: \(button)")
            }
        }
        host.rootView = VideoApertureHost(model: model, angle: 0)
        model.selectVideoRatio(.ratio16x9)
        try await wait("预览") { camera.ready && !camera.videoConfiguring }
        let firstFrame = camera.previewPublicationTimesForTestingSnapshot.last ?? 0
        try await wait("实际新帧") { (camera.previewPublicationTimesForTestingSnapshot.last ?? 0) > firstFrame }
        for pass in 0..<3 {
            model.setFilterParameterEditing(true); camera.resetPreviewPublicationTimesForTesting()
            let began = CACurrentMediaTime()
            for n in 0..<60 { model.virtualAperturePosition = Double(n)/59; try await Task.sleep(for: .milliseconds(16)) }
            model.setFilterParameterEditing(false)
            let end = CACurrentMediaTime(), stamps = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= began }
            let gaps = zip([began]+stamps, stamps+[end]).map { $1-$0 }
            XCTAssertGreaterThan(stamps.count, 8); XCTAssertLessThan(gaps.max() ?? 99, 0.6)
            print("VIDEO-APERTURE-DRAG pass=\(pass) frames=\(stamps.count) wall=\(end-began) maxGap=\(gaps.max() ?? 0)")
        }
        let combinations: [(VideoResolution, VideoFrameRate, VideoColorSpace, VideoCodec)] = [
            (.hd720,.fps30,.sdr,.hevc),(.hd1080,.fps30,.p3,.h264),(.uhd4K,.fps30,.sdr,.hevc),(.hd1080,.fps30,.sdr,.proRes)
        ]
        for (index,c) in combinations.enumerated() {
            model.setMode(index.isMultiple(of: 2) ? .auto : .manual)
            model.videoCodec = c.3; model.videoColorSpace = c.2; model.videoResolution = c.0; model.videoFrameRate = c.1
            try await wait("录制规格") { camera.ready && !camera.videoConfiguring && !camera.videoBusy && camera.videoSettings.resolution == c.0 && camera.videoSettings.frameRate == c.1 && camera.videoSettings.colorSpace == c.2 && camera.videoSettings.codec == c.3 }
            model.virtualAperture = 16; result = nil
            let began = CACurrentMediaTime(); model.toggleVideoRecording()
            try await wait("首录制帧") { camera.videoRecording || result != nil }
            XCTAssertTrue(camera.videoRecording, camera.message ?? "")
            if index == 0 { try await Task.sleep(for: .milliseconds(400)); screenshot("Video-aperture-recording-hidden-controls") }
            try await Task.sleep(for: .milliseconds(1200))
            model.toggleVideoRecording(); try await wait("录制完成") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result?.get()); files.append(url)
            let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first), duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0.6)
            let metadata = try await asset.load(.metadata)
            let description = metadata.first { $0.commonKey == .commonKeyDescription }
            let text = try await description?.load(.stringValue)
            XCTAssertTrue(text?.contains("虚拟光圈") == true)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0; while output.copyNextSampleBuffer() != nil { frames += 1 }
            XCTAssertGreaterThan(frames, 10); XCTAssertEqual(reader.status, .completed)
            XCTAssertTrue(model.virtualApertureEnabled)
            print("VIDEO-APERTURE-REAL index=\(index) requested=\(c) size=\(try await track.load(.naturalSize)) duration=\(duration.seconds) decoded=\(frames) wall=\(CACurrentMediaTime()-began) writer=\(String(describing:camera.lastRecordingFrameCountsForTesting))")
        }
        try await Task.sleep(for: .milliseconds(400))
        screenshot("Video-aperture-stopped-restores-slider")
        // 用户点击别的子模块时互斥，退出后重新开启；快速开关/返回路径仍能恢复普通预览。
        model.toggleTimeLapseMode()
        try await wait("延时互斥") { model.timeLapseEnabled && !model.virtualApertureEnabled && !camera.videoConfiguring }
        model.toggleVirtualAperture()
        try await wait("恢复星芒") { model.virtualApertureEnabled && !model.timeLapseEnabled && !camera.videoConfiguring }
        for _ in 0..<3 { model.toggleVirtualAperture(); model.toggleVirtualAperture(); XCTAssertTrue(model.virtualApertureEnabled) }
        model.videoColorSpace = .hdr
        try await wait("直接参数保护") { model.videoColorSpace == .sdr && !camera.videoConfiguring }
        model.setCaptureKind(.photo)
        try await wait("照片恢复") { camera.ready && !camera.videoConfiguring }
        XCTAssertFalse(model.virtualApertureEnabled)
        model.toggleVirtualAperture(); XCTAssertTrue(model.virtualApertureEnabled)
        model.setCaptureKind(.video)
        try await wait("视频返回") { camera.ready && !camera.videoConfiguring }
        XCTAssertFalse(model.virtualApertureEnabled)
    }
    #endif
}
