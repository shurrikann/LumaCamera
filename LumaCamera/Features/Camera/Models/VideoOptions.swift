import Foundation

/// Resolution and frame rate are backed by capture-device format capabilities.
enum VideoResolution: String, CaseIterable, Identifiable {
    case hd720
    case hd1080
    case uhd4K

    var id: String { rawValue }

    var dimensions: CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .uhd4K: return CGSize(width: 3840, height: 2160)
        }
    }

    var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30
    case fps50 = 50
    case fps60 = 60
    case fps120 = 120
    /// 240 fps 只作为慢动作传感器采集帧率，不显示在普通视频帧率选择器中。
    case fps240 = 240

    static var allCases: [VideoFrameRate] { [.fps24, .fps25, .fps30, .fps50, .fps60, .fps120] }

    var id: Int { rawValue }
}

/// 视频延时摄影的采样间隔预设。档位描述拍摄题材，成片按当前帧率连续播放。
enum TimeLapsePreset: String, CaseIterable, Identifiable, Codable {
    case people
    case traffic
    case clouds
    case sunset
    case nightSky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "人流"
        case .traffic: return "车流"
        case .clouds: return "云层"
        case .sunset: return "日落"
        case .nightSky: return "星夜"
        }
    }

    /// 这些间隔是应用提供的起始建议，可按主体运动速度选择。
    var intervalSeconds: TimeInterval { recommendedInterval.seconds }

    var recommendedInterval: TimeLapseInterval {
        switch self {
        case .people: return .s1
        case .traffic: return .s3
        case .clouds: return .s5
        case .sunset: return .s10
        case .nightSky: return .s15
        }
    }

    var recommendedFrameCount: TimeLapseFrameCount { .f300 }

    var intervalDescription: String { "每 \(Int(intervalSeconds)) 秒" }
}

enum TimeLapseInterval: Int, CaseIterable, Identifiable, Codable {
    case s1 = 1, s3 = 3, s5 = 5, s10 = 10, s15 = 15, s30 = 30, s60 = 60
    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String { "\(rawValue)s" }
}

enum TimeLapseFrameCount: Int, CaseIterable, Identifiable, Codable {
    case f60 = 60, f120 = 120, f150 = 150, f240 = 240, f300 = 300
    case f450 = 450, f600 = 600, f900 = 900, infinite = 0
    var id: Int { rawValue }
    var title: String { self == .infinite ? "∞" : "\(rawValue)" }
    var target: Int? { self == .infinite ? nil : rawValue }
}

/// 慢动作采用设备的高帧率采集，再按用户选择的帧率分配回放时间戳。
enum SlowMotionCapturePolicy {
    /// 优先采用设备提供的最高慢动作采集率；未提供 240 fps 时回退到 120 fps。
    static let captureRates: [VideoFrameRate] = [.fps240, .fps120]
    static let fallbackCaptureRate = VideoFrameRate.fps120

    /// 慢动作必须以高于回放帧率的采集率录制；HDR 只开放主摄 4K/120 的 HEVC 组合。
    static func isSupported(playbackFrameRate: VideoFrameRate, captureFrameRate: VideoFrameRate?,
                            codec: VideoCodec, colorSpace: VideoColorSpace, isRAW: Bool,
                            openGate: Bool, resolution: VideoResolution = .hd1080) -> Bool {
        guard let captureFrameRate else { return false }
        let colorCombinationIsSupported = colorSpace == .sdr || colorSpace == .p3
            || (colorSpace == .hdr && resolution == .uhd4K
                && captureFrameRate == .fps120 && codec == .hevc)
        return captureRates.contains(captureFrameRate)
            && playbackFrameRate.rawValue < captureFrameRate.rawValue
            && (codec == .hevc || (codec == .h264 && (colorSpace == .sdr || colorSpace == .p3)))
            && colorCombinationIsSupported
            && !isRAW
            && !openGate
    }

    static func playbackSpeed(playbackFrameRate: VideoFrameRate,
                              captureFrameRate: VideoFrameRate = fallbackCaptureRate) -> Double {
        Double(playbackFrameRate.rawValue) / Double(captureFrameRate.rawValue)
    }
}

/// 电影效果使用 iOS 26 Cinematic Video API；只在相机格式本身提供电影处理时开放。
enum CinematicVideoCapturePolicy {
    /// Apple 为 iPhone 17 Pro 公布的原生电影模式基础组合；较新机型的 60 fps
    /// 规格仅在实际格式同时公布 Cinematic 支持和对应帧率范围时开放。
    static let documentedSpecifications: [(VideoResolution, VideoFrameRate)] = [
        (.hd1080, .fps30),
        (.uhd4K, .fps24),
        (.uhd4K, .fps30)
    ]

    static func isDocumentedSpecification(resolution: VideoResolution, frameRate: VideoFrameRate) -> Bool {
        documentedSpecifications.contains { $0.0 == resolution && $0.1 == frameRate }
            || (frameRate == .fps60 && (resolution == .hd1080 || resolution == .uhd4K))
    }

