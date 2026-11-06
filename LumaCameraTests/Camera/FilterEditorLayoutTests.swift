import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class FilterEditorLayoutTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testAllRatiosKeepEditorHeightScrollEffectsAndUseInAppReset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first(where: \.isKeyWindow)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .leicaM9; model.panel = .film; model.filters.showStrength = true
        let host = UIHostingController(rootView: CameraView(model: model).preferredColorScheme(.dark))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.camera.stop(); window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        model.camera.start()
        for _ in 0..<100 { if model.camera.ready && model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.camera.preview)
        for ratio in FrameRatio.allCases {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(300))
            var expected: CGRect?
            for tab in FilterEditorTab.allCases {
                model.filterEditorTab = tab
                try await Task.sleep(for: .milliseconds(180))
                host.view.layoutIfNeeded()
                let frame = model.popupFrameForTesting
                XCTAssertGreaterThan(frame.width, 200)
                XCTAssertGreaterThan(frame.height, 250)
                if let expected { XCTAssertEqual(frame.minY, expected.minY, accuracy: 1); XCTAssertEqual(frame.height, expected.height, accuracy: 1) }
                else { expected = frame }
                if tab == .effects {
                    XCTAssertGreaterThan(model.filterEditorTab.parameters.count, 5)
                }
                snapshot(window, name: "Filter-Fixed-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-") + "-" + String(describing: tab))
            }
        }
        model.presentFilterReset()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(host.presentedViewController, "Reset must use the app glass overlay")
        XCTAssertTrue(model.filterResetVisible)
        snapshot(window, name: "Filter-Glass-Reset")
        model.dismissFilterReset()
    }
    @MainActor private func snapshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    #endif
}
