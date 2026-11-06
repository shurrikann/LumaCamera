import CoreImage

enum FrameRatio: String, CaseIterable {
    case standard = "4:3", square = "1:1", classic = "3:2", wide = "16:9", panorama = "2:1", cinema = "2.39:1", xpan = "XPAN", openGate = "Open Gate"
    static var photoOptions: [FrameRatio] { allCases.filter { $0 != .openGate } }

    var portraitRatio: CGFloat {
        switch self {
        case .standard: return 3.0 / 4
        case .square: return 1
        case .classic: return 2.0 / 3
        case .wide: return 9.0 / 16
        case .panorama: return 0.5
        case .cinema: return 1.0 / 2.39
        case .xpan: return 24.0 / 65
        case .openGate: return 3.0 / 4.0
        }
    }
    var landscapeRatio: CGFloat { 1 / portraitRatio }
    var overlaysToolbar: Bool { portraitRatio <= 9.0 / 16 }
    func crop(_ image: CIImage, landscape: Bool = false) -> CIImage {
        guard self != .openGate else { return image }
        let extent = image.extent
        let targetRatio = landscape ? landscapeRatio : portraitRatio
        guard extent.width.isFinite, extent.height.isFinite, extent.width >= 1, extent.height >= 1 else { return image }
        // CI 会把小数裁切边界向外扩展到像素网格；先选择源图内部的整数尺寸，
        // 再按最近像素居中，确保预览和编码使用同一画幅，不引入边缘空像素。
        let bounds = CGRect(x: ceil(extent.minX), y: ceil(extent.minY),
                            width: floor(extent.maxX) - ceil(extent.minX),
                            height: floor(extent.maxY) - ceil(extent.minY))
        guard bounds.width >= 1, bounds.height >= 1 else { return image }
        let width = min(bounds.width, max(1, (bounds.height * targetRatio).rounded()))
        let height = min(bounds.height, max(1, (width / targetRatio).rounded()))
        let x = min(bounds.maxX - width, max(bounds.minX, (extent.midX - width / 2).rounded()))
        let y = min(bounds.maxY - height, max(bounds.minY, (extent.midY - height / 2).rounded()))
        return image.cropped(to: CGRect(x: x, y: y, width: width, height: height))
    }
}

