import CoreImage
import ImageIO

/// 与DNG分开保存显影配方；DNG字节始终不改写。可选字段兼容旧照片编辑存档。
struct RAWDevelopmentSettings: Codable, Equatable {
    var version = 1
    var adaptive = true
    var hdr = false
    var tone = PhotoTone.natural.rawValue
    var virtualAperture: Double?
    var maximumPixels: Double? = nil
}
enum RAWDevelopmentRecipe {
    private static let prefix = "LumaCamera.RAWDevelopment.v1="
    static func initial(source:CIImage,look:CaptureLook,hdr:Bool,maximumPixels:Double? = nil) -> PhotoAdjustments {
        var result = PhotoAdjustments()
        result.filterID = look.style.rawValue; result.filterIntensity = look.intensity; result.filterAdjustments = look.adjustments
        result.rawDevelopment = RAWDevelopmentSettings(hdr:hdr,tone:look.tone.rawValue,virtualAperture:look.virtualAperture)
        result.rawDevelopment?.maximumPixels = maximumPixels
        let e = source.extent, crop = look.ratio.crop(source,landscape:look.landscape).extent
        result.crop = PhotoCropRectangle(x:(crop.minX-e.minX)/e.width,y:(e.maxY-crop.maxY)/e.height,
            width:crop.width/e.width,height:crop.height/e.height).clamped
        return result
    }
    static func applying(_ value:PhotoAdjustments,to source:CIImage) throws -> CIImage {
        let bytes = try JSONEncoder().encode(value)
        var props = source.properties, exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let previous = exif[kCGImagePropertyExifUserComment as String] as? String ?? ""
        var lines = previous.components(separatedBy:"\n").filter { !$0.hasPrefix(prefix) && !$0.isEmpty }
        lines.append(prefix+bytes.base64EncodedString())
        exif[kCGImagePropertyExifUserComment as String] = lines.joined(separator:"\n")
        props[kCGImagePropertyExifDictionary as String] = exif
        return source.settingProperties(props)
    }
    static func read(_ properties:[String:Any]) -> PhotoAdjustments? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        guard let comment = exif[kCGImagePropertyExifUserComment as String] as? String,
              let line = comment.components(separatedBy:"\n").first(where: { $0.hasPrefix(prefix) }), line.count < 65536,
              let data = Data(base64Encoded:String(line.dropFirst(prefix.count))),
              let value = try? JSONDecoder().decode(PhotoAdjustments.self,from:data), value.rawDevelopment?.version == 1 else { return nil }
        return value
    }
}
