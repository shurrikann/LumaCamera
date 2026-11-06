import XCTest
import Photos
import CoreImage
import UIKit
@testable import LumaCamera

final class SystemGalleryRefreshTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testExternalPhotoKitBurstAppearsWithoutReopeningOrManualRefresh() async throws {
        // Simulator-only fixtures; never write diagnostic pictures into a user's physical library.
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Grant simulator Photos access before running the PhotoKit integration case")
        }
        let browser = SystemPhotoLibraryService()
        let gallery = GalleryViewModel(browser: browser, library: PhotoLibraryViewModel(service: browser))
        gallery.refresh()
        for _ in 0..<200 { if !gallery.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(gallery.loading)
        // A separate service represents photos produced outside this gallery/camera pipeline.
        let external = PhotoLibraryViewModel(service: SystemPhotoLibraryService())
        let prefix = "External-Gallery-Test-" + UUID().uuidString
        let expected = Set((0..<3).map { prefix + "-\($0).jpg" })
        for index in 0..<3 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor(hue: CGFloat(index)/3, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
            external.acceptCapture(CapturedPhoto(preview: image, resources: [PhotoResource(data: data, filename: prefix + "-\(index).jpg")]), automaticallySave: true)
        }
        for _ in 0..<500 { if external.pendingSaveCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(external.failedSaveCount, 0, external.message ?? "")
        XCTAssertEqual(external.pendingSaveCount, 0)
        var visible = Set<String>()
        for _ in 0..<300 {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: gallery.photos.map(\.id), options: nil)
            visible = []
            assets.enumerateObjects { asset, _, _ in
                for resource in PHAssetResource.assetResources(for: asset) where expected.contains(resource.originalFilename) { visible.insert(resource.originalFilename) }
            }
            if visible == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(visible, expected, "All external burst assets must arrive via Photos changes, without reopening the gallery")
        let batch = BatchPhotoShareModel()
        let chosen = gallery.photos.filter { photo in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else { return false }
            return PHAssetResource.assetResources(for: asset).contains { expected.contains($0.originalFilename) }
        }
        batch.prepare(photos: chosen, service: browser)
        for _ in 0..<300 { if !batch.preparing { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(batch.prepared?.urls.count, 3, batch.message ?? "")
        XCTAssertEqual(Set(batch.prepared?.urls.map(\.lastPathComponent) ?? []), expected)
        for url in batch.prepared?.urls ?? [] { XCTAssertNotNil(UIImage(contentsOfFile: url.path)) }
        batch.prepared = nil
    }
    @MainActor func testSaveCopyAndReplaceKeepOriginalIdentityAndFilterFlags() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw XCTSkip("Simulator Photos permission required") }
        let service = SystemPhotoLibraryService()
        let image = UIGraphicsImageRenderer(size: CGSize(width:48,height:64)).image { c in UIColor.green.setFill(); c.fill(CGRect(x:0,y:0,width:48,height:64)) }
        let id = try await withCheckedThrowingContinuation { continuation in service.save(image) { continuation.resume(with: $0) } }
        func resources(_ id: String) async throws -> [PhotoResource] {
            try await withCheckedThrowingContinuation { c in _ = service.shareResources(id:id) { c.resume(with:$0) } }
        }
        func editor(_ id: String) async throws -> PhotoEditSession {
            try await withCheckedThrowingContinuation { c in _ = service.openEditor(id:id) { c.resume(with:$0) } }
        }
        let original = try await resources(id)
        let session = try await editor(id)
        XCTAssertTrue(session.supportsSaveCopy)
        var recipe = PhotoAdjustments(); recipe.filterID = FilmStyle.fujiCC.rawValue; recipe.crop = PhotoCropRectangle(x:0,y:0,width:0.5,height:0.5)
        let copy = try await withCheckedThrowingContinuation { c in session.saveCopy(recipe) { c.resume(with:$0) } }
        let copyID = try XCTUnwrap(copy.copiedAssetID)
        XCTAssertNotEqual(copyID,id); XCTAssertEqual(copy.filterApplied,true)
        let unchanged = try await resources(id); XCTAssertEqual(unchanged.first?.data,original.first?.data)
        XCTAssertTrue(PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID:copyID))
        XCTAssertFalse(PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID:id))
        let replaced = try await withCheckedThrowingContinuation { c in session.save(recipe) { c.resume(with:$0) } }
        XCTAssertNil(replaced.copiedAssetID); XCTAssertEqual(replaced.filterApplied,true)
        let changed = try await resources(id); XCTAssertNotEqual(changed.first?.data,original.first?.data)
        let resumed = try await editor(id); XCTAssertEqual(resumed.initialAdjustments,recipe)
        _ = try await withCheckedThrowingContinuation { c in resumed.save(PhotoAdjustments()) { c.resume(with:$0) } }
        XCTAssertFalse(PhotoCaptureDiagnosticsStore.shared.filterApplied(assetID:id))
        let copied = try await editor(copyID)
        let copiedAgain = try await withCheckedThrowingContinuation { c in copied.saveCopy(PhotoAdjustments()) { c.resume(with:$0) } }
        XCTAssertEqual(copiedAgain.filterApplied,true,"Flattened filter must remain marked even with no additional LUT")
        let page = await withCheckedContinuation { c in service.fetchPhotos(offset:0,limit:1000) { c.resume(returning:$0) } }
        XCTAssertEqual(page.photos.first(where:{$0.id==copyID})?.hasFilter,true)
        XCTAssertEqual(page.photos.first(where:{$0.id==id})?.hasFilter,false)
    }
    @MainActor func testFilteredCaptureAndOriginalSaveAsSeparateAssetsInOneTransaction() async throws {
        guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized else { throw XCTSkip("Simulator Photos permission required") }
        let service = SystemPhotoLibraryService()
        let source = CIImage(color:.green).cropped(to:CGRect(x:0,y:0,width:64,height:96))
        let photo = try PhotoEncoder.encode(source:source,raw:nil,look:CaptureLook(style:.mono),options:PhotoOptions(copyright:"Test Artist",saveUnfilteredOriginal:true),context:CIContext())
        let id = try await withCheckedThrowingContinuation { c in service.saveCapture(photo) { c.resume(with:$0) } }
        let page = await withCheckedContinuation { c in service.fetchPhotos(offset:0,limit:1000) { c.resume(returning:$0) } }
        let originalName = try XCTUnwrap(photo.unfilteredOriginal).filename
        let originals = page.photos.filter { entry in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers:[entry.id],options:nil).firstObject else { return false }
            return PHAssetResource.assetResources(for:asset).contains { $0.originalFilename == originalName }
        }
        XCTAssertEqual(originals.count,1); XCTAssertNotEqual(originals.first?.id,id); XCTAssertFalse(try XCTUnwrap(originals.first).hasFilter)
        let main = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject)
        XCTAssertEqual(PHAssetResource.assetResources(for:main).count,1,"Original companion must never be added as a second primary photo in the same asset")
    }
    #endif
}
