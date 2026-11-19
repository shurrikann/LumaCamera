import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LumaCamera

final class AstroImageEncoderTests: XCTestCase {
    func testActualAndEquivalentFocalLengthAreSeparateInSavedFile() throws {
        let image = try makeImage(width: 120, height: 80)
        var options = AstroImageOptions(); options.format = .jpg
        options.focalLength35mm = 24
        func exif(_ options: AstroImageOptions) throws -> [CFString: Any] {
            let data = try XCTUnwrap(AstroImageEncoder.encode(image, options: options))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return try XCTUnwrap(values[kCGImagePropertyExifDictionary] as? [CFString: Any])
        }
        let unknown = try exif(options)
        XCTAssertNil(unknown[kCGImagePropertyExifFocalLength])
        XCTAssertEqual((unknown[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, 24)
        options.focalLengthMM = 6.765
        let known = try exif(options)
        XCTAssertEqual(try XCTUnwrap((known[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue), 6.765, accuracy: 0.001)
        XCTAssertEqual((known[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, 24)
    }
    func testJPGAndSquareCrop() throws {
        let source = try makeImage(width: 120, height: 80)
        var options = AstroImageOptions()
        options.format = .jpg
        options.aspect = 1
        options.exposureSeconds = 0.5
        options.iso = 800
        options.lensName = "Test Lens"
        let data = try XCTUnwrap(AstroImageEncoder.encode(source, options: options))
        let sourceImage = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(sourceImage) as String?, UTType.jpeg.identifier)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 80)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 80)
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((exif[kCGImagePropertyExifLensModel] as? String), "Test Lens")
    }

    func testHEIFWatermarkChangesPixels() throws {
        let source = try makeImage(width: 120, height: 80)
        var plain = AstroImageOptions(); plain.format = .heif
        var marked = plain; marked.watermark = true
        let plainData = try XCTUnwrap(AstroImageEncoder.encode(source, options: plain))
        let markedData = try XCTUnwrap(AstroImageEncoder.encode(source, options: marked))
        XCTAssertNotEqual(plainData, markedData)
        let sourceImage = try XCTUnwrap(CGImageSourceCreateWithData(markedData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(sourceImage) as String?, UTType.heic.identifier)
    }

    func testCommentsRoundTripInJPGAndHEIFFiles() throws {
        let image = try makeImage(width: 120, height: 80)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let start = ProcessInfo.processInfo.systemUptime
        var count = 0
        for format in [AstroImageFormat.jpg, .heif] {
            for (mode, englishName) in [("星空照片", "Astro Photo"), ("星轨", "Star Trails")] {
                let options = AstroImageOptions(format: format, mode: mode, frameCount: 12, exposureSeconds: 0.012195,
                                               iso: 54, lensName: "Test Lens", focalLengthMM: 6.765, focalLength35mm: 24)
                let encoded = try XCTUnwrap(AstroImageEncoder.encode(image, options: options))
                let url = folder.appendingPathComponent("\(count).\(format.fileExtension)")
                try encoded.write(to: url)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, format.utType.identifier)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                XCTAssertEqual(exif[kCGImagePropertyExifUserComment] as? String, "Luma \(englishName) | 12 frames | 0.012195s | ISO 54")
                XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime] as? Double), 0.012195, accuracy: 0.000001)
                XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], [54])
                XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, 24)
                let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
                let description = CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description[x-default]" as CFString) as String?
                XCTAssertEqual(description, "Luma \(mode) · 12 帧 · 0.012195s · ISO 54")
                count += 1
            }
        }
        XCTAssertEqual(count, 4)
        print("ASTRO-METADATA samples=\(count) formats=JPG,HEIF encodeWriteReadMilliseconds=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
    }

    func testAstroDetailFieldsRoundTripAndLocationIsOptional() throws {
        let image = try makeImage(width: 120, height: 80)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        for format in [AstroImageFormat.jpg, .heif] {
            for location in [PhotoLocation(latitude: -33.87, longitude: 151.21, timestamp: date), nil] {
                let parameters = PhotoCaptureParameters(capturedAt: date, mode: "星空", shootingType: "星空照片",
                    aperture: 1.78, requestedExposureBiasEV: -0.7, whiteBalanceKelvin: 4100,
                    whiteBalanceTint: -4, whiteBalanceMode: "手动", requestedFormat: "HEIF", ratio: "4:3", location: location)
                let options = AstroImageOptions(format: format, mode: "星空照片", frameCount: 9,
                    exposureSeconds: 0.2, iso: 800, focalLengthMM: 6.765, focalLength35mm: 24,
                    parameters: parameters)
                let data = try XCTUnwrap(AstroImageEncoder.encode(image, options: options))
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let rawGPS = PhotoLocation.fromGPS(properties)
                if let location {
                    XCTAssertEqual(try XCTUnwrap(rawGPS?.latitude), location.latitude, accuracy: 0.000001)
                    XCTAssertEqual(try XCTUnwrap(rawGPS?.longitude), location.longitude, accuracy: 0.000001)
                } else {
                    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
                }
                let diagnostics = try XCTUnwrap(AstroImageEncoder.readDiagnostics(source, properties: properties))
                let recorded = try XCTUnwrap(diagnostics.currentParameters)
                XCTAssertEqual(try XCTUnwrap(recorded.aperture), 1.78, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(recorded.exifExposureBiasEV), -0.7, accuracy: 0.001)
                XCTAssertEqual(recorded.capturedAt, date)
                XCTAssertEqual(recorded.location, location)
                let info = PhotoInfoPresentation(details: PhotoDetails(
                    rows: PhotoCaptureDiagnostics.exposureRows(properties: properties) + diagnostics.detailRows,
                    captureParameters: recorded, location: rawGPS, capturedAt: date))
                XCTAssertEqual(info.parameterItems.first { $0.title == "拍摄类型" }?.value, "星空照片")
                XCTAssertEqual(info.additionalRows.first { $0.title == "快门时白平衡" }?.value, "4100 K")
                XCTAssertEqual(info.additionalRows.first { $0.title == "合成帧数" }?.value, "9 帧")
            }
        }
        print("ASTRO-DETAIL-ROUNDTRIP samples=4 milliseconds=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testStarPostProcessingPreservesExtent() {
        let input = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertEqual(AstroPostProcessor.enhanceStars(input).extent, input.extent)
        XCTAssertEqual(AstroPostProcessor.enhanceTrails(input).extent, input.extent)
    }
}
