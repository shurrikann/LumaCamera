import Foundation
import ImageIO
import CoreImage

/// Standard EXIF/TIFF fields; never burn attribution into the image pixels.
enum PhotoMetadata {
    static func capture(location: PhotoLocation?, copyright: String) -> [String:Any] {
        var properties: [String:Any] = [:]
        if let location, location.isValid { properties[kCGImagePropertyGPSDictionary as String] = location.gpsMetadata }
        let name = String(copyright.trimmingCharacters(in:.whitespacesAndNewlines).prefix(256))
        if !name.isEmpty {
            properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFArtist as String:name,kCGImagePropertyTIFFCopyright as String:name]
            properties[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCByline as String:[name],kCGImagePropertyIPTCCopyrightNotice as String:name]
        }
        return properties
    }
    static func applying(to image: CIImage, location: PhotoLocation?, copyright: String) -> CIImage {
        var properties = image.properties
        properties.removeValue(forKey:kCGImagePropertyGPSDictionary as String)
        for (key,value) in capture(location:location,copyright:copyright) {
            if var existing = properties[key] as? [String:Any], let added = value as? [String:Any] { existing.merge(added) { _,new in new }; properties[key] = existing }
            else { properties[key] = value }
        }
        return image.settingProperties(properties)
    }
}
