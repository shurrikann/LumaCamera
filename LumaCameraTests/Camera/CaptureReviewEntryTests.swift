import XCTest
import UIKit
@testable import LumaCamera

final class CaptureReviewEntryTests: XCTestCase {
    @MainActor func testDiagnosticEnvironmentProtectsDefaultModelCallbacks() throws {
        guard ProcessInfo.processInfo.environment["LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS"] == "1" else {
            throw XCTSkip("仅在显式只读诊断构建中验证默认服务")
        }
        let model = AppDependencies.makeCameraModel()
        model.camera.onCaptureCompleted?(CapturedPhoto(preview: UIImage(), resources: []))
        XCTAssertEqual(model.library.failedSaveCount, 1)
        XCTAssertEqual(model.library.pendingSaveCount, 0)
        XCTAssertNil(model.library.savedPhotoID)
        model.camera.onVideoRecorded?(.success(FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-not-written.mov")))
        XCTAssertFalse(model.library.videoSaving)
        XCTAssertTrue(model.library.message?.contains("未获得相册写入权限") == true)
    }

    /// 隔离本身不连接 Photos；验证迟到录像回调及全部写入口都会被拒绝。
    @MainActor func testDiagnosticPhotoIsolationBlocksAllMutationEntrypoints() {
        let service = DiagnosticReadOnlyPhotoService(reader: DiagnosticReadOnlyBrowserStub())
        var failures = 0
        func receive<T>(_ result: Result<T, Error>) {
            if case .failure = result { failures += 1 }
            else { XCTFail("诊断服务不得返回真实保存或删除成功") }
        }
        let image = UIImage(), url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-not-written.mov")
        service.save(image, completion: receive)
        service.saveCapture(CapturedPhoto(preview: image, resources: []), completion: receive)
        service.saveVideo(at: url, completion: receive)
        service.saveLivePhoto(stillImage: Data(), movieURL: url, location: nil, creationDate: nil, completion: receive)
        service.delete(assetID: "never-a-real-asset", completion: receive)
        service.delete(assetIDs: ["never-a-real-asset"], completion: receive)
        XCTAssertEqual(service.blockedMutationCount, 6)
        XCTAssertEqual(failures, 6)
        let model = AppDependencies.makeCameraModel(photoService: service)
        model.camera.onVideoRecorded?(.success(url))
        XCTAssertEqual(service.blockedMutationCount, 7, "恢复的默认录像回调也必须被同一服务拦住")
        XCTAssertEqual(model.library.pendingSaveCount, 0)
    }

    @MainActor
    func testCaptureOpensDetailsOnceThenAlwaysOpensGridUntilNextCapture() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.openLibrary(); XCTAssertFalse(model.reviewCapture); model.review = false
        model.library.acceptPhoto(UIImage())
        model.openLibrary(); XCTAssertTrue(model.reviewCapture)
        // Duplicate entry while the gallery is already open must not change its route.
        model.openLibrary(); XCTAssertTrue(model.reviewCapture)
        model.review = false
        for _ in 0..<100 {
            model.openLibrary(); XCTAssertFalse(model.reviewCapture); model.review = false
        }
        model.library.acceptPhoto(UIImage())
        model.openLibrary(); XCTAssertTrue(model.reviewCapture); model.review = false
        model.openLibrary(); XCTAssertFalse(model.reviewCapture)
    }

    @MainActor
    func testEditingCurrentCaptureDoesNotMakeItAnUnviewedNewCapture() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.library.acceptPhoto(UIImage())
        model.openLibrary(); model.review = false
        let result = PhotoEditResult(preview: UIImage(), resource: PhotoResource(data: Data([1]), filename: "edit.jpg"))
        model.library.replaceUnsavedPhoto(result)
        model.openLibrary(); XCTAssertFalse(model.reviewCapture)
    }

    @MainActor
    func testNewSessionHasNoAutomaticCaptureEntry() {
        let old = AppDependencies.makeCameraModel(automaticallySave: false)
        old.library.acceptPhoto(UIImage())
        XCTAssertTrue(old.library.captureAwaitingReview)
        let fresh = AppDependencies.makeCameraModel(automaticallySave: false)
        fresh.openLibrary(); XCTAssertFalse(fresh.reviewCapture)
    }

    @MainActor
    func testRejectedCaptureWhileSavingDoesNotRearmViewedPhoto() {
        let service = PendingReviewLibrary()
        let library = PhotoLibraryViewModel(service: service)
        library.acceptPhoto(UIImage())
        XCTAssertTrue(library.consumeCaptureReview())
        library.savePhoto(showSuccessMessage: false)
        library.acceptPhoto(UIImage())
        XCTAssertFalse(library.captureAwaitingReview)
        service.completion?(.success("saved"))
        XCTAssertFalse(library.consumeCaptureReview())
    }
}

private final class DiagnosticReadOnlyBrowserStub: PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.denied) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { completion(nil, nil); return PhotoImageRequest(cancel: {}) }
}

private final class PendingReviewLibrary: PhotoLibraryService {
    var completion: ((Result<String, Error>) -> Void)?
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
