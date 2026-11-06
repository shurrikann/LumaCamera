import XCTest
import UIKit
import Combine
@testable import LumaCamera

final class GalleryViewModelTests: XCTestCase {
    @MainActor
    func testDeniedAccessDoesNotFetchSystemPhotos() async {
        let service = GalleryServiceStub()
        service.access = .denied
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        XCTAssertEqual(model.access, .denied)
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertEqual(service.offsets, [])
        XCTAssertFalse(model.loading)
    }

    @MainActor
    func testLimitedAccessLoadsOnlyProvidedPhotosAndPaginates() async {
        let service = GalleryServiceStub()
        service.access = .limited
        service.entries = (0..<75).map { LibraryPhoto(id: "photo-\($0)", date: nil) }
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        XCTAssertEqual(model.access, .limited)
        XCTAssertEqual(model.photos.count, 60)
        XCTAssertTrue(model.hasMore)
        model.loadMore()
        XCTAssertEqual(model.photos.count, 75)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(service.offsets, [0, 60])
    }

    @MainActor
    func testLibraryChangeReloadsAvailablePhotos() async {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "first", date: nil)]
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        service.entries = [LibraryPhoto(id: "new", date: nil)]
        service.onLibraryChange?()
        XCTAssertEqual(model.photos.map(\.id), ["new"])
    }

    @MainActor func testSaveCompletionRefreshesListWithoutPhotoKitChangeNotification() async {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "old", date: nil)]
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        library.acceptPhoto(UIImage())
        service.entries.insert(LibraryPhoto(id: "saved", date: nil), at: 0)
        library.savePhoto()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        XCTAssertEqual(model.photos.map(\.id), ["saved", "old"])
        XCTAssertFalse(model.loading)
    }

    @MainActor func testEachQueuedSaveRefreshesEvenBeforeNewestCaptureFinishes() async {
        let service = GalleryServiceStub(); service.deferSaves = true
        service.entries = [LibraryPhoto(id: "old", date: nil)]
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        for _ in 0..<3 { library.acceptCapture(CapturedPhoto(preview: UIImage(), resources: []), automaticallySave: true) }
        for index in 1...3 {
            let id = "burst-\(index)"
            service.entries.insert(LibraryPhoto(id: id, date: nil), at: 0)
            service.saveCompletions.removeFirst()(.success(id))
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            XCTAssertEqual(model.photos.map(\.id), service.entries.map(\.id))
        }
        XCTAssertEqual(library.pendingSaveCount, 0)
        XCTAssertEqual(model.photos.count, 4)
    }

    @MainActor func testConfirmedMissingRowsArePrunedBeforeSlowMetadataAndCannotBeReinserted() {
        let service = GalleryServiceStub()
        let deleted = LibraryPhoto(id:"deleted",date:nil), remaining = LibraryPhoto(id:"remaining",date:nil)
        service.entries = [deleted,remaining]
        let model = GalleryViewModel(browser:service,library:PhotoLibraryViewModel(service:service))
        model.refresh(); model.beginSelection(); model.toggleSelection("deleted")
        service.availableIDs = ["remaining"]; service.deferFetch = true
        var invalidated = Set<String>()
        let observation = model.unavailablePhotos.sink { ids in
            invalidated.formUnion(ids)
            XCTAssertTrue(model.photos.contains(deleted), "Notify the detail before discarding its neighboring order")
        }
        defer { observation.cancel() }
        model.refresh()
        XCTAssertEqual(invalidated,["deleted"])
        XCTAssertTrue(model.loading)
        XCTAssertEqual(model.photos,[remaining],"Do not retain a deleted placeholder until full metadata finishes")
        XCTAssertTrue(model.selectedIDs.isEmpty)
        service.fetchCompletion?(PhotoPage(photos:[deleted,remaining],hasMore:false))
        XCTAssertEqual(model.photos,[remaining],"An older metadata snapshot must not reinsert a confirmed missing asset")
    }

    @MainActor
    func testDeleteFailureKeepsSystemAndCurrentPhoto() async {
        let service = GalleryServiceStub()
        let photo = LibraryPhoto(id: "selected", date: nil)
        service.entries = [photo]
        let library = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        library.acceptPhoto(image)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        var completed: Bool?
        model.delete(photo) { completed = $0 }
        XCTAssertTrue(library.deleting)
        XCTAssertEqual(model.deletingID, photo.id)
        service.completeDelete(.failure(PhotoLibraryError.inaccessible))
        XCTAssertEqual(completed, false)
        XCTAssertEqual(model.photos, [photo])
        XCTAssertTrue(library.lastPhoto === image)
        XCTAssertFalse(library.deleting)
        XCTAssertNil(model.deletingID)
        XCTAssertNotNil(model.message)
    }

    @MainActor
    func testDecliningSystemDeleteConfirmationIsSilentAndCanRetryAfterReentry() async {
        let service = GalleryServiceStub()
        let photo = LibraryPhoto(id: "selected", date: nil)
        service.entries = [photo]
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()

        var completed: Bool?
        model.delete(photo) { completed = $0 }
        service.completeDelete(.failure(NSError(domain: "PHPhotosErrorDomain", code: 3072)))
        XCTAssertEqual(completed, false)
        XCTAssertNil(model.message, "A declined system confirmation is a normal cancellation, not an app error")
        XCTAssertEqual(model.photos, [photo])

        // Re-entering and retrying the same item must not replay a stale cancellation alert.
        model.refresh()
        model.delete(photo) { completed = $0 }
        service.entries = []
        service.completeDelete(.success(()))
        XCTAssertEqual(completed, true)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.photos.isEmpty)
    }

    @MainActor
    func testDecliningBatchDeleteConfirmationKeepsSelectionWithoutAlert() async {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "one", date: nil), LibraryPhoto(id: "two", date: nil)]
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        model.beginSelection()
        model.selectAll(service.entries.map(\.id))
        model.deleteSelected()
        service.completeDelete(.failure(NSError(domain: "PHPhotosErrorDomain", code: 3072)))
        XCTAssertNil(model.message)
        XCTAssertTrue(model.selecting)
        XCTAssertEqual(model.selectedIDs, Set(["one", "two"]))
        XCTAssertEqual(model.photos, service.entries)
    }

    @MainActor
    func testDeletingSavedCurrentPhotoClearsBothViewsAndBlocksDuplicateDelete() async {
        let service = GalleryServiceStub()
        let photo = LibraryPhoto(id: "saved", date: nil)
        service.entries = [photo]
        let library = PhotoLibraryViewModel(service: service)
        library.acceptPhoto(UIImage())
        library.savePhoto()
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        var deleted = false
        model.delete(photo) { deleted = $0 }
        model.delete(photo) { _ in XCTFail("Duplicate delete must be ignored") }
        XCTAssertEqual(service.deleteIDs, ["saved"])
        service.entries = []
        service.completeDelete(.success(()))
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertNil(library.lastPhoto)
        XCTAssertFalse(library.photoSaved)
    }

    @MainActor
    func testDeletingUnrelatedSystemPhotoPreservesCurrentCapture() async {
        let service = GalleryServiceStub()
        let photo = LibraryPhoto(id: "other", date: nil)
        service.entries = [photo]
        let library = PhotoLibraryViewModel(service: service)
        let image = UIImage()
        library.acceptPhoto(image)
        library.savePhoto()
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh()
        model.delete(photo) { _ in }
        service.entries = []
        service.completeDelete(.success(()))
        XCTAssertTrue(library.lastPhoto === image)
        XCTAssertTrue(library.photoSaved)
    }

    @MainActor
    func testOldFetchCannotOverwriteNewPermissionState() async {
        let service = GalleryServiceStub()
        service.deferFetch = true
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        let old = service.fetchCompletion
        service.access = .denied
        model.refresh()
        old?(PhotoPage(photos: [LibraryPhoto(id: "stale", date: nil)], hasMore: false))
        XCTAssertEqual(model.access, .denied)
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertFalse(model.loading)
    }
    @MainActor func testBatchDeleteUsesOneRequestAndCancellationPreservesSelection() {
        let service = GalleryServiceStub()
        service.entries = (0..<4).map { LibraryPhoto(id: "item-\($0)", date: nil) }
        let library = PhotoLibraryViewModel(service: service)
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh(); model.beginSelection()
        model.toggleSelection("item-1"); model.toggleSelection("item-2")
        model.deleteSelected(); model.deleteSelected()
        XCTAssertEqual(service.batchIDs, [Set(["item-1", "item-2"])])
        XCTAssertTrue(library.deleting)
        service.completeDelete(.failure(PhotoLibraryError.inaccessible))
        XCTAssertEqual(model.photos.count, 4)
        XCTAssertEqual(model.selectedIDs, Set(["item-1", "item-2"]))
        XCTAssertTrue(model.selecting)
        model.deleteSelected()
        service.entries.removeAll { model.selectedIDs.contains($0.id) }
        service.completeDelete(.success(()))
        XCTAssertEqual(model.photos.map(\.id), ["item-0", "item-3"])
        XCTAssertFalse(model.selecting); XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    @MainActor func testLibraryRefreshKeepsLoadedPagesAndPrunesMissingSelections() {
        let service = GalleryServiceStub()
        service.entries = (0..<130).map { LibraryPhoto(id: "item-\($0)", date: nil) }
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh(); model.loadMore()
        XCTAssertEqual(model.photos.count, 120)
        model.beginSelection(); model.toggleSelection("item-110"); model.toggleSelection("item-10")
        service.entries.removeAll { $0.id == "item-10" }
        service.onLibraryChange?()
        XCTAssertEqual(model.photos.count, 120)
        XCTAssertEqual(model.selectedIDs, ["item-110"])
        var completed = false
        model.loadMore { completed = true }
        XCTAssertTrue(completed); XCTAssertEqual(model.photos.count, 129)
    }

    @MainActor func testForegroundRefreshFindsExternalImportsWhenChangeNotificationWasMissed() {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "old", date: nil)]
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        service.entries.insert(LibraryPhoto(id: "external-camera", date: nil), at: 0)
        model.refreshAfterForeground()
        XCTAssertEqual(model.photos.map(\.id), ["external-camera", "old"])
        XCTAssertFalse(model.loading)
    }
    @MainActor func testEachGalleryEntryRequeriesSavedBurstEvenWithoutChangeNotification() {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "old", date: nil)]
        let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: service)
        model.openLibrary(); model.review = false
        service.entries = ["burst-3", "burst-2", "burst-1", "old"].map { LibraryPhoto(id: $0, date: nil) }
        model.library.acceptPhoto(UIImage())
        model.openLibrary()
        XCTAssertEqual(model.gallery.photos.map(\.id), ["burst-3", "burst-2", "burst-1", "old"])
        XCTAssertTrue(model.reviewCapture)
        model.review = false; model.openLibrary()
        XCTAssertFalse(model.reviewCapture)
        XCTAssertEqual(model.gallery.photos.count, 4)
    }
    @MainActor func testForegroundWithUnrequestedAccessDoesNotAskForPhotoPermission() {
        let service = GalleryServiceStub()
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refreshAfterForeground()
        XCTAssertEqual(service.authorizationCount, 0)
        XCTAssertTrue(service.offsets.isEmpty)
    }

    @MainActor func testExternalDeletionClearsSavedCaptureAndSelectionInsteadOfReinsertingGhost() {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "saved", date: nil), LibraryPhoto(id: "older", date: nil)]
        let library = PhotoLibraryViewModel(service: service)
        library.acceptPhoto(UIImage()); library.savePhoto()
        let model = GalleryViewModel(browser: service, library: library)
        model.refresh(); model.beginSelection(); model.toggleSelection("saved")
        service.availability["saved"] = .missing
        service.entries.removeFirst()
        service.onLibraryChange?()
        XCTAssertEqual(model.photos.map(\.id), ["older"])
        XCTAssertNil(library.lastPhoto); XCTAssertNil(library.savedPhotoID)
        XCTAssertFalse(library.photoSaved); XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    @MainActor func testUnavailableThumbnailOnlyRemovesConfirmedDeletionNotOfflineOrLimitedPhotos() {
        let service = GalleryServiceStub()
        service.entries = [LibraryPhoto(id: "offline", date: nil), LibraryPhoto(id: "deleted", date: nil)]
        let model = GalleryViewModel(browser: service, library: PhotoLibraryViewModel(service: service))
        model.refresh()
        service.availability["offline"] = .available
        service.availability["deleted"] = .missing
        model.removeIfConfirmedMissing(id: "offline")
        XCTAssertEqual(model.photos.count, 2)
        model.removeIfConfirmedMissing(id: "deleted")
        XCTAssertEqual(model.photos.map(\.id), ["offline"])
        service.availability["offline"] = .unknown
        model.removeIfConfirmedMissing(id: "offline")
        XCTAssertEqual(model.photos.count, 1)
    }
    @MainActor func testLateMissingResultCannotClearNewerCapture() {
        let service = GalleryServiceStub()
        let library = PhotoLibraryViewModel(service: service)
        library.acceptPhoto(UIImage()); library.savePhoto()
        let model = GalleryViewModel(browser: service, library: library)
        service.deferAvailability = true
        model.removeIfConfirmedMissing(id: "saved")
        let old = service.availabilityCompletion
        service.nextSavedID = "new"; let image = UIImage()
        library.acceptPhoto(image); library.savePhoto()
        old?(.missing)
        XCTAssertTrue(library.lastPhoto === image); XCTAssertEqual(library.savedPhotoID, "new")
    }

}

