import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class GalleryLazyPaginationTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testOpeningGalleryDoesNotEagerlyLoadEveryPage() async throws {
        let service = PaginationGalleryService()
        let library = PhotoLibraryViewModel(service:service)
        let model = GalleryViewModel(browser:service,library:library)
        model.refresh()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:393,height:800)
        let host = UIHostingController(rootView:GalleryView(model:model,library:library,isDemo:true,onCamera:{}))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(model.photos.count,60,"The off-screen load-more control must not recursively load the entire library")
        XCTAssertFalse(service.offsets.contains { $0 > 0 })
        func scrollView(_ view:UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
            return view.subviews.compactMap { scrollView($0) }.first
        }
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollView(host.view))
        scroll.setContentOffset(CGPoint(x:0,y:scroll.contentSize.height-scroll.bounds.height),animated:false)
        for _ in 0..<100 { if model.photos.count > 60 { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(model.photos.count,120,"Scrolling to the end should load one subsequent page")
    }
    #endif
}
private final class PaginationGalleryService: PhotoBrowserService, PhotoLibraryService {
    var onLibraryChange:(()->Void)?
    var existingAccess:PhotoLibraryAccess? { .full }
    var offsets:[Int] = []
    let entries = (0..<600).map { LibraryPhoto(id:"item-\($0)",date:nil) }
    func authorize(completion:@escaping(PhotoLibraryAccess)->Void) { completion(.full) }
    func fetchPhotos(offset:Int,limit:Int,completion:@escaping(PhotoPage)->Void) {
        offsets.append(offset)
        completion(PhotoPage(photos:Array(entries.dropFirst(offset).prefix(limit)),hasMore:offset+limit<entries.count))
    }
    func requestImage(id:String,size:CGSize,completion:@escaping(UIImage?,Error?)->Void)->PhotoImageRequest {
        completion(UIImage(),nil); return PhotoImageRequest(cancel:{})
    }
    func save(_ image:UIImage,completion:@escaping(Result<String,Error>)->Void) { completion(.success("saved")) }
    func delete(assetID:String,completion:@escaping(Result<Void,Error>)->Void) {}
}
