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
}

enum AstroImageEncoder {
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
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: formatter.string(from: Date()),
            kCGImagePropertyExifExposureTime: options.exposureSeconds,
            kCGImagePropertyExifISOSpeedRatings: [Int(options.iso.rounded())],
            kCGImagePropertyExifLensModel: options.lensName,
            kCGImagePropertyExifUserComment: "Luma \(options.mode) · \(options.frameCount) 帧 · \(String(format: "%.2f", options.exposureSeconds))s · ISO \(Int(options.iso))"
        ]
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
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyPixelWidth: final.width,
            kCGImagePropertyPixelHeight: final.height,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImageDestinationLossyCompressionQuality: 0.94
        ]
        CGImageDestinationAddImage(destination, final, properties as CFDictionary)
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
