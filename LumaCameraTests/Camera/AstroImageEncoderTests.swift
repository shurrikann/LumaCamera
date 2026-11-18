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
