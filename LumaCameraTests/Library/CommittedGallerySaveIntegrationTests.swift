import XCTest
import Photos
import UIKit
@testable import LumaCamera

final class CommittedGallerySaveIntegrationTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testOwnBurstSavesReachGalleryWhenPhotoKitChangeCallbacksAreSuppressed() async throws {
        guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized else { throw XCTSkip("Simulator Photos permission required") }
        let service = SystemPhotoLibraryService()
        let library = PhotoLibraryViewModel(service:service)
        let gallery = GalleryViewModel(browser:service,library:library)
        gallery.refresh()
        for _ in 0..<200 { if !gallery.loading { break }; try await Task.sleep(for:.milliseconds(20)) }
        // Simulate losing all PhotoKit notifications while the camera owns the screen.
        service.onLibraryChange = nil
        let prefix = "Committed-Capture-" + UUID().uuidString
        let expected = Set((0..<3).map { prefix + "-\($0).jpg" })
        for index in 0..<3 {
            let image = UIGraphicsImageRenderer(size:CGSize(width:32,height:48)).image { context in
                UIColor(hue:CGFloat(index)/3,saturation:0.7,brightness:0.8,alpha:1).setFill()
                context.fill(CGRect(x:0,y:0,width:32,height:48))
            }
            let data = try XCTUnwrap(image.jpegData(compressionQuality:0.9))
            library.acceptCapture(CapturedPhoto(preview:image,resources:[PhotoResource(data:data,filename:prefix + "-\(index).jpg")]),automaticallySave:true)
        }
        var visible = Set<String>()
        for _ in 0..<400 {
            visible = []
            let assets = PHAsset.fetchAssets(withLocalIdentifiers:gallery.photos.map(\.id),options:nil)
            assets.enumerateObjects { asset,_,_ in
                for resource in PHAssetResource.assetResources(for:asset) where expected.contains(resource.originalFilename) { visible.insert(resource.originalFilename) }
            }
            if library.pendingSaveCount == 0, visible == expected { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(library.pendingSaveCount,0)
        XCTAssertEqual(library.failedSaveCount,0,library.message ?? "")
        XCTAssertEqual(visible,expected,"Committed captures must populate the gallery without a Photos change callback or reopening")
        XCTAssertTrue(library.photoSaved)
    }
    #endif
}
