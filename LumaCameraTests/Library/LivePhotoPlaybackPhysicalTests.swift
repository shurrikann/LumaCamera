import XCTest
import SwiftUI
import Photos
import PhotosUI
@testable import LumaCamera

final class LivePhotoPlaybackPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testDetailLongPressPlaysSavedLiveWithSoundAndReleaseRestoresStill() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let oldCallback = camera.onCaptureCompleted, oldLook = model.effectiveCaptureLook
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var captured: CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0 }
        defer {
            camera.onCaptureCompleted = oldCallback; camera.updateLook(oldLook); camera.stop()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        camera.updateLook(CaptureLook()); camera.start()
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg, live: true))
        for _ in 0..<600 { if captured != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        let capturedPhoto = try XCTUnwrap(captured, camera.message ?? "Capture Live without saving to Photos")
        let source = LivePhotoPlaybackSource(resources: capturedPhoto.resources)
        let loader = LivePhotoPlayback()
        loader.press(true, source: source, size: CGSize(width: 390, height: 650))
        for _ in 0..<300 { if loader.photo != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        let live = try XCTUnwrap(loader.photo)
        XCTAssertTrue(loader.holding); XCTAssertFalse(loader.loading)
        loader.press(false, source: source, size: .zero)
        XCTAssertFalse(loader.holding); XCTAssertNotNil(loader.photo, "Keep a bounded cached Live for repeated holds")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let preview = capturedPhoto.preview
        window.rootViewController = UIHostingController(rootView: PhotoViewerLayout(image: preview, date: Date(), isLive: true, liveSource: source,
                                                onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {}).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { loader.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        let zoom = try XCTUnwrap(find(PhotoZoomScrollView.self, in: window).first)
        zoom.beginLivePress()
        for _ in 0..<200 { if !find(PHLivePhotoView.self, in: window).isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
        let playback = try XCTUnwrap(find(PHLivePhotoView.self, in: window).first)
        XCTAssertNotNil(playback.livePhoto); XCTAssertFalse(playback.isMuted)
        for _ in 0..<80 {
            if (playback as? HoldLivePhotoView)?.fullPlaybackBeginCount ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan((playback as? HoldLivePhotoView)?.fullPlaybackBeginCount ?? 0, 0, "Must start full video playback after attaching, not only display the still image")
        try await Task.sleep(for: .milliseconds(500))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) })
        attachment.name = "Live-Detail-Hold-Playback"; attachment.lifetime = .keepAlways; add(attachment)
        zoom.endLivePress()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(find(PHLivePhotoView.self, in: window).isEmpty)
        XCTAssertTrue(find(PhotoZoomScrollView.self, in: window).first?.photoView.image === preview)
        // A second hold must still find the retained local movie.
        zoom.beginLivePress()
        for _ in 0..<120 { if !find(PHLivePhotoView.self, in: window).isEmpty { break }; try await Task.sleep(for: .milliseconds(25)) }
        let repeated = try XCTUnwrap(find(HoldLivePhotoView.self, in: window).first)
        for _ in 0..<80 { if repeated.fullPlaybackBeginCount > 0 { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThan(repeated.fullPlaybackBeginCount, 0)
        zoom.endLivePress()
        _ = live
    }
    @MainActor private func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) } }
    #endif
}
