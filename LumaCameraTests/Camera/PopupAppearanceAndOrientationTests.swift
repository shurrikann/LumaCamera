import XCTest
import SwiftUI
import UIKit
import QuartzCore
@testable import LumaCamera

/// Performance and stability checks for the dark-glass popups and the
/// portrait/landscape fade transition added in this round.
final class PopupAppearanceAndOrientationTests: XCTestCase {

    @MainActor
    func testSubmodePopupUsesCompactOptionHeightWithoutStatusText() {
        XCTAssertEqual(ShootingModePanelLayout.optionHeight, 74, accuracy: 0.1)
        XCTAssertEqual(ShootingModePanelLayout.panelHeight(for: 3), 74, accuracy: 0.1)
        XCTAssertEqual(ShootingModePanelLayout.panelHeight(for: 6), 158, accuracy: 0.1)
        XCTAssertEqual(ShootingModePanelLayout.panelHeight(for: 4), 158, accuracy: 0.1)
    }

    // MARK: - Performance

    @MainActor
    func testPopupGlassDrawPerformance() async throws {
        let window = makeWindow()
        defer { tearDown(window) }
        try await Task.sleep(for: .milliseconds(250))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<6 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
        }
    }

    @MainActor
    func testPopupOrientationSwitchDrawPerformance() async throws {
        let window = makeWindow()
        defer { tearDown(window) }
        let host = try XCTUnwrap(window.rootViewController as? UIHostingController<PopupHarness>)
        try await Task.sleep(for: .milliseconds(250))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for index in 0..<8 {
                host.rootView = PopupHarness(angle: index.isMultiple(of: 2) ? 90.0 : 0.0)
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
        }
    }


    @MainActor
    func testPopupOrientationFramePacingOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Display-link frame pacing is measured on a physical device")
        #else
        let window = makeWindow()
        defer { tearDown(window) }
        let host = try XCTUnwrap(window.rootViewController as? UIHostingController<PopupHarness>)
        try await Task.sleep(for: .milliseconds(300))

        let recorder = FrameRecorder()
        let link = CADisplayLink(target: recorder, selector: #selector(FrameRecorder.tick(_:)))
        link.add(to: .main, forMode: .common)
        host.rootView = PopupHarness(angle: 90.0)
        try await Task.sleep(for: .milliseconds(700))
        link.invalidate()

        let stamps = recorder.timestamps
        XCTAssertGreaterThan(stamps.count, 20, "Display link should keep ticking during the orientation transition")
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let average = gaps.reduce(0, +) / Double(max(1, gaps.count))
        let maximum = gaps.max() ?? 0
        print(String(format: "POPUP-FRAME-PACING frames=%d average=%.4f max=%.4f", stamps.count, average, maximum))
        XCTAssertLessThan(maximum, 0.1, "No multi-frame stall during the popup orientation transition")
        #endif
    }

    // MARK: - Stability

    @MainActor
    func testPopupOrientationRapidStressEndsVisible() async throws {
        let window = makeWindow()
        defer { tearDown(window) }
        let host = try XCTUnwrap(window.rootViewController as? UIHostingController<PopupHarness>)
        try await Task.sleep(for: .milliseconds(250))

        for index in 0..<200 {
            host.rootView = PopupHarness(angle: index.isMultiple(of: 2) ? 90.0 : 0.0)
            try await Task.sleep(for: .milliseconds(8))
        }
        host.rootView = PopupHarness(angle: 90.0)
        try await Task.sleep(for: .milliseconds(700))

        let image = snapshot(window)
        XCTAssertGreaterThan(visiblePixelCount(image), 1_000, "Popup must remain visible after rapid orientation changes")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Popup-Rotation-Stress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPopupOpenCloseDuringOrientationChangesRemainsResponsive() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Full camera UI stress runs in the simulator; the device runs the harness orientation stress")
        #else
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setMode(.manual)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: CameraView(model: model).environment(\.captureControlAngle, 0.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.closePopups()
            model.setCameraActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(350))

        for index in 0..<60 {
            model.closePopups()
            if index.isMultiple(of: 2) { model.openParameter(index.isMultiple(of: 4) ? .iso : .wb) }
            else { model.togglePanel(.film) }
            host.rootView = CameraView(model: model).environment(\.captureControlAngle, index.isMultiple(of: 2) ? 90.0 : 0.0)
            try await Task.sleep(for: .milliseconds(45))
        }

        model.closePopups()
        model.toolbarPanel = nil
        model.popupFrameForTesting = .zero
        model.openParameter(.iso)
        host.rootView = CameraView(model: model).environment(\.captureControlAngle, 90.0)
        try await Task.sleep(for: .milliseconds(750))

        let rect = model.popupFrameForTesting
        XCTAssertGreaterThan(rect.width, 40)
        XCTAssertGreaterThan(rect.height, 100)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
        XCTAssertLessThanOrEqual(rect.maxX, window.bounds.width + 0.5)
        XCTAssertGreaterThan(rect.width, window.bounds.width - 24, "Parameter sheet keeps the portrait full width")
        XCTAssertGreaterThan(rect.maxY, window.bounds.height - 20, "Parameter sheet stays at the portrait bottom")
        XCTAssertTrue(model.popupVisible)
        #endif
    }

    // MARK: - Parameter sheet and fixed controls

    @MainActor
    func testParameterPopupKeepsFocalControlsFixed() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(350))

        let keys = ["lenses", "mode", "tools"]
        let before = Dictionary(uniqueKeysWithValues: keys.map { ($0, model.captureButtonFramesForTesting[$0] ?? .zero) })
        model.openParameter(.iso)
        try await Task.sleep(for: .milliseconds(650))

        for key in keys {
            let after = model.captureButtonFramesForTesting[key] ?? .zero
            XCTAssertEqual(before[key]!.minY, after.minY, accuracy: 1.0, "\(key) moved when the parameter popup opened")
            XCTAssertEqual(before[key]!.midX, after.midX, accuracy: 1.0, "\(key) shifted horizontally")
        }
        let popup = model.popupFrameForTesting
        XCTAssertGreaterThan(popup.width, window.bounds.width - 2, "Parameter sheet should be full width")
        XCTAssertGreaterThan(popup.maxY, window.bounds.height - 2, "Parameter sheet should reach the bottom edge")
    }

    @MainActor
    func testParameterPopupStaysPortraitAtLandscapeAngle() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 90)
        defer { tearDownCameraWindow(window, model) }
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(350))

        let keys = ["lenses", "mode", "tools"]
        let before = Dictionary(uniqueKeysWithValues: keys.map { ($0, model.captureButtonFramesForTesting[$0] ?? .zero) })
        model.openParameter(.iso)
        try await Task.sleep(for: .milliseconds(650))

        for key in keys {
            let after = model.captureButtonFramesForTesting[key] ?? .zero
            XCTAssertEqual(before[key]!.minY, after.minY, accuracy: 1.0, "\(key) moved at a landscape control angle")
        }
        let popup = model.popupFrameForTesting
        XCTAssertGreaterThan(popup.width, popup.height, "Parameter sheet must keep its portrait card shape")
        XCTAssertLessThanOrEqual(abs(popup.minX), 2, "Portrait sheet should be edge to edge")
        XCTAssertLessThanOrEqual(abs(popup.maxX - window.bounds.width), 2)
        XCTAssertGreaterThanOrEqual(popup.maxY, window.bounds.height - 2)
    }

    @MainActor
    func testParameterPopupRapidOpenCloseRotationStress() async throws {
        let (window, model, host) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(300))

        for index in 0..<40 {
            model.closePopups()
            if index.isMultiple(of: 2) { model.openParameter(index.isMultiple(of: 4) ? .iso : .wb) }
            host.rootView = AnyView(CameraView(model: model)
                .environment(\.captureControlAngle, index.isMultiple(of: 2) ? 90.0 : 0.0))
            try await Task.sleep(for: .milliseconds(18))
        }

        model.closePopups()
        model.openParameter(.iso)
        host.rootView = AnyView(CameraView(model: model).environment(\.captureControlAngle, 90.0))
        try await Task.sleep(for: .milliseconds(750))

        XCTAssertTrue(model.popupVisible)
        XCTAssertNotNil(model.captureButtonFramesForTesting["lenses"])
        XCTAssertGreaterThan(model.captureButtonFramesForTesting["lenses"]!.width, 40)
        let popup = model.popupFrameForTesting
        XCTAssertGreaterThan(popup.width, popup.height, "Final sheet must remain portrait-shaped")
        XCTAssertLessThanOrEqual(abs(popup.minX), 2)
        XCTAssertGreaterThanOrEqual(popup.maxY, window.bounds.height - 2)
    }

    @MainActor
    func testParameterSheetDrawPerformance() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }
        model.setMode(.manual)
        model.openParameter(.iso)
        try await Task.sleep(for: .milliseconds(700))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<6 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
        }
    }

    @MainActor
    private func makeCameraWindow(angle: Double) async throws -> (UIWindow, CameraViewModel, UIHostingController<AnyView>) {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setMode(.manual)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: AnyView(CameraView(model: model)
            .environment(\.captureControlAngle, angle)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        previous?.makeKey()
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        return (window, model, host)
    }

    @MainActor
    private func tearDownCameraWindow(_ window: UIWindow, _ model: CameraViewModel) {
        model.closePopups()
        model.setCameraActive(false)
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene?.windows.first(where: { $0 !== window && !$0.isHidden })?.makeKeyAndVisible()
    }

    // MARK: - Top toolbar popups

    @MainActor
    func testTopToolbarPopupStaysPortraitAtLandscapeAngle() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 90)
        defer { tearDownCameraWindow(window, model) }
        model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(650))

        let popup = model.popupFrameForTesting
        XCTAssertGreaterThan(popup.width, window.bounds.width - 24, "Top popup should keep the portrait full-width card")
        XCTAssertLessThan(popup.minY, 160, "Top popup should stay attached below the toolbar")
        XCTAssertLessThan(popup.height, 520, "Top popup should keep the portrait height instead of the rotated landscape card")
    }

    @MainActor
    func testOpenGateVideoFormatPopupHidesResolutionAndUnsupportedRates() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }
        model.setCameraActive(true)
        model.videoRatio = .ratio4x3
        model.setCaptureKind(.video)
        for _ in 0..<300 { if model.camera.ready && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard model.supportsVideoOpenGate else { throw XCTSkip("当前镜头不提供 Open Gate") }
        model.setVideoOpenGateEnabled(true)
        for _ in 0..<200 { if model.videoOpenGateEnabled && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.videoOpenGateEnabled)
        model.toolbarPanel = .videoFormat
        try await Task.sleep(for: .milliseconds(500))
        let keys = Set(model.captureButtonFramesForTesting.keys)
        XCTAssertFalse(keys.contains { $0.hasPrefix("videoResolution.") }, "Open Gate 下不能显示分辨率选项")
        let actualRates = keys.filter { $0.hasPrefix("videoRate.") }
        let expectedRates = Set(model.videoFrameRateOptions.map { "videoRate.\($0.rawValue)" })
        XCTAssertEqual(actualRates, expectedRates, "只显示 Open Gate 支持的帧率")
    }

    @MainActor
    func testTopToolbarPopupRapidOpenCloseRotationStress() async throws {
        let (window, model, host) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }

        for index in 0..<30 {
            model.toolbarPanel = index.isMultiple(of: 3) ? nil : .format
            host.rootView = AnyView(CameraView(model: model)
                .environment(\.captureControlAngle, index.isMultiple(of: 2) ? 90.0 : 0.0))
            try await Task.sleep(for: .milliseconds(18))
        }

        model.toolbarPanel = .format
        host.rootView = AnyView(CameraView(model: model).environment(\.captureControlAngle, 90.0))
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertNotNil(model.toolbarPanel)
        let popup = model.popupFrameForTesting
        XCTAssertGreaterThan(popup.width, window.bounds.width - 24)
        XCTAssertLessThan(popup.minY, 160)
    }

    @MainActor
    func testTopToolbarPopupDrawPerformance() async throws {
        let (window, model, _) = try await makeCameraWindow(angle: 90)
        defer { tearDownCameraWindow(window, model) }
        model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(700))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<6 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
        }
    }

    @MainActor
    func testFocalPresetSelectionGlassStabilityAndDrawCost() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Liquid Glass selection appearance is validated on a physical iOS 26+ device")
        #else
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("System Liquid Glass is available starting with iOS 26")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: FocalPresetGlassHarness(selectedIndex: 0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(250))

        // Repeated rapid selection changes must leave exactly one visible glass
        // background and keep every preset available for subsequent interaction.
        for index in 0..<60 {
            let selected = index % 5
            host.rootView = FocalPresetGlassHarness(selectedIndex: selected)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(12))
            let buttons = focalButtons(in: window)
            XCTAssertEqual(buttons.count, 5)
            for (buttonIndex, button) in buttons.enumerated() {
                XCTAssertEqual(hasVisibleLiquidGlass(in: button), buttonIndex == selected)
                XCTAssertTrue(button.isEnabled)
            }
        }

        var sampleMilliseconds: [Double] = []
        for sample in 0..<5 {
            let start = CACurrentMediaTime()
            for step in 0..<6 {
                host.rootView = FocalPresetGlassHarness(selectedIndex: (sample + step) % 5)
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
            sampleMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
        }
        let average = sampleMilliseconds.reduce(0, +) / Double(sampleMilliseconds.count)
        let formattedSamples = sampleMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let formattedAverage = String(format: "%.2f", average)
        print("FOCAL-GLASS-DRAW samples-ms=\(formattedSamples) avg-ms-per-6-snapshots=\(formattedAverage)")
        let metrics = XCTAttachment(string: "device=iPhone 17 Pro; selectionChanges=60; buttons=5; drawSamples=5 groups x 6 snapshots; samples-ms=\(formattedSamples); average-ms-per-6-snapshots=\(formattedAverage); UI snapshot cost only, not display FPS or touch latency")
        metrics.name = "Focal-Preset-Glass-Metrics"
        metrics.lifetime = .keepAlways
        add(metrics)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Focal-Preset-Selected-Glass"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    @MainActor
    func testSlowShutterPresetGroupGlassStabilityAndDrawCost() async throws {
        try await PresetToolbarChecks.slow(test: self, extended: false)
    }

    @MainActor
    func testToolbarOverlapGlassStabilityAndDrawCost() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Toolbar overlap Liquid Glass appearance is validated on a physical iOS 26+ device")
        #else
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("System Liquid Glass is available starting with iOS 26")
        }
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            throw XCTSkip("Reduce Transparency intentionally uses the solid accessibility fallback")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: ToolbarOverlapGlassHarness(height: 58))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(250))

        for index in 0..<60 {
            let height: CGFloat = index.isMultiple(of: 2) ? 58 : 0
            host.rootView = ToolbarOverlapGlassHarness(height: height)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(12))
            XCTAssertNil(toolbarOverlapGlassView(in: host.view),
                         "Toolbar overlap must remain transparent (no Liquid Glass)")
        }

        var sampleMilliseconds: [Double] = []
        for sample in 0..<5 {
            let start = CACurrentMediaTime()
            for step in 0..<6 {
                host.rootView = ToolbarOverlapGlassHarness(height: 58 + CGFloat((sample + step) % 3))
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
                XCTAssertNil(toolbarOverlapGlassView(in: host.view))
            }
            sampleMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
        }
        let average = sampleMilliseconds.reduce(0, +) / Double(sampleMilliseconds.count)
        let formattedSamples = sampleMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("TOOLBAR-OVERLAP-TRANSPARENT samples-ms=\(formattedSamples) avg-ms-per-6-snapshots=\(String(format: "%.2f", average))")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Toolbar-Overlap-Transparent"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    @MainActor
    func testToolbarOverlapGlassTracksEveryPhotoRatioOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Camera ratio integration is validated on a physical device")
        #else
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("System Liquid Glass is available starting with iOS 26")
        }
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            throw XCTSkip("Reduce Transparency intentionally uses the solid accessibility fallback")
        }

        let (window, model, host) = try await makeCameraWindow(angle: 0)
        defer { tearDownCameraWindow(window, model) }
        model.closePopups()
        try await Task.sleep(for: .milliseconds(250))
        let toolbarTop = model.toolbarFrameForTesting.minY

        for ratio in FrameRatio.photoOptions {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(220))
            window.layoutIfNeeded()

            XCTAssertNil(toolbarOverlapGlassView(in: host.view),
                         "Toolbar overlap must stay transparent at \(ratio.rawValue)")
            XCTAssertEqual(model.toolbarFrameForTesting.minY, toolbarTop, accuracy: 1.0,
                           "Changing the photo ratio must not move the toolbar at \(ratio.rawValue)")
        }
        #endif
    }

    @MainActor
    func testLogVideoFilterNameStaysLeadingAlignedOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Log filter panel alignment is validated on a physical device")
        #else
        let (window, model, _) = try await makeCameraWindow(angle: 0)
        let previousLogLUTID = model.selectedLogLUTID
        let previousBurnSetting = model.burnLogLUT
        defer {
            model.selectedLogLUTID = previousLogLUTID
            model.burnLogLUT = previousBurnSetting
            tearDownCameraWindow(window, model)
        }

        model.setCaptureKind(.video)
        model.videoColorSpace = .appleLog
        model.panel = .film
        if let preset = model.logLUTPresets.first { model.selectLogLUT(preset.id) }
        for _ in 0..<50 {
            if !model.logLUTTitleFrameForTesting.isEmpty { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        window.layoutIfNeeded()

        let titleFrame = model.logLUTTitleFrameForTesting
        let infoFrame = model.logLUTInfoFrameForTesting
        XCTAssertGreaterThan(titleFrame.width, 0)
        XCTAssertGreaterThan(infoFrame.width, 0)
        XCTAssertEqual(titleFrame.minX, infoFrame.minX, accuracy: 1.0,
                       "The selected Log filter name should start at the info row's leading edge")

        for _ in 0..<10 {
            model.panel = nil
            try await Task.sleep(for: .milliseconds(20))
            model.panel = .film
            try await Task.sleep(for: .milliseconds(220))
            window.layoutIfNeeded()
            XCTAssertEqual(model.logLUTTitleFrameForTesting.minX, model.logLUTInfoFrameForTesting.minX,
                           accuracy: 1.0, "The title must remain leading-aligned after closing and reopening the panel")
        }

        var snapshotMilliseconds: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            snapshotMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
            XCTAssertNotNil(image.cgImage)
        }
        let averageSnapshotMilliseconds = snapshotMilliseconds.reduce(0, +) / Double(snapshotMilliseconds.count)
        let formattedSnapshotSamples = snapshotMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let formattedAverageSnapshot = String(format: "%.2f", averageSnapshotMilliseconds)
        print("LOG-FILTER-ALIGN samples-ms=\(formattedSnapshotSamples) avg-ms-per-snapshot=\(formattedAverageSnapshot)")
        #endif
    }

    // MARK: - Harness

    private typealias PopupHarness = HarnessView

    private struct HarnessView: View {
        var angle: Double = 0

        var body: some View {
            ZStack(alignment: .bottom) {
                Color(white: 0.02)
                sampleCard
                    .orientedPopup()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .environment(\.captureControlAngle, angle)
        }
    }

    @MainActor
    private func makeWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: PopupHarness(angle: 0.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    @MainActor
    private func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        let scene = window.windowScene
        scene?.windows.first(where: { $0 !== window && !$0.isHidden })?.makeKeyAndVisible()
    }

    private func imageFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return format
    }

    @MainActor
    private func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds, format: imageFormat()).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func visiblePixelCount(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let luminance = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
            if luminance > 24 { count += 1 }
        }
        return count
    }
}

