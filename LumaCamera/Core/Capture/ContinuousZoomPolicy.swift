import Foundation
import CoreImage

enum ContinuousZoomPolicy {
    static func range(_ cameras: [LensZoomCapabilities]) -> ClosedRange<CGFloat> {
        let valid = cameras.filter { $0.baseZoom > 0 && $0.maximum >= $0.minimum }
        guard let low = valid.map({ $0.baseZoom * $0.minimum }).min(),
              let high = valid.map({ $0.baseZoom * $0.maximum }).max() else { return 1...1 }
        return low...max(low, min(high, 40))
    }
    static func draggedValue(origin: CGFloat, translation: CGFloat, width: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard origin.isFinite, translation.isFinite else { return range.lowerBound }
        let value = origin * pow(2, -translation / max(width, 1) * 3)
        return min(max(value, range.lowerBound), range.upperBound)
    }
    static func demoFrame(_ source: CIImage, zoom: CGFloat) -> CIImage {
        let factor = min(max(zoom, 1), 5)
        let rect = CGRect(x: source.extent.midX - source.extent.width / factor / 2,
                          y: source.extent.midY - source.extent.height / factor / 2,
                          width: source.extent.width / factor, height: source.extent.height / factor)
        return source.cropped(to: rect)
    }
}
