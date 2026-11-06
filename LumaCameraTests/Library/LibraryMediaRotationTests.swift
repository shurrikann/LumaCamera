import XCTest
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import LumaCamera

final class LibraryMediaRotationTests: XCTestCase {
    @MainActor func testPhotoFitRotationAndStableControlsOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("照片旋转渲染需真机复测")
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        var costs: [Double] = [], count = 0
        for width: CGFloat in [320, scene.screen.bounds.width] {
            for ratio in FrameRatio.photoOptions {
                for aspect in [ratio.portraitRatio, 1 / ratio.portraitRatio] {
                    let image = fixture(size: CGSize(width: 240, height: 240 / aspect))
                    var portrait = CGSize.zero
                    for angle in [0.0, 90, -90, 180] {
                        host.rootView = AnyView(viewer(image).frame(width: width)
                            .environment(\.libraryMediaAngle, angle).environment(\.captureControlAngle, 0))
                        try await Task.sleep(for: .milliseconds(260))
                        window.layoutIfNeeded()
                        let zoom = try XCTUnwrap(zooms(window).first)
                        zoom.layoutIfNeeded()
                        XCTAssertTrue(zoom.photoView.image === image)
                        XCTAssertEqual(zoom.pagingAngle, angle)
                        XCTAssertEqual(zoom.zoomScale, 1, accuracy: 0.01)
                        if angle == 0 { portrait = zoom.bounds.size }
                        let expected = LibraryMediaRotation.canvasSize(portrait, angle: angle)
                        let deadline = CACurrentMediaTime() + 2
                        while (abs(zoom.bounds.width - expected.width) > 0.5 || abs(zoom.bounds.height - expected.height) > 0.5), CACurrentMediaTime() < deadline {
                            try await Task.sleep(for: .milliseconds(20)); window.layoutIfNeeded()
                        }
                        XCTAssertEqual(zoom.bounds.width, expected.width, accuracy: 1)
                        XCTAssertEqual(zoom.bounds.height, expected.height, accuracy: 1)
                        let fit = PhotoRAWBadgeLayout.fit(image: image.size, viewport: zoom.bounds.size)
                        XCTAssertEqual(zoom.photoView.bounds.width, fit.width, accuracy: 1)
                        XCTAssertEqual(zoom.photoView.bounds.height, fit.height, accuracy: 1)
                        let rect = zoom.photoView.convert(zoom.photoView.bounds, to: zoom)
                        XCTAssertGreaterThanOrEqual(rect.minX, -1); XCTAssertGreaterThanOrEqual(rect.minY, -1)
                        XCTAssertLessThanOrEqual(rect.maxX, zoom.bounds.width + 1)
                        XCTAssertLessThanOrEqual(rect.maxY, zoom.bounds.height + 1)
                        if width == scene.screen.bounds.width && aspect > 1 && ratio == .standard {
                            let began = CACurrentMediaTime()
                            let shot = snapshot(window)
                            costs.append((CACurrentMediaTime() - began) * 1000)
                            let a = XCTAttachment(image: shot); a.name = "Landscape-photo-angle-\(angle)"; a.lifetime = .keepAlways; add(a)
                        }
                        count += 1
                    }
                }
            }
        }
        // Keep one actual UIView alive during rapid turns, pinch, cancellation and return.
        let image = fixture(size: CGSize(width: 480, height: 320))
        func display(_ angle: Double) {
            host.rootView = AnyView(viewer(image).environment(\.libraryMediaAngle, angle)
                .environment(\.captureControlAngle, 0))
        }
        display(0); try await Task.sleep(for: .milliseconds(300))
        let first = try XCTUnwrap(zooms(window).first)
        let before = snapshot(window)
        first.setZoomScale(3, animated: false)
        display(90); try await Task.sleep(for: .milliseconds(300))
        let current = try XCTUnwrap(zooms(window).first)
        XCTAssertTrue(current === first); XCTAssertEqual(current.zoomScale, 1, accuracy: 0.01)
        let after = snapshot(window)
        assertBottomControlsEqual(before, after)
        for angle in (0..<40).map({ Double(($0 % 4) * 90) }) { display(angle); await Task.yield() }
        display(0); try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(zooms(window).first === first); XCTAssertTrue(first.photoView.image === image)
        // Dismiss and reopen while sideways: no retained magnified viewport or blank media.
        host.rootView = AnyView(Color.black); await Task.yield()
        display(-90); try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try XCTUnwrap(zooms(window).first).photoView.image === image)
        print("PHOTO_ROTATION_LAYOUT count=\(count) rapid=40 snapshotsMS=\(costs)")
        #endif
    }

    @MainActor func testThumbnailOrientationDoesNotReloadPhotoOrMoveCell() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let service = RotationBrowser(image: fixture(size: CGSize(width: 480, height: 320)))
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        var costs: [Double] = []
        for isVideo in [false, true] {
        for angle in [0.0, 90, -90, 180, 0, 90, 0, -90, 0] {
            host.rootView = AnyView(VStack {
                LibraryMediaThumbnail(image: service.image).frame(width: 52, height: 52).clipShape(Circle())
                LibraryImageView(photo: LibraryPhoto(id: isVideo ? "video" : "photo", date: nil, isVideo: isVideo), browser: service, size: CGSize(width: 360, height: 360))
                    .frame(width: 130, height: 130)
            }.environment(\.libraryMediaAngle, angle))
            try await Task.sleep(for: .milliseconds(260))
            let began = CACurrentMediaTime(), shot = snapshot(window)
            costs.append((CACurrentMediaTime() - began) * 1000)
            if angle == 90 || angle == 0 { let a = XCTAttachment(image: shot); a.name = "Thumbnail-video-\(isVideo)-angle-\(angle)"; a.lifetime = .keepAlways; add(a) }
        }
        }
        XCTAssertEqual(service.requests, 2, "Each photo/video poster loads once; turns cannot reload it")
        host.rootView = AnyView(Color.black); try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(service.cancels, 2)
        print("PHOTO_ROTATION_THUMB requests=\(service.requests) cancels=\(service.cancels) snapshotsMS=\(costs)")
    }

    @MainActor func testScreenPagingAndLiveCancellationAfterRotation() {
        let directions: [UISwipeGestureRecognizer.Direction] = [.left, .right, .up, .down]
        for angle in [0.0, 90, -90, 180, 270, 360] {
            let steps = directions.compactMap { LibraryMediaRotation.pageStep(direction: $0, angle: angle) }
            XCTAssertEqual(steps.sorted(), [-1, 1])
        }
        XCTAssertEqual(LibraryMediaRotation.pageStep(direction: .down, angle: 90), 1)
        XCTAssertEqual(LibraryMediaRotation.pageStep(direction: .up, angle: -90), 1)
        let scroll = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scroll.display(fixture(size: CGSize(width: 480, height: 320))); scroll.layoutIfNeeded()
        var presses: [Bool] = []
        scroll.onSwipe = { _ in }
        scroll.onLivePress = { presses.append($0) }
        scroll.beginLivePress(); XCTAssertFalse(scroll.canPage)
        scroll.updatePagingAngle(90)
        XCTAssertEqual(presses, [true, false]); XCTAssertTrue(scroll.canPlayLive); XCTAssertTrue(scroll.canPage)
        for angle in [0.0, 90, -90, 180] {
            scroll.updatePagingAngle(angle)
            let swipes = (scroll.gestureRecognizers ?? []).compactMap { $0 as? UISwipeGestureRecognizer }
            XCTAssertEqual(swipes.filter { $0.delegate?.gestureRecognizerShouldBegin?($0) == true }.count, 2)
            let translation = LibraryMediaRotation.screenTranslation(CGSize(width: 0, height: -50), angle: angle)
            if abs(angle) == 90 {
                XCTAssertEqual(GalleryPhotoPaging.swipeStep(horizontal: translation.width, vertical: translation.height), angle == 90 ? -1 : 1)
            }
        }
        scroll.setZoomScale(3, animated: false); scroll.updatePagingAngle(-90)
        XCTAssertEqual(scroll.zoomScale, 1, accuracy: 0.01)
    }

    @MainActor func testAllEXIFOrientationsRemainUntouched() throws {
        let cg = try XCTUnwrap(fixture(size: CGSize(width: 480, height: 320)).cgImage)
        for tag in 1...8 {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: tag] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = data as Data, image = try XCTUnwrap(UIImage(data: original))
            let scroll = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
            scroll.display(image)
            for angle in [0.0, 90, -90, 180] { scroll.updatePagingAngle(angle); scroll.layoutIfNeeded() }
            XCTAssertTrue(scroll.photoView.image === image)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, tag)
            XCTAssertEqual(data as Data, original)
        }
    }

    @MainActor func testPresentedGalleryDropsStaleCameraAngleAndFollowsCurrentPose() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let image = fixture(size: CGSize(width: 480, height: 320)), service = RotationBrowser(image: fixture(size: CGSize(width: 480, height: 320)))
        let library = PhotoLibraryViewModel(service: service); library.acceptPhoto(image)
        let gallery = GalleryViewModel(browser: service, library: library)
        let orientation = CaptureControlOrientation()
        let host = UIHostingController(rootView: Color.black.fullScreenCover(isPresented: .constant(true)) {
            GalleryView(model: gallery, library: library, isDemo: true, openLatestCapture: true, mediaOrientation: orientation, onCamera: {})
        }.environment(\.libraryMediaAngle, 90).environment(\.videoPlaybackAngle, 90))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        let deadline = CACurrentMediaTime() + 8
        while zooms(window).isEmpty && CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let zoom = try XCTUnwrap(zooms(window).first)
        var costs: [Double] = []
        for pose: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait, .portraitUpsideDown, .portrait] {
            orientation.update(pose)
            let target = try XCTUnwrap(CaptureControlOrientation.angle(for: pose))
            let began = CACurrentMediaTime()
            let end = began + 2
            while abs(CaptureControlOrientation.shortestDelta(from: zoom.pagingAngle, to: target)) > 0.1 && CACurrentMediaTime() < end {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(CaptureControlOrientation.shortestDelta(from: zoom.pagingAngle, to: target), 0, accuracy: 0.1)
            XCTAssertTrue(zoom.photoView.image === image)
            costs.append((CACurrentMediaTime() - began) * 1000)
        }
        orientation.update(.landscapeLeft)
        for pose: UIDeviceOrientation in [.unknown, .faceUp, .faceDown, .portrait] {
            orientation.resetForMediaPresentation(pose)
            XCTAssertEqual(orientation.degrees, 0)
        }
        try await Task.sleep(for: .milliseconds(320))
        let shot = XCTAttachment(image: snapshot(window)); shot.name = "Gallery-stale-camera-90-return-portrait"; shot.lifetime = .keepAlways; add(shot)
        print("GALLERY_MEDIA_CURRENT_POSE samples=\(costs.count) publishObservedMS=\(costs)")
    }

    @MainActor private func viewer(_ image: UIImage) -> some View {
        PhotoViewerLayout(image: image, date: nil, onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {}, onSwipe: { _ in })
            .preferredColorScheme(.dark)
    }
    @MainActor private func zooms(_ view: UIView) -> [PhotoZoomScrollView] {
        (view as? PhotoZoomScrollView).map { [$0] } ?? view.subviews.flatMap { zooms($0) }
    }
    @MainActor private func fixture(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
            UIColor.systemTeal.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 25, height: 25))
            UIColor.blue.setFill(); UIRectFill(CGRect(x: size.width - 25, y: 0, width: 25, height: 25))
            UIColor.yellow.setFill(); UIRectFill(CGRect(x: 0, y: size.height - 25, width: 25, height: 25))
            UIColor.white.setFill(); UIRectFill(CGRect(x: size.width - 25, y: size.height - 25, width: 25, height: 25))
        }
    }
    @MainActor private func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }
    private func assertBottomControlsEqual(_ a: UIImage, _ b: UIImage) {
        func pixels(_ image: UIImage) -> [UInt8] {
            let cg = image.cgImage!; var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            bytes.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }; return bytes
        }
        let x = pixels(a), y = pixels(b), width = a.cgImage!.width, height = a.cgImage!.height
        var difference = 0.0, samples = 0.0
        for row in (height * 9 / 10)..<height { for col in 0..<(width * 4) {
            difference += abs(Double(x[row * width * 4 + col]) - Double(y[row * width * 4 + col])); samples += 1
        } }
        XCTAssertLessThan(difference / samples, 0.5, "Bottom controls stay upright in the same positions")
    }
}

private final class RotationBrowser: PhotoBrowserService, PhotoLibraryService {
    let image: UIImage
    var requests = 0, cancels = 0
    init(image: UIImage) { self.image = image }
    var onLibraryChange: (() -> Void)?
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { XCTFail("Diagnostic media must not be saved"); completion(.failure(CancellationError())) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { XCTFail("Diagnostic media must not be deleted"); completion(.failure(CancellationError())) }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        requests += 1; completion(image, nil); return PhotoImageRequest { self.cancels += 1 }
    }
}
