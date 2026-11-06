import XCTest
import UIKit
import Combine
@testable import LumaCamera

final class PhotoLibraryViewModelTests: XCTestCase {
    @MainActor
    func testVideoSaveFailureKeepsFileForRetryAndPublishesSavedAsset() throws {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-save-test-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var published: String?
        let observation = model.didSavePhoto.sink { published = $0 }
        defer { observation.cancel() }
        model.saveVideo(at: url)
        XCTAssertTrue(model.videoSaving)
        service.completeVideoSave(.failure(PhotoLibraryError.writeDenied))
        XCTAssertFalse(model.videoSaving)
        XCTAssertEqual(model.failedVideos, [url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model.retryFailedVideo()
        service.completeVideoSave(.success("video-asset"))
        XCTAssertTrue(model.failedVideos.isEmpty)
        XCTAssertEqual(published, "video-asset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor
    func testCaptureAutomaticallySavesEncodedResourcesWithoutSuccessPrompt() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let resource = PhotoResource(data: Data([1, 2, 3]), filename: "capture.heic")
        let photo = CapturedPhoto(preview: UIImage(), resources: [resource])
        model.acceptCapture(photo, automaticallySave: true)
        XCTAssertTrue(model.saving)
        XCTAssertEqual(service.saveCount, 1)
        XCTAssertEqual(service.savedResources.first?.data, resource.data)
        service.completeSave(.success("automatic-asset"))
        XCTAssertTrue(model.photoSaved)
        XCTAssertEqual(model.savedPhotoID, "automatic-asset")
        XCTAssertNil(model.message)
        model.savePhoto()
        XCTAssertEqual(service.saveCount, 1)
    }

    @MainActor
    func testAutomaticSaveFailureRetainsResourcesAndSupportsRetry() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        let raw = PhotoResource(data: Data([4, 5]), filename: "capture.dng")
        model.acceptCapture(CapturedPhoto(preview: image, resources: [raw]), automaticallySave: true)
        service.completeSave(.failure(PhotoLibraryError.writeDenied))
        XCTAssertTrue(model.lastPhoto === image)
        XCTAssertFalse(model.photoSaved)
        XCTAssertEqual(model.shareResources.first?.data, raw.data)
        XCTAssertNotNil(model.message)
        model.savePhoto(showSuccessMessage: false)
        service.completeSave(.success("retried-asset"))
        XCTAssertEqual(service.saveCount, 2)
        XCTAssertTrue(model.photoSaved)
    }

    @MainActor
    func testEditingProtectsCaptureAndOnlyUpdatesMatchingSavedPhoto() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        model.acceptPhoto(image); model.savePhoto()
        service.completeSave(.success("asset"))
        XCTAssertTrue(model.beginEditing())
        XCTAssertFalse(model.beginEditing())
        model.acceptPhoto(UIImage())
        model.deletePhoto()
        XCTAssertTrue(model.lastPhoto === image)
        XCTAssertTrue(service.deletedIDs.isEmpty)
        let updated = UIImage()
        let result = PhotoEditResult(preview: updated, resource: PhotoResource(data: Data([6]), filename: "edit.jpg"))
        model.updateSavedPreview(assetID: "other", result: result)
        XCTAssertTrue(model.lastPhoto === image)
        model.updateSavedPreview(assetID: "asset", result: result)
        XCTAssertTrue(model.lastPhoto === updated)
        XCTAssertTrue(model.shareResources.isEmpty, "Saved edits must reload full-size resources from Photos")
        model.endEditing()
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testSavedCaptureReleasesFullSizeBytesButRetainsFlagsMetadataAndOneTimeReview() {
        let service = PhotoLibraryStub(), image = UIGraphicsImageRenderer(size:CGSize(width:1000,height:1500)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x:0,y:0,width:1000,height:1500)) }
        let model = PhotoLibraryViewModel(service:service)
        let raw = PhotoResource(data:Data(repeating:1,count:1024),filename:"capture.dng")
        let video = PhotoResource(data:Data(repeating:2,count:1024),filename:"capture.mov",pairedVideo:true)
        let location = PhotoLocation(latitude:34,longitude:108)
        model.acceptCapture(CapturedPhoto(preview:image,resources:[raw,video],location:location),automaticallySave:true)
        XCTAssertFalse(model.hasReleasedCaptureResources)
        XCTAssertEqual(model.shareResources.count,2)
        service.completeSave(.success("saved"))
        XCTAssertTrue(model.hasReleasedCaptureResources)
        XCTAssertTrue(model.shareResources.isEmpty)
        XCTAssertLessThanOrEqual(max(model.lastPhoto!.size.width,model.lastPhoto!.size.height),240)
        XCTAssertTrue(model.hasRAWResource); XCTAssertTrue(model.hasLiveResource)
        XCTAssertEqual(model.captureLocation?.latitude,34)
        XCTAssertTrue(model.consumeCaptureReview()); XCTAssertFalse(model.consumeCaptureReview())
        XCTAssertEqual(model.savedPhotoID,"saved")
    }

    @MainActor
    func testWriteOnlyAccessRetainsResourcesUntilSavedPhotoCanBeRead() {
        let service = PhotoLibraryStub(); service.canReload = false
        let model = PhotoLibraryViewModel(service:service)
        let resource = PhotoResource(data:Data([1,2,3]),filename:"saved.jpg")
        model.acceptCapture(CapturedPhoto(preview:UIImage(),resources:[resource]),automaticallySave:true)
        service.completeSave(.success("saved"))
        XCTAssertTrue(model.photoSaved); XCTAssertFalse(model.hasReleasedCaptureResources)
        XCTAssertEqual(model.shareResources.first?.data,resource.data)
        model.releaseSavedCaptureCacheIfAccessible()
        XCTAssertEqual(model.shareResources.count,1)
        service.canReload = true; model.releaseSavedCaptureCacheIfAccessible()
        XCTAssertTrue(model.hasReleasedCaptureResources); XCTAssertTrue(model.shareResources.isEmpty)
    }

