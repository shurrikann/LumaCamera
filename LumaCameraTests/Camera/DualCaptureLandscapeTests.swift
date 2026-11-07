import XCTest
import AVFoundation
import UIKit
import SwiftUI
@testable import LumaCamera

private struct DualLandscapeHost: View {
    @ObservedObject var model: CameraViewModel
    var angle: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(model: model).viewfinderContent(controlAngle: angle)
                CameraView(model: model).fixedCameraControls(width: geometry.size.width)
            }
        }.environment(\.captureControlAngle, angle)
            .preferredColorScheme(.dark)
    }
}

final class DualCaptureLandscapeTests: XCTestCase {
    func testLandscapeGeometryAndDragAcrossAllRatios() {
        for ratio in VideoRatio.aspectOptions {
            let landscape = DualCaptureInsetLayout.resized(DualCaptureInsetLayout.initial, landscape: true, ratio: ratio.frameRatio.portraitRatio)
            XCTAssertEqual(landscape.width * ratio.frameRatio.portraitRatio / landscape.height, 16.0 / 9, accuracy: 0.00001)
            for turns in 0..<4 {
                let moved = DualCaptureInsetLayout.translated(landscape, displayTranslation: CGSize(width: -0.02, height: 0.02), ratio: ratio.frameRatio.portraitRatio, turns: turns)
                XCTAssertEqual(moved.size, landscape.size)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(moved))
            }
            let portrait = DualCaptureInsetLayout.resized(landscape, landscape: false, ratio: ratio.frameRatio.portraitRatio)
            XCTAssertEqual(portrait.size, DualCaptureInsetLayout.initial.size)
        }
    }

    func testRepeatedResizeKeepsDockedEdges() {
        for ratio in VideoRatio.aspectOptions {
            for x in [0.01, 0.35, 0.71] { for y in [0.01, 0.4, 0.71] {
                var rect = CGRect(x: x, y: y, width: 0.28, height: 0.28)
                for _ in 0..<100 {
                    rect = DualCaptureInsetLayout.resized(rect, landscape: true, ratio: ratio.frameRatio.portraitRatio)
                    if x == 0.01 { XCTAssertEqual(rect.minX, 0.01, accuracy: 0.000001) }
                    if x == 0.71 { XCTAssertEqual(rect.maxX, 0.99, accuracy: 0.000001) }
                    if y == 0.01 { XCTAssertEqual(rect.minY, 0.01, accuracy: 0.000001) }
                    if y == 0.71 { XCTAssertEqual(rect.maxY, 0.99, accuracy: 0.000001) }
                    rect = DualCaptureInsetLayout.resized(rect, landscape: false, ratio: ratio.frameRatio.portraitRatio)
                    XCTAssertEqual(rect.minX, x, accuracy: 0.000001)
                    XCTAssertEqual(rect.minY, y, accuracy: 0.000001)
                }
            } }
        }
    }

    func testObstacleProjectionAcrossRatiosAndWindowShapes() {
        let obstacles = [CGRect(x: 0, y: 0.78, width: 1, height: 0.22), CGRect(x: 0.8, y: 0.62, width: 0.2, height: 0.16), CGRect(x: 0, y: 0, width: 1, height: 0.08)]
        for ratio in VideoRatio.aspectOptions { for landscape in [false, true] {
            let shape = DualCaptureInsetLayout.resized(DualCaptureInsetLayout.initial, landscape: landscape, ratio: ratio.frameRatio.portraitRatio)
            for x in stride(from: 0.0, through: 1.0, by: 0.05) { for y in stride(from: 0.0, through: 1.0, by: 0.05) {
                let target = CGRect(origin: CGPoint(x: x, y: y), size: shape.size)
                let safe = DualCaptureInsetLayout.avoiding(target, ratio: ratio.frameRatio.portraitRatio, turns: 0, obstacles: obstacles)
                XCTAssertEqual(safe.size, shape.size)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(safe))
                for obstacle in obstacles { XCTAssertFalse(safe.insetBy(dx: 0.000001, dy: 0.000001).intersects(obstacle)) }
            } }
        } }
    }

    #if !targetEnvironment(simulator)
    @MainActor func testActualWideRestoreRapidSwitchRecordingAndRatioChanges() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onVideoRecorded
        let originalHistogram = model.showHistogram, originalCapacity = model.showsRecordingCapacity, originalAudio = model.showsAudioMeter
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let controller = UIHostingController(rootView: DualLandscapeHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { model.showHistogram = originalHistogram; model.showsRecordingCapacity = originalCapacity; model.showsAudioMeter = originalAudio; window.isHidden = true; window.rootViewController = nil; original?.makeKey(); camera.onVideoRecorded = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 18
            while CACurrentMediaTime() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        func state() async -> [String: String] {
            await withCheckedContinuation { continuation in camera.dualCaptureStateForTesting { continuation.resume(returning: $0) } }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        let front = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        _ = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
        model.selectFocalLength(front); try await wait("前置") { camera.ready && model.currentPosition == .front }
        model.toggleDualCapture(frontWide: false); try await wait("双拍") { camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        model.showHistogram = true; model.showsRecordingCapacity = true; model.showsAudioMeter = true
        model.refreshRecordingCapacity()
        try await wait("辅助显示几何") { model.captureButtonFramesForTesting["histogram"] != nil && model.captureButtonFramesForTesting["videoHUD"] != nil }
        var samples: [Double] = []
        for ratio in VideoRatio.aspectOptions {
            model.selectVideoRatio(ratio); try await wait("主画幅") { camera.ready && !camera.videoConfiguring }
            for priorWide in [false, true] {
                // 双拍主画面为后置时，前置广角/标准是 inset 属性，不是主焦段按钮。
                camera.setDualCaptureFrontWide(priorWide)
                try await wait("设置进入前画幅") { camera.dualCaptureFrontWide == priorWide }
                let began = CACurrentMediaTime()
                model.toggleDualCaptureInsetAspect()
                // 快速重复点击不能反转未完成的硬件切换。
                for _ in 0..<10 { model.toggleDualCaptureInsetAspect() }
                try await wait("横幅") { !model.dualInsetAspectChanging && camera.dualCaptureInsetLandscape && camera.dualCaptureFrontWide }
                let firstFrame = camera.previewFrameTimeForTesting
                try await wait("横幅新帧") { camera.previewFrameTimeForTesting > firstFrame }
                samples.append(CACurrentMediaTime() - began)
                let actual = await state()
                XCTAssertEqual(Double(actual["frontZoom"] ?? "") ?? -1, 1, accuracy: 0.001)
                let inset = camera.dualCaptureInsetRect
                XCTAssertEqual(inset.width * ratio.frameRatio.portraitRatio / inset.height, 16.0 / 9, accuracy: 0.0001)
                var moveDurations: [Double] = []
                for x in [-1.0, -0.5, 0, 0.5, 1] { for y in [-1.0, -0.5, 0, 0.5, 1] {
                    let begin = CACurrentMediaTime()
                    model.moveDualCaptureInset(from: inset, translation: CGSize(width: x, height: y))
                    moveDurations.append(CACurrentMediaTime() - begin)
                    let display = DualCaptureInsetLayout.displayRect(camera.dualCaptureInsetRect, ratio: ratio.frameRatio.portraitRatio, turns: 0)
                    let preview = model.previewFrameForTesting
                    let frame = CGRect(x: preview.minX + display.minX * preview.width, y: preview.minY + display.minY * preview.height,
                        width: display.width * preview.width, height: display.height * preview.height)
                    for key in ["mode", "tools", "lenses", "shootingMode", "histogram", "videoHUD"] {
                        if let obstacle = model.captureButtonFramesForTesting[key] {
                            XCTAssertFalse(frame.intersects(obstacle.insetBy(dx: -5, dy: -5)), "拖动遮挡\(key)")
                            if key == "tools" {
                                let visual = obstacle.offsetBy(dx: 0, dy: CameraControlLayout.upperButtonOffset(diameter: obstacle.height))
                                XCTAssertFalse(frame.intersects(visual.insetBy(dx: -5, dy: -5)), "拖动遮挡子模块视觉按钮")
                            }
                        }
                    }
                } }
                print("DUAL-AVOID-MOVES ratio=\(ratio.rawValue) samples=\(moveDurations)")
                model.toggleDualCaptureInsetAspect(); try await wait("恢复原画幅") { !model.dualInsetAspectChanging && !camera.dualCaptureInsetLandscape && camera.dualCaptureFrontWide == priorWide }
                let restored = await state()
                XCTAssertEqual(Double(restored["frontZoom"] ?? "") ?? -1, priorWide ? 1 : 1.6, accuracy: 0.002)
                XCTAssertEqual(camera.dualCaptureInsetRect.size, DualCaptureInsetLayout.initial.size)
            }
        }
        // 横幅时改变主画幅，必须重算归一化高度；交换后保留小窗形状和位置。
        model.toggleDualCaptureInsetAspect(); try await wait("横幅再次开启") { !model.dualInsetAspectChanging && camera.dualCaptureInsetLandscape }
        for ratio in VideoRatio.aspectOptions {
            model.selectVideoRatio(ratio); try await wait("横幅中改主比例") { !camera.videoConfiguring && camera.ready }
            XCTAssertEqual(camera.dualCaptureInsetRect.width * ratio.frameRatio.portraitRatio / camera.dualCaptureInsetRect.height, 16.0 / 9, accuracy: 0.0001)
            model.swapDualCaptureCameras(); model.swapDualCaptureCameras()
        }
        model.showHistogram = false; model.showsRecordingCapacity = false; model.showsAudioMeter = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.captureButtonFramesForTesting["histogram"])
        XCTAssertNil(model.captureButtonFramesForTesting["videoHUD"])
        // 真实前置倍率往返中，左右贴边不应随窗口变窄产生中心锚点漂移。
        for right in [false, true] {
            let shape = camera.dualCaptureInsetRect.size
            camera.setDualCaptureInsetRect(CGRect(x: right ? 0.99 - shape.width : 0.01, y: 0.35, width: shape.width, height: shape.height))
            for _ in 0..<6 {
                model.toggleDualCaptureInsetAspect()
                try await wait("贴边切画幅") { !model.dualInsetAspectChanging }
                let actual = right ? camera.dualCaptureInsetRect.maxX : camera.dualCaptureInsetRect.minX
                XCTAssertEqual(actual, right ? 0.99 : 0.01, accuracy: 0.00001)
            }
        }
        model.moveDualCaptureInset(from: camera.dualCaptureInsetRect, translation: CGSize(width: 1, height: -1))
        model.showHistogram = true; model.showsRecordingCapacity = true; model.showsAudioMeter = true
        model.refreshRecordingCapacity()
        try await Task.sleep(for: .milliseconds(350))
        let preview = model.previewFrameForTesting
        let rect = camera.dualCaptureInsetRect
        let projected = CGRect(x: preview.minX + rect.minX * preview.width, y: preview.minY + rect.minY * preview.height,
            width: rect.width * preview.width, height: rect.height * preview.height)
        for key in ["histogram", "videoHUD"] {
            XCTAssertFalse(projected.intersects(try XCTUnwrap(model.captureButtonFramesForTesting[key]).insetBy(dx: -5, dy: -5)))
        }
        model.toggleDualCapture(); try await wait("退出") { !camera.dualCaptureEnabled && camera.ready }
        print("DUAL-LANDSCAPE-PERF samples=\(samples)")
    }
    #endif
}
