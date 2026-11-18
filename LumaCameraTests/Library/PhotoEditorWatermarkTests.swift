import XCTest
import SwiftUI
import CoreImage
import ImageIO
import Photos
import AVFoundation
@testable import LumaCamera

final class PhotoEditorWatermarkTests: XCTestCase {
    private let content = PhotoWatermarkContent(capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
        signature: "SHURRIKANN", location: "杭州市 · 西湖区", exposureSeconds: 1/125,
        iso: 200, whiteBalanceKelvin: 5200, ev: -0.3, filter: "原片")
    private func source(_ size: CGSize = CGSize(width: 600, height: 800)) -> CIImage {
        { () -> CIImage in
            let image = CIImage(image: UIImage(named: "FilterLandscape")!)!
            return image.transformed(by: CGAffineTransform(scaleX: size.width/image.extent.width, y: size.height/image.extent.height))
        }()
    }
    func testRecipeCompatibilityMetadataAndRenderedFiles() throws {
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        XCTAssertNil(old.watermark)
        let metadata: [String: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifExposureTime as String: 0.125,
            kCGImagePropertyExifISOSpeedRatings as String: [640],
            kCGImagePropertyExifFocalLength as String: 6.765,
            kCGImagePropertyExifDateTimeOriginal as String: "2026:02:17 20:15:30",
            kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "作者"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 30.2,
                kCGImagePropertyGPSLatitudeRef as String: "N", kCGImagePropertyGPSLongitude as String: 120.1,
                kCGImagePropertyGPSLongitudeRef as String: "E"]]
        let read = PhotoEditWatermark.content(metadata: metadata)
        XCTAssertEqual(read.iso, 640); XCTAssertEqual(read.exposureSeconds, 0.125)
        XCTAssertEqual(read.signature, "作者"); XCTAssertEqual(read.location, "30.20000, 120.10000")
        XCTAssertEqual(ISO8601DateFormatter().string(from: read.capturedAt), "2026-02-17T12:15:30Z")
        for size in [CGSize(width: 600, height: 800), CGSize(width: 800, height: 600)] {
            for style in PhotoWatermarkStyle.allCases {
                for flags in 0..<4 {
                    var recipe = PhotoAdjustments()
                    recipe.watermark = PhotoEditWatermark(settings: .init(style: style, showsLocation: flags & 1 != 0,
                        showsParameters: flags & 2 != 0), content: content)
                    recipe.crop = PhotoCropRectangle(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                    let restored = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(recipe))
                    XCTAssertEqual(restored, recipe)
                    let input = source(size), bare = recipe.apply(to: input, includesWatermark: false)
                    let expected = PhotoWatermarkLayout(photoSize: bare.extent.size, settings: recipe.watermark!.settings, content: content)
                    let output = try PhotoEditRenderer.render(source: input, adjustments: recipe, metadata: metadata)
                    let file = try XCTUnwrap(CGImageSourceCreateWithData(output.resource.data as CFData, nil))
                    let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, nil))
                    XCTAssertEqual(Double(cg.width), expected.size.width, accuracy: 1)
                    XCTAssertEqual(Double(cg.height), expected.size.height, accuracy: 1)
                    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
                    XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
                    let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
                    XCTAssertEqual((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0, 6.765, accuracy: 0.0001)
                    XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue, cg.width)
                    XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension as String] as? NSNumber)?.intValue, cg.height)
                    XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue, 640)
                    if flags == 3 {
                        let attachment = XCTAttachment(data: output.resource.data, uniformTypeIdentifier: "public.jpeg")
                        attachment.name = "Editor-Watermark-\(style.rawValue)-\(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
        print("EDITOR-WATERMARK files=32 PhotosWrites=0")
    }
    func testCaptureRAWRecipeRetainsEditableWatermarkAndCanRemoveIt() throws {
        var look = CaptureLook(); look.border = true
        look.watermark = .init(style: .newYear, showsLocation: true, showsParameters: true)
        look.watermarkContent = content
        let initial = RAWDevelopmentRecipe.initial(source: source(), look: look, hdr: true)
        XCTAssertEqual(initial.watermark?.content, content)
        XCTAssertEqual(initial.watermark?.settings, look.watermark)
        let described = try RAWDevelopmentRecipe.applying(initial, to: source())
        var resumed = try XCTUnwrap(RAWDevelopmentRecipe.read(described.properties))
        XCTAssertEqual(resumed, initial)
        resumed.watermark = nil
        XCTAssertNotNil(resumed.rawDevelopment)
        XCTAssertEqual(resumed.apply(to: source()).extent, source().extent)
    }
    @MainActor func testDraftDoesNotChangeCaptureSettingsAndSaveFreezesWatermark() async throws {
        var saved: PhotoAdjustments?
        var callback: ((Result<PhotoEditResult, Error>) -> Void)?
        let session = PhotoEditSession(source: source(), watermarkContent: content) { recipe, done in saved = recipe; callback = done }
        let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: WatermarkEditorLibraryStub()))
        let preferences = CapturePreferencesStore().load()
        model.setWatermarkInformation(location: true, parameters: true)
        XCTAssertNil(model.adjustments.watermark)
        model.selectWatermarkStyle(.blurredPhoto)
        XCTAssertEqual(model.adjustments.watermark?.content, content)
        model.save { _ in }
        model.selectWatermarkStyle(.newYear); model.setWatermarkInformation(location: false)
        XCTAssertEqual(model.adjustments, saved)
        callback?(.failure(PhotoDetailError.unavailable))
        XCTAssertFalse(model.saving)
        XCTAssertEqual(CapturePreferencesStore().load(), preferences)
        let reopened = PhotoEditorViewModel(session: PhotoEditSession(source: source(), initialAdjustments: try XCTUnwrap(saved)) { _, _ in },
            library: PhotoLibraryViewModel(service: WatermarkEditorLibraryStub()))
        XCTAssertEqual(reopened.adjustments.watermark, saved?.watermark)
        reopened.selectWatermarkStyle(.blurredPhoto); XCTAssertNil(reopened.adjustments.watermark)
        model.cancelPreview(); reopened.cancelPreview()
    }
    func testHDRPixelsRemainExtendedOutsideArtworkAndLiveGeometryMatches() throws {
        let input = CIImage(color: CIColor(red: 2, green: 1.4, blue: 0.8, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 300))
        let context = CIContext()
        for style in PhotoWatermarkStyle.allCases {
            var recipe = PhotoAdjustments(); recipe.watermark = PhotoEditWatermark(settings: .init(style: style), content: content)
            // Exercise the compositing stage before unrelated tone / filter processing.
            let image = recipe.watermark!.apply(to: input, filterID: FilmStyle.original.rawValue, intensity: 0)
            let layout = PhotoWatermarkLayout(photoSize: input.extent.size, settings: recipe.watermark!.settings, content: content)
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: layout.photo.midX, y: layout.size.height-layout.photo.midY, width: 1, height: 1),
                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            }
            XCTAssertGreaterThan(pixel[0], 1.5)
            XCTAssertEqual(LivePhotoEditRenderer.frame(input, adjustments: recipe, time: 0).extent,
                           recipe.apply(to: input).extent)
        }
    }
    @MainActor func testEditorPanelRepeatedOperationsCropAndSaveSnapshot() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        var samples = [Double](), operations = 0
        for width in [CGFloat(320), 390, 440] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            for ratio in FrameRatio.allCases {
                let session = PhotoEditSession(source: source(CGSize(width: 600, height: 600/ratio.portraitRatio)), watermarkContent: content) { _, done in done(.failure(PhotoDetailError.unavailable)) }
                let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: WatermarkEditorLibraryStub()))
                model.toggleEditorControls(.watermark)
                host.rootView = AnyView(PhotoEditorView(model: model).environment(\.captureControlAngle, 90).id(session.id))
                for _ in 0..<150 { if model.captureButtonFramesForTesting["photo.editor.watermark.panel"] != nil && model.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                for _ in 0..<3 {
                    for style in PhotoWatermarkStyle.allCases {
                        model.selectWatermarkStyle(style); operations += 1
                        XCTAssertEqual(model.adjustments.watermark?.settings.style, style)
                        model.setWatermarkInformation(location: true, parameters: true)
                        model.selectWatermarkStyle(style); operations += 1
                        XCTAssertNil(model.adjustments.watermark)
                    }
                }
                model.selectWatermarkStyle(.newYear)
                try await Task.sleep(for: .milliseconds(250))
                let panel = try XCTUnwrap(model.captureButtonFramesForTesting["photo.editor.watermark.panel"])
                XCTAssertGreaterThan(panel.height, 100); XCTAssertLessThanOrEqual(panel.maxX, width+1)
                for style in PhotoWatermarkStyle.allCases {
                    let button = try XCTUnwrap(model.captureButtonFramesForTesting["photo.editor.watermark."+style.rawValue])
                    XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(button)); XCTAssertEqual(button.height, 54, accuracy: 1)
                }
                let start = CACurrentMediaTime()
                let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                samples.append((CACurrentMediaTime()-start)*1000)
                if ratio == .standard {
                    let attachment = XCTAttachment(image: snapshot); attachment.name = "Editor-Watermark-Panel-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
                }
                let watermark = model.adjustments.watermark
                model.enterCrop(); XCTAssertFalse(model.editorControlsVisible)
                model.adjustments.crop = PhotoCropRectangle(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
                model.finishCrop(commit: false)
                XCTAssertEqual(model.adjustments.watermark, watermark); XCTAssertEqual(model.adjustments.crop, .full)
                for _ in 0..<10 { model.toggleEditorControls(.watermark); model.closeEditorControls() }
                model.presentSaveOptions(); model.dismissSaveOptions(); XCTAssertEqual(model.adjustments.watermark, watermark)
                model.cancelPreview(); let cancelled = model.adjustments; model.selectWatermarkStyle(.whiteFrame)
                XCTAssertEqual(model.adjustments, cancelled)
            }
        }
        print("EDITOR-WATERMARK UI widths=3 ratios=\(FrameRatio.allCases.count) operations=\(operations) snapshot_ms=\(samples) PhotosWrites=0")
    }
    #if !targetEnvironment(simulator)
    @MainActor func testExistingDNGReDevelopmentWatermarkWithoutWritingPhotos() async throws {
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { throw XCTSkip("Photo read access unavailable") }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = 120
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var rawResource: PHAssetResource?
        assets.enumerateObjects { asset, _, stop in
            if let raw = PHAssetResource.assetResources(for: asset).first(where: {
                PhotoResourceKind.isRAW(typeIdentifier: $0.uniformTypeIdentifier, filename: $0.originalFilename)
            }) { rawResource = raw; stop.pointee = true }
        }
        guard let rawResource else { throw XCTSkip("No existing DNG among recent 120 photos; diagnostics do not create Photos assets") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let readOptions = PHAssetResourceRequestOptions(); readOptions.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: rawResource, toFile: url, options: readOptions)
        let raw = try Data(contentsOf: url)
        let container = try XCTUnwrap(CGImageSourceCreateWithData(raw as CFData, nil))
        let metadata = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any] ?? [:]
        let captured = PhotoEditWatermark.content(metadata: metadata)
        let result = try await Task.detached(priority: .userInitiated) { () throws -> [(PhotoWatermarkStyle, PhotoEditResult, Double)] in
            var outputs = [(PhotoWatermarkStyle, PhotoEditResult, Double)]()
            for style in [PhotoWatermarkStyle.newYear, .glassStrip] {
                var recipe = PhotoAdjustments(); recipe.rawDevelopment = RAWDevelopmentSettings(hdr: true, maximumPixels: 3_000_000)
                recipe.watermark = PhotoEditWatermark(settings: .init(style: style, showsParameters: true), content: captured)
                let developer = RAWPhotoDevelopment(raw: raw, initial: recipe, metadata: metadata)
                let start = CACurrentMediaTime(), output = try developer.render(recipe)
                XCTAssertEqual(developer.raw, raw)
                outputs.append((style, output, (CACurrentMediaTime()-start)*1000))
            }
            return outputs
        }.value
        for (style, output, milliseconds) in result {
            let file = try XCTUnwrap(CGImageSourceCreateWithData(output.resource.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
            XCTAssertGreaterThanOrEqual((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? 0, 10)
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
            let recipe = try XCTUnwrap(RAWDevelopmentRecipe.read(properties))
            XCTAssertEqual(recipe.watermark?.settings.style, style)
            var removed = recipe; removed.watermark = nil
            XCTAssertNil(try RAWDevelopmentRecipe.read(RAWDevelopmentRecipe.applying(removed, to: CIImage(color: .black)).properties)?.watermark)
            let attachment = XCTAttachment(data: output.resource.data, uniformTypeIdentifier: "public.heic")
            attachment.name = "Editor-DNG-Watermark-"+style.rawValue; attachment.lifetime = .keepAlways; add(attachment)
            print("EDITOR-WATERMARK actualDNG \(style.rawValue) ms=\(milliseconds) depth=\(properties[kCGImagePropertyDepth as String] ?? "missing") PhotosWrites=0")
        }
    }
    #endif
    func testExportPerformanceRepeatedRendering() throws {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 4000, height: 3000)] {
            for style in PhotoWatermarkStyle.allCases {
                var samples = [Double]()
                for _ in 0..<(size.width > 1000 ? 3 : 5) {
                    try autoreleasepool {
                        var recipe = PhotoAdjustments(); recipe.watermark = PhotoEditWatermark(settings: .init(style: style, showsLocation: true, showsParameters: true), content: content)
                        let start = CACurrentMediaTime()
                        let result = try PhotoEditRenderer.render(source: source(size), adjustments: recipe)
                        XCTAssertFalse(result.resource.data.isEmpty)
                        samples.append((CACurrentMediaTime()-start)*1000)
                    }
                }
                print("EDITOR-WATERMARK export \(Int(size.width))x\(Int(size.height)) \(style.rawValue) n=\(samples.count) ms=\(samples)")
            }
        }
    }
}
private final class WatermarkEditorLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { XCTFail("No Photos writes"); completion(.failure(PhotoDetailError.unavailable)) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { XCTFail("No Photos writes"); completion(.failure(PhotoDetailError.unavailable)) }
}
