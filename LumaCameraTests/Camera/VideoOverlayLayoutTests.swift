import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class VideoOverlayLayoutTests: XCTestCase {
    @MainActor func testToolbarPanelsKeepSameWidthAndFixedButtons() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        // 单规格能力确保分辨率和帧率各只显示一个按钮。
        model.camera.installVideoCapabilitiesForTesting(ordinary: [VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)], cinematic: [])
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = .sdr
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let panels: [CameraToolbarPanel] = [.format, .ratio, .tone, .videoFormat, .videoRatio, .videoColor, .videoCodec, .slowShutterDuration]
        let started = CACurrentMediaTime()
        var samples = 0
        for width in [CGFloat(304), window.bounds.width - 16] {
            for panel in panels {
                model.toolbarPanel = panel
                host.rootView = AnyView(VStack {
                    CameraView(model: model).toolbarOptionsPanel(availableWidth: width)
                    Spacer()
                }.preferredColorScheme(.dark))
                try await Task.sleep(for: .milliseconds(80))
                let frame = try XCTUnwrap(model.captureButtonFramesForTesting["videoOptionsPanel"])
                XCTAssertEqual(frame.width, width, accuracy: 0.5, "\(panel)")
                if panel == .videoFormat {
                    XCTAssertEqual(model.videoResolutionOptions.count, 1)
                    XCTAssertEqual(model.videoFrameRateOptions.count, 1)
                    for resolution in model.videoResolutionOptions {
                        let button = try XCTUnwrap(model.captureButtonFramesForTesting["videoResolution.\(resolution.rawValue)"])
                        XCTAssertEqual(button.width, 70, accuracy: 0.5)
                        XCTAssertEqual(button.minX, frame.minX + 16, accuracy: 0.5)
                    }
                    let rate = try XCTUnwrap(model.captureButtonFramesForTesting["videoRate.30"])
                    XCTAssertEqual(rate.minX, frame.minX + 16, accuracy: 0.5)
                    XCTAssertEqual(rate.width, (width - 32 - 40) / 6, accuracy: 0.5)
                }
                samples += 1
            }
        }
        for index in 0..<40 { model.toggleToolbarPanel(panels[index % panels.count]) }
        model.closePopups()
        XCTAssertNil(model.toolbarPanel)
        print("TOOLBAR-PANEL-WIDTH layouts=\(samples) switches=40 elapsed=\(CACurrentMediaTime()-started) includesWaits=true")
    }

    @MainActor func testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCaptureKind(.video)
        model.showsRecordingCapacity = true
        model.showsAudioMeter = true
        model.refreshRecordingCapacity()
        model.showHistogram = true
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        let began = CACurrentMediaTime()
        let visibleRatios = VideoRatio.aspectOptions
        for ratio in visibleRatios {
            model.videoRatio = ratio
            for angle in [0.0, 90, -90, 180] {
                host.rootView = AnyView(CameraViewfinderTestHost(model: model, camera: model.camera).environment(\.captureControlAngle, angle).ignoresSafeArea())
                try await Task.sleep(for: .milliseconds(300))
                let preview = model.previewFrameForTesting.insetBy(dx: -1, dy: -1)
                let hud = model.recordingHUDFrameForTesting
                let histogram = model.histogramFrameForTesting
                XCTAssertGreaterThan(hud.width, 0)
                XCTAssertTrue(preview.contains(hud), "HUD outside preview: \(ratio) angle=\(angle) \(hud) / \(preview)")
                XCTAssertTrue(preview.contains(histogram), "Histogram outside preview")
                XCTAssertFalse(hud.intersects(histogram), "HUD overlaps histogram")
                if ratio == .ratio16x9 && (angle == 0 || angle == 90) { attach(window, "Video-HUD-\(Int(angle))") }
            }
        }
        print("VIDEO-OVERLAY layouts=\(visibleRatios.count * 4) elapsed=\(CACurrentMediaTime()-began); includes animation waits, not FPS")
        for panel in [CameraToolbarPanel.videoFormat, .videoRatio, .videoColor] {
            model.toolbarPanel = panel
            for width in [CGFloat(320), window.bounds.width] {
                host.rootView = AnyView(VStack {
                    CameraView(model: model).toolbarOptionsPanel(availableWidth: width - 16)
                    Spacer()
                }.environment(\.captureControlAngle, 0).preferredColorScheme(.dark).background(Color.black))
                try await Task.sleep(for: .milliseconds(300))
                let fitted = host.sizeThatFits(in: window.bounds.size)
                XCTAssertLessThanOrEqual(fitted.width, window.bounds.width + 1)
                let panelName: String
                switch panel {
                case .videoFormat: panelName = "Frame-Rates"
                case .videoRatio: panelName = "Ratios-Open-Gate"
                default: panelName = "Color-Space"
                }
                attach(window, "Video-\(panelName)-\(Int(width))")
            }
        }
        // 用设备规格注入慢动作能力，直接检查采集帧率弹窗的固定按钮布局。
        let normalRates = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr)
        ]
        let captureRates = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps240, colorSpace: .sdr)
        ]
        model.camera.installVideoCapabilitiesForTesting(ordinary: normalRates, cinematic: [], slowMotionCaptureRates: captureRates)
        model.setCaptureKind(.video)
        model.toggleSlowMotionMode()
        XCTAssertTrue(model.slowMotionEnabled)
        model.toolbarPanel = .videoFormat
        host.rootView = AnyView(CameraView(model: model).toolbarOptionsPanel(availableWidth: window.bounds.width - 16)
            .background(Color.black).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(300))
        attach(window, "Video-SlowMotion-FixedCaptureRateButtons")

        for width in [CGFloat(320), window.bounds.width] {
            host.rootView = AnyView(OpenGateInformationDialog(
                specsSummary: "SDR：720p：24–60 / 1080p：24–60 / 4K：24–30\nP3：720p：24–60 / 1080p：24–60 / 4K：24–30",
                onDismiss: {}
            ).frame(width: width, height: window.bounds.height).preferredColorScheme(.dark))
            try await Task.sleep(for: .milliseconds(300))
            let fitted = host.sizeThatFits(in: window.bounds.size)
            XCTAssertLessThanOrEqual(fitted.width, window.bounds.width + 1)
            attach(window, "OpenGate-Info-\(Int(width))")
        }
        for index in 0..<60 {
            model.videoFrameRate = VideoFrameRate.allCases[index % 6]
            model.toggleToolbarPanel([CameraToolbarPanel.videoFormat, .videoRatio, .videoColor][index % 3])
        }
        model.closePopups()
        XCTAssertNil(model.toolbarPanel)
        XCTAssertFalse(model.camera.videoBusy)
    }

    @MainActor private func attach(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// 由已挂载的测试视图读取环境，再传给取景内容。
struct CameraViewfinderTestHost: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject var camera: CameraEngine
    @Environment(\.captureControlAngle) private var angle
    @Environment(\.accessibilityReduceMotion) private var reducingMotion

    var body: some View {
        CameraView(model: model).viewfinderContent(controlAngle: angle, reducingMotion: reducingMotion)
    }
}
