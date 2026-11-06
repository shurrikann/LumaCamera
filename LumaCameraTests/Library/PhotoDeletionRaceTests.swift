import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class PhotoDeletionRaceTests: XCTestCase {
    func testRepeatedAndDelayedDeletionCallbacksCannotSkipTheImmediateNeighbor() throws {
        let first = GalleryRoute.asset(LibraryPhoto(id: "older-1", date: nil))
        let second = GalleryRoute.asset(LibraryPhoto(id: "older-2", date: nil))
        var navigation = PhotoDeletionNavigation()
        let request = try XCTUnwrap(navigation.begin(from: .capture, current: .capture))
        for _ in 0..<20 {
            XCTAssertNil(navigation.begin(from: .capture, current: .capture), "Repeated notifications must not consume a second fallback while the first image loads")
        }
        XCTAssertTrue(navigation.matches(request, current: .capture))
        navigation.finish(request)
        XCTAssertNil(navigation.begin(from: .capture, current: first), "A late callback still belongs to the deleted photo, not its neighbor")
        let next = try XCTUnwrap(navigation.begin(from: first, current: first))
        navigation.finish(request)
        XCTAssertTrue(navigation.matches(next, current: first), "An old completion cannot cancel the next legitimate deletion")
        XCTAssertFalse(navigation.matches(next, current: second))
    }

    func testMixedMediaDeletionCanContinueAfterEachCommittedPageAndRejectLateCallbacks() throws {
        var navigation = PhotoDeletionNavigation()
        let started = Date()
        var current = GalleryRoute.asset(LibraryPhoto(id: "first", date: nil))
        for index in 0..<100 {
            let origin = current
            let token = try XCTUnwrap(navigation.begin(from: origin, current: current))
            let next = GalleryRoute.asset(LibraryPhoto(id: "next-\(index)", date: nil, isVideo: index.isMultiple(of: 2)))
            XCTAssertFalse(GalleryPhotoPaging.requiresImagePreload(next, afterDeletion: true), "删除完成后不能被下一张的网络下载阻塞")
            current = next
            navigation.finish(token)
            XCTAssertNil(navigation.begin(from: origin, current: current), "旧删除完成通知不能再次跳页")
            XCTAssertNil(navigation.token, "切到视频或照片都必须释放删除事务")
        }
        print("GALLERY-DELETION transactions=100 logic-seconds=\(Date().timeIntervalSince(started)); 不含 PhotoKit 确认或图像下载延迟")
    }

    @MainActor func testExternalCacheClearDoesNotAlsoReportALocalDeletion() async throws {
        #if targetEnvironment(simulator)
        let browser = DeletionRaceBrowser()
        let library = PhotoLibraryViewModel(service: browser)
        library.acceptPhoto(browser.image); library.savePhoto(showSuccessMessage: false)
        XCTAssertEqual(library.savedPhotoID, "capture")
        var localDeletionCallbacks = 0
        let view = PhotoReview(model: library, isDemo: true, browser: browser, onCamera: {}, onDeleted: { localDeletionCallbacks += 1 })
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        library.clearExternallyDeletedPhoto(assetID: "capture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(library.lastPhoto)
        XCTAssertEqual(localDeletionCallbacks, 0, "The paging parent's availability event already owns external-deletion navigation")
        #endif
    }

    @MainActor func testLocalDeletionCompletionOnlyFollowsSuccessfulMatchingDeletion() {
        let service = DeletionRaceBrowser(), library = PhotoLibraryViewModel(service: DeletionRaceBrowser())
        let model = PhotoLibraryViewModel(service: service)
        model.acceptPhoto(service.image); model.savePhoto(showSuccessMessage: false)
        var results: [Bool] = []
        model.deletePhoto { results.append($0) }
        XCTAssertTrue(results.isEmpty)
        service.deleteCompletion?(.failure(PhotoLibraryError.inaccessible))
        XCTAssertEqual(results, [false]); XCTAssertNotNil(model.lastPhoto)
        model.deletePhoto { results.append($0) }
        service.deleteCompletion?(.success(()))
        XCTAssertEqual(results, [false, true]); XCTAssertNil(model.lastPhoto)
        library.deletePhoto { XCTAssertFalse($0) }
    }
}

private final class DeletionRaceBrowser: PhotoBrowserService, PhotoLibraryService {
    var onLibraryChange: (() -> Void)?
    var deleteCompletion: ((Result<Void, Error>) -> Void)?
    let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
        UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        completion(image, nil); return PhotoImageRequest(cancel: {})
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("capture")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { deleteCompletion = completion }
}
