import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class FixedCameraControlsTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testRecordingHidesControlsWithoutReflowAndRestoresMode() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let originalKind = model.captureKind, originalMode = model.mode, originalRatio = model.ratio
        let wasReady = camera.ready
        defer {
            camera.setVideoRecordingForTesting(false)
            model.setCaptureKind(originalKind)
            model.setMode(originalMode)
            model.ratio = originalRatio
            model.setCameraActive(wasReady)
        }
        model.setCameraActive(true)
        for _ in 0..<150 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.video)
        try await Task.sleep(for: .milliseconds(350))
        let keys = ["album", "functions", "shutter", "filter", "flip", "mode", "lenses", "tools", "parameters"]

        for mode in [CameraShootingMode.auto, .manual] {
            model.setMode(mode)
            try await Task.sleep(for: .milliseconds(300))
            let baseline = model.captureButtonFramesForTesting
            let toolbar = model.toolbarFrameForTesting
            for key in keys { XCTAssertGreaterThan(try XCTUnwrap(baseline[key]).width, 0, key) }
            XCTAssertGreaterThan(toolbar.width, 0)

            camera.setVideoRecordingForTesting(true)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(camera.videoRecording)
            XCTAssertEqual(model.mode, mode)
            for key in keys {
                let before = try XCTUnwrap(baseline[key]), during = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                XCTAssertEqual(during.minX, before.minX, accuracy: 0.5, key)
                XCTAssertEqual(during.minY, before.minY, accuracy: 0.5, key)
                XCTAssertEqual(during.width, before.width, accuracy: 0.5, key)
                XCTAssertEqual(during.height, before.height, accuracy: 0.5, key)
            }
            let recordingToolbar = model.toolbarFrameForTesting
            XCTAssertEqual(recordingToolbar.minX, toolbar.minX, accuracy: 0.5)
            XCTAssertEqual(recordingToolbar.minY, toolbar.minY, accuracy: 0.5)
            XCTAssertEqual(recordingToolbar.width, toolbar.width, accuracy: 0.5)
            XCTAssertEqual(recordingToolbar.height, toolbar.height, accuracy: 0.5)
            snapshot(name: "Recording-Controls-Hidden-" + mode.rawValue)

            camera.setVideoRecordingForTesting(false)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(camera.videoRecording)
            XCTAssertEqual(model.mode, mode, "Stopping recording must restore the same A/M control row")
            for key in keys {
                let before = try XCTUnwrap(baseline[key]), after = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, key)
                XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, key)
                XCTAssertEqual(after.width, before.width, accuracy: 0.5, key)
                XCTAssertEqual(after.height, before.height, accuracy: 0.5, key)
            }
            snapshot(name: "Recording-Controls-Restored-" + mode.rawValue)
        }
    }

    @MainActor func testEveryRatioTransitionKeepsAllButtonsAndBothParameterRowsAtFixedPositions() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let oldRatio = model.ratio, oldMode = model.mode, oldHistogram = model.showHistogram
        defer { model.closePopups(); model.ratio = oldRatio; model.setMode(oldMode); model.showHistogram = oldHistogram }
        model.closePopups(); model.showHistogram = true
        var parameterY: CGFloat?
        let keys = ["album", "functions", "shutter", "filter", "flip", "mode", "lenses", "tools", "parameters"]
        for mode in [CameraShootingMode.auto, .manual] {
            model.setMode(mode); model.ratio = .standard
            try await Task.sleep(for: .milliseconds(350))
            let baseline = model.captureButtonFramesForTesting
            for key in keys { XCTAssertGreaterThan(try XCTUnwrap(baseline[key]).width, 0) }
            if let parameterY { XCTAssertEqual(try XCTUnwrap(baseline["parameters"]).midY, parameterY, accuracy: 0.5) }
            else { parameterY = try XCTUnwrap(baseline["parameters"]).midY }
            let stableKeys = keys + (mode == .manual ? CameraParameter.allCases.map { "parameter." + $0.rawValue } : [])
            for source in FrameRatio.allCases {
                model.ratio = source
                try await Task.sleep(for: .milliseconds(100))
                for target in FrameRatio.allCases where target != source {
                    withAnimation(AppTheme.frameAnimation) { model.ratio = target }
                    for _ in 0..<3 {
                        try await Task.sleep(for: .milliseconds(65))
                        for key in stableKeys {
                            let before = try XCTUnwrap(baseline[key]), after = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                            XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, key)
                            XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, key)
                            XCTAssertEqual(after.width, before.width, accuracy: 0.5, key)
                            XCTAssertEqual(after.height, before.height, accuracy: 0.5, key)
                        }
                    }
                }
            }
            for ratio in FrameRatio.allCases {
                model.ratio = ratio; try await Task.sleep(for: .milliseconds(300))
                snapshot(name: "Fixed-Controls-" + mode.rawValue + "-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "p"))
            }
        }
    }
    @MainActor func testButtonsStayVisibleDuringAnimatedFourThreeAndSixteenNineSwitches() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let oldRatio = model.ratio, oldMode = model.mode
        defer { model.closePopups(); model.ratio = oldRatio; model.setMode(oldMode) }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow))
        for mode in [CameraShootingMode.auto, .manual] {
            model.closePopups(); model.setMode(mode); model.ratio = .standard
            try await Task.sleep(for: .milliseconds(400))
            let names = ["shutter", "functions", "filter", "mode", "tools"] + (mode == .manual ? CameraParameter.allCases.map { "parameter." + $0.rawValue } : [])
            let reference = capture(window)
            let frames = model.captureButtonFramesForTesting
            for ratio in [FrameRatio.wide, .standard] {
                withAnimation(AppTheme.frameAnimation) { model.ratio = ratio }
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(60))
                    let during = capture(window)
                    for key in names {
                        let rect = try XCTUnwrap(frames[key])
                        let base = brightPixels(reference, rect: rect)
                        XCTAssertGreaterThan(base, 5, key)
                        XCTAssertGreaterThan(brightPixels(during, rect: rect), base / 2, "Control disappeared during crop animation: " + key)
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }
    @MainActor func testOpenZoomWheelInEveryRatioKeepsShutterControlsFixed() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let oldRatio = model.ratio, oldMode = model.mode
        let wasReady = model.camera.ready
        defer { model.closePopups(); model.ratio = oldRatio; model.setMode(oldMode); model.setCameraActive(wasReady) }
        model.closePopups()
        model.setCameraActive(true)
        for _ in 0..<150 { if model.camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.camera.ready)
        model.setMode(.manual)
        model.ratio = .standard
        try await Task.sleep(for: .milliseconds(350))
        let baseline = model.captureButtonFramesForTesting
        for ratio in FrameRatio.allCases {
            model.ratio = ratio
            model.beginZoomDial(at: model.camera.currentZoom)
            model.finishZoomDrag()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(model.zoomDialVisible)
            for key in ["album", "functions", "shutter", "filter", "flip", "parameters"] {
                let before = try XCTUnwrap(baseline[key]), after = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, key)
                XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, key)
            }
            snapshot(name: "Preview-Clipped-Zoom-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-"))
            model.endZoomDial()
        }
    }
    @MainActor private func snapshot(name: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) else { return }
        let a = XCTAttachment(image: capture(window)); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @MainActor private func capture(_ window: UIWindow) -> UIImage { UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) } }
    private func brightPixels(_ image: UIImage, rect: CGRect) -> Int {
        let cg = image.cgImage!, scale = image.scale
        let cropRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = cg.cropping(to: cropRect) else { return 0 }
        var data = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress!, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let isLight = data[i] > 190 && data[i + 1] > 165
            let isAccentOrange = data[i] > 150 && data[i + 1] > 40 && data[i + 2] < data[i + 1] && Double(data[i]) > Double(data[i + 1]) * 1.35
            if isLight || isAccentOrange { count += 1 }
        }
        return count
    }
    #endif
}
