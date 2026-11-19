import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class PreviewControlContrastTests: XCTestCase {
    func testLocalTilesAndAspectFill() throws {
        let image = try fixture(split: true)
        let sample = try XCTUnwrap(PreviewContrastSample.render(image))
        let preview = CGRect(x: 20, y: 40, width: 200, height: 200)
        let imageSize = CGSize(width: image.width, height: image.height)
        let top = PreviewContrastSample.imageRegion(for: CGRect(x: 40, y: 70, width: 20, height: 14),
                                                     preview: preview, imageSize: imageSize)
        let bottom = PreviewContrastSample.imageRegion(for: CGRect(x: 40, y: 205, width: 20, height: 14),
                                                        preview: preview, imageSize: imageSize)
        let mixed = PreviewContrastSample.imageRegion(for: CGRect(x: 40, y: 129, width: 20, height: 22),
                                                       preview: preview, imageSize: imageSize)
        XCTAssertEqual(try XCTUnwrap(sample.minimumContrast(in: top, foreground: 1)), 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(sample.minimumContrast(in: bottom, foreground: 1)), 21, accuracy: 0.02)
        XCTAssertLessThan(try XCTUnwrap(sample.minimumContrast(in: mixed, foreground: 1)), 1.5)
        XCTAssertNil(sample.minimumContrast(in: PreviewContrastSample.imageRegion(
            for: CGRect(x: 40, y: 0, width: 20, height: 14), preview: preview, imageSize: imageSize), foreground: 1))
    }

    func testLinearSRGBAndFixedOrange() throws {
        XCTAssertEqual(PreviewContrastSample.luminance(255, 0, 0), 0.2126, accuracy: 0.0001)
        XCTAssertEqual(PreviewContrastSample.luminance(0, 0, 255), 0.0722, accuracy: 0.0001)
        XCTAssertEqual(PreviewContrastSample.luminance(118, 118, 118), 0.1812, accuracy: 0.001)
        let contrastOnBlack = (PreviewContrastSample.orange + 0.05) / 0.05
        XCTAssertGreaterThan(contrastOnBlack, 4.5)
        XCTAssertLessThan(1.05 / (PreviewContrastSample.orange + 0.05), 4.5)
    }

    func testAlternatingSamplesAndRecovery() {
        var state = PreviewContrastHysteresis()
        for i in 0..<300 {
            state.update(contrast: i.isMultiple(of: 2) ? 4.3 : 5.2, target: 4.5, at: Double(i) * 0.2)
            XCTAssertTrue(state.enhanced)
        }
        state.update(contrast: 4.3, target: 4.5, at: 60)
        for i in 0..<3 {
            state.update(contrast: 5.2, target: 4.5, at: 60.2 + Double(i) * 0.2)
            XCTAssertEqual(state.enhanced, i < 2)
        }
        state.update(contrast: 4, target: 4.5, at: 61)
        XCTAssertTrue(state.enhanced)
        state.update(contrast: nil, target: 4.5, at: 61.2)
        XCTAssertFalse(state.enhanced)
    }

    func testSamplingPerformance() throws {
        let image = try fixture(split: true)
        let regions = (0..<20).map { index in
            CGRect(x: Double(index % 7) * 0.13, y: Double(index / 7) * 0.45, width: 0.09, height: 0.08)
        }
        var count = 0
        measure(metrics: [XCTClockMetric()]) {
            count = 0
            for _ in 0..<120 {
                guard let sample = PreviewContrastSample.render(image) else { continue }
                count += regions.compactMap { sample.minimumContrast(in: $0, foreground: 1) }.count
            }
        }
        XCTAssertEqual(count, 120 * regions.count)
    }

    @MainActor
    func testFocalButtonEdgeDoesNotChangeTintOrLayout() async throws {
        let image = UIImage(cgImage: try fixture(split: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: ContrastFocalHarness(image: image)
            .environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()

        let top = try XCTUnwrap(focalButton(in: host.view, label: "明区焦段"))
        let bottom = try XCTUnwrap(focalButton(in: host.view, label: "暗区焦段"))
        let originalFrame = top.frame
        for _ in 0..<20 where top.titleLabel?.layer.shadowOpacity != 0.94 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(top.titleLabel?.layer.shadowOpacity, 0.94)
        XCTAssertEqual(bottom.titleLabel?.layer.shadowOpacity, 0)
        XCTAssertEqual(top.titleColor(for: .normal), AppTheme.accentUIColor)
        XCTAssertEqual(bottom.titleColor(for: .normal), AppTheme.accentUIColor)
        XCTAssertEqual(top.frame, originalFrame)
    }

    @MainActor
    private func focalButton(in view: UIView, label: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { self.focalButton(in: $0, label: label) }.first
    }

    private func fixture(split: Bool) throws -> CGImage {
        // Match the preview pipeline's typical 900 px portrait width.
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 1200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
        if split {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 600, width: 900, height: 600))
        }
        return try XCTUnwrap(context.makeImage())
    }
}


private struct ContrastFocalHarness: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 200, height: 200).clipped()
                .previewControlContrastFrame()
            VStack(spacing: 100) {
                focal("明区焦段")
                focal("暗区焦段")
            }
        }
        .previewControlContrastSource(active: true) { image }
    }

    private func focal(_ description: String) -> some View {
        CameraFocalButton(title: "1×", selected: true, enabled: true, accessibilityLabel: description,
                          usesEnclosingGlassBackground: true, onTap: {}, onLongPress: {},
                          onDrag: { _, _ in }, onFinish: {})
            .frame(width: 38, height: 38)
            .previewFocalContrast(title: "1×", selected: true)
    }
}
