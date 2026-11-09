import UIKit
import XCTest
@testable import LumaCamera

final class VideoEntryWatchdogLifecycleTests: XCTestCase {
    @MainActor func testCameraDeactivationCancelsVideoEntryWatchdog() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        defer { model.setCameraActive(false) }
        model.setCaptureKind(.video)
        model.armVideoEntryWatchdogForTesting()
        XCTAssertTrue(model.videoEntryWatchdogActiveForTesting)
        model.setCameraActive(false)
        XCTAssertFalse(model.videoEntryWatchdogActiveForTesting,
                       "后台/离页后不能让入口 watchdog 在休眠期间继续计时")
    }
}
