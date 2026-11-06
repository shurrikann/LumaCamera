import Foundation
import ImageIO

/// Keep capture facts while describing the newly rendered pixels truthfully.
/// Never copy old orientation, dimensions, colour profiles or opaque maker-note offsets.
enum PhotoEditMetadata {
    static func preserving(_ original: [String: Any], in encoded: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil), let type = CGImageSourceGetType(source),
              var output = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw PhotoEncodingError.encoding }
        let groups = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary]
        for key in groups {
            if let values = original[key as String] as? [String: Any] { output[key as String] = values }
        }
        let tiffKeys = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist,
                        kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFSoftware]
        var tiff = output[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let originalTIFF = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        for key in tiffKeys { if let value = originalTIFF[key as String] { tiff[key as String] = value } }
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        output[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = output[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifMakerNote as String] = NSNull()
        exif[kCGImagePropertyExifSubjectArea as String] = NSNull()
        exif[kCGImagePropertyExifSubjectLocation as String] = NSNull()
        exif[kCGImagePropertyExifPixelXDimension as String] = output[kCGImagePropertyPixelWidth as String]
        exif[kCGImagePropertyExifPixelYDimension as String] = output[kCGImagePropertyPixelHeight as String]
        exif[kCGImagePropertyExifColorSpace as String] = 1 // Editor currently exports sRGB JPEG.
        output[kCGImagePropertyExifDictionary as String] = exif
        output[kCGImagePropertyOrientation as String] = 1
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type, 1, nil) else { throw PhotoEncodingError.encoding }
        CGImageDestinationAddImageFromSource(destination, source, 0, output as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEncodingError.encoding }
        return bytes as Data
    }
}
