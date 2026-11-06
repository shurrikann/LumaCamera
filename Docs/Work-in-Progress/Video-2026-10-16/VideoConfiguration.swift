import AVFoundation
import CoreImage

enum VideoColorMode: String, CaseIterable, Codable, Identifiable {
    case sdr = "SDR", p3 = "P3", hdr = "HDR", log = "Apple Log", log2 = "Apple Log 2"
    var id: String { rawValue }
    var filtersAllowed: Bool { self == .sdr || self == .p3 }
    var isLog: Bool { self == .log || self == .log2 }
    var tenBit: Bool { !filtersAllowed }
    var captureSpace: AVCaptureColorSpace? {
        switch self {
        case .sdr: return .sRGB
        case .p3: return .P3_D65
        case .hdr: return .HLG_BT2020
        case .log: return .appleLog
        case .log2: if #available(iOS 26, *) { return .appleLog2 }; return nil
        }
    }
    var outputSpace: CGColorSpace { CGColorSpace(name: self == .p3 ? CGColorSpace.displayP3 : self == .hdr ? CGColorSpace.itur_2100_HLG : CGColorSpace.sRGB)! }
    var colorProperties: [String: Any]? {
        if isLog { return nil } // Keep source Log attachments; never relabel it as SDR.
        return [AVVideoColorPrimariesKey: self == .p3 ? AVVideoColorPrimaries_P3_D65 : self == .hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: self == .hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: self == .hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]
    }
}
enum VideoResolution: String, CaseIterable, Codable, Identifiable {
    case hd = "720", fullHD = "1080", ultraHD = "4K"
    var id: String { rawValue }
    var longEdge: Int { self == .hd ? 1280 : self == .fullHD ? 1920 : 3840 }
}
enum VideoRatio: String, CaseIterable, Codable, Identifiable {
    case standard = "4:3", wide = "16:9", panorama = "2:1", cinema = "2.35:1"
    var id: String { rawValue }
    var aspect: CGFloat { self == .standard ? 4/3 : self == .wide ? 16/9 : self == .panorama ? 2 : 2.35 }
    func crop(_ image: CIImage, landscape: Bool) -> CIImage {
        let a = landscape ? aspect : 1 / aspect, e = image.extent
        let w = min(e.width, e.height * a), h = min(e.height, e.width / a)
        return image.cropped(to: CGRect(x: e.midX-w/2, y: e.midY-h/2, width: w, height: h))
    }
}
struct VideoConfiguration: Codable, Equatable {
    static let frameRates = [24, 25, 30, 60, 120]
    var resolution = VideoResolution.fullHD
    var fps = 30
    var ratio = VideoRatio.wide
    var color = VideoColorMode.sdr
    func dimensions(landscape: Bool) -> CGSize {
        let long = resolution.longEdge, short = max(2, Int(CGFloat(long)/ratio.aspect/2)*2)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
    func supports(_ format: AVCaptureDevice.Format) -> Bool {
        guard let colorSpace = color.captureSpace, format.supportedColorSpaces.contains(colorSpace),
              format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) else { return false }
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription), target = dimensions(landscape: true)
        return CGFloat(d.width) >= target.width && CGFloat(d.height) >= target.height
    }
}
struct VideoManualSettings {
    var manual = false
    var iso: Double? = nil
    var shutter: Double? = nil
    var ev = 0.0
    var focus: Double? = nil
    var kelvin: Double? = nil
    var tint = 0.0
}
enum VideoCaptureError: LocalizedError {
    case unsupported, unavailable, encoding, empty
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前镜头不支持这组分辨率、帧率或色彩空间。"
        case .unavailable: return "视频暂时无法读取或保存，请重试。"
        case .encoding: return "视频处理失败，原始录制文件已保留，可重试保存。"
        case .empty: return "录制时间过短，未生成有效视频。"
        }
    }
}
