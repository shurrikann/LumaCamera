import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class ToolbarHistogramLayoutTests: XCTestCase {
    @MainActor func testAllRatioTransitionsKeepToolbarFixedAndHistogramClear() async throws {
        #if targetEnvironment(simulator)
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let oldRatio = model.ratio, oldHistogram = model.showHistogram
        defer { model.ratio = oldRatio; model.showHistogram = oldHistogram; model.closePopups() }
        model.closePopups(); model.showHistogram = true; model.ratio = .standard
        try await Task.sleep(for: .milliseconds(350))
        let top = model.toolbarFrameForTesting.minY
        XCTAssertGreaterThan(model.toolbarFrameForTesting.height, 30)
        for source in FrameRatio.allCases {
            model.ratio = source
            try await Task.sleep(for: .milliseconds(300))
            for target in FrameRatio.allCases where source != target {
                withAnimation(AppTheme.frameAnimation) { model.ratio = target }
                for _ in 0..<4 {
                    try await Task.sleep(for: .milliseconds(65))
                    XCTAssertEqual(model.toolbarFrameForTesting.minY, top, accuracy: 0.5, "Toolbar moved: \(source) → \(target)")
                    XCTAssertGreaterThanOrEqual(model.histogramFrameForTesting.minY, model.toolbarFrameForTesting.maxY + 1, "Histogram overlaps: \(source) → \(target)")
                    if target.overlaysToolbar {
                        XCTAssertGreaterThan(model.toolbarBackdropFrameForTesting.height, 0)
                        XCTAssertLessThanOrEqual(model.toolbarBackdropFrameForTesting.maxY, model.histogramFrameForTesting.minY - 4, "Toolbar background overlaps histogram: \(source) → \(target)")
                    }
                }
            }
        }
        #else
        throw XCTSkip("Ratio layout is tested in simulator")
        #endif
    }
    #if targetEnvironment(simulator)
    @MainActor func testEnlargedSideButtonsKeepSpacingOnNormalAndCompactScreensInEveryRatio() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .leicaM9; model.showHistogram = true
        let host = UIHostingController(rootView: CameraView(model: model).preferredColorScheme(.dark))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.camera.stop(); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for: .milliseconds(300)); model.camera.start()
        for width in [scene.screen.bounds.width, CGFloat(320)] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: scene.screen.bounds.height)
            for ratio in FrameRatio.allCases {
                model.ratio = ratio
                try await Task.sleep(for: .milliseconds(350))
                let frames = model.captureButtonFramesForTesting
                let names = ["album", "functions", "shutter", "filter", "flip"]
                let ordered = try names.map { try XCTUnwrap(frames[$0]) }
                for i in 1..<ordered.count { XCTAssertGreaterThanOrEqual(ordered[i].minX - ordered[i-1].maxX, 5) }
                for index in [0, 1, 3, 4] {
                    XCTAssertEqual(ordered[index].width, width > 350 ? 52 : 45, accuracy: 1)
                    XCTAssertEqual(ordered[index].midY, ordered[2].midY, accuracy: 1)
                }
                XCTAssertEqual(ordered[2].width, 76, accuracy: 1)
                XCTAssertGreaterThanOrEqual(ordered.first!.minX, 19)
                XCTAssertLessThanOrEqual(ordered.last!.maxX, width - 19)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let a = XCTAttachment(image: image); a.name = "Capture-Buttons-\(Int(width))-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "p"); a.lifetime = .keepAlways; add(a)
            }
        }
    }
    @MainActor func testLongFilterNamesKeepCaptureButtonSizeAndShowTruncation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: VStack(spacing: 30) {
            ForEach(["原片", "徕卡 M9", "Fujifilm Classic Negative 经典负片特别版", "一款名字非常非常长的自定义滤镜"], id: \.self) { title in
                HStack(spacing: 30) { CameraFilterButtonLabel(title: title, equipment: title == "原片" ? nil : "Fujifilm 富士特别系列", active: true); Text(title).font(.system(size: 12)) }
            }
        }.padding(20).background(Color(red: 0.08, green: 0.12, blue: 0.18)).preferredColorScheme(.dark))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let a = XCTAttachment(image: image); a.name = "Filter-Button-Long-Names"; a.lifetime = .keepAlways; add(a)
    }
    #endif
}