    @MainActor
    func testEarlierSaveCompletionDoesNotReleaseNewestUnsavedCapture() {
        let service = PhotoLibraryStub()
        let library = PhotoLibraryViewModel(service:service)
        let resource = PhotoResource(data:Data([1,2]),filename:"first.jpg")
        library.acceptCapture(CapturedPhoto(preview:UIImage(),resources:[resource]),automaticallySave:true)
        let second = PhotoResource(data:Data([3,4]),filename:"second.jpg")
        library.acceptCapture(CapturedPhoto(preview:UIImage(),resources:[second]))
        service.completeSave(.success("first"))
        XCTAssertEqual(library.shareResources.first?.filename,"second.jpg")
        XCTAssertFalse(library.photoSaved); XCTAssertFalse(library.hasReleasedCaptureResources)
    }

    @MainActor
    func testUnsavedDeleteDoesNotAccessSystemLibrary() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        model.acceptPhoto(UIImage())
        model.deletePhoto()
        XCTAssertNil(model.lastPhoto)
        XCTAssertEqual(service.deletedIDs, [])
        XCTAssertFalse(model.photoSaved)
    }

    @MainActor
    func testSaveTracksAssetAndPreventsDuplicateWrites() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        model.acceptPhoto(UIImage())
        model.savePhoto()
        model.savePhoto()
        XCTAssertTrue(model.saving)
        XCTAssertEqual(service.saveCount, 1)
        service.completeSave(.success("asset-123"))
        XCTAssertTrue(model.photoSaved)
        XCTAssertFalse(model.saving)
        model.savePhoto()
        XCTAssertEqual(service.saveCount, 1)
        model.deletePhoto()
        XCTAssertEqual(service.deletedIDs, ["asset-123"])
        service.completeDelete(.success(()))
        XCTAssertNil(model.lastPhoto)
        XCTAssertFalse(model.photoSaved)
    }

    @MainActor
    func testPermissionFailurePreservesPhotoAndAllowsRetry() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        model.acceptPhoto(image)
        model.savePhoto()
        service.completeSave(.failure(PhotoLibraryError.writeDenied))
        XCTAssertTrue(model.lastPhoto === image)
        XCTAssertFalse(model.saving)
        XCTAssertFalse(model.photoSaved)
        XCTAssertNotNil(model.message)
        model.savePhoto()
        XCTAssertEqual(service.saveCount, 2)
        service.completeSave(.success("asset-retry"))
        XCTAssertTrue(model.photoSaved)
    }

    @MainActor
    func testDeleteCancellationOrLimitedAccessPreservesSavedPhoto() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        model.acceptPhoto(image)
        model.savePhoto()
        service.completeSave(.success("asset-123"))
        model.deletePhoto()
        XCTAssertTrue(model.deleting)
        service.completeDelete(.failure(PhotoLibraryError.inaccessible))
        XCTAssertFalse(model.deleting)
        XCTAssertTrue(model.lastPhoto === image)
        XCTAssertTrue(model.photoSaved)
        XCTAssertNotNil(model.message)
    }

    @MainActor
    func testBusyOperationProtectsCurrentPhoto() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        model.acceptPhoto(image)
        model.savePhoto()
        model.acceptPhoto(UIImage())
        model.deletePhoto()
        XCTAssertTrue(model.lastPhoto === image)
        XCTAssertTrue(service.deletedIDs.isEmpty)
        service.completeSave(.success("asset-123"))
        model.deletePhoto()
        model.savePhoto()
        XCTAssertEqual(service.saveCount, 1)
        service.completeDelete(.success(()))
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testCaptureBlocksSaveAndDeleteUntilProcessingFinishes() async {
        let service = PhotoLibraryStub()
        let model = PhotoLibraryViewModel(service: service)
        model.acceptPhoto(UIImage())
        model.captureInProgress = true
        model.savePhoto()
        model.deletePhoto()
        XCTAssertEqual(service.saveCount, 0)
        XCTAssertNotNil(model.lastPhoto)
        model.captureInProgress = false
        model.savePhoto()
        XCTAssertEqual(service.saveCount, 1)
        service.completeSave(.success("asset-123"))
    }
}

/// Deferred completions exercise in-flight operation guards without requesting OS permissions.
private final class PhotoLibraryStub: PhotoLibraryService {
    var saveCount = 0
    var canReload = true
    func canReloadSavedPhoto(id:String) -> Bool { canReload }
    var deletedIDs: [String] = []
    var savedResources: [PhotoResource] = []
    private var saveCompletion: ((Result<String, Error>) -> Void)?
    private var videoSaveCompletion: ((Result<String, Error>) -> Void)?
    private var deleteCompletion: ((Result<Void, Error>) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        saveCount += 1
        saveCompletion = completion
    }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) {
        savedResources = photo.resources
        save(photo.preview, completion: completion)
    }
    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        videoSaveCompletion = completion
    }
    func completeVideoSave(_ result: Result<String, Error>) {
        let completion = videoSaveCompletion
        videoSaveCompletion = nil
        completion?(result)
    }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        deletedIDs.append(assetID)
        deleteCompletion = completion
    }
    func completeSave(_ result: Result<String, Error>) {
        let completion = saveCompletion
        saveCompletion = nil
        completion?(result)
    }
    func completeDelete(_ result: Result<Void, Error>) {
        let completion = deleteCompletion
        deleteCompletion = nil
        completion?(result)
    }
}
