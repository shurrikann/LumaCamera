import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor
final class CameraNewUIFeaturesTests: XCTestCase {
    private func host(_ model: CameraViewModel, width: CGFloat = 390, angle: Double = 0, scenePhase: ScenePhase = .active) throws -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: CameraView(model: model)
            .environment(\.scenePhase, scenePhase)
            .environment(\.captureControlAngle, angle))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 760)
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
        XCTAssertLessThanOrEqual(model.popupFrameForTesting.maxY, window.bounds.maxY + 1, "测试宿主应遵循真实安全区，不把底部滑条截掉")
        let recipe = model.filterAdjustments
        let originalHeight = model.popupFrameForTesting.height
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
            XCTAssertEqual(model.popupFrameForTesting.height, originalHeight, accuracy: 1, "三类弹窗高度必须固定")
        }
        // 重复切换、离开/返回编辑，不改写配方；横拿仍维持竖屏弹窗。
        for _ in 0..<5 {
            for tab in FilterEditorTab.allCases { model.filterEditorTab = tab; await Task.yield() }
        }
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.preferences.filterDialPad = false
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.filterDialPadFrameForTesting, .zero, "关闭设置后应恢复旧样式")
    }

    func testCompactDialFitsNarrowAndRotatedControlsForEveryPhotoRatio() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        defer { model.setCameraActive(false); model.closePopups() }
        var samples = 0
        for width: CGFloat in [320, 390] {
            for angle in [0.0, 90.0] {
                let (controller, window) = try host(model, width: width, angle: angle, scenePhase: .inactive)
                defer { window.isHidden = true; window.rootViewController = nil }
                _ = controller.view
                model.style = .leicaM9
                model.preferences.filterDialPad = true
                model.panel = .film; model.filters.showStrength = true
                try await Task.sleep(for: .milliseconds(250))
                let height = model.popupFrameForTesting.height
                for ratio in FrameRatio.photoOptions {
                    model.ratio = ratio
                    for tab in FilterEditorTab.allCases {
                        model.filterEditorTab = tab
                        try await Task.sleep(for: .milliseconds(70))
                        let frame = model.filterDialPadFrameForTesting
                        XCTAssertGreaterThan(frame.height, 200)
                        XCTAssertGreaterThanOrEqual(frame.minX, -1)
                        XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                        XCTAssertLessThanOrEqual(frame.maxY, window.bounds.maxY + 1)
                        XCTAssertEqual(model.popupFrameForTesting.height, height, accuracy: 1)
                        samples += 1
                    }
                }
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: shot)
                attachment.name = "Compact-Dial-width-\(Int(width))-angle-\(Int(angle))"
                attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden = true; window.rootViewController = nil
            }
        }
        print("DIAL-LAYOUT samples=\(samples) widths=320/390 controlAngles=0/90 ratios=7 tabs=3; hosted UI layout, no FPS claim")
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

    func testDialPadStrengthUsesUniformLinearStrength() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.preferences.filterDialPad = true
        model.style = .leicaM9
        let binding = model.filterParameterBinding(.strength)
        binding.wrappedValue = 80
        XCTAssertEqual(model.intensity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 1, accuracy: 0.0001)
        binding.wrappedValue = 100
        XCTAssertEqual(model.intensity, 1, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 1.3, accuracy: 0.0001)
        binding.wrappedValue = 0
        XCTAssertEqual(model.intensity, 0, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 0, accuracy: 0.0001)
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

/// 调色盘参数与手势回归：不启动相机、不创建系统相册资产。
@MainActor
final class CompactFilterDialTests: XCTestCase {
    func testAllParametersStayReachableWithoutChangingDefaultStyle() throws {
        XCTAssertFalse(CapturePreferences().filterDialPad)
        XCTAssertFalse(try JSONDecoder().decode(CapturePreferences.self, from: Data("{}".utf8)).filterDialPad)
        for tab in FilterEditorTab.allCases {
            let layout = FilterDialLayout.layout(for: tab)
            XCTAssertEqual(Set(layout.parameters), Set(tab.parameters))
            XCTAssertEqual(layout.parameters.count, Set(layout.parameters).count, "同页不能重复放置参数")
        }
        XCTAssertEqual(FilterDialLayout.layout(for: .effects).bottom, [.aberration, .grainSize, .grainSaturation])
    }

    func testPairCommitsOncePreservesIndependentValuesAndRejectsStaleGestures() throws {
        let suite = "Luma.Dial." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilterSettingsStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: store)
        model.filterEditorTab = .effects
        model.style = .leicaM9
        model.intensity = 0.8
        model.filterParameterBinding(.softness).wrappedValue = 20
        model.filterParameterBinding(.halation).wrappedValue = 60
        let pair = model.filterParameterPairBinding(.softness, .halation)
        XCTAssertEqual(pair.wrappedValue, CGPoint(x: 20, y: 60))
        var publications = 0
        let token = model.$filterAdjustments.dropFirst().sink { _ in publications += 1 }
        defer { token.cancel() }
        var times: [Double] = []
        for index in 0..<300 {
            let start = CACurrentMediaTime()
            pair.wrappedValue = CGPoint(x: index % 100, y: (index + 40) % 100)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        XCTAssertEqual(publications, 300, "每次二维输入只发布一次配方")
        XCTAssertEqual(model.intensity, 0.8, "调色盘参数不能反向改写基础滤镜浓度")
        let recipe = model.filterAdjustments
        pair.wrappedValue = CGPoint(x: CGFloat.nan, y: 10)
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.preferences.filterDialPad = true
        model.preferences.filterDialPad = false
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.filterEditorTab = .light
        pair.wrappedValue = CGPoint(x: 90, y: 90)
        XCTAssertEqual(model.filterAdjustments, recipe, "切页后的旧手势不能污染配方")
        model.filterEditorTab = .effects
        let beforeReset = model.filterParameterPairBinding(.softness, .halation)
        model.presentFilterReset()
        beforeReset.wrappedValue = CGPoint(x: 80, y: 90)
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.dismissFilterReset()
        model.resetCurrentFilter()
        beforeReset.wrappedValue = CGPoint(x: 80, y: 90)
        XCTAssertTrue(model.filterAdjustments.isNeutral)
        times.sort()
        print("DIAL-PAIR samples=300 medianMs=\(times[150]) p95Ms=\(times[285]) publications=\(publications); binding submission only, not frame rate")
    }

    func testPadEndpointAndNeutralMappingsMatchVisibleHandle() {
        for length: CGFloat in [80, 124, 180, 240] {
            for parameter in FilterParameter.allCases {
                let range = parameter.range
                for value in [range.lowerBound, 0, range.upperBound] {
                    let fraction = FilterDialGeometry.fraction(value, in: range)
                    let coordinate = 13 + CGFloat(fraction) * (length - 26)
                    XCTAssertEqual(FilterDialGeometry.value(at: coordinate, length: length, in: range), value, accuracy: 0.00001)
                }
            }
        }
    }
}
