import XCTest
import SwiftUI
import CoreImage
@testable import LumaCamera

final class CaptureControlRotationTests: XCTestCase {
    /// 使用有上下色标的照片/视频相册替身核对实际像素旋转，按钮外框不能移动或重新请求缩略图。
    @MainActor func testAlbumThumbnailRotatesWithControlsWithoutMovingButton() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let context = CIContext()
        var renderDurations: [Double] = []
        for video in [false, true] {
            let service = RotationGalleryService()
            service.isVideo = video
            let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: service)
            defer { model.setCameraActive(false) }
            model.gallery.refreshThumbnail()
            for _ in 0..<100 {
                if model.gallery.albumButtonImage != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let thumbnail = try XCTUnwrap(model.gallery.albumButtonImage)
            let requests = service.requestCount
            var baseline: CGRect?
            let rotation = AlbumThumbnailRotationAngle()
            host.rootView = AnyView(AlbumThumbnailRotationHarness(model: model, rotation: rotation).id(video))
            // 连续往返方向仍须得到正确像素且不修改源图；减弱动态效果沿用系统实际环境。
            for pass in 0..<4 { for (index, angle) in [0.0, 90.0, -90.0, 180.0].enumerated() {
                model.ratio = FrameRatio.photoOptions[(pass * 4 + index) % FrameRatio.photoOptions.count]
                rotation.angle = angle
                try await Task.sleep(for: .milliseconds(280))
                let rect = try XCTUnwrap(model.captureButtonFramesForTesting["album"], "video=\(video), pass=\(pass), angle=\(angle)")
                if let baseline {
                    XCTAssertEqual(rect.minX, baseline.minX, accuracy: 0.5)
                    XCTAssertEqual(rect.minY, baseline.minY, accuracy: 0.5)
                    XCTAssertEqual(rect.size, baseline.size)
                } else { baseline = rect }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                renderDurations.append(CACurrentMediaTime() - start)
                let image = try XCTUnwrap(CIImage(image: shot))
                func color(_ point: CGPoint) -> [UInt8] {
                    var bytes = [UInt8](repeating: 0, count: 4)
                    context.render(image, toBitmap: &bytes, rowBytes: 4,
                        bounds: CGRect(x: point.x, y: window.bounds.height - point.y, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                    return bytes
                }
                let radians = angle * .pi / 180
                let dx = 10 * sin(radians), dy = -10 * cos(radians)
                let red = color(CGPoint(x: rect.midX + dx, y: rect.midY + dy))
                let blue = color(CGPoint(x: rect.midX - dx, y: rect.midY - dy))
                XCTAssertGreaterThan(Int(red[0]) - Int(red[2]), 100, "video=\(video) angle=\(angle) 红色上边须跟随旋转")
                XCTAssertGreaterThan(Int(blue[2]) - Int(blue[0]), 100, "video=\(video) angle=\(angle) 蓝色下边须跟随旋转")
                let edgeDistance = rect.width * 0.4
                let edgeDX = edgeDistance * sin(radians), edgeDY = -edgeDistance * cos(radians)
                let redEdge = color(CGPoint(x: rect.midX + edgeDX, y: rect.midY + edgeDY))
                let blueEdge = color(CGPoint(x: rect.midX - edgeDX, y: rect.midY - edgeDY))
                XCTAssertGreaterThan(Int(redEdge[0]) - Int(redEdge[2]), 80, "Photo must fill the circle near its edge")
                XCTAssertGreaterThan(Int(blueEdge[2]) - Int(blueEdge[0]), 80, "Video poster must fill the circle near its edge")
                XCTAssertTrue(model.gallery.albumButtonImage === thumbnail)
                XCTAssertEqual(service.requestCount, requests, "旋转不得重新加载或清空缩略图")
                XCTAssertEqual(thumbnail.imageOrientation, .up, "控件旋转不能改写源图方向")
            } }
        }
        print("ALBUM-ROTATION mediaKinds=photo,video samples=\(renderDurations.count) snapshot-render-seconds=\(renderDurations); all-photo-ratio-values/backtracking, system-reduced-motion-not-overridden; snapshot work only, not display FPS")
    }

    @MainActor func testFlatDeviceKeepsLastDirectionAndRotationTakesShortestPath() {
        let rotation = CaptureControlOrientation()
        rotation.update(.portrait); rotation.update(.landscapeLeft)
        XCTAssertEqual(rotation.degrees, 90, accuracy: 0.01)
        rotation.update(.faceUp); rotation.update(.unknown)
        XCTAssertEqual(rotation.degrees, 90, accuracy: 0.01)
        rotation.update(.portraitUpsideDown); rotation.update(.landscapeRight)
        XCTAssertEqual(rotation.degrees, 270, accuracy: 0.01)
        XCTAssertEqual(CaptureControlOrientation.shortestDelta(from: 270, to: 0), 90)
    }
    #if targetEnvironment(simulator)
    @MainActor func testRotatingContentsNeverMovesCameraButtonsAcrossAllSevenRatios() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setMode(.manual)
        let host = UIHostingController(rootView: CameraView(model: model).environment(\.captureControlAngle, 0.0))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        model.style = .original; model.filterAdjustments = FilterAdjustments()
        model.setCameraActive(true)
        for _ in 0..<100 { if model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        let names = ["mode", "tools", "lenses", "album", "functions", "shutter", "filter", "flip", "parameters"]
        for ratio in FrameRatio.allCases {
            model.ratio = ratio
            host.rootView = CameraView(model: model).environment(\.captureControlAngle, 0.0)
            try await Task.sleep(for: .milliseconds(350))
            let baseline = model.captureButtonFramesForTesting
            for angle in [90.0, -90.0, 180.0] {
                host.rootView = CameraView(model: model).environment(\.captureControlAngle, angle)
                try await Task.sleep(for: .milliseconds(280))
                for key in names {
                    let before = try XCTUnwrap(baseline[key]), after = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                    XCTAssertEqual(before.minX, after.minX, accuracy: 0.5, key)
                    XCTAssertEqual(before.minY, after.minY, accuracy: 0.5, key)
                    XCTAssertEqual(before.width, after.width, accuracy: 0.5, key)
                    XCTAssertEqual(before.height, after.height, accuracy: 0.5, key)
                }
                if angle == 90 { attach(window, name: "Camera-Landscape-" + ratio.rawValue) }
            }
            attach(window, name: "Camera-Rotated-" + ratio.rawValue)
        }
        model.ratio = .standard; model.setMode(.auto)
        host.rootView = CameraView(model: model).environment(\.captureControlAngle, 90.0)
        model.setCameraActive(true)
        for _ in 0..<100 { if model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        try await Task.sleep(for: .milliseconds(350)); attach(window, name: "Auto-EV-Landscape", heldAngle: 90)
        model.setMode(.manual); model.openParameter(.iso)
        try await Task.sleep(for: .milliseconds(350)); attach(window, name: "Manual-Popup-Landscape", heldAngle: 90)
        model.closePopups()
    }
    @MainActor func testPhotoEditorDialAndCropKeepPortraitLayoutInBothLandscapeDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let session = PhotoEditSession(source: CIImage(image: DemoImageFactory.make())!) { _, _ in }
        let editor = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: RotationLibraryStub()))
        editor.tool = .adjustments
        let host = UIHostingController(rootView: PhotoEditorView(model: editor).environment(\.captureControlAngle, 90.0))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { editor.cancelPreview(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for angle in [90.0, -90.0] {
            host.rootView = PhotoEditorView(model: editor).environment(\.captureControlAngle, angle)
            for _ in 0..<150 { if editor.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNotNil(editor.preview)
            let rect = editor.filterDialPadFrameForTesting
            XCTAssertGreaterThan(rect.width, 250)
            XCTAssertGreaterThan(rect.height, 200)
            XCTAssertTrue(window.bounds.contains(rect))
            XCTAssertLessThanOrEqual(editor.photoViewportFrameForTesting.maxY, rect.minY)
            attach(window, name: "Editor-Dial-\(angle)", heldAngle: angle)
        }
        editor.enterCrop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(editor.editingRulerFrameForTesting.width, 180)
        XCTAssertLessThanOrEqual(editor.photoViewportFrameForTesting.maxY, editor.editingRulerFrameForTesting.minY)
        attach(window, name: "Editor-Crop-Vertical", heldAngle: -90)
        editor.finishCrop(commit: false)
        host.rootView = PhotoEditorView(model: editor).environment(\.captureControlAngle, 0.0)
        try await Task.sleep(for: .milliseconds(300))
        attach(window, name: "Editor-Portrait")
    }
    @MainActor func testGalleryAndPhotoDetailControlsInBothLandscapeDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for angle in [90.0, -90.0] {
            host.rootView = AnyView(GalleryActionBar(selecting: true, selectedCount: 123, preparing: false, completedCount: 0, totalCount: 0,
                libraryBusy: false, captureInProgress: false, destructiveBusy: false, onShare: {}, onCamera: {}, onDelete: {}, onCancelShare: {})
                .environment(\.captureControlAngle, angle).frame(maxHeight: .infinity, alignment: .bottom).background(AppTheme.popupColor))
            try await Task.sleep(for: .milliseconds(300)); attach(window, name: "Gallery-Buttons-\(angle)")
            host.rootView = AnyView(PhotoViewerLayout(image: DemoImageFactory.make(), date: Date(),
                onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {})
                .environment(\.captureControlAngle, angle))
            try await Task.sleep(for: .milliseconds(300)); attach(window, name: "Photo-Detail-Buttons-\(angle)")
        }
        model.setCameraActive(false)
    }
    @MainActor func testAllLandscapeCameraPopupTypesStayInsideWindowForEveryRatio() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let host = UIHostingController(rootView: CameraView(model: model).environment(\.captureControlAngle, 90.0))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.closePopups(); model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(300)); model.setCameraActive(true)
        for angle in [90.0, -90.0] {
            host.rootView = CameraView(model: model).environment(\.captureControlAngle, angle)
            for ratio in FrameRatio.allCases {
                model.ratio = ratio
                for name in ["format", "ratio", "tone", "tools", "functions", "filter", "filterEdit", "iso", "wb"] {
                    model.closePopups(); model.popupFrameForTesting = .zero
                    switch name {
                    case "format": model.toggleToolbarPanel(.format)
                    case "ratio": model.toggleToolbarPanel(.ratio)
                    case "tone": model.toggleToolbarPanel(.tone)
                    case "tools": model.openTools()
                    case "functions": model.openFunctions()
                    case "filter": model.togglePanel(.film)
                    case "filterEdit": model.togglePanel(.film); model.filters.showStrength = true
                    default: model.setMode(.manual); model.openParameter(name == "iso" ? .iso : .wb)
                    }
                    try await Task.sleep(for: .milliseconds(240))
                    let rect = model.popupFrameForTesting
                    XCTAssertGreaterThan(rect.width, 40, name)
                    XCTAssertGreaterThan(rect.height, 100, name)
                    XCTAssertGreaterThanOrEqual(rect.minX, -0.5, name)
                    XCTAssertLessThanOrEqual(rect.maxX, window.bounds.width + 0.5, name)
                    XCTAssertGreaterThanOrEqual(rect.minY, 0, name)
                    XCTAssertLessThanOrEqual(rect.maxY, window.bounds.height + 0.5, name)
                    if ["tools", "functions", "filter", "filterEdit", "iso", "wb"].contains(name) {
                        XCTAssertGreaterThan(rect.width, window.bounds.width - 40, "\(name) should keep the portrait full-width card")
                        XCTAssertGreaterThan(rect.maxY, window.bounds.height - 80, "\(name) should stay near the portrait bottom")
                    } else {
                        XCTAssertLessThan(rect.minY, 160, "\(name) should stay attached below the top toolbar")
                        XCTAssertGreaterThan(rect.width, window.bounds.width - 24, "\(name) should keep the portrait full-width card")
                    }
                    if ratio == .standard && angle == 90 {
                        try await Task.sleep(for: .milliseconds(350))
                        attach(window, name: "Landscape-Popup-" + name, heldAngle: angle)
                    }
                }
            }
        }
    }
    @MainActor func testRoundTextLabelsAndGalleryScopeFitInPortraitAndLandscape() async throws {
        XCTAssertEqual(RoundTextControlLabel.lines("曝光补偿"), "曝光\n补偿")
        XCTAssertEqual(RoundTextControlLabel.lines("颗粒大小"), "颗粒\n大小")
        XCTAssertEqual(RoundTextControlLabel.lines("颗粒饱和度"), "颗粒\n饱和度")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black)); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for angle in [0.0, 90.0, -90.0] {
            host.rootView = AnyView(VStack(spacing: 36) {
                HStack { GalleryScopeLabel(recentOnly: false); GalleryScopeLabel(recentOnly: true) }
                HStack(spacing: 18) { ForEach(["色彩", "明暗", "效果"], id: \.self) { RoundTextControlLabel(title: $0, highlighted: true) } }
                HStack(spacing: 18) { ForEach(["曝光补偿", "颗粒大小", "颗粒饱和度", "模糊／锐化"], id: \.self) { RoundTextControlLabel(title: $0) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.popupColor).environment(\.captureControlAngle, angle))
            try await Task.sleep(for: .milliseconds(300)); attach(window, name: "Bounded-Labels-\(angle)", heldAngle: angle)
        }
    }
    @MainActor func testGalleryKeepsPortraitPhotosAndOrderWhenDeviceRotates() async throws {
        let service = RotationGalleryService()
        let library = PhotoLibraryViewModel(service: service)
        let gallery = GalleryViewModel(browser: service, library: library)
        gallery.refresh()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: GalleryView(model: gallery, library: library, isDemo: true, onCamera: {}).environment(\.captureControlAngle, 0))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for angle in [0.0, 90.0, -90.0] {
            host.rootView = GalleryView(model: gallery, library: library, isDemo: true, onCamera: {}).environment(\.captureControlAngle, angle)
            try await Task.sleep(for: .milliseconds(400))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            var red = CGPoint.zero, blue = CGPoint.zero, nr = 0.0, nb = 0.0
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 245 && bytes[i + 1] < 10 && bytes[i + 2] < 10 { red.x += CGFloat(x); red.y += CGFloat(y); nr += 1 }
                if bytes[i + 2] > 245 && bytes[i] < 10 && bytes[i + 1] < 10 { blue.x += CGFloat(x); blue.y += CGFloat(y); nb += 1 }
            } }
            XCTAssertGreaterThan(nr, 1000); XCTAssertGreaterThan(nb, 1000)
            XCTAssertEqual(red.x / nr, blue.x / nb, accuracy: 1, "Gallery thumbnails stay upright in portrait coordinates")
            XCTAssertLessThan(red.y / nr, blue.y / nb - 20)
            XCTAssertEqual(gallery.photos.map(\.id), ["rotation-0", "rotation-1", "rotation-2"])
            attach(window, name: "Portrait-Gallery-Device-\(angle)", heldAngle: angle)
        }
    }
    @MainActor private func attach(_ window: UIWindow, name: String, heldAngle: Double = 0) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let visible = heldAngle == 0 ? image : UIImage(cgImage: image.cgImage!, scale: 1, orientation: heldAngle > 0 ? .left : .right)
        let shot = XCTAttachment(image: visible); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    #endif
}
private final class RotationLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("unused")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

private final class RotationGalleryService: PhotoBrowserService, PhotoLibraryService {
    var isVideo = false
    var requestCount = 0
    var onLibraryChange: (() -> Void)?
    var existingAccess: PhotoLibraryAccess? { .full }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) {
        completion(PhotoPage(photos: (0..<3).map { LibraryPhoto(id: "rotation-\($0)", date: nil, isVideo: isVideo) }, hasMore: false))
    }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        requestCount += 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        completion(image, nil); return PhotoImageRequest(cancel: {})
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("saved")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}

/// 保持同一 SwiftUI 树，只更新角度；反复替换 hosting root 会销毁旧几何观察器，影响测试取框。
private final class AlbumThumbnailRotationAngle: ObservableObject {
    @Published var angle = 0.0
}
private struct AlbumThumbnailRotationHarness: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject var rotation: AlbumThumbnailRotationAngle
    var body: some View {
        CameraView(model: model).shutterBar
            .environment(\.captureControlAngle, rotation.angle)
            .frame(maxHeight: .infinity).background(.black)
    }
}
