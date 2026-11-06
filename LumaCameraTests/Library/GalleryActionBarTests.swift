import XCTest
import SwiftUI
import UIKit
import CoreImage
@testable import LumaCamera

final class GalleryActionBarTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testSharePreparationDoesNotMoveOrFlashCameraAndDeleteOnCompactAndNormalWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        for width in [CGFloat(320), 393] {
            let height: CGFloat = 200
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            func content(_ preparing: Bool, _ count: Int, selecting: Bool = true) -> AnyView {
                AnyView(ZStack {
                    AppTheme.popupColor
                    GalleryActionBar(selecting: selecting, selectedCount: 3, preparing: preparing, completedCount: count, totalCount: 3,
                                     libraryBusy: false, captureInProgress: false, destructiveBusy: false,
                                     onShare: {}, onCamera: {}, onDelete: {}, onCancelShare: {})
                        .frame(width: width).position(x: width/2, y: height/2)
                }.ignoresSafeArea().preferredColorScheme(.dark))
            }
            host.rootView = content(false, 0)
            try await Task.sleep(for: .milliseconds(150))
            let before = capture(window)
            let cameraRect = CGRect(x: width/2-31, y: height/2-30, width: 62, height: 60)
            let deleteRect = CGRect(x: width*5/6-38, y: height/2-30, width: 76, height: 60)
            let camera = try pixels(before, rect: cameraRect), delete = try pixels(before, rect: deleteRect)
            XCTAssertGreaterThan(stride(from: 0, to: camera.count, by: 4).filter { max(camera[$0],camera[$0+1],camera[$0+2]) > 150 }.count, 500, "Camera must be at the exact horizontal center")
            XCTAssertGreaterThan(stride(from: 0, to: delete.count, by: 4).filter { delete[$0] > 150 && delete[$0+1] < 130 }.count, 10, "Delete must occupy the right slot")
            for (preparing, progress) in [(true,0), (true,1), (true,3), (false,3)] {
                host.rootView = content(preparing, progress)
                try await Task.sleep(for: .milliseconds(45))
                let during = capture(window)
                assertSame(camera, try pixels(during, rect: cameraRect))
                assertSame(delete, try pixels(during, rect: deleteRect))
                let attachment = XCTAttachment(image: during); attachment.name = "Gallery-Bar-\(Int(width))-\(preparing)-\(progress)"; attachment.lifetime = .keepAlways; add(attachment)
            }
            host.rootView = content(false, 0, selecting: false)
            try await Task.sleep(for: .milliseconds(45))
            assertSame(camera, try pixels(capture(window), rect: cameraRect))
        }
    }
    @MainActor func testFilterNamesAndSaveChoicesVisualCheck() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x:0,y:0,width:393,height:900)
        let host = UIHostingController(rootView: AnyView(EmptyView())); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        for size: CGFloat in [44,52] {
            host.rootView = AnyView(LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)),count:5),spacing:12) {
                ForEach(FilmStyle.availableStyles) { style in
                    VStack(spacing:3) {
                        CameraFilterButtonLabel(title:style.filterButtonName,equipment:style.filterButtonEquipment,active:true,size:size)
                        Text(style.title).font(.system(size:7)).lineLimit(1)
                    }.frame(width:72,height:72)
                }
            }.padding(8).frame(width:393,height:900).background(AppTheme.popupColor).preferredColorScheme(.dark))
            try await Task.sleep(for:.milliseconds(150))
            let shot = XCTAttachment(image:capture(window)); shot.name="Filter-Two-Line-All-Names-\(Int(size))"; shot.lifetime = .keepAlways; add(shot)
        }
        let session = PhotoEditSession(source:CIImage(image:DemoImageFactory.make())!,copy:{ _, _ in }) { _,_ in }
        let model = PhotoEditorViewModel(session:session,library:PhotoLibraryViewModel(service:GalleryBarVisualLibrary()))
        model.presentSaveOptions()
        host.rootView = AnyView(PhotoEditorView(model:model))
        try await Task.sleep(for:.milliseconds(200))
        let save = XCTAttachment(image:capture(window)); save.name="Photo-Editor-Save-Choices"; save.lifetime = .keepAlways; add(save)
        model.cancelPreview()
    }
    @MainActor private func capture(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }
    private func pixels(_ image: UIImage, rect: CGRect) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cgImage?.cropping(to: rect.integral))
        var bytes = [UInt8](repeating: 0, count: cropped.width*cropped.height*4)
        let context = CGContext(data: &bytes, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: cropped.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return bytes
    }
    private func assertSame(_ first: [UInt8], _ second: [UInt8]) {
        XCTAssertEqual(first.count, second.count)
        guard first.count == second.count else { return }
        let mean = zip(first,second).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(max(1,first.count))
        XCTAssertLessThan(mean, 0.3, "Unrelated buttons must retain the same position, brightness and pixels through share preparation")
    }
    #endif
}

private final class GalleryBarVisualLibrary: PhotoLibraryService {
    func save(_ image:UIImage,completion:@escaping(Result<String,Error>)->Void) { completion(.success("visual")) }
    func delete(assetID:String,completion:@escaping(Result<Void,Error>)->Void) { completion(.success(())) }
}
