import XCTest
@testable import LumaCamera

final class AutomaticLensTransitionTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testSystemLensNotificationsDoNotCreatePreviewAnimationsOrHeldFramesAcrossAllRatios() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 { if model.camera.ready && model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(model.camera.ready)
        for ratio in FrameRatio.allCases {
            model.ratio = ratio
            try await Task.sleep(for: .milliseconds(80))
            model.camera.onAutomaticLensChange?()
            XCTAssertNil(model.focalTransitionImage, "Automatic switching must never superimpose a held frame")
            XCTAssertNil(model.resumeTransitionImage)
            for _ in 0..<20 { model.camera.onAutomaticLensChange?() }
            XCTAssertNil(model.focalTransitionImage, "Repeated events must not create ghost frames")
            model.camera.updateLook(model.effectiveCaptureLook)
            await Task.yield()
            XCTAssertNil(model.focalTransitionImage); XCTAssertNil(model.resumeTransitionImage)
        }
        model.setMode(.manual)
        for _ in 0..<100 { if model.focalTransitionImage == nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.camera.onAutomaticLensChange?()
        XCTAssertNil(model.focalTransitionImage)
        model.setMode(.auto)
        for _ in 0..<100 { if model.focalTransitionImage == nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.review = true
        model.camera.onAutomaticLensChange?()
        XCTAssertNil(model.focalTransitionImage)
    }
    #endif
}