private struct FocalPresetGlassHarness: View {
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(["0.5", "1", "2", "4", "8"].enumerated()), id: \.offset) { index, title in
                CameraFocalButton(title: title, selected: selectedIndex == index, enabled: true,
                    accessibilityLabel: "测试焦段 \(title)", onTap: {}, onLongPress: {}, onDrag: { _, _ in }, onFinish: {})
                    .frame(width: 44, height: 44)
            }
        }
        .padding(2)
        .modifier(PreviewSurface(radius: 24, opacity: 0.16, curve: .circular))
        .padding(12)
        .background(Color(red: 0.06, green: 0.09, blue: 0.14))
        .preferredColorScheme(.dark)
    }
}

private struct ToolbarOverlapGlassHarness: View {
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color.blue, Color.cyan, Color.orange, Color.green],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .top) {
                    VStack(spacing: 7) {
                        HStack(spacing: 13) {
                            Text("24mm")
                            Image(systemName: "camera.aperture")
                            Text("16:9 · HEIF PRO")
                            Image(systemName: "slider.horizontal.3")
                        }
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        HStack(spacing: 0) {
                            ForEach(0..<20, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.88) : Color.black.opacity(0.72))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 6)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.top, 9)
                }
            VStack(spacing: 0) {
                CameraToolbarOverlapBackground(height: height)
                Spacer(minLength: 0)
            }
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
private func focalButtons(in root: UIView) -> [UIButton] {
    let own = (root as? UIButton).map { [$0] } ?? []
    return own + root.subviews.flatMap { focalButtons(in: $0) }
        .filter { $0.accessibilityLabel?.hasPrefix("测试焦段") == true }
}

