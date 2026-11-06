import XCTest
import UIKit
@testable import LumaCamera

final class PhotoPageLoaderTests: XCTestCase {
    @MainActor func testDestinationIsOnlyCommittedAfterImageArrivesAndOnlyOnce() async {
        let browser = PageBrowserStub()
        let loader = PhotoPageLoader(browser: browser)
        var images: [UIImage] = []
        loader.prepare(.asset(LibraryPhoto(id: "next", date: nil)), capture: nil) { images.append($0) }
        XCTAssertTrue(loader.loading); XCTAssertTrue(images.isEmpty)
        let preview = UIImage()
        browser.callbacks[0](preview, nil)
        await drain()
        XCTAssertFalse(loader.loading); XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images[0] === preview)
        browser.callbacks[0](UIImage(), nil)
        await drain()
        XCTAssertEqual(images.count, 1)
    }
    @MainActor func testCancelSupersededRequestsAndFailuresKeepCurrentPage() async {
        let browser = PageBrowserStub()
        let loader = PhotoPageLoader(browser: browser)
        var selected = "current"
        loader.prepare(.asset(LibraryPhoto(id: "old", date: nil)), capture: nil) { _ in selected = "old" }
        loader.prepare(.asset(LibraryPhoto(id: "new", date: nil)), capture: nil) { _ in selected = "new" }
        browser.callbacks[0](UIImage(), nil)
        await drain()
        XCTAssertEqual(selected, "current"); XCTAssertTrue(loader.loading)
        browser.callbacks[1](nil, PhotoLibraryError.inaccessible)
        await drain()
        XCTAssertEqual(selected, "current"); XCTAssertFalse(loader.loading); XCTAssertNotNil(loader.message)
        loader.prepare(.capture, capture: UIImage()) { _ in selected = "capture" }
        loader.cancel()
        await drain()
        XCTAssertEqual(selected, "current")
        XCTAssertGreaterThanOrEqual(browser.cancels, 2)
    }
    @MainActor func testSeededDetailNeverStartsWithAnEmptyImage() {
        let browser = PageBrowserStub()
        let library = PhotoLibraryViewModel(service: browser)
        let gallery = GalleryViewModel(browser: browser, library: library)
        let image = UIImage()
        let detail = PhotoDetailViewModel(photo: LibraryPhoto(id: "next", date: nil), gallery: gallery, initialImage: image)
        XCTAssertTrue(detail.image === image)
        detail.load()
        XCTAssertTrue(detail.image === image)
        detail.cancelLoading()
        browser.callbacks[0](UIImage(), nil)
        XCTAssertTrue(detail.image === image)
    }
    @MainActor private func drain() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
}
private final class PageBrowserStub: PhotoBrowserService, PhotoLibraryService {
    var onLibraryChange: (() -> Void)?
    var callbacks: [(UIImage?, Error?) -> Void] = []
    var cancels = 0
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        callbacks.append(completion); return PhotoImageRequest { self.cancels += 1 }
    }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("saved")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
