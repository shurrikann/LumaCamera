import Foundation
import CoreGraphics
import ImageIO
import CoreImage

enum PhotoWatermarkStyle: String, Codable, CaseIterable, Identifiable {
    case whiteFrame, glassStrip, blurredPhoto, newYear
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Migrate the previously selected third style without losing preferences.
        self = value == "festiveRed" ? .blurredPhoto : Self(rawValue: value) ?? .whiteFrame
    }
    var id: String { rawValue }
    var title: String {
        switch self { case .whiteFrame: "白色边框"; case .glassStrip: "液态玻璃"; case .blurredPhoto: "照片叠框"; case .newYear: "新年水印" }
    }
}

struct PhotoWatermarkSettings: Codable, Equatable {
    var style: PhotoWatermarkStyle = .whiteFrame
    var showsLocation = false
    var showsParameters = false
}

/// Frozen capture values; watermark location is independent from GPS metadata permission.
struct PhotoWatermarkContent: Equatable, Codable {
    var capturedAt: Date
    var signature = ""
    var location: String?
    var exposureSeconds: Double?
    var iso: Double?
    var whiteBalanceKelvin: Double?
    var whiteBalanceAutomatic = false
    var ev: Double?
    var filter = "原片"

    static func capture(source: CIImage, look: CaptureLook, options: PhotoOptions,
                        parameters: PhotoCaptureParameters?, date: Date) -> Self {
        var p = parameters ?? PhotoCaptureParameters()
        p.updateEXIF(Dictionary(uniqueKeysWithValues: source.properties.map { ($0.key as CFString,$0.value) }))
        let exif = source.properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let place = options.watermarkLocation
        return Self(capturedAt:date,signature:options.copyright,
                    location:place.map { $0.watermarkText },
                    exposureSeconds:p.exposureSeconds ?? p.sampledExposureSeconds,
                    iso:p.iso ?? p.sampledISO,whiteBalanceKelvin:p.whiteBalanceKelvin,
                    whiteBalanceAutomatic:p.whiteBalanceMode == "自动" || (exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue == 0,
                    ev:p.exifExposureBiasEV ?? p.requestedExposureBiasEV,
                    filter:look.style == .original || look.intensity <= 0 ? "原片" : look.style.title)
    }
}

struct PhotoWatermarkLayout {
    static func glassCornerRadius(photoSize: CGSize, card: CGRect) -> CGFloat {
        // Round both ends more deeply while keeping the existing text inset safe.
        min(min(card.width,card.height)*0.45,min(photoSize.width,photoSize.height)*0.05)
    }
    let size: CGSize
    let photo: CGRect
    let information: CGRect
    let decoration: CGRect?
    init(photoSize: CGSize, settings: PhotoWatermarkSettings, content: PhotoWatermarkContent? = nil) {
        let w = photoSize.width, h = photoSize.height
        let hasLocation = settings.showsLocation && (content.map { !($0.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
        let hasSignature = content.map { !$0.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        let leftRows = 1 + (hasLocation ? 1 : 0) + (settings.showsParameters ? 1 + (hasSignature ? 1 : 0) : 0)
        let rightRows = settings.showsParameters ? 3 : 1 + (hasSignature ? 1 : 0)
        let informationHeight = w * max(0.052, Double(max(leftRows, rightRows)) * 0.031)
        let footer = informationHeight + w * 0.024
        switch settings.style {
        case .whiteFrame:
            let margin = w*0.035
            size = CGSize(width:w+margin*2,height:h+margin+footer+w*0.018)
            photo = CGRect(x:margin,y:margin,width:w,height:h)
            information = CGRect(x:margin,y:h+margin,width:w,height:footer)
            decoration = nil
        case .glassStrip:
            let base = min(w,h), edge = base*0.018, textInset = base*0.045
            let width = max(1,w-textInset*2)
            let measured = PhotoFrameInformationLayout(photoSize:photoSize,settings:settings,
                content:content ?? PhotoWatermarkContent(capturedAt:Date(),signature:"署名",location:settings.showsLocation ? "地点" : nil),
                informationWidth:width,compact:true)
            size = photoSize
            photo = CGRect(origin:.zero,size:photoSize)
            let cardHeight = ceil(measured.height*1.12)
            let top = max(0,h-base*0.012-cardHeight)
            decoration = CGRect(x:edge,y:top,width:w-edge*2,height:cardHeight)
            information = CGRect(x:textInset,y:top,width:width,height:cardHeight)
        case .newYear:
            let canvasWidth = (w / 0.75).rounded(.up)
            let margin = (min(w, h) * 0.045).rounded(.up)
            let side = canvasWidth - w - margin*2
            size = CGSize(width: canvasWidth, height: h + margin*2)
            photo = CGRect(x: margin, y: margin, width: w, height: h)
            decoration = CGRect(x: w + margin, y: margin, width: side, height: h)
            information = CGRect(x: w + margin + side*0.065, y: margin + h*0.018, width: side*0.90, height: h*0.964)
        case .blurredPhoto:
            let margin = (min(w,h)*0.03).rounded(.up)
            let measured = PhotoFrameInformationLayout(photoSize:photoSize,settings:settings,
                content:content ?? PhotoWatermarkContent(capturedAt:Date(),signature:"署名",location:settings.showsLocation ? "地点" : nil))
            size = CGSize(width:w+margin*2,height:h+margin+measured.height+min(w,h)*0.018)
            photo = CGRect(x:margin,y:margin,width:w,height:h)
            information = CGRect(x:margin,y:h+margin,width:w,height:measured.height)
            decoration = nil
        }
    }
}
