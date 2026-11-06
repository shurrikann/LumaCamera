import XCTest
import CoreImage
import ImageIO
import UIKit
@testable import LumaCamera

final class PhotoEditMetadataTests: XCTestCase {
    func testRAWRecipeCanRemoveBakedFilterWithoutChangingCaptureFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = PhotoCaptureDiagnosticsStore(directory:directory)
        var parameters = PhotoCaptureParameters(); parameters.iso = 100; parameters.filterID = FilmStyle.leicaM9.rawValue
        parameters.filterName = FilmStyle.leicaM9.title; parameters.filterIntensity = 0.8; parameters.adaptiveHighDynamic = true
        let original = PhotoCaptureDiagnostics(parameters:parameters)
        XCTAssertTrue(store.save(original,assetID:"raw-original"))
        var recipe = PhotoAdjustments(); recipe.rawDevelopment = RAWDevelopmentSettings(adaptive:false)
        XCTAssertTrue(store.copyRecord(from:"raw-original",to:"raw-copy",adjustments:recipe,sourceIsOriginal:true))
        let copy = try XCTUnwrap(store.load(assetID:"raw-copy"))
        XCTAssertFalse(copy.currentFilter?.applied ?? true)
        XCTAssertEqual(copy.parameters?.iso,100); XCTAssertEqual(copy.parameters?.adaptiveHighDynamic,false)
        XCTAssertEqual(store.load(assetID:"raw-original"),original)
    }
    private let metadata: [String: Any] = [
        kCGImagePropertyOrientation as String: 6,
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifISOSpeedRatings as String: [1250], kCGImagePropertyExifExposureTime as String: 0.0125,
            kCGImagePropertyExifFNumber as String: 1.78, kCGImagePropertyExifFocalLength as String: 6.9,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: 24, kCGImagePropertyExifLensModel as String: "Fixture Lens",
            kCGImagePropertyExifDateTimeOriginal as String: "2026:10:16 20:00:00",
            kCGImagePropertyExifPixelXDimension as String: 9999, kCGImagePropertyExifPixelYDimension as String: 8888,
            kCGImagePropertyExifSubjectArea as String: [2000, 2000, 100, 100]],
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone 17 Pro", kCGImagePropertyTIFFArtist as String: "Fixture Author", kCGImagePropertyTIFFCopyright as String: "Fixture Copyright"],
        kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 31.23, kCGImagePropertyGPSLatitudeRef as String: "N", kCGImagePropertyGPSLongitude as String: 121.47, kCGImagePropertyGPSLongitudeRef as String: "E"],
        kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCByline as String: ["Fixture Author"], kCGImagePropertyIPTCCopyrightNotice as String: "Fixture Copyright"]]
    func testCroppedRotatedJPEGKeepsCaptureFactsButUpdatesGeometry() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64)).settingProperties(metadata)
        var recipe = PhotoAdjustments(); recipe.quarterTurns = 1
        recipe.crop = PhotoCropRectangle(x: 0.125, y: 0.125, width: 0.5, height: 0.75)
        recipe.filterID = FilmStyle.leicaM9.rawValue
        let output = try PhotoEditRenderer.render(source: image, adjustments: recipe)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output.resource.data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        let gps = try XCTUnwrap(props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue, 1250)
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime as String] as? Double ?? 0, 0.0125, accuracy: 0.000001)
        XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, "Fixture Lens")
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:10:16 20:00:00")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "iPhone 17 Pro")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "Fixture Author")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "Fixture Copyright")
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String, "Fixture Copyright")
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 31.23, accuracy: 0.000001)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 32)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 36)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, 32)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension as String] as? Int, 36)
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertNil(exif[kCGImagePropertyExifSubjectArea as String])
        let again = try PhotoEditRenderer.render(source: XCTUnwrap(CIImage(data: output.resource.data)), adjustments: PhotoAdjustments())
        let second = try XCTUnwrap(CGImageSourceCreateWithData(again.resource.data as CFData, nil))
        let secondProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(second, 0, nil) as? [String: Any])
        XCTAssertEqual((secondProps[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFArtist as String] as? String, "Fixture Author")
    }
    func testNewAssetCopiesCaptureDiagnosticsWithoutAlteringOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoCaptureDiagnosticsStore(directory: directory)
        var parameters = PhotoCaptureParameters(); parameters.iso = 1250; parameters.exposureSeconds = 0.0125; parameters.focusPosition = 0.67; parameters.whiteBalanceKelvin = 5200
        let original = PhotoCaptureDiagnostics(rows: [.init(title: "快门时主镜头", value: "主摄")], parameters: parameters)
        XCTAssertTrue(store.save(original, assetID: "original"))
        var recipe = PhotoAdjustments(); recipe.filterID = FilmStyle.leicaM9.rawValue; recipe.filterIntensity = 0.65
        XCTAssertTrue(store.copyRecord(from: "original", to: "edited", adjustments: recipe))
        XCTAssertEqual(store.load(assetID: "original"), original)
        let copy = try XCTUnwrap(store.load(assetID: "edited"))
        XCTAssertEqual(copy.parameters, parameters)
        XCTAssertTrue(copy.rows.contains { $0.title == "快门时主镜头" && $0.value == "主摄" })
        XCTAssertEqual(copy.detailRows.first { $0.title == "滤镜强度" }?.value, "65%")
        XCTAssertTrue(store.copyRecord(from: "missing", to: "unknown", adjustments: recipe))
        XCTAssertNil(store.load(assetID: "unknown")?.parameters)
    }
}
