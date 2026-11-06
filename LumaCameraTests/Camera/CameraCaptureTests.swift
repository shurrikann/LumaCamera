import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class CameraCaptureTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor
    func testCaptureAutomaticallyPersistsBeforeRequiringAnyConfirmation() async {
        let service = CapturePhotoServiceStub()
        let model = AppDependencies.makeCameraModel(photoService: service)
        let ready = expectation(description: "Camera ready for automatic-save capture")
        let readySubscription = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        let saving = expectation(description: "Automatic save started")
        let saveSubscription = model.library.$saving.filter { $0 }.first().sink { _ in saving.fulfill() }
        model.takePhoto()
        await fulfillment(of: [saving], timeout: 5)
        XCTAssertFalse(model.camera.capturing)
        XCTAssertFalse(model.library.captureInProgress)
        XCTAssertEqual(service.saveCount, 1)
        XCTAssertFalse(service.savedResources.isEmpty)
        service.finishSave()
        XCTAssertTrue(model.library.photoSaved)
        XCTAssertNil(model.library.message)
        model.camera.stop()
        withExtendedLifetime((readySubscription, saveSubscription)) {}
    }

    @MainActor
    func testDemoCaptureUsesSelectedLookAndStopDisablesShutter() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let camera = model.camera
        let library = model.library
        let ready = expectation(description: "Camera ready")
        let readySubscription = camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        camera.start()
        await fulfillment(of: [ready], timeout: 5)
        let captured = expectation(description: "Photo processed")
        let photoSubscription = library.$lastPhoto.compactMap { $0 }.first().sink { _ in captured.fulfill() }
        camera.updateLook(CaptureLook(style: .mono, intensity: 1, ratio: .square, border: true))
        camera.capture(flash: false)
        await fulfillment(of: [captured], timeout: 5)
        let image = try XCTUnwrap(library.lastPhoto)
        XCTAssertEqual(image.size.width, 963, accuracy: 1)
        XCTAssertEqual(image.size.height, 1071, accuracy: 1)
        // Preview remains full-frame even though the captured photograph is cropped square.
        XCTAssertEqual(camera.preview?.size.width, 900)
        XCTAssertEqual(camera.preview?.size.height, 1200)
        XCTAssertFalse(camera.capturing)
        camera.stop()
        XCTAssertFalse(camera.ready)
        library.deletePhoto()
        XCTAssertNil(library.lastPhoto)
        XCTAssertFalse(library.photoSaved)
        XCTAssertFalse(library.deleting)
        withExtendedLifetime((readySubscription, photoSubscription)) {}
    }
    #endif

}

private final class CapturePhotoServiceStub: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var saveCount = 0
    var savedResources: [PhotoResource] = []
    private var completion: ((Result<String, Error>) -> Void)?
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { saveCount += 1; self.completion = completion }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) {
        savedResources = photo.resources; save(photo.preview, completion: completion)
    }
    func finishSave() { completion?(.success("auto-capture")); completion = nil }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { PhotoImageRequest(cancel: {}) }
}
