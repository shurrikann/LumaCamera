import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class VideoMacroIndicatorTests: XCTestCase {
    @MainActor func testMacroIndicatorReplacesRemovedPortraitDepthControl() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let camera = model.camera
        model.setCaptureKind(.photo)
        model.setMode(.auto)
        model.setPortraitDepthControlsForTesting(enabled: true, sliderVisible: true)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            camera.setVideoRecordingForTesting(false)
            camera.setMacroActiveForTesting(false)
            model.setPortraitDepthControlsForTesting(enabled: false, sliderVisible: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        host.rootView = AnyView(MacroControlsHost(model: model, camera: camera,
            width: window.bounds.width, angle: 0))
        try await Task.sleep(for: .milliseconds(350))
        let modeFrame = try XCTUnwrap(model.captureButtonFramesForTesting["mode"])
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepth"],
                     "景深入口已移到顶部工具栏，A/M 上方不应再有景深按钮")
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepthPanel"],
                     "A/M 上方不应再有竖向景深滑块")

        camera.setVideoRecordingForTesting(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(model.captureButtonFramesForTesting["shootingModeToggle"],
                        "照片模式下的 A/M 按钮不能被视频录像状态隐藏")
        camera.setVideoRecordingForTesting(false)

        camera.setMacroActiveForTesting(true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(model.portraitDepthSliderVisible,
                       "进入系统微距后应关闭景深滑块，避免隐藏状态仍运行预览处理")
        let macroFrame = try XCTUnwrap(model.captureButtonFramesForTesting["macro"])
        XCTAssertLessThan(macroFrame.maxY, modeFrame.minY,
                          "微距标识应独立位于 A/M 按钮上方，不覆盖档位切换")
        XCTAssertNotNil(model.captureButtonFramesForTesting["shootingModeToggle"],
                        "微距标识不能覆盖或替代 A/M 切换按钮")
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepth"])
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepthPanel"])

        model.captureButtonFramesForTesting.removeValue(forKey: "macro")
        camera.setMacroActiveForTesting(false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepth"],
                     "退出微距后也不恢复旧景深按钮")
        XCTAssertNil(model.captureButtonFramesForTesting["portraitDepthPanel"])
    }

    /// Render synthetic recording state without starting or reconfiguring a camera.
    @MainActor func testRecordingControlsKeepPositionsAcrossRatiosAndRotation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let camera = model.camera
        model.setCaptureKind(.video)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            camera.setVideoRecordingForTesting(false)
            camera.setMacroActiveForTesting(false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func show(angle: Double) {
            host.rootView = AnyView(MacroControlsHost(model: model, camera: camera,
                width: window.bounds.width, angle: angle))
        }
        show(angle: 0)
        try await Task.sleep(for: .milliseconds(350))
        let baseline = try XCTUnwrap(model.captureButtonFramesForTesting["mode"])
        let toolsFrame = try XCTUnwrap(model.captureButtonFramesForTesting["tools"])
        let shootingModeFrame = try XCTUnwrap(model.captureButtonFramesForTesting["shootingMode"])
        let shootingModeGap = toolsFrame.minY - (shootingModeFrame.maxY + CameraControlLayout.upperButtonOffset(diameter: shootingModeFrame.height))
        XCTAssertEqual(shootingModeGap, CameraControlLayout.upperButtonGap, accuracy: 0.5,
                       "Shooting-mode button gap should match the macro-indicator gap")
        var drawTimes: [Double] = []
        for ratio in VideoRatio.allCases {
            model.videoRatio = ratio
            for angle in [0.0, 90.0] {
                show(angle: angle)
                for recording in [false, true] {
                    camera.setVideoRecordingForTesting(recording)
                    try await Task.sleep(for: .milliseconds(350))
                    let frame = try XCTUnwrap(model.captureButtonFramesForTesting["mode"])
                    if recording {
                        XCTAssertNil(model.captureButtonFramesForTesting["shootingModeToggle"],
                                     "视频录制中仍隐藏 A/M 切换")
                    } else {
                        XCTAssertNotNil(model.captureButtonFramesForTesting["shootingModeToggle"],
                                        "停止录制后恢复 A/M 切换")
                    }
                    let currentToolsFrame = try XCTUnwrap(model.captureButtonFramesForTesting["tools"])
                    let currentShootingModeFrame = try XCTUnwrap(model.captureButtonFramesForTesting["shootingMode"])
                    XCTAssertEqual(frame.minX, baseline.minX, accuracy: 0.5)
                    XCTAssertEqual(frame.minY, baseline.minY, accuracy: 0.5)
                    let shootingModeGap = currentToolsFrame.minY - (currentShootingModeFrame.maxY + CameraControlLayout.upperButtonOffset(diameter: currentShootingModeFrame.height))
                    XCTAssertEqual(shootingModeGap, CameraControlLayout.upperButtonGap, accuracy: 0.5,
                                   "Shooting-mode button spacing must remain constant")
                    let began = CACurrentMediaTime()
                    let image = capture(window)
                    drawTimes.append(CACurrentMediaTime() - began)
                    if ratio == .ratio16x9 && recording {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "Video-Recording-Controls-\(Int(angle))"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
        for index in 0..<40 {
            camera.setMacroActiveForTesting(index.isMultiple(of: 2))
            camera.setVideoRecordingForTesting(index.isMultiple(of: 3))
            try await Task.sleep(for: .milliseconds(10))
        }
        camera.setVideoRecordingForTesting(false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotNil(model.captureButtonFramesForTesting["shootingModeToggle"],
                        "视频停止且 A 模式时应恢复 A/M 按钮")
        let mean = drawTimes.reduce(0, +) / Double(drawTimes.count)
        let evidence = XCTAttachment(string: "layouts=\(drawTimes.count) rapidChanges=40 snapshotDrawMean=\(mean) snapshotDrawMax=\(drawTimes.max() ?? 0); UIKit snapshot cost, not screen FPS or camera processing time")
        evidence.name = "video-recording-controls-render-metrics"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor private func capture(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func goldPixels(_ image: UIImage, rect: CGRect) -> Int {
        guard let source = image.cgImage else { return 0 }
        let cropRect = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                              width: rect.width * image.scale, height: rect.height * image.scale).integral
        guard let crop = source.cropping(to: cropRect) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, i in
            count + (bytes[i] > 150 && bytes[i + 1] > 100 && bytes[i + 2] < 190 ? 1 : 0)
        }
    }
}

private struct MacroControlsHost: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject var camera: CameraEngine
    let width: CGFloat
    let angle: Double

    var body: some View {
        CameraView(model: model).fixedCameraControls(width: width)
            // 该视图只验证合成布局，注入后台场景避免测试启动真机相机会话。
            .environment(\.scenePhase, .background)
            .environment(\.captureControlAngle, angle).preferredColorScheme(.dark)
            .background(Color.black).ignoresSafeArea()
    }
}

