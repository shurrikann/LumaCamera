import CoreImage
import UIKit
import ImageIO

enum PhotoEditRenderer {
    static func preview(source: CIImage, adjustments: PhotoAdjustments, context: CIContext) -> UIImage? {
        let scale = min(1, 1200 / max(source.extent.width, source.extent.height))
        let image = adjustments.apply(to: source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        guard let cg = Imaging.ownedCGImage(image, from: image.extent, context: context, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return UIImage(cgImage: cg)
    }
    static func render(source: CIImage, adjustments: PhotoAdjustments, metadata: [String: Any]? = nil) throws -> PhotoEditResult {
        let context = CIContext(options: [.cacheIntermediates: false])
        let image = adjustments.apply(to: source)
        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]),
              let preview = preview(source: source, adjustments: adjustments, context: context) else { throw PhotoEncodingError.encoding }
        let preserved = try PhotoEditMetadata.preserving(metadata ?? source.properties, in: data)
        return PhotoEditResult(preview: preview, resource: PhotoResource(data: preserved, filename: "Luma-Edited-" + UUID().uuidString + ".jpg"), filterApplied: adjustments.usesFilter)
    }
}
