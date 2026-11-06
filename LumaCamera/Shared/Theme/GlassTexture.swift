import SwiftUI
import UIKit

/// One tiny, deterministic grain tile shared by every glass surface.
/// A static image avoids re-drawing noise during scrolling or animation.
enum GlassTexture {
    static let grain: Image = {
        let edge = 128
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            for y in 0..<edge {
                for x in 0..<edge {
                    // 2D integer hash keeps the texture stable between launches.
                    var hash = UInt32(truncatingIfNeeded: (x &* 374_761_393) &+ (y &* 668_265_263))
                    hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                    hash ^= hash >> 16
                    let value = 0.40 + Double(hash & 0xFF) / 255 * 0.20
                    cg.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return Image(uiImage: image)
    }()
}
