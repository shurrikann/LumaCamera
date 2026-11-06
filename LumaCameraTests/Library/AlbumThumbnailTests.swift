import XCTest
import UIKit
@testable import LumaCamera

final class AlbumThumbnailTests: XCTestCase {
    @MainActor
    func testLatestAccessiblePhotoUsesOnlySmallThumbnailRequest() {
        let service = ThumbnailService()
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refreshThumbnail()
        XCTAssertEqual(service.limits, [1])
        XCTAssertEqual(service.requestedIDs, ["newest"])
        XCTAssertEqual(service.sizes, [CGSize(width: 160, height: 160)])
        let image = UIImage()
        service.callbacks[0](image, nil)
        XCTAssertTrue(model.albumButtonImage === image)
    }

    @MainActor
    func testSavedCaptureNeverFlashesPreviousAssetWhilePhotosIndexCatchesUp() {
        let service = ThumbnailService()
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        service.entries = [LibraryPhoto(id: "previous", date: nil)]
        model.refreshThumbnail()
        let previous = UIImage()
        service.callbacks.last?(previous, nil)
        XCTAssertTrue(model.albumButtonImage === previous)
        let current = UIImage()
        library.acceptPhoto(current)
        library.savePhoto()
        XCTAssertTrue(model.albumButtonImage === current)
        // Photos may notify before the newly saved asset appears in fetch results.
        model.refreshThumbnail()
        XCTAssertTrue(model.albumButtonImage === current)
        service.callbacks.last?(previous, nil)
        XCTAssertTrue(model.albumButtonImage === current)
        service.entries = [LibraryPhoto(id: "newest", date: nil)]
        model.refreshThumbnail()
        XCTAssertTrue(model.albumButtonImage === current)
        let currentSystemThumbnail = UIImage()
        service.callbacks.last?(currentSystemThumbnail, nil)
        XCTAssertTrue(model.albumButtonImage === currentSystemThumbnail)
        // A refresh must retain that image until its replacement is actually available.
        model.refreshThumbnail()
        XCTAssertTrue(model.albumButtonImage === currentSystemThumbnail)
    }

    @MainActor
    func testCameraEntryDoesNotRequestNewPermissionOrReadDeniedLibrary() {
        for access in [PhotoLibraryAccess?.none, .some(.denied)] {
            let service = ThumbnailService(); service.existingAccess = access
            let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
            model.refreshThumbnail()
            XCTAssertEqual(service.authorizationCalls, 0)
            XCTAssertTrue(service.limits.isEmpty)
            XCTAssertNil(model.albumButtonImage)
        }
    }

    @MainActor
    func testOldThumbnailCallbackCannotOverwriteNewAssetOrRevokedAccess() {
        let service = ThumbnailService()
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refreshThumbnail()
        let old = service.callbacks[0]
        service.entries = [LibraryPhoto(id: "replacement", date: nil)]
        model.refreshThumbnail()
        XCTAssertEqual(service.cancellations, 1)
        let replacement = UIImage()
        service.callbacks[1](replacement, nil); old(UIImage(), nil)
        XCTAssertTrue(model.albumButtonImage === replacement)
        service.existingAccess = .denied; model.refreshThumbnail()
        service.callbacks[1](replacement, nil)
        XCTAssertNil(model.albumButtonImage)
    }

    @MainActor
    func testDeletedLastPhotoDoesNotKeepStaleCaptureThumbnail() {
        let service = ThumbnailService()
        let library = PhotoLibraryViewModel(service: service)
        library.acceptPhoto(UIImage()); library.savePhoto()
        let model = GalleryViewModel(browser: service, library: library)
        model.refreshThumbnail(); service.callbacks[0](UIImage(), nil)
        service.entries = []; model.refreshThumbnail()
        XCTAssertNil(model.albumButtonImage)
        XCTAssertNotNil(library.lastPhoto)
    }

    @MainActor
    func testLaunchWithExistingAccessRefreshesListAndClearsConfirmedDeletedCapture() {
        let service = ThumbnailService(), library = PhotoLibraryViewModel(service:ThumbnailService())
        library.acceptPhoto(UIImage()); library.savePhoto()
        service.availability = .missing
        service.entries = [LibraryPhoto(id:"external",date:Date().addingTimeInterval(10))]
        let model = GalleryViewModel(browser:service,library:library)
        model.refreshAfterForeground()
        XCTAssertEqual(model.photos.map(\.id),["external"])
        XCTAssertNil(library.savedPhotoID); XCTAssertNil(library.lastPhoto)
        let newest = UIImage(); service.callbacks.last?(newest,nil)
        XCTAssertTrue(model.albumButtonImage === newest)
    }

    @MainActor
    func testNewerExternalPhotoCanReplaceSavedCaptureThumbnailWithoutWaitingForSameAsset() {
        let service = ThumbnailService(), library = PhotoLibraryViewModel(service:ThumbnailService())
        library.acceptPhoto(UIImage()); library.savePhoto()
        service.entries = [LibraryPhoto(id:"external",date:Date().addingTimeInterval(10))]
        let model = GalleryViewModel(browser:service,library:library)
        model.refreshThumbnail()
        let newest = UIImage(); service.callbacks.last?(newest,nil)
        XCTAssertTrue(model.albumButtonImage === newest)
    }

    @MainActor
    func testCaptureShowsImmediatelyAndLibraryChangeLoadsLatestAccessibleAsset() {
        let service = ThumbnailService(); service.existingAccess = .limited
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        let capture = UIImage(); library.acceptPhoto(capture)
        XCTAssertTrue(model.albumButtonImage === capture)
        library.savePhoto()
        service.onLibraryChange?()
        XCTAssertEqual(service.requestedIDs.last, "newest")
        let newest = UIImage(); service.callbacks.last?(newest, nil)
        XCTAssertTrue(model.albumButtonImage === newest)
    }
}

private final class ThumbnailService: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var existingAccess: PhotoLibraryAccess? = .full
    var entries = [LibraryPhoto(id: "newest", date: nil)]
    var authorizationCalls = 0
    var limits: [Int] = []
    var requestedIDs: [String] = []
    var sizes: [CGSize] = []
    var callbacks: [(UIImage?, Error?) -> Void] = []
    var cancellations = 0
    var availability = PhotoAssetAvailability.unknown
    func photoAvailability(id:String,completion:@escaping(PhotoAssetAvailability)->Void) { completion(availability) }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { authorizationCalls += 1; completion(existingAccess ?? .denied) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) {
        limits.append(limit)
        completion(.init(photos: Array(entries.prefix(limit)), hasMore: false))
    }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        requestedIDs.append(id); sizes.append(size); callbacks.append(completion)
        return PhotoImageRequest { self.cancellations += 1 }
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("newest")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
