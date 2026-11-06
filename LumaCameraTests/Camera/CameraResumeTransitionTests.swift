import XCTest
@testable import LumaCamera

final class CameraResumeTransitionTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testAlbumReturnWaitsForFreshPreviewThenReleasesSnapshotForEveryRatio() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 { if model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        for ratio in FrameRatio.allCases {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(60))
            let before = try XCTUnwrap(model.camera.preview)
            model.openLibrary()
            XCTAssertTrue(model.resumeTransitionImage === before)
            model.setCameraActive(false)
            await Task.yield()
            await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
            model.review = false
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(model.resumeTransitionOpacity, 1, "Never fade to a stale pre-album frame")
            model.setCameraActive(true)
            for _ in 0..<100 { if model.resumeTransitionImage == nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(model.resumeTransitionImage)
            XCTAssertTrue(model.camera.ready)
            XCTAssertFalse(model.camera.preview === before)
        }
    }
    #endif
}
