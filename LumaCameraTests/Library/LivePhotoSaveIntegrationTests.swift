import XCTest
import Photos
import UIKit
@testable import LumaCamera

final class LivePhotoSaveIntegrationTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testFileBackedEditedLiveImportAndRepeatedCopyActuallyCommitToPhotos() async throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveImportFixture")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("photo.jpg").path) else { throw XCTSkip("Temporary real-device Live fixture required") }
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized)
        let data = try Data(contentsOf: folder.appendingPathComponent("photo.jpg"))
        let movie = try Data(contentsOf: folder.appendingPathComponent("video.mov"))
        let image = try XCTUnwrap(UIImage(data: data))
        let capture = CapturedPhoto(preview: image, resources: [PhotoResource(data: data, filename: "Live-Import.jpg"), PhotoResource(data: movie, filename: "Live-Import.mov", pairedVideo: true)])
        let service = SystemPhotoLibraryService()
        let original: String = try await withCheckedThrowingContinuation { c in service.saveCapture(capture) { c.resume(with: $0) } }
        let originalAsset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [original], options: nil).firstObject)
        XCTAssertTrue(originalAsset.mediaSubtypes.contains(.photoLive))
        var parameters = PhotoCaptureParameters(); parameters.focusPosition = 0.42; parameters.whiteBalanceKelvin = 5200
        let diagnostic = PhotoCaptureDiagnostics(rows: [.init(title: "快门时主镜头", value: "测试主摄")], parameters: parameters)
        PhotoCaptureDiagnosticsStore.shared.save(diagnostic, assetID: original)
        let session: PhotoEditSession = try await withCheckedThrowingContinuation { c in
            _ = service.openEditor(id: original) { c.resume(with: $0) }
        }
        XCTAssertTrue(session.supportsLiveEditing)
        var recipe = PhotoAdjustments(); recipe.filterID = FilmStyle.leicaM9.rawValue; recipe.filterIntensity = 0.7
        recipe.quarterTurns = 1; recipe.flipHorizontal = true
        recipe.crop = PhotoCropRectangle(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let copy: PhotoEditResult = try await withCheckedThrowingContinuation { c in session.saveLive(recipe, asCopy: true) { c.resume(with: $0) } }
        let copyID = try XCTUnwrap(copy.copiedAssetID)
        XCTAssertNotEqual(copyID, original)
        XCTAssertEqual(PhotoCaptureDiagnosticsStore.shared.load(assetID: copyID)?.parameters, parameters)
        XCTAssertEqual(PhotoCaptureDiagnosticsStore.shared.load(assetID: copyID)?.currentFilter?.id, FilmStyle.leicaM9.rawValue)
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [copyID], options: nil).firstObject)
        XCTAssertTrue(asset.mediaSubtypes.contains(.photoLive))
        let types = PHAssetResource.assetResources(for: asset).map(\.type)
        XCTAssertTrue(types.contains(.photo)); XCTAssertTrue(types.contains(.pairedVideo))
        // A second copy detects duplicate-pair identifier rejection, not merely decoding.
        let repeated: PhotoEditResult = try await withCheckedThrowingContinuation { c in session.saveLive(recipe, asCopy: true) { c.resume(with: $0) } }
        XCTAssertNotEqual(repeated.copiedAssetID, copyID)
        XCTAssertTrue(PHAsset.fetchAssets(withLocalIdentifiers: [original], options: nil).firstObject?.mediaSubtypes.contains(.photoLive) == true)
        let staticCopy: PhotoEditResult = try await withCheckedThrowingContinuation { c in session.saveCopy(recipe) { c.resume(with: $0) } }
        let staticID = try XCTUnwrap(staticCopy.copiedAssetID)
        XCTAssertEqual(PhotoCaptureDiagnosticsStore.shared.load(assetID: staticID)?.parameters, parameters)
        XCTAssertFalse(try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [staticID], options: nil).firstObject).mediaSubtypes.contains(.photoLive))
        print("LIVE-IMPORT actual simulator Photos transactions passed: original, two edited Live copies, static copy")
    }
    #endif
}
