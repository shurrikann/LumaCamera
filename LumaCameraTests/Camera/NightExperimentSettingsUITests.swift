import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor
final class NightExperimentSettingsUITests: XCTestCase {
    func testNightExperimentSettingsRemovedAndDefaultsAreThreeFramesSDR() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let options = model.photoOptions
        XCTAssertEqual(options.nightProfile, .standard)
        XCTAssertFalse(options.nightHDRPhoto)
        let host = UIHostingController(rootView: CameraView(model: model).settingsView)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let identifiers = Set(descendants(host.view).map(\.accessibilityIdentifier).compactMap { $0 })
        XCTAssertFalse(identifiers.contains("settings.independentNightProfile"))
        XCTAssertFalse(identifiers.contains("settings.forceIndependentNight"))
        XCTAssertFalse(identifiers.contains("settings.nightHDRPhoto"))
        XCTAssertFalse(host.view.bounds.isEmpty)
    }
}
