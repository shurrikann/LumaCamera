import ImageIO
import UIKit
import UniformTypeIdentifiers

enum AstroImageFormat: String, Codable { case heif, jpg
    var utType: UTType { self == .heif ? .heic : .jpeg }
    var fileExtension: String { self == .heif ? "heic" : "jpg" }
}

struct AstroImageOptions: Codable {
    var format: AstroImageFormat = .heif
    var aspect: Double? = nil
    var watermark = false
    var watermarkSettings: PhotoWatermarkSettings?
    var watermarkContent: PhotoWatermarkContent?
    var mode: String = ""
    var frameCount = 1
    var exposureSeconds: Double = 1
    var iso: Double = 1600
    var lensName = ""
    var focalLengthMM: Double? = nil
    var focalLength35mm: Double? = nil
    var parameters: PhotoCaptureParameters? = nil

    var diagnostics: PhotoCaptureDiagnostics? {
        guard var parameters else { return nil }
        parameters.shootingType = mode.isEmpty ? parameters.shootingType : mode
        parameters.focalLengthMM = focalLengthMM
        parameters.equivalentFocalLengthMM = focalLength35mm
        parameters.exposureSeconds = exposureSeconds
        parameters.iso = iso
        if !lensName.isEmpty { parameters.lensModel = lensName }
        var details = PhotoCaptureDiagnostics(parameters: parameters)
        details.add("合成帧数", "\(frameCount) 帧")
        return details
    }
}

enum AstroImageEncoder {
    private static let metadataNamespace = "https://lumacamera.app/ns/astro/1.0/"
    private static let diagnosticsPath = "lumaAstro:captureDiagnostics"

    static func readDiagnostics(_ source: CGImageSource, properties: [CFString: Any]) -> PhotoCaptureDiagnostics? {
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, diagnosticsPath as CFString) as String?,
           let data = text.data(using: .utf8),
           var diagnostics = try? JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: data) {
            diagnostics.parameters?.updateEXIF(properties)
            return diagnostics
        }
        // Previously exported files contain a structured English user comment.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let comment = exif?[kCGImagePropertyExifUserComment] as? String else { return nil }
        let fields = comment.components(separatedBy: " | ")
        guard fields.count == 4, fields[1].hasSuffix(" frames"),
              let count = Int(fields[1].dropLast(" frames".count)), count > 0 else { return nil }
        let mode: String
        switch fields[0] {
        case "Luma Astro Photo": mode = "星空照片"
        case "Luma Star Trails": mode = "星轨"
        default: return nil
        }
        return PhotoCaptureDiagnostics(rows: [.init(title: "拍摄类型", value: mode),
                                               .init(title: "合成帧数", value: "\(count) 帧")])
    }

    static func encode(_ source: CGImage, options: AstroImageOptions) -> Data? {
        guard let image = cropped(source, aspect: options.aspect) else { return nil }
        var final = image
        if options.watermark {
            let rendered = PhotoWatermarkRenderer.render(
                UIImage(cgImage: image),
                settings: options.watermarkSettings ?? PhotoWatermarkSettings(),
                content: options.watermarkContent ?? PhotoWatermarkContent(capturedAt: Date()))
            guard let renderedCG = rendered.cgImage else { return nil }
            final = renderedCG
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, options.format.utType.identifier as CFString, 1, nil) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let exifMode: String
        switch options.mode {
        case "星空照片": exifMode = "Astro Photo"
        case "星轨": exifMode = "Star Trails"
        case "星空延时": exifMode = "Astro Timelapse"
        default: exifMode = "Astro"
        }
        let exposure = String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), options.exposureSeconds)
        let iso = Int(options.iso.rounded())
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: formatter.string(from: options.parameters?.capturedAt ?? Date()),
            kCGImagePropertyExifExposureTime: options.exposureSeconds,
            kCGImagePropertyExifISOSpeedRatings: [iso],
            kCGImagePropertyExifLensModel: options.lensName,
            kCGImagePropertyExifUserComment: "Luma \(exifMode) | \(options.frameCount) frames | \(exposure)s | ISO \(iso)"
        ]
        if let aperture = options.parameters?.aperture, aperture.isFinite, aperture > 0 {
            exif[kCGImagePropertyExifFNumber] = aperture
        }
        if let ev = options.parameters?.requestedExposureBiasEV, ev.isFinite {
            exif[kCGImagePropertyExifExposureBiasValue] = ev
        }
        if let focal = options.focalLengthMM, focal.isFinite, focal > 0 {
            exif[kCGImagePropertyExifFocalLength] = focal
        }
        if let focal = options.focalLength35mm, focal.isFinite, focal > 0, focal < 65536 {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = Int(focal.rounded())
        }
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: UIDevice.current.model,
            kCGImagePropertyTIFFSoftware: "LumaCamera"
        ]
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyPixelWidth: final.width,
            kCGImagePropertyPixelHeight: final.height,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImageDestinationLossyCompressionQuality: 0.94
        ]
        if let location = options.parameters?.location, location.isValid {
            properties[kCGImagePropertyGPSDictionary] = location.gpsMetadata
        }
        let metadata = CGImageMetadataCreateMutable()
        var hasMetadata = false
        if let diagnostics = options.diagnostics, let encoded = try? JSONEncoder().encode(diagnostics),
           let text = String(data: encoded, encoding: .utf8),
           CGImageMetadataRegisterNamespaceForPrefix(metadata, metadataNamespace as CFString, "lumaAstro" as CFString, nil) {
            hasMetadata = CGImageMetadataSetValueWithPath(metadata, nil, diagnosticsPath as CFString, text as CFString)
        }
        let localizedMode = options.mode.isEmpty ? "星空" : options.mode
        let description = "Luma \(localizedMode) · \(options.frameCount) 帧 · \(exposure)s · ISO \(iso)"
        // Image I/O substitutes ASCII question marks for Chinese in EXIF UserComment.
        let hasDescription = CGImageMetadataSetValueWithPath(metadata, nil, "dc:description[x-default]" as CFString, description as CFString)
        if hasMetadata || hasDescription {
            properties[kCGImageDestinationMergeMetadata] = true
            CGImageDestinationAddImageAndMetadata(destination, final, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, final, properties as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func cropped(_ image: CGImage, aspect: Double?) -> CGImage? {
        guard let aspect, aspect.isFinite, aspect > 0 else { return image }
        let current = Double(image.width) / Double(image.height)
        guard abs(current - aspect) > 0.005 else { return image }
        let width: Int, height: Int
        if current > aspect {
            height = image.height
            width = max(1, Int((Double(height) * aspect).rounded()))
        } else {
            width = image.width
            height = max(1, Int((Double(width) / aspect).rounded()))
        }
        let rect = CGRect(x: (image.width - width) / 2, y: (image.height - height) / 2, width: width, height: height)
        return image.cropping(to: rect)
    }
}
