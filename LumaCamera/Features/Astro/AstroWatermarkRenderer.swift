import CoreImage
import UIKit

enum AstroWatermarkRenderer {
    static func overlay(on image: CIImage, text: String = "LUMA · 星空") -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let overlay = UIGraphicsImageRenderer(size: extent.size, format: format).image { _ in
            let fontSize = max(18, extent.width * 0.018)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.82)
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let padding = max(10, fontSize * 0.55)
            let origin = CGPoint(x: extent.width * 0.05,
                                 y: extent.height - size.height - extent.height * 0.035)
            let background = CGRect(x: origin.x - padding, y: origin.y - padding * 0.4,
                                    width: size.width + padding * 2, height: size.height + padding * 0.8)
            UIColor.black.withAlphaComponent(0.28).setFill()
            UIBezierPath(roundedRect: background, cornerRadius: background.height / 2).fill()
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
        guard let cg = overlay.cgImage else { return image }
        let ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return ci.composited(over: image)
    }
}
