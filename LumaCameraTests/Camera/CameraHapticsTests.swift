import UIKit
import XCTest
@testable import LumaCamera

final class CameraHapticsTests: XCTestCase {
    @MainActor func testToolbarPanelSwitchEmitsFeedbackWhenAnotherPanelIsOpen() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        defer { model.setCameraActive(false); CameraHaptics.recorderForTesting = nil }
        var kinds: [CameraHaptics.FeedbackKind] = []
        CameraHaptics.recorderForTesting = { kinds.append($0) }
        model.toolbarPanel = nil
        model.toggleToolbarPanel(.format)
        model.toggleToolbarPanel(.ratio)
        model.toggleToolbarPanel(.ratio)
        XCTAssertEqual(kinds.filter { if case .impact = $0 { return true }; return false }.count, 3,
                       "打开面板后切换/关闭另一个顶部面板仍必须触发触感")
        XCTAssertEqual(model.toolbarPanel, nil)
    }
}
