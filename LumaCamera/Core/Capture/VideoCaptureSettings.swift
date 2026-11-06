import AVFoundation
import VideoToolbox

enum VideoWhiteBalancePolicy {
    static func requiresLocking(isRAW: Bool, userPreference: Bool) -> Bool {
        isRAW || userPreference
    }
}

/// RAW 元数据接口要求白平衡已经锁定；先检查再查询，避免触发不可被 Swift catch 捕获的系统异常。
struct RAWVideoWriterConfiguration {
    let videoSettings: [String: Any]
    let metadata: [AVMetadataItem]

    static func read(whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode,
                     videoSettings: () -> [String: Any]?,
                     metadata: () -> [AVMetadataItem]?) throws -> Self {
        guard whiteBalanceMode == .locked else {
            throw MovieRecorder.RecorderError.cannotStart("RAW 录像白平衡尚未锁定，请重试。")
        }
        guard let settings = videoSettings() else {
            throw MovieRecorder.RecorderError.cannotStart("外接存储不支持当前 RAW 规格。")
        }
        return Self(videoSettings: settings, metadata: metadata() ?? [])
    }
}

struct VideoCaptureSettings: Equatable, Hashable {
    private static let hardwareCodecs: Set<UInt32> = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr else { return [] }
        return Set((list as? [[String: Any]] ?? []).compactMap { item in
            guard (item[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue == true else { return nil }
            return (item[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
        })
    }()
    var resolution: VideoResolution = .hd1080
    var frameRate: VideoFrameRate = .fps30
    /// 慢动作的传感器采集帧率；nil 表示普通录制按 frameRate 采集。
    var captureFrameRate: VideoFrameRate? = nil
    var colorSpace: VideoColorSpace = .sdr
    var codec: VideoCodec = .hevc
    var proRes: ProResSpecification = .hq
    var bitratePreset: VideoBitratePreset = .systemDefault
    var isRAW: Bool { codec == .proRes && (proRes == .raw || proRes == .rawHQ) }
    var hardwareEncoderAvailable: Bool {
        let bytes = Array(avCodec.rawValue.utf8)
        guard bytes.count == 4 else { return false }
        let code = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Self.hardwareCodecs.contains(code)
    }
    var avCodec: AVVideoCodecType {
        switch codec {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes:
            switch proRes {
            case .proxy: return .proRes422Proxy
            case .lt: return .proRes422LT
            case .standard: return .proRes422
            case .hq: return .proRes422HQ
            case .four4: return .proRes4444
            case .four4xq: return AVVideoCodecType(rawValue: "ap4x")
            case .raw:
                if #available(iOS 26, *) { return .proResRAW }
                return .proRes422HQ
            case .rawHQ:
                if #available(iOS 26, *) { return .proResRAWHQ }
                return .proRes422HQ
            }
        }
    }

    var baseSettings: Self {
        var result = self
        result.codec = .hevc; result.proRes = .hq
        if codec == .h264 && (colorSpace.usesTenBit || colorSpace.isLog) { result.colorSpace = .sdr }
        return result
    }
    var bitRate: Int {
        let pixels = resolution.dimensions.width * resolution.dimensions.height
        let base: Double
        if codec == .proRes {
            base = proRes == .proxy ? 45_000_000 : proRes == .lt ? 102_000_000 : proRes == .standard ? 147_000_000 : proRes == .hq ? 220_000_000 : proRes == .four4 ? 330_000_000 : 500_000_000
        } else {
            switch bitratePreset {
            case .systemDefault: base = 12_000_000 // Estimate only; the writer does not override the encoder default.
            case .low: base = codec == .h264 ? 10_000_000 : 8_000_000
            case .medium: base = codec == .h264 ? 20_000_000 : 16_000_000
            case .high: base = codec == .h264 ? 35_000_000 : 28_000_000
            }
        }
        let frameRateScale = codec == .proRes
            ? Double(frameRate.rawValue) / 30
            : sqrt(Double(frameRate.rawValue) / 30)
        let bitDepthScale = colorSpace.usesTenBit && codec != .proRes ? 1.2 : 1
        return Int(max(4_000_000, pixels / (1920 * 1080) * base * frameRateScale * bitDepthScale))
    }

    var writerAverageBitRate: Int? {
        guard codec != .proRes, bitratePreset != .systemDefault else { return nil }
        return bitRate
    }

    static func format(for settings: Self, device: AVCaptureDevice, requiringOpenGate: Bool = false,
                       requiringCinematicVideo: Bool = false, requiringCenterStage: Bool = false,
                       ratio: FrameRatio? = nil) -> AVCaptureDevice.Format? {
        // 优先对齐原生电影模式规格：iPhone 17 Pro 为 1080p30、4K24 与 4K30；
        // 新机型公开的 60 fps 规格也需通过下面的 Cinematic 格式和帧率范围检查。
        if requiringCinematicVideo,
           !CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: settings.resolution,
                                                                  frameRate: settings.frameRate) {
            return nil
        }
        guard let color = settings.colorSpace.captureColorSpace else { return nil }
        let baseSize = settings.resolution.dimensions
        // Narrower-than-16:9 outputs (4:3 and 1:1) should prefer a native 4:3
        // readout (e.g. 1440×1080) so cropping keeps the full sensor width.
        // 16:9 and wider ratios keep the existing 16:9 reference size.
        // Open Gate ignores the ordinary 1080/4K width/height reference and chooses
        // among native 4:3/1:1 formats. Other paths keep the resolution reference.
        let size: CGSize = requiringOpenGate
            ? .zero
            : ((ratio == .standard || ratio == .square)
                ? CGSize(width: baseSize.height * 4 / 3, height: baseSize.height)
                : baseSize)
        let fps = Double((settings.captureFrameRate ?? settings.frameRate).rawValue)
        let matches = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let raw = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
            if raw != settings.isRAW { return false }
            let frameRateIsSupported: Bool
            if requiringCenterStage {
                if format.isCenterStageSupported, let range = format.videoFrameRateRangeForCenterStage, !settings.isRAW {
                    frameRateIsSupported = range.minFrameRate <= fps && range.maxFrameRate >= fps
                } else { frameRateIsSupported = false }
            } else if requiringCinematicVideo {
                if #available(iOS 26.0, *), format.isCinematicVideoCaptureSupported,
                   let range = format.videoFrameRateRangeForCinematicVideo {
                    frameRateIsSupported = range.minFrameRate <= fps && range.maxFrameRate >= fps
                } else {
                    frameRateIsSupported = false
                }
            } else {
                frameRateIsSupported = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= fps && $0.maxFrameRate >= fps
                }
            }
            return Double(dimensions.width) >= size.width && Double(dimensions.height) >= size.height
                && (settings.isRAW || format.supportedColorSpaces.contains(color))
                && (settings.colorSpace != .hdr || format.isVideoHDRSupported)
                && frameRateIsSupported
                && (!requiringOpenGate || OpenGateCapability.supportsNativeVideoDimensions(width: Int(dimensions.width), height: Int(dimensions.height)))
        }
        // Open Gate must use the largest native 4:3/1:1 readout, not the smallest
        // format that happens to satisfy the selected ordinary resolution.
        if requiringOpenGate {
            return matches.max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
        }
        return matches.min { a, b in
            let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let y = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let ax = Int64(x.width) * Int64(x.height), by = Int64(y.width) * Int64(y.height)
            if ax != by { return ax < by }
            // Prefer native 8-bit YUV over RGB and 10-bit HDR formats for SDR.
            let native: FourCharCode = settings.codec == .proRes ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : settings.colorSpace.pixelFormat
            let ap = CMFormatDescriptionGetMediaSubType(a.formatDescription) == native
            let bp = CMFormatDescriptionGetMediaSubType(b.formatDescription) == native
            if ap != bp { return ap }
            return (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
    }

    static func supported(by device: AVCaptureDevice) -> [Self] {
        VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.compactMap { rate in
                    let value = Self(resolution: resolution, frameRate: rate, colorSpace: color)
                    return format(for: value, device: device) == nil ? nil : value
                }
            }
        }
    }