@MainActor
private func views(in root: UIView, accessibilityPrefix: String) -> [UIView] {
    let own = root.accessibilityIdentifier?.hasPrefix(accessibilityPrefix) == true ? [root] : []
    return own + root.subviews.flatMap { views(in: $0, accessibilityPrefix: accessibilityPrefix) }
}

@available(iOS 26.0, *)
@MainActor
private func toolbarOverlapGlassView(in root: UIView) -> UIVisualEffectView? {
    if let effectView = root as? UIVisualEffectView,
       effectView.accessibilityIdentifier == "camera.toolbar.overlap.glass",
       effectView.effect is UIGlassEffect,
       !effectView.isHidden,
       effectView.alpha > 0 {
        return effectView
    }
    for child in root.subviews {
        if let match = toolbarOverlapGlassView(in: child) { return match }
    }
    return nil
}

@available(iOS 26.0, *)
@MainActor
private func hasVisibleLiquidGlass(in root: UIView) -> Bool {
    if let effectView = root as? UIVisualEffectView, effectView.effect is UIGlassEffect, !effectView.isHidden {
        return true
    }
    return root.subviews.contains { hasVisibleLiquidGlass(in: $0) }
}

@available(iOS 26.0, *)
private func visibleLiquidGlassCount(in root: UIView) -> Int {
    let own = (root as? UIVisualEffectView)?.effect is UIGlassEffect && root.alpha > 0.01 && !root.isHidden ? 1 : 0
    return own + root.subviews.reduce(0) { $0 + visibleLiquidGlassCount(in: $1) }
}

