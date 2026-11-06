import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class GallerySharingAppearanceTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testWholeGalleryStaysStableWhileSharingAndDeletingPrepare() async throws {
        let service = StableGalleryService(), library = PhotoLibraryViewModel(service:StableGalleryService())
        let model = GalleryViewModel(browser:service,library:library), batch = BatchPhotoShareModel()
        model.refresh(); model.beginSelection(); model.selectAll(model.photos.map(\.id))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let old = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:393,height:800)
        let host = UIHostingController(rootView:GalleryView(model:model,library:library,isDemo:true,batchShare:batch,onCamera:{}))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { batch.cancelPreparation(); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for:.milliseconds(250))
        func capture() throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let cg = try XCTUnwrap(image.cgImage?.cropping(to:CGRect(x:0,y:0,width:393,height:650)))
            var bytes = [UInt8](repeating:0,count:393*650*4)
            let context = CGContext(data:&bytes,width:393,height:650,bitsPerComponent:8,bytesPerRow:393*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg,in:CGRect(x:0,y:0,width:393,height:650)); return bytes
        }
        let before = try capture(), requests = service.imageRequests
        batch.prepare(photos:model.photos,service:service)
        for _ in 0..<3 {
            try await Task.sleep(for:.milliseconds(60))
            let after = try capture()
            let difference = zip(before,after).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) }/Double(before.count)
            XCTAssertLessThan(difference,0.3,"Header and photo grid must not dim or flash during share preparation")
        }
        XCTAssertEqual(service.imageRequests,requests,"Share progress must not reload visible thumbnails")
        batch.cancelPreparation()
    }
    #endif
}
private final class StableGalleryService: PhotoBrowserService, PhotoLibraryService, PhotoFileExportService {
    var onLibraryChange:(()->Void)?
    var imageRequests = 0
    var existingAccess:PhotoLibraryAccess? { .full }
    func authorize(completion:@escaping(PhotoLibraryAccess)->Void) { completion(.full) }
    func fetchPhotos(offset:Int,limit:Int,completion:@escaping(PhotoPage)->Void) { completion(PhotoPage(photos:(0..<6).map{LibraryPhoto(id:"tile-\($0)",date:nil)},hasMore:false)) }
    func requestImage(id:String,size:CGSize,completion:@escaping(UIImage?,Error?)->Void)->PhotoImageRequest {
        imageRequests += 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).image { c in UIColor.systemBlue.setFill(); c.fill(CGRect(x:0,y:0,width:64,height:64)) }
        completion(image,nil); return PhotoImageRequest(cancel:{})
    }
    func save(_ image:UIImage,completion:@escaping(Result<String,Error>)->Void) { completion(.success("saved")) }
    func delete(assetID:String,completion:@escaping(Result<Void,Error>)->Void) {}
    func exportPhoto(id:String,directory:URL,completion:@escaping(Result<URL,Error>)->Void)->PhotoImageRequest { PhotoImageRequest(cancel:{}) }
}