    /// 慢动作专用采集率单独枚举；240 fps 不进入普通视频帧率规格列表。
    static func slowMotionCaptureRates(by device: AVCaptureDevice) -> [Self] {
        let standard = [VideoColorSpace.sdr, .p3].flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                SlowMotionCapturePolicy.captureRates.compactMap { rate in
                    let value = Self(resolution: resolution, frameRate: rate, colorSpace: color)
                    return format(for: value, device: device) == nil ? nil : value
                }
            }
        }
        // iPhone 17 Pro 的 4K Dolby Vision 慢动作规格只对后置主摄开放；仍以该物理
        // 镜头实际公布的 10-bit HDR 格式、色彩空间和 120 fps 范围作为最终门槛。
        guard device.position == .back, device.deviceType == .builtInWideAngleCamera,
              !device.isVirtualDevice else { return standard }
        let dolbyVisionCandidate = Self(resolution: .uhd4K, frameRate: .fps120, colorSpace: .hdr)
        guard format(for: dolbyVisionCandidate, device: device) != nil else { return standard }
        return standard + [dolbyVisionCandidate]
    }

    /// 读取当前路由真正支持 Cinematic Video 的规格，不根据普通视频帧率推测。
    static func cinematicVideoSupported(by device: AVCaptureDevice) -> [Self] {
        guard #available(iOS 26.0, *) else { return [] }
        return VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.compactMap { rate in
                    let value = Self(resolution: resolution, frameRate: rate, colorSpace: color)
                    return format(for: value, device: device, requiringCinematicVideo: true) == nil ? nil : value
                }
            }
        }
    }

    static func openGateSupported(by device: AVCaptureDevice) -> [Self] {
        VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.compactMap { rate in
                    let value = Self(resolution: resolution, frameRate: rate, colorSpace: color)
                    return format(for: value, device: device, requiringOpenGate: true) == nil ? nil : value
                }
            }
        }
    }

    static func resolved(_ requested: Self, supported: [Self]) -> Self? {
        if requested.codec != .hevc || requested.proRes != .hq {
            guard var result = resolved(requested.baseSettings, supported: supported) else { return nil }
            result.codec = requested.codec; result.proRes = requested.proRes
            return result
        }
        if supported.contains(requested) { return requested }
        let sameColor = supported.filter { $0.colorSpace == requested.colorSpace }
        let colorCandidates = sameColor.isEmpty ? supported.filter { $0.colorSpace == .sdr } : sameColor
        let sameSize = colorCandidates.filter { $0.resolution == requested.resolution }
        let candidates = sameSize.isEmpty ? colorCandidates : sameSize
        return candidates.min {
            let resolutions = VideoResolution.allCases
            let wanted = resolutions.firstIndex(of: requested.resolution) ?? 1
            let a = abs((resolutions.firstIndex(of: $0.resolution) ?? 1) - wanted)
            let b = abs((resolutions.firstIndex(of: $1.resolution) ?? 1) - wanted)
            if a != b { return a < b }
            return abs($0.frameRate.rawValue - requested.frameRate.rawValue) < abs($1.frameRate.rawValue - requested.frameRate.rawValue)
        }
    }
}

