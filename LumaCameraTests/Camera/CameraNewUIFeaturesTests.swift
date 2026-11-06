import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor
final class CameraNewUIFeaturesTests: XCTestCase {
    private func host(_ model: CameraViewModel) throws -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: CameraView(model: model)
            .environment(\.scenePhase, .active)
            .environment(\.captureControlAngle, 0)
            .frame(width: 390, height: 760))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        window.rootViewController = host
        window.isHidden = false
        return (host, window)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func test48MPPillIsDisabledInAutoAndEnabledInManual() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<300 { if camera.ready && camera.availableResolutions.contains(.high) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (controller, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setMode(.auto); model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(400))
        let autoFrame = try XCTUnwrap(model.captureButtonFramesForTesting["format.resolution.48"])
        XCTAssertFalse(autoFrame.isEmpty)
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 按钮必须禁用")
        model.setMode(.manual)
        for _ in 0..<200 { if camera.ready && model.mode == .manual { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(700))
        let manualFrame = try XCTUnwrap(model.captureButtonFramesForTesting["format.resolution.48"])
        XCTAssertFalse(manualFrame.isEmpty)
        XCTAssertTrue(model.canSelectPhotoResolution(.high), "M 挡 48MP 按钮应可用")
        model.photoResolution = .high
        model.setMode(.auto)
        for _ in 0..<200 { if model.mode == .auto && model.photoResolution == .standard { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.photoResolution, .standard, "M 48MP 切回 A 必须回退 12MP")
    }

    func testFilterDialPadSettingSwitchesEditorLayout() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.preferences.filterDialPad = false; model.closePopups() }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.style = .leicaM9
        model.panel = .film
        model.filters.showStrength = true
        model.preferences.filterDialPad = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.filterDialPadFrameForTesting, .zero, "设置关闭时必须走旧滑条布局")
        model.preferences.filterDialPad = true
        model.filters.showStrength = true
        for _ in 0..<100 { if model.filterDialPadFrameForTesting.height > 200 { break }; try await Task.sleep(for: .milliseconds(30)) }
        let frame = model.filterDialPadFrameForTesting
        XCTAssertGreaterThan(frame.width, 250)
        XCTAssertGreaterThan(frame.height, 200)
        XCTAssertFalse(frame.isEmpty)
        print("DIAL-GEOMETRY panel=\(model.popupFrameForTesting) dial=\(frame) window=\(window.bounds)")
        for tab in FilterEditorTab.allCases {
            model.filterEditorTab = tab
            try await Task.sleep(for: .milliseconds(250))
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: shot)
            attachment.name = "Filter-Dial-" + tab.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        model.preferences.filterDialPad = false
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.filterDialPadFrameForTesting, .zero, "关闭设置后应恢复旧样式")
    }

    func testStrengthFadeKeepsSamePreviewDynamicRange() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.intensity = 0.8; model.style = .original }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.hdr = false
        model.style = .leicaM9; model.intensity = 1
        try await Task.sleep(for: .milliseconds(700))
        for value in [1.0, 0.8, 0.5, 0.2, 0.05, 0.0] {
            model.intensity = value
            try await Task.sleep(for: .milliseconds(250))
            let bits = camera.preview?.cgImage?.bitsPerComponent ?? -1
            let headroom = camera.preview?.cgImage?.contentHeadroom ?? -1
            print("STRENGTH-FADE value=\(value) bits=\(bits) headroom=\(headroom) hdrActive=\(camera.hdrPreviewActive)")
        }
    }

    func testJPEGDisablesHDRAndManualHDRRestoresFilter() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.photoFormat = .jpeg; model.style = .original; model.setMode(.auto) }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.style = .leicaM9; model.intensity = 0.8
        model.setMode(.manual)
        model.hdr = true
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original, "M挡HDR也应临时回原片")
        model.hdr = false
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9, "关闭HDR恢复M挡滤镜")
        model.photoFormat = .jpeg
        XCTAssertFalse(model.hdr, "JPG没有HDR，切换后应关闭")
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9)
    }

    func testHDRSuppressesFilterTemporarilyAndRestoresIt() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.style = .original; model.intensity = 0.8 }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.style = .leicaM9; model.intensity = 0.8
        model.hdr = true
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.style, .leicaM9, "HDR不应清空已选滤镜")
        XCTAssertEqual(model.effectiveCaptureLook.style, .original, "HDR拍摄临时使用原片")
        XCTAssertFalse(model.filtersEnabled, "HDR开启后滤镜入口禁用")
        XCTAssertEqual(model.style.filterButtonName, FilmStyle.leicaM9.filterButtonName, "HDR不应改滤镜按钮文字")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(camera.preview?.cgImage?.bitsPerComponent, 8, "HDR预览应为SDR")
        XCTAssertEqual(camera.preview?.cgImage?.contentHeadroom ?? -1, 1, accuracy: 0.01)
        model.hdr = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.filtersEnabled)
        XCTAssertEqual(model.style, .leicaM9)
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9, "关闭HDR后恢复原滤镜")
        XCTAssertEqual(model.effectiveCaptureLook.intensity, 0.8, accuracy: 0.001)
    }

    func testBurstCountOccupiesLiveToolbarSlot() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (controller, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo)
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        if model.virtualApertureEnabled { model.toggleVirtualAperture() }
        if model.burstModeEnabled { model.toggleBurstMode() }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        model.ratio = .standard; model.setMode(.auto)
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.closePopups()
        for _ in 0..<300 { if camera.ready && !model.captureKindSwitching && !model.isPreparingSubmode && !camera.videoBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<300 { if camera.ready && camera.preview != nil && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
        if !model.burstModeEnabled { model.toggleBurstMode() }
        for _ in 0..<300 { if model.burstModeEnabled { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.burstModeEnabled)
        try await Task.sleep(for: .milliseconds(700))
        _ = controller
        XCTAssertNotNil(model.captureButtonFramesForTesting["toolbar.burstCount"])
        XCTAssertNil(model.captureButtonFramesForTesting["toolbar.live"])
        if model.burstModeEnabled { model.toggleBurstMode() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(model.captureButtonFramesForTesting["toolbar.live"])
    }
}
