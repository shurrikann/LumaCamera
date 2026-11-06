import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class PhotoPagingAnimationTests: XCTestCase {
    @MainActor func testVisiblePhotoSurvivesDelayedLoadThenBothPagesParticipateInTransition() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first(where: \.isKeyWindow)
        let browser = AnimatedPageBrowser()
        let library = PhotoLibraryViewModel(service: browser)
        let gallery = GalleryViewModel(browser: browser, library: library)
        let photos = [LibraryPhoto(id: "first", date: nil), LibraryPhoto(id: "second", date: nil)]
        let first = image(.red), second = image(.blue)
        browser.images["first"] = first
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            PhotoPagingView(model: gallery, library: library, initial: .asset(photos[0]), photos: photos, isDemo: true, canLoadMore: false, onCamera: {})
        }.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey() }
        for _ in 0..<100 { if zooms(window).contains(where: { $0.photoView.image === first }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let current = try XCTUnwrap(zooms(window).first { $0.photoView.image === first })
        try await Task.sleep(for: .milliseconds(200))
        let before = capture(window)
        current.page(1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(zooms(window).contains { $0.photoView.image === first }, "Keep current photo during loading")
        XCTAssertFalse(zooms(window).contains { $0.photoView.image === second })
        assertPhotoMovesAndControlsStayFixed(before: before, during: capture(window), moving: false)
        browser.images["second"] = second
        try XCTUnwrap(browser.pending["second"])(second, nil)
        try await Task.sleep(for: .milliseconds(100))
        let during = zooms(window)
        XCTAssertEqual(during.count, 1, "Only the incoming photo owns the zoom view; outgoing image is a frozen viewport layer")
        XCTAssertTrue(during.contains { $0.photoView.image === second }, "Incoming page starts with its ready image")
        assertPhotoMovesAndControlsStayFixed(before: before, during: capture(window))
        snapshot(window, name: "Paging-Mid-Transition")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(zooms(window).count, 1)
        XCTAssertTrue(zooms(window).first?.photoView.image === second)
        snapshot(window, name: "Paging-Completed")
        try XCTUnwrap(zooms(window).first).page(-1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(zooms(window).count, 1)
        assertPhotoMovesAndControlsStayFixed(before: before, during: capture(window))
        snapshot(window, name: "Paging-Reverse-Transition")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(zooms(window).count, 1)
        XCTAssertTrue(zooms(window).first?.photoView.image === first)
    }
    @MainActor func testRAWBadgeAndLocationHeaderAcrossEveryPhotoRatio() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first(where: \.isKeyWindow)
        let location = PhotoLocation(latitude: 34.25, longitude: 108.95, timestamp: Date(timeIntervalSince1970: 0))
        func layout(_ image: UIImage, live: Bool = false) -> PhotoViewerLayout {
            PhotoViewerLayout(image: image, date: Date(timeIntervalSince1970: 1_700_000_000), location: location, isRAW: !live, isLive: live,
                              onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {})
        }
        let host = UIHostingController(rootView: layout(image(.gray)))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey() }
        for ratio in FrameRatio.allCases {
            let size = CGSize(width: 300, height: 300 / ratio.portraitRatio)
            let photo = UIGraphicsImageRenderer(size: size).image { _ in UIColor.darkGray.setFill(); UIRectFill(CGRect(origin: .zero, size: size)) }
            host.rootView = layout(photo)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(zooms(window).count, 1)
            snapshot(window, name: "RAW-Header-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-"))
            host.rootView = layout(photo, live: true)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(zooms(window).count, 1)
            snapshot(window, name: "LIVE-Header-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-"))
        }
    }
        @MainActor private func zooms(_ view: UIView) -> [PhotoZoomScrollView] {
        (view as? PhotoZoomScrollView).map { [$0] } ?? view.subviews.flatMap { zooms($0) }
    }
    @MainActor private func capture(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
    }
    private func assertPhotoMovesAndControlsStayFixed(before: UIImage, during: UIImage, moving: Bool = true) {
        func pixels(_ image: UIImage) -> [UInt8] {
            let cg = image.cgImage!
            var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress!, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return data
        }
        let a = pixels(before), b = pixels(during), width = before.cgImage!.width, height = before.cgImage!.height
        var difference = 0.0, samples = 0.0, red = 0, blue = 0
        for y in 0..<height {
            if y < height / 8 || y > height * 7 / 8 {
                for x in 0..<width { for channel in 0..<3 {
                    let index = (y * width + x) * 4 + channel
                    difference += abs(Double(a[index]) - Double(b[index])); samples += 1
                } }
            }
        }
        for x in 0..<width {
            let index = (height / 2 * width + x) * 4
            if b[index] > 200 && b[index + 2] < 50 { red += 1 }
            if b[index + 2] > 200 && b[index] < 50 { blue += 1 }
        }
        XCTAssertLessThan(difference / samples, 0.5, "Top and bottom controls must remain visually stationary")
        if moving {
            XCTAssertGreaterThan(red, width / 30)
            XCTAssertGreaterThan(blue, width / 30)
        }
    }
    @MainActor private func snapshot(_ window: UIWindow, name: String) {
        let image = capture(window)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { _ in color.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400)) }
    }
}
private final class AnimatedPageBrowser: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var images: [String: UIImage] = [:]
    var pending: [String: (UIImage?, Error?) -> Void] = [:]
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        if let image = images[id] { completion(image, nil) } else { pending[id] = completion }
        return PhotoImageRequest(cancel: {})
    }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("saved")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
