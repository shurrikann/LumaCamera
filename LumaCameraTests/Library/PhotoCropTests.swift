import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class PhotoCropTests: XCTestCase {
    func testCropRotationFlipsRenderCorrectDimensionsAndMetadataRoundTrip() throws {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 20, y: 30, width: 64, height: 96))
        for rotation in 0..<4 {
            for horizontal in [false, true] {
                for vertical in [false, true] {
                    var recipe = PhotoAdjustments(); recipe.quarterTurns = rotation; recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
                    recipe.crop = PhotoCropRectangle(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    let restored = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(recipe))
                    XCTAssertEqual(restored, recipe)
                    let image = recipe.apply(to: source)
                    XCTAssertEqual(image.extent.minX, 0, accuracy: 0.001); XCTAssertEqual(image.extent.minY, 0, accuracy: 0.001)
                    XCTAssertEqual(image.extent.width, rotation % 2 == 0 ? 32 : 48, accuracy: 0.001)
                    XCTAssertEqual(image.extent.height, rotation % 2 == 0 ? 48 : 32, accuracy: 0.001)
                    let rendered = try PhotoEditRenderer.render(source: source, adjustments: recipe)
                    XCTAssertEqual(rendered.preview.size.width, image.extent.width, accuracy: 1)
                    XCTAssertEqual(rendered.preview.size.height, image.extent.height, accuracy: 1)
                }
            }
        }
        let legacy = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.crop, .full); XCTAssertFalse(legacy.flipHorizontal); XCTAssertEqual(legacy.filterIntensity, 0.8)
    }
    @MainActor func testCropPreviewUpdatesForStraightenAndPerspective() async throws {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 240)
        var source = CIImage(color: .black).cropped(to: extent)
        for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
            let rect = CGRect(x: CGFloat(index % 2) * 160, y: CGFloat(index / 2) * 120, width: 160, height: 120)
            source = CIImage(color: CIColor(color: color)).cropped(to: rect).composited(over: source)
        }
        let model = PhotoEditorViewModel(session: PhotoEditSession(source: source) { _, _ in },
                                         library: PhotoLibraryViewModel(service: CropLibraryStub()))
        defer { model.cancelPreview() }
        model.enterCrop()
        for _ in 0..<150 { if model.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let initial = try XCTUnwrap(model.preview?.pngData())

        model.adjustments.straightenAngle = 22
        var afterRotation: Data?
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            if let data = model.preview?.pngData(), data != initial { afterRotation = data; break }
        }
        XCTAssertNotNil(afterRotation, "校正角度必须实时更新裁剪预览")

        model.adjustments.stretch.horizontal = 0.45
        var afterPerspective: Data?
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            if let data = model.preview?.pngData(), data != afterRotation { afterPerspective = data; break }
        }
        XCTAssertNotNil(afterPerspective, "透视参数必须实时更新裁剪预览")
    }

    func testCropUsesDisplayedTopLeftAndHandlesInvalidOrExcessiveGestures() {
        let extent = CGRect(x: 10, y: 20, width: 100, height: 200)
        let rect = PhotoCropRectangle(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let pixels = rect.imageRect(in: extent)
        XCTAssertEqual(pixels.minX, 20, accuracy: 0.0001); XCTAssertEqual(pixels.minY, 100, accuracy: 0.0001)
        XCTAssertEqual(pixels.width, 30, accuracy: 0.0001); XCTAssertEqual(pixels.height, 80, accuracy: 0.0001)
        for index in 0..<4 {
            let resized = rect.resized(corner: index, delta: CGSize(width: 1000, height: -1000))
            XCTAssertGreaterThanOrEqual(resized.width, 0.019); XCTAssertGreaterThanOrEqual(resized.height, 0.019)
            XCTAssertLessThanOrEqual(resized.x+resized.width, 1.001); XCTAssertLessThanOrEqual(resized.y+resized.height, 1.001)
        }
        XCTAssertEqual(PhotoCropRectangle(x: .nan).clamped, .full)
        XCTAssertEqual(rect.scaled(.infinity), rect)
        XCTAssertEqual(rect.moved(CGSize(width: -20, height: 20)).x, 0)
    }
    func testCropAndFlipDirectionsMatchDisplayedImagePixels() throws {
        let extent = CGRect(x: 0, y: 0, width: 2, height: 2)
        var source = CIImage(color: .white).cropped(to: extent)
        for (color, rect) in [(CIColor.red, CGRect(x: 0, y: 1, width: 1, height: 1)), (.green, CGRect(x: 1, y: 1, width: 1, height: 1)), (.blue, CGRect(x: 0, y: 0, width: 1, height: 1))] {
            source = CIImage(color: color).cropped(to: rect).composited(over: source)
        }
        let context = CIContext()
        func pixel(_ recipe: PhotoAdjustments, x: CGFloat, y: CGFloat) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(recipe.apply(to: source), toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return bytes
        }
        var crop = PhotoAdjustments(); crop.crop = PhotoCropRectangle(x: 0, y: 0, width: 0.5, height: 0.5)
        let topLeft = pixel(crop, x: 0, y: 0)
        XCTAssertGreaterThan(topLeft[0], 250); XCTAssertLessThan(topLeft[1], 5); XCTAssertLessThan(topLeft[2], 5)
        var horizontal = PhotoAdjustments(); horizontal.flipHorizontal = true
        let flipped = pixel(horizontal, x: 0, y: 0)
        XCTAssertTrue(flipped.prefix(3).allSatisfy { $0 > 250 }, "Horizontal flip must place the white bottom-right pixel at bottom-left")
        var vertical = PhotoAdjustments(); vertical.flipVertical = true
        let verticalPixel = pixel(vertical, x: 0, y: 0)
        XCTAssertGreaterThan(verticalPixel[0], 250); XCTAssertLessThan(verticalPixel[1], 5); XCTAssertLessThan(verticalPixel[2], 5)
    }
    func testStretchRoundTripsAndKeepsCropExtent() throws {
        var adjustments = PhotoAdjustments()
        XCTAssertTrue(adjustments.stretch.isIdentity)
        adjustments.stretch.horizontal = 0.25
        adjustments.stretch.vertical = 0.15
        let encoded = try JSONEncoder().encode(adjustments)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: encoded)
        XCTAssertEqual(decoded.stretch, adjustments.stretch)

        let source = CIImage(color: CIColor(red: 0.5, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 120, height: 90))
        let output = adjustments.stretch.apply(to: source)
        XCTAssertEqual(output.extent, source.extent)
        XCTAssertFalse(adjustments.stretch.isIdentity)

        var clamped = PhotoStretch(horizontal: -2, vertical: 2)
        clamped = clamped.clamped
        XCTAssertEqual(clamped.horizontal, -0.5)
        XCTAssertEqual(clamped.vertical, 0.5)
    }

    func testStraighteningMaintainsExtentAndDoesNotExposeBlackCorners() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 96))
        let context = CIContext()
        for angle in [-45.0,-13,0.5,17,45] {
            var recipe = PhotoAdjustments(); recipe.straightenAngle = angle
            let image = recipe.apply(to: source)
            XCTAssertEqual(image.extent, source.extent)
            var pixel = [UInt8](repeating: 0, count: 4)
            for point in [CGPoint(x: 0,y: 0), CGPoint(x: 63,y: 0), CGPoint(x: 0,y: 95), CGPoint(x: 63,y: 95)] {
                context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1,height: 1)), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                XCTAssertGreaterThan(pixel[0], 245, "No black corner after straighten \(angle)"); XCTAssertEqual(pixel[3],255)
            }
            XCTAssertEqual(try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        }
    }
    @MainActor func testCropCancelRestoresEntryAndDoneCommitsWithoutResettingFilterRecipe() {
        let source = CIImage(color: .white).cropped(to: CGRect(x:0,y:0,width:640,height:960))
        let model = PhotoEditorViewModel(session: PhotoEditSession(source: source) { _, _ in }, library: PhotoLibraryViewModel(service: CropLibraryStub()))
        model.selectFilter(.fujiCC); model.parameterBinding(.temperature).wrappedValue = 17
        model.tool = .adjustments
        let before = model.adjustments
        model.enterCrop(); model.rotate(); model.flip(horizontal: true); model.setCropAspect(.square); model.adjustments.straightenAngle = 12
        model.finishCrop(commit: false)
        XCTAssertEqual(model.adjustments,before); XCTAssertEqual(model.tool,.adjustments)
        model.enterCrop(); model.setCropAspect(.square); model.adjustments.straightenAngle = -5
        let committed = model.adjustments
        model.finishCrop(commit: true)
        XCTAssertEqual(model.adjustments,committed); XCTAssertEqual(model.tool,.adjustments)
        XCTAssertEqual(model.adjustments.filterAdjustments[.temperature],17)
        model.cancelPreview()
    }
    @MainActor func testSwitchingEditorToolsKeepsCropAndAllSharedParametersThroughSave() {
        var saved: PhotoAdjustments?
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 960))
        let session = PhotoEditSession(source: source) { recipe, completion in saved = recipe; completion(.failure(PhotoDetailError.unavailable)) }
        let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: CropLibraryStub()))
        model.tool = .crop; model.setCropAspect(.square)
        let crop = model.adjustments.crop
        model.flip(horizontal: true); model.flip(horizontal: false)
        model.tool = .filters; model.selectFilter(.fujiNC)
        model.tool = .adjustments
        for parameter in FilterParameter.allCases where parameter != .strength { model.parameterBinding(parameter).wrappedValue = 7 }
        XCTAssertEqual(model.adjustments.crop.width, crop.width)
        XCTAssertEqual(model.adjustments.crop.height, crop.height)
        XCTAssertTrue(model.adjustments.flipHorizontal); XCTAssertTrue(model.adjustments.flipVertical)
        XCTAssertEqual(Set(FilterEditorTab.allCases.flatMap(\.parameters)), Set(FilterParameter.allCases))
        model.save { _ in }
        XCTAssertEqual(saved, model.adjustments)
        model.cancelPreview()
    }
}
private final class CropLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("saved")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