enum OpenGateCapability {
    static func supportedSpecsSummary(from supported: [VideoCaptureSettings]) -> String {
        guard !supported.isEmpty else { return "暂无可用规格" }
        return VideoColorSpace.allCases.compactMap { colorSpace in
            let resolutions = VideoResolution.allCases.compactMap { resolution -> String? in
                let rates = VideoFrameRate.allCases.filter { frameRate in
                    supported.contains {
                        $0.colorSpace == colorSpace && $0.resolution == resolution && $0.frameRate == frameRate
                    }
                }
                guard let first = rates.first, let last = rates.last else { return nil }
                let range = first == last ? "\(first.rawValue)" : "\(first.rawValue)–\(last.rawValue)"
                return "\(resolution.title)：\(range)"
            }
            guard !resolutions.isEmpty else { return nil }
            return "\(colorSpace.rawValue)：\(resolutions.joined(separator: " / "))"
        }.joined(separator: "\n")
    }

    /// Open Gate is available only when the selected native capture format can
    /// provide its full square or 4:3 frame without an app-side center crop.
    static func supportsNativeVideoDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let aspect = Double(max(width, height)) / Double(min(width, height))
        return abs(aspect - 1.0) <= 0.015 || abs(aspect - (4.0 / 3.0)) <= 0.02
    }

    static func outputDimensions(longEdge: CGFloat, nativeWidth: CGFloat, nativeHeight: CGFloat) -> CGSize? {
        guard longEdge > 0, nativeWidth > 0, nativeHeight > 0 else { return nil }
        let nativeLong = max(nativeWidth, nativeHeight)
        let nativeShort = min(nativeWidth, nativeHeight)
        let shortEdge = max(2, ((longEdge * nativeShort / nativeLong) / 2).rounded() * 2)
        return CGSize(width: longEdge, height: shortEdge)
    }
}
