import Foundation
import CoreGraphics

/// Normalized image coordinates, with the origin at the displayed top-left corner.
struct PhotoCropRectangle: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 1
    var height: CGFloat = 1
    static let full = PhotoCropRectangle()
    var clamped: Self {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return .full }
        let w = min(1, max(0.02, width)), h = min(1, max(0.02, height))
        return Self(x: min(max(0, x), 1-w), y: min(max(0, y), 1-h), width: w, height: h)
    }
    func moved(_ delta: CGSize) -> Self { Self(x: x + delta.width, y: y + delta.height, width: width, height: height).clamped }
    func resized(corner: Int, delta: CGSize) -> Self {
        guard delta.width.isFinite, delta.height.isFinite else { return clamped }
        let left = corner == 0 || corner == 2, top = corner < 2
        let x0 = left ? min(max(0, x + delta.width), x + width - 0.02) : x
        let x1 = left ? x + width : min(1, max(x + 0.02, x + width + delta.width))
        let y0 = top ? min(max(0, y + delta.height), y + height - 0.02) : y
        let y1 = top ? y + height : min(1, max(y + 0.02, y + height + delta.height))
        return Self(x: x0, y: y0, width: x1-x0, height: y1-y0).clamped
    }
    func scaled(_ scale: CGFloat) -> Self {
        guard scale.isFinite, scale > 0 else { return clamped }
        let factor = min(min(1/width, 1/height), max(max(0.02/width, 0.02/height), scale))
        let w = width*factor, h = height*factor
        return Self(x: x + (width-w)/2, y: y + (height-h)/2, width: w, height: h).clamped
    }
    func imageRect(in extent: CGRect) -> CGRect {
        let value = clamped
        return CGRect(x: extent.minX + value.x*extent.width, y: extent.maxY - (value.y+value.height)*extent.height,
                      width: value.width*extent.width, height: value.height*extent.height)
    }
}

enum PhotoEditorTool: String, CaseIterable, Identifiable {
    case crop = "裁剪", filters = "滤镜", adjustments = "调整"
    var id: String { rawValue }
}
