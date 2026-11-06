import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor
final class NightExperimentSettingsUITests: XCTestCase {
    func testNightExperimentSettingsLoadsAndOptionsAreWired() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.nightHDRPhotoEnabled = false
        let host = UIHostingController(rootView: CameraView(model: model).settingsView)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let switches = descendants(host.view).compactMap { $0 as? UISwitch }
        XCTAssertGreaterThanOrEqual(switches.count, 7, "设置页应加载包含开关的表单")
        XCTAssertFalse(host.view.bounds.isEmpty)

        model.nightHDRPhotoEnabled = true
        model.independentNightProfile = .highlight
        let options = model.photoOptions
        XCTAssertTrue(options.nightHDRPhoto)
        XCTAssertEqual(options.nightProfile, .highlight)
        XCTAssertEqual(IndependentNightProfile.highlight.exposureOffsets, [0, 0, 0, -1, -2])
        XCTAssertFalse(IndependentNightProfile.allCases.contains { $0.exposureOffsets.contains { $0 > 0 } })
        print("NIGHT-SETTINGS-UI switches=\(switches.count) hdr=\(options.nightHDRPhoto) profile=\(options.nightProfile.rawValue)")
    }
}