private final class GalleryServiceStub: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var access = PhotoLibraryAccess.full
    var authorizationCount = 0
    var availableIDs: Set<String>?
    func availablePhotoIDs(_ ids:[String],completion:@escaping(Set<String>?)->Void) { completion(availableIDs) }
    var availability: [String: PhotoAssetAvailability] = [:]
    var deferAvailability = false
    var availabilityCompletion: ((PhotoAssetAvailability) -> Void)?
    var nextSavedID = "saved"
    var deferSaves = false
    var saveCompletions: [(Result<String, Error>) -> Void] = []
    var entries: [LibraryPhoto] = []
    var offsets: [Int] = []
    var deleteIDs: [String] = []
    var batchIDs: [Set<String>] = []
    var deferFetch = false
    var fetchCompletion: ((PhotoPage) -> Void)?
    private var deleteCompletion: ((Result<Void, Error>) -> Void)?

    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { authorizationCount += 1; completion(access) }
    func photoAvailability(id: String, completion: @escaping (PhotoAssetAvailability) -> Void) {
        if deferAvailability { availabilityCompletion = completion }
        else { completion(availability[id] ?? .unknown) }
    }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) {
        offsets.append(offset)
        if deferFetch { fetchCompletion = completion; return }
        completion(PhotoPage(photos: Array(entries.dropFirst(offset).prefix(limit)), hasMore: offset + limit < entries.count))
    }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        completion(UIImage(), nil)
        return PhotoImageRequest(cancel: {})
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        if deferSaves { saveCompletions.append(completion) }
        else { completion(.success(nextSavedID)) }
    }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        deleteIDs.append(assetID)
        deleteCompletion = completion
    }
    func delete(assetIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        if assetIDs.count == 1 { delete(assetID: assetIDs[0], completion: completion); return }
        batchIDs.append(Set(assetIDs)); deleteCompletion = completion
    }
    func completeDelete(_ result: Result<Void, Error>) {
        let completion = deleteCompletion
        deleteCompletion = nil
        completion?(result)
    }
}
