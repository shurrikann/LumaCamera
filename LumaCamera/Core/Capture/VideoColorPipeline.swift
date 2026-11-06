import AVFoundation
import VideoToolbox

extension VideoColorSpace {
    var captureColorSpace: AVCaptureColorSpace? {
        switch self {
        case .sdr: return .sRGB
        case .p3: return .P3_D65
        case .hdr: return .HLG_BT2020
        case .appleLog:
            // The public HEVC Log writer settings were introduced in iOS 27.
            // Older systems must not offer a file with missing/incorrect Log tags.
            if #available(iOS 27, *) { return .appleLog }
            return nil
        case .appleLog2:
            if #available(iOS 27, *) { return .appleLog2 }
            return nil
        }
    }
    var isLog: Bool { self == .appleLog || self == .appleLog2 }
    var usesTenBit: Bool { self == .hdr || isLog }
    var pixelFormat: OSType {
        usesTenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    var profile: String {
        (usesTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
    }
    var encodingColorProperties: [String: Any] {
        switch self {
        case .sdr, .p3:
            return [AVVideoColorPrimariesKey: self == .p3 ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .hdr:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .appleLog, .appleLog2:
            if #available(iOS 27, *) {
                var values: [String: Any] = [
                    AVVideoLogTransferFunctionKey: self == .appleLog ? AVVideoLogTransferFunction_AppleLog : AVVideoLogTransferFunction_AppleLog2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
                if self == .appleLog { values[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_2020 }
                // Apple Log 2 uses Apple Gamut: do not label it BT.2020, and
                // neither Log variant may carry a conventional transfer key.
                return values
            }
            return [:]
        }
    }
}