    static func isSupported(hasCinematicFormat: Bool, codec: VideoCodec, isRAW: Bool,
                            openGate: Bool, timeLapse: Bool, slowMotion: Bool) -> Bool {
        hasCinematicFormat && codec != .proRes && !isRAW && !openGate && !timeLapse && !slowMotion
    }
}

/// 在切换视频子模式时选择离当前设置最近的受支持规格，减少用户重新配置的步骤。
enum VideoSubmodeSettingsPolicy {
    static func compatibleSettings(_ candidates: [VideoCaptureSettings], preserving requested: VideoCaptureSettings,
                                   defaultPlaybackRate: VideoFrameRate = .fps30) -> VideoCaptureSettings? {
        guard !candidates.isEmpty else { return nil }
        if let exact = candidates.first(where: {
            $0.resolution == requested.resolution && $0.frameRate == requested.frameRate
                && $0.colorSpace == requested.colorSpace
        }) { return exact }
        let baseline = VideoCaptureSettings(resolution: .hd1080, frameRate: defaultPlaybackRate, colorSpace: .sdr)
        return closestSupported(candidates, to: baseline, preferredFrameRate: defaultPlaybackRate)
    }

    static func closestSupported(_ candidates: [VideoCaptureSettings], to requested: VideoCaptureSettings,
                                 preferredFrameRate: VideoFrameRate? = nil) -> VideoCaptureSettings? {
        guard !candidates.isEmpty else { return nil }
        let targetRate = preferredFrameRate ?? requested.frameRate
        return candidates.min { lhs, rhs in
            score(lhs, requested: requested, targetRate: targetRate)
                < score(rhs, requested: requested, targetRate: targetRate)
        }
    }

    /// 返回确实支持当前分辨率、帧率与色彩空间组合的镜头，不因同朝向而一并放行。
    static func compatibleLensIDs(in routes: [VideoSubmodeCaptureRoute], matching requested: VideoCaptureSettings) -> Set<String> {
        Set(routes.filter { route in
            route.settings.contains {
                $0.resolution == requested.resolution && $0.frameRate == requested.frameRate
                    && $0.colorSpace == requested.colorSpace
            }
        }.map(\.lensID))
    }

    static func score(_ value: VideoCaptureSettings, requested: VideoCaptureSettings,
                      targetRate: VideoFrameRate) -> Int {
        let colors = VideoColorSpace.allCases
        let resolutions = VideoResolution.allCases
        let colorDistance = abs((colors.firstIndex(of: value.colorSpace) ?? 0)
            - (colors.firstIndex(of: requested.colorSpace) ?? 0))
        let resolutionDistance = abs((resolutions.firstIndex(of: value.resolution) ?? 1)
            - (resolutions.firstIndex(of: requested.resolution) ?? 1))
        // 保留色彩空间优先，其次是分辨率，再尽量保持用户选择的回放帧率。
        return colorDistance * 10_000
            + resolutionDistance * 1_000
            + abs(value.frameRate.rawValue - targetRate.rawValue)
    }

    static func slowMotionPlaybackSettings(from supported: [VideoCaptureSettings],
                                           captureRates: [VideoCaptureSettings]) -> [VideoCaptureSettings] {
        supported.compactMap { playback in
            guard playback.colorSpace == .sdr || playback.colorSpace == .p3
                    || (playback.colorSpace == .hdr && playback.resolution == .uhd4K) else { return nil }
            let bestRate = SlowMotionCapturePolicy.captureRates.first { rate in
                SlowMotionCapturePolicy.isSupported(playbackFrameRate: playback.frameRate,
                    captureFrameRate: rate, codec: playback.codec, colorSpace: playback.colorSpace,
                    isRAW: playback.isRAW, openGate: false, resolution: playback.resolution)
                    && captureRates.contains {
                    $0.resolution == playback.resolution && $0.colorSpace == playback.colorSpace && $0.frameRate == rate
                }
            }
            guard let bestRate else { return nil }
            var value = playback
            value.captureFrameRate = bestRate
            return value
        }
    }
}

