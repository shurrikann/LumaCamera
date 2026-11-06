import XCTest
import Photos
@testable import LumaCamera

final class LibraryQueryPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testReadOnlyGalleryQueryMatchesAccessibleRecentCaptures() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("LIBRARY-QUERY access=\(status.rawValue) add=\(PHPhotoLibrary.authorizationStatus(for:.addOnly).rawValue) now=\(Date().timeIntervalSince1970)")
        guard status == .authorized || status == .limited else { throw XCTSkip("Existing Photos read permission required; audit never prompts") }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        model.gallery.refresh()
        for _ in 0..<300 { if !model.gallery.loading { break }; try await Task.sleep(for:.milliseconds(20)) }
        let loaded = Set(model.gallery.photos.map(\.id))
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key:"creationDate",ascending:false)]
        let all = PHAsset.fetchAssets(with:options)
        print("LIBRARY-QUERY total=\(all.count) loaded=\(loaded.count) more=\(model.gallery.hasMore) firstDate=\(all.firstObject?.creationDate?.timeIntervalSince1970 ?? 0)")
        options.includeAllBurstAssets = true
        let burst = PHAsset.fetchAssets(with:.image,options:options)
        print("LIBRARY-QUERY withBurst=\(burst.count)")
        var omittedOwn = 0
        burst.enumerateObjects { asset,_,_ in
            guard all.index(of:asset) == NSNotFound else { return }
            if PHAssetResource.assetResources(for:asset).contains(where:{ $0.originalFilename.hasPrefix("Luma-") }) { omittedOwn += 1 }
        }
        print("LIBRARY-QUERY omittedOwnBurst=\(omittedOwn)")

        let recentOptions = PHFetchOptions(); recentOptions.sortDescriptors = [NSSortDescriptor(key:"modificationDate",ascending:false)]; recentOptions.fetchLimit = 100
        let recent = PHAsset.fetchAssets(with:.image,options:recentOptions)
        var own = 0
        recent.enumerateObjects { asset,_,stop in
            let ours = PHAssetResource.assetResources(for:asset).contains { $0.originalFilename.hasPrefix("Luma-") }
            guard ours else { return }
            own += 1
            print("LIBRARY-QUERY own rank=\(all.index(of:asset)) visible=\(loaded.contains(asset.localIdentifier)) creation=\(asset.creationDate?.timeIntervalSince1970 ?? 0) modified=\(asset.modificationDate?.timeIntervalSince1970 ?? 0) source=\(asset.sourceType.rawValue) subtypes=\(asset.mediaSubtypes.rawValue)")
            if own >= 10 { stop.pointee = true }
        }
        XCTAssertFalse(model.gallery.loading)
        XCTAssertEqual(model.gallery.photos.map(\.id), (0..<min(60,all.count)).map { all.object(at:$0).localIdentifier })
    }
    #endif
}