private final class FrameRecorder: NSObject {
    private(set) var timestamps: [CFTimeInterval] = []
    @objc func tick(_ link: CADisplayLink) { timestamps.append(link.timestamp) }
}

private var sampleCard: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("文件格式").font(.system(size: 15, weight: .semibold))
        HStack(spacing: 8) {
            ForEach(["HEIF", "JPG", "RAW", "RAW+JPG", "TIFF"], id: \.self) { title in
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(Color.white.opacity(0.13), in: Capsule())
            }
        }
        HStack(spacing: 10) {
            Text("HEIF Pro").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 78).frame(height: 32)
                .background(Color.white.opacity(0.13), in: Capsule())
            Text("通过 RAW 格式转换 HEIF，保留更多细节\n并降低锐化，支持 Pro 影调。")
                .font(.system(size: 9)).lineSpacing(1).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("滤镜、影调、画幅和边框直接写入所选格式。HEIF 和 JPG 为压缩格式。")
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        HStack(spacing: 8) {
            Text("HDR").font(.system(size: 15))
            Toggle("HDR", isOn: .constant(false)).labelsHidden()
            Text("10-bit HEIF").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
    }
    .foregroundStyle(.white)
    .padding(16)
    .frame(width: 360)
    .modifier(PopupSurface(radius: 28, glass: true))
    .padding(12)
    .environment(\.colorScheme, .dark)
}
