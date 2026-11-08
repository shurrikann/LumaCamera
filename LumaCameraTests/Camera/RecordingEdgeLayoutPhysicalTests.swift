import XCTest
import SwiftUI
import UIKit
import AVFoundation
@testable import LumaCamera

private struct RecordingEdgeTestHost: View {
    @ObservedObject var model: CameraViewModel
    var angle: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(model: model).viewfinderContent(controlAngle: angle)
                CameraView(model: model).fixedCameraControls(width: geometry.size.width)
            }
        }
        .environment(\.captureControlAngle, angle)
        .preferredColorScheme(.dark)
    }
}

/// 真机只挂载当前引擎，不创建第二个相机；矩阵的recording标志用于布局，另有真实录像核对。
final class RecordingEdgeLayoutPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testFrontButtonGroupsStayCenteredAndRecordingPanelsUsePreviewEdges() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, preferences = model.preferences
        let histogram = model.showHistogram, capacity = model.showsRecordingCapacity, audio = model.showsAudioMeter
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let controller = UIHostingController(rootView: RecordingEdgeTestHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            camera.setVideoRecordingForTesting(false)
            model.showHistogram = histogram; model.showsRecordingCapacity = capacity; model.showsAudioMeter = audio
            model.preferences = preferences; model.setCameraActive(false)
            window.isHidden = true; window.rootViewController = nil; original?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 12
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label); throw CancellationError()
        }
        func attach(_ name: String) {
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let a = XCTAttachment(image: shot); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        let front = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        model.selectFocalLength(front); try await wait("前置") { camera.ready && model.currentPosition == .front }
        let began = CACurrentMediaTime()
        var samples = 0
        for kind in [CameraViewModel.CaptureKind.photo, .video] {
            model.setCaptureKind(kind); try await wait("媒体切换") { camera.ready && !camera.videoConfiguring }
            for mode in [CameraShootingMode.auto, .manual] {
                model.setMode(mode)
            for angle in [0.0, 90.0, -90.0, 180.0] {
                controller.rootView = RecordingEdgeTestHost(model: model, angle: angle)
                try await Task.sleep(for: .milliseconds(300))
                let key = kind == .photo ? "frontPhotoWide" : "frontVideoWide"
                // 固定栏的视频第二个控件是人物居中；同步双拍入口在视频子模块，不在固定栏。
                let companion = kind == .photo ? "frontPhotoAspectRatio" : "frontVideoCentering"
                let a = try XCTUnwrap(model.captureButtonFramesForTesting[key], key)
                let b = try XCTUnwrap(model.captureButtonFramesForTesting[companion], companion)
                let group = a.union(b)
                XCTAssertEqual(group.midX, window.bounds.midX, accuracy: 1.5, "前置按钮组必须整体居中")
                XCTAssertEqual(a.midY, b.midY, accuracy: 1)
                XCTAssertFalse(a.intersects(b))
                samples += 1
                if angle == 0 || angle == 90 { attach("Front-centered-\(kind)-\(angle)") }
            }
            }
        }
        model.setMode(.auto)
        model.showHistogram = true; model.showsRecordingCapacity = true; model.showsAudioMeter = true
        model.refreshRecordingCapacity()
        var recordingSamples = 0
        for ratio in VideoRatio.aspectOptions {
            model.videoRatio = ratio
            for angle in [0.0, 90.0, -90.0, 180.0] {
                controller.rootView = RecordingEdgeTestHost(model: model, angle: angle)
                camera.setVideoRecordingForTesting(false)
                try await Task.sleep(for: .milliseconds(300))
                let oldHistogram = model.histogramFrameForTesting
                camera.setVideoRecordingForTesting(true)
                try await Task.sleep(for: .milliseconds(350))
                let preview = model.previewFrameForTesting, h = model.histogramFrameForTesting, c = model.recordingHUDFrameForTesting
                let timer = try XCTUnwrap(model.captureButtonFramesForTesting["recordingTimer"])
                let top = preview.minY + (preview.width < 300 ? 34 : 5)
                XCTAssertEqual(h.minY, top, accuracy: 1.5, "直方图贴近预览边缘")
                XCTAssertEqual(c.minY, top, accuracy: 1.5, "容量贴近预览边缘")
                XCTAssertEqual(timer.minY, preview.minY + 5, accuracy: 1.5, "计时不再避让隐藏工具栏")
                XCTAssertTrue(preview.insetBy(dx: -1, dy: -1).contains(h))
                XCTAssertTrue(preview.insetBy(dx: -1, dy: -1).contains(c))
                XCTAssertTrue(preview.insetBy(dx: -1, dy: -1).contains(timer))
                XCTAssertFalse(timer.intersects(h)); XCTAssertFalse(timer.intersects(c)); XCTAssertFalse(h.intersects(c))
                if (ratio == .ratio16x9 || ratio == .cinema), angle == 0 || angle == 90 { attach("Recording-edge-\(ratio.rawValue)-\(angle)") }
                camera.setVideoRecordingForTesting(false)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(model.histogramFrameForTesting.minY, oldHistogram.minY, accuracy: 1.5)
                recordingSamples += 1
            }
        }
        print("RECORDING-EDGE groupSamples=\(samples) recordingLayouts=\(recordingSamples) elapsedWithWaits=\(CACurrentMediaTime()-began) not-FPS")
    }
    @MainActor func testRealRecordingUsesEdgePositionsAndStopsCleanly() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled, preferences = model.preferences
        let histogram = model.showHistogram, capacity = model.showsRecordingCapacity
        let audit = SessionRuntimeErrorAudit()
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onVideoRecorded = callback; camera.stopVideoRecording()
            model.showHistogram = histogram; model.showsRecordingCapacity = capacity; model.preferences = preferences
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 15
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); model.videoRatio = .ratio16x9
        model.showHistogram = true; model.showsRecordingCapacity = true; model.refreshRecordingCapacity()
        try await wait("录像准备") { camera.ready && !camera.videoConfiguring }
        camera.startVideoRecording(aspect: .wide)
        try await wait("实际录像开始") { camera.videoRecording }
        try await Task.sleep(for: .milliseconds(700))
        let preview = model.previewFrameForTesting
        let timer = try XCTUnwrap(model.captureButtonFramesForTesting["recordingTimer"])
        XCTAssertEqual(timer.minY, preview.minY + 5, accuracy: 1.5)
        XCTAssertEqual(model.histogramFrameForTesting.minY, preview.minY + 5, accuracy: 1.5)
        XCTAssertEqual(model.recordingHUDFrameForTesting.minY, preview.minY + 5, accuracy: 1.5)
        camera.stopVideoRecording(); try await wait("结束") { result != nil && !camera.videoBusy }
        let url = try XCTUnwrap(result).get()
        let asset = AVURLAsset(url: url), duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.4)
        XCTAssertFalse(camera.videoRecording)
        print("RECORDING-EDGE realDuration=\(duration.seconds) preview=\(preview) timer=\(timer)")
    }
    #endif
}