/// 慢动作规格弹窗只列出当前路线可用的传感器采集参数，不把回放帧率混入采集选项。
enum SlowMotionCapturePickerPolicy {
    static func resolutions(captureFormats: [VideoCaptureSettings],
                            playbackSettings: [VideoCaptureSettings],
                            colorSpace: VideoColorSpace, codec: VideoCodec) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in
            captureRates(for: resolution, captureFormats: captureFormats,
                         playbackSettings: playbackSettings, colorSpace: colorSpace,
                         codec: codec).isEmpty == false
        }
    }

    static func captureRates(for resolution: VideoResolution,
                             captureFormats: [VideoCaptureSettings],
                             playbackSettings: [VideoCaptureSettings],
                             colorSpace: VideoColorSpace, codec: VideoCodec) -> [VideoFrameRate] {
        SlowMotionCapturePolicy.captureRates.filter { captureRate in
            let inputFormatExists = captureFormats.contains {
                $0.resolution == resolution && $0.colorSpace == colorSpace && $0.frameRate == captureRate
            }
            guard inputFormatExists else { return false }
            return playbackSettings.contains { playback in
                playback.resolution == resolution && playback.colorSpace == colorSpace
                    && playback.frameRate.rawValue < captureRate.rawValue
                    && SlowMotionCapturePolicy.isSupported(playbackFrameRate: playback.frameRate,
                        captureFrameRate: captureRate, codec: codec, colorSpace: colorSpace,
                        isRAW: playback.isRAW, openGate: false, resolution: resolution)
            }
        }
    }
}

/// 相机队列上枚举出的兼容镜头路线，供子模块自动换镜头使用。
struct VideoSubmodeCaptureRoute {
    let lensID: String
    let settings: [VideoCaptureSettings]
}

/// 各物理镜头的视频规格缓存；避免每次界面刷新都遍历 AVCaptureDevice 格式。
struct VideoLensCaptureCapabilities: Equatable {
    let ordinary: [VideoCaptureSettings]
    let slowMotionCaptureRates: [VideoCaptureSettings]
    let openGate: [VideoCaptureSettings]
    let cinematic: [VideoCaptureSettings]
    var raw: [VideoCaptureSettings] = []
    var centerStage: [VideoCaptureSettings] = []

    func settings(for mode: VideoSubmode, openGateEnabled: Bool) -> [VideoCaptureSettings] {
        switch mode {
        case .timeLapse:
            return openGateEnabled ? openGate : ordinary
        case .slowMotion:
            return VideoSubmodeSettingsPolicy.slowMotionPlaybackSettings(from: ordinary, captureRates: slowMotionCaptureRates)
        case .cinematic:
            return cinematic
        }
    }
}

enum VideoSubmode: Equatable {
    case timeLapse
    case slowMotion
    case cinematic

    /// 与子模块弹窗保持一致；退出子模块后由入口恢复普通视频图标。
    var symbol: String {
        switch self {
        case .timeLapse: return "timelapse"
        case .slowMotion: return "slowmo"
        case .cinematic: return "movieclapper"
        }
    }
}

enum VideoRatio: String, CaseIterable, Identifiable {
    case ratio4x3 = "4:3"
    case square = "1:1"
    case ratio16x9 = "16:9"
    case wide = "2:1"
    case cinema = "2.39:1"
    case openGate = "Open Gate"

    static var aspectOptions: [VideoRatio] { allCases.filter { $0 != .openGate } }
    static var openGateAspectOptions: [VideoRatio] { [.ratio4x3, .square] }

    static func options(openGateEnabled: Bool) -> [VideoRatio] {
        openGateEnabled ? openGateAspectOptions : aspectOptions
    }

    var id: String { rawValue }

    var frameRatio: FrameRatio {
        switch self {
        case .ratio4x3: return .standard
        case .square: return .square
        case .ratio16x9: return .wide
        case .wide: return .panorama
        case .cinema: return .cinema
        case .openGate: return .openGate
        }
    }
}

enum VideoColorSpace: String, CaseIterable, Identifiable, Codable, Hashable {
    case sdr = "SDR"
    case p3 = "P3"
    case hdr = "HDR"
    case appleLog = "Apple Log"
    case appleLog2 = "Apple Log 2"

    var id: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case h264 = "H.264"
    case proRes = "ProRes"

    var id: String { rawValue }
}

enum VideoStabilizationPreference: String, CaseIterable, Identifiable, Codable {
    case off = "关闭"
    case lowLatency = "低延迟"
    case standard = "标准"
    case cinematic = "电影"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .off: return "不启用防抖，画面无额外裁切，适合三脚架或固定机位。"
        case .lowLatency: return "低延迟防抖，预览更跟手，裁切和稳定性居中。"
        case .standard: return "标准防抖，稳定性更好，延迟和裁切略高于低延迟。"
        case .cinematic: return "电影防抖，稳定性最强，裁切最大，预览和录制延迟最明显。"
        }
    }
}

enum VideoBitratePreset: String, CaseIterable, Identifiable, Codable {
    case systemDefault = "默认"
    case low = "低"
    case medium = "中"
    case high = "高"

    var id: String { rawValue }
}

enum ProResSpecification: String, CaseIterable, Identifiable {
    case proxy = "422 Proxy"
    case lt = "422 LT"
    case standard = "422"
    case hq = "422 HQ"
    case four4 = "4444"
    case four4xq = "4444 XQ"
    case raw = "RAW"
    case rawHQ = "RAW HQ"

    var id: String { rawValue }

    // RAW capture requires authorized external storage and a compatible lens.
    var isSelectable: Bool { self != .raw && self != .rawHQ }
}
