import XCTest
@testable import LumaCamera

final class LivePhotoOptionsTests: XCTestCase {
    func testLiveNeverRequestsAnUnsupportedRAWOrHighResolutionCombination() {
        for format in PhotoFileFormat.allCases {
            for resolution in PhotoResolution.allCases {
                let options = PhotoOptions(format: format, resolution: resolution, live: true)
                XCTAssertEqual(options.capturesLive, (format == .jpeg || format == .heif) && resolution == .standard)
                XCTAssertFalse(PhotoOptions(format: format, resolution: resolution).capturesLive)
            }
        }
    }
    @MainActor func testUnavailableLiveToggleDoesNotShowAnInstructionToCloseFeatures() {
        let model=AppDependencies.makeCameraModel(automaticallySave:false)
        model.photoFormat = .raw
        model.toggleLivePhoto()
        XCTAssertFalse(model.livePhotoEnabled); XCTAssertNil(model.camera.message)
    }
    @MainActor func testSlowShutterDisablesLiveAndCannotBeReenabled() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<750 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route")
        if model.livePhotoAvailable && !model.livePhotoEnabled { model.toggleLivePhoto() }
        model.toggleSlowShutterMode()
        try XCTSkipUnless(model.slowShutterEnabled, "Slow shutter unavailable on this route")
        XCTAssertFalse(model.livePhotoAvailable)
        XCTAssertFalse(model.canToggleLivePhoto)
        XCTAssertFalse(model.capturesLivePhoto)
        XCTAssertFalse(model.livePhotoEnabled)
        model.toggleLivePhoto()
        XCTAssertFalse(model.livePhotoEnabled)
    }

    @MainActor func testOnlyHEIFProAppliesProToneAndSwitchingFormatClosesItsPanel() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.tone = .contrast; model.photoFormat = .heifPro; model.toolbarPanel = .tone
        XCTAssertEqual(model.effectiveCaptureLook.tone, .contrast)
        model.photoFormat = .jpeg
        XCTAssertNil(model.toolbarPanel)
        XCTAssertEqual(model.effectiveCaptureLook.tone, .natural)
        model.photoFormat = .heifPro
        XCTAssertEqual(model.tone, .contrast)
    }
}
