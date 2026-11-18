import XCTest
@testable import LumaCamera

final class AstroRouteFormatPhysicalTests: XCTestCase {
    @MainActor func testAstroRouteSwitchesTo12MPAndRestoresPhotoFormat() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实相机")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        let original = await format(camera)
        camera.enterAstroRoute()
        try await Task.sleep(for: .milliseconds(600))
        let astro = await format(camera)
        XCTAssertEqual(astro, "4032x3024", "astro must use the 12MP shared session format")
        camera.exitAstroRoute()
        try await Task.sleep(for: .milliseconds(600))
        let restored = await format(camera)
        XCTAssertEqual(restored, original, "exiting astro must restore the photo active format")
        #endif
    }

    @MainActor private func format(_ camera: CameraEngine) async -> String {
        await withCheckedContinuation { c in camera.astroActiveFormatForTesting { c.resume(returning: $0) } }
    }
}
