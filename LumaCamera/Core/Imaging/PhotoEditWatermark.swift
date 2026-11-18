import CoreImage
import UIKit
import ImageIO

/// Persisted with the edit recipe, always rebuilt from the unframed editing input.
struct PhotoEditWatermark: Codable, Equatable {
    var settings: PhotoWatermarkSettings
    var content: PhotoWatermarkContent
    private static let context = CIContext(options: [.cacheIntermediates: false])

    func apply(to image: CIImage, filterID: String, intensity: Double) -> CIImage {
        var content = content
        if filterID != FilmStyle.original.rawValue, intensity > 0,
           let filter = FilmStyle(rawValue: filterID) { content.filter = filter.title }
        guard let cg = Imaging.ownedCGImage(image, from: image.extent, context: Self.context,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return image }
        let result = PhotoWatermarkRenderer.render(UIImage(cgImage: cg), settings: settings, content: content)
        guard let framed = CIImage(image: result) else { return image }
        // Keep original high-range photo pixels. Only frame / glass content is SDR artwork.
        let layout = PhotoWatermarkLayout(photoSize: CGSize(width: cg.width, height: cg.height), settings: settings, content: content)
        let photo = CGRect(x: layout.photo.minX, y: layout.size.height-layout.photo.maxY,
                           width: layout.photo.width, height: layout.photo.height)
        let shifted = image.transformed(by: CGAffineTransform(translationX: photo.minX, y: photo.minY))
        if settings.style != .glassStrip { return shifted.composited(over: framed).cropped(to: framed.extent) }
        // Retain the actual rounded native glass patch and information, preserve HDR elsewhere.
        guard let card = layout.decoration else { return shifted }
        let rect = CGRect(x: card.minX, y: layout.size.height-card.maxY, width: card.width, height: card.height)
        let radius = PhotoWatermarkLayout.glassCornerRadius(photoSize: image.extent.size, card: card)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius,
            "inputColor": CIColor.white])!.outputImage!.cropped(to: framed.extent)
        return framed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: shifted,
            kCIInputMaskImageKey: mask]).cropped(to: framed.extent)
    }

    static func content(metadata: [String: Any], capturedAt: Date? = nil, location: PhotoLocation? = nil,
                        parameters: PhotoCaptureParameters? = nil, signature: String = "") -> PhotoWatermarkContent {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var exifDate: Date?
        if let rawDate = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
                exifDate = formatter.date(from: rawDate+offset.replacingOccurrences(of: ":", with: ""))
            }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if exifDate == nil { exifDate = formatter.date(from: rawDate) }
        }
        let date = capturedAt ?? exifDate
            ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String).flatMap { formatter.date(from: $0) } ?? Date()
        var p = parameters ?? PhotoCaptureParameters()
        p.updateEXIF(Dictionary(uniqueKeysWithValues: metadata.map { ($0.key as CFString, $0.value) }))
        let gps = PhotoLocation.fromGPS(Dictionary(uniqueKeysWithValues: metadata.map { ($0.key as CFString,$0.value) }), date: date)
        return PhotoWatermarkContent(capturedAt: date,
            signature: (tiff[kCGImagePropertyTIFFArtist as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? signature,
            location: (p.location ?? location ?? gps)?.watermarkText,
            exposureSeconds: p.exposureSeconds ?? p.sampledExposureSeconds, iso: p.iso ?? p.sampledISO,
            whiteBalanceKelvin: p.whiteBalanceKelvin,
            whiteBalanceAutomatic: p.whiteBalanceMode == "自动" || (exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue == 0,
            ev: p.exifExposureBiasEV ?? p.requestedExposureBiasEV, filter: p.filterName ?? "原片")
    }
}
