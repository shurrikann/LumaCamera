import AVFoundation
import CoreImage
import UIKit

enum PhotoFileFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF", jpeg = "JPG", raw = "RAW", rawJPEG = "RAW+JPG", tiff = "TIFF", heifPro = "HEIF Pro"
    var id: String { rawValue }
    var needsRAW: Bool { self == .raw || self == .rawJPEG || self == .heifPro }
}
enum PhotoResolution: Int, CaseIterable, Identifiable {
    case standard = 12, high = 48
    var id: Int { rawValue }
    var title: String { "\(rawValue)MP" }
}

/// 单个镜头路由可用于子模块默认配置与焦段禁用状态。
struct PhotoLensCaptureCapabilities: Equatable {
    let formats: Set<PhotoFileFormat>
    let resolutions: Set<PhotoResolution>
    let supportsNightCapture: Bool
    let supportsPortraitCapture: Bool

    func supports(_ mode: PhotoSubmode) -> Bool {
        switch mode {
        case .slowShutter:
            return !resolutions.isEmpty
        case .night:
            return supportsNightCapture && formats.contains { NightCapturePolicy.supportedFormats.contains($0) }
                && resolutions.contains(.standard)
        case .portrait:
            return supportsPortraitCapture && formats.contains { PortraitCapturePolicy.processedFormats.contains($0) }
                && resolutions.contains(.standard)
        case .burst:
            return formats.contains { PhotoBurstPolicy.supportedFormats.contains($0) }
                && resolutions.contains(.standard)
        }
    }
}

enum PhotoSubmode: Equatable {
    case slowShutter
    case night
    case portrait
    case burst

    /// 子模块入口与弹窗选项共用同一图标，避免选中后仍显示普通相机图案。
    var symbol: String {
        switch self {
        case .slowShutter: return "timer"
        case .night: return "moon.stars.fill"
        case .portrait: return "person.crop.rectangle"
        case .burst: return "square.stack.3d.up"
        }
    }
}

/// 不兼容时提供一个默认基线；可保留仍符合目标模式的用户选择。
enum PhotoSubmodeSettingsPolicy {
    static func formats(for mode: PhotoSubmode) -> [PhotoFileFormat] {
        switch mode {
        case .night, .burst: return [.heif, .jpeg]
        case .portrait: return [.heif, .jpeg, .raw, .rawJPEG, .heifPro]
        case .slowShutter: return PhotoFileFormat.allCases
        }
    }

    static func preferredFormat(for mode: PhotoSubmode, requested: PhotoFileFormat,
                                supported: Set<PhotoFileFormat>) -> PhotoFileFormat? {
        let compatible = formats(for: mode).filter { supported.contains($0) }
        return compatible.contains(requested) ? requested : compatible.first
    }

    static func resolution(for mode: PhotoSubmode, requested: PhotoResolution,
                           supported: Set<PhotoResolution>) -> PhotoResolution? {
        let allowed = supported.filter { resolution in
            switch mode {
            case .night, .burst: return resolution == .standard
            case .portrait: return PhotoResolution.allCases.contains(resolution)
            case .slowShutter: return true
            }
        }
        if allowed.contains(requested) { return requested }
        if allowed.contains(.standard) { return .standard }
        return allowed.sorted { $0.rawValue > $1.rawValue }.first
    }
}

enum PhotoBurstPolicy {
    static let supportedFormats: Set<PhotoFileFormat> = [.jpeg, .heif]

    static func supports(format: PhotoFileFormat, resolution: PhotoResolution, live: Bool, hdr: Bool) -> Bool {
        supportedFormats.contains(format) && resolution == .standard && !live && !hdr
    }
}

enum NightCapturePolicy {
    /// 单次包围的张数；完整夜景总张数由 NightAdaptiveCapturePolicy 决定。
    static let frameCount = 3
    static let exposureTargetBiases: [Float] = [-1.0, 0.0, 1.0]
    static let supportedFormats: Set<PhotoFileFormat> = [.jpeg, .heif]

    static func supports(format: PhotoFileFormat, resolution: PhotoResolution, live: Bool, hdr: Bool,
                         timerSeconds: Int, manualMode: Bool = false, flashMode: CameraFlashMode = .off,
                         maximumBracketedCapturePhotoCount: Int = frameCount) -> Bool {
        supportedFormats.contains(format) && resolution == .standard && !live && !hdr && timerSeconds == 0
            && flashMode == .off && maximumBracketedCapturePhotoCount >= frameCount
    }

    static func qualityPriority(nightMode: Bool, usesRAW: Bool, usesManualExposure: Bool,
                                maximum: AVCapturePhotoOutput.QualityPrioritization) -> AVCapturePhotoOutput.QualityPrioritization {
        let desired: AVCapturePhotoOutput.QualityPrioritization = nightMode ? .quality : (usesRAW || usesManualExposure ? .speed : .balanced)
        switch desired {
        case .quality: return maximum == .quality ? .quality : maximum
        case .balanced: return maximum == .speed ? .speed : .balanced
        case .speed: return .speed
        @unknown default: return maximum
        }
    }
}

enum PortraitCapturePolicy {
    static let processedFormats: Set<PhotoFileFormat> = [.jpeg, .heif]
    static let proRAWFormats: Set<PhotoFileFormat> = [.raw, .rawJPEG, .heifPro]

    /// 原生深度/人像蒙版不是软件人物分割的前提。只将可解码的照片路线作为软件入口，
    /// 不因其他镜头的原生深度能力而误禁用当前物理主摄的 JPG/HEIF 人像。
    static func supportsSoftwarePortrait(formats: Set<PhotoFileFormat>, resolutions: Set<PhotoResolution>) -> Bool {
        resolutions.contains(.standard) && !formats.intersection(processedFormats).isEmpty
    }

    static func availableFormats(proRAWAvailable: Bool) -> Set<PhotoFileFormat> {
        processedFormats.union(proRAWAvailable ? proRAWFormats : [])
    }

    static func supports(format: PhotoFileFormat, resolution: PhotoResolution, live: Bool, hdr: Bool,
                         proRAWAvailable: Bool = false) -> Bool {
        // AVFoundation exposes portrait-matte delivery at the photo-output and
        // per-request levels; it does not define a blanket 12MP-only limit.
        // Apple documents portrait mattes for ProRAW, but not Bayer RAW. The
        // active camera format still determines whether a requested size exists.
        let formatIsSupported = processedFormats.contains(format)
            || (proRAWAvailable && proRAWFormats.contains(format))
        // Apple doesn't document a general Portrait + HDR prohibition. However,
        // this app's RAW-backed HEIF HDR still path did not complete on iPhone 17 Pro
        // when portrait capture was armed, so keep this combination unavailable until
        // that capture route is implemented and verified independently.
        let hdrFormatIsSupported = !hdr
        return formatIsSupported && hdrFormatIsSupported
            && PhotoResolution.allCases.contains(resolution) && !live
    }
}

enum NightIndicatorState: Equatable {
    case hidden
    case waitingForLowLight
    case triggered
    case unsupported

    static func resolve(isEnabled: Bool, captureSupported: Bool, environmentTriggered: Bool) -> Self {
        guard isEnabled else { return .hidden }
        guard captureSupported else { return .unsupported }
        return environmentTriggered ? .triggered : .waitingForLowLight
    }
}

/// App-side low-light heuristic for the night-mode indicator. AVFoundation provides
/// automatic exposure readings, but doesn't publish a universal Night-mode threshold.
struct NightCaptureEnvironmentGate {
    static let triggerExposureIndex = 64.0 // ISO × seconds, approximately ISO 1600 at 1/25 s.
    static let releaseExposureIndex = 40.0
    static let samplesToTrigger = 2
    static let samplesToRelease = 3

    private(set) var isTriggered = false
    private var lowLightSamples = 0
    private var brightSamples = 0

    mutating func update(iso: Double, seconds: Double, exposureBiasEV: Double) -> Bool {
        guard iso.isFinite, iso > 0, seconds.isFinite, seconds > 0, exposureBiasEV.isFinite else {
            lowLightSamples = 0
            brightSamples = 0
            return isTriggered
        }

        // Normalize the user's exposure compensation so raising EV alone doesn't
        // falsely make a normally lit scene look like a night-mode scene.
        let exposureIndex = iso * seconds / pow(2, exposureBiasEV)
        guard exposureIndex.isFinite else { return isTriggered }

        if isTriggered {
            lowLightSamples = 0
            if exposureIndex <= Self.releaseExposureIndex {
                brightSamples += 1
                if brightSamples >= Self.samplesToRelease {
                    isTriggered = false
                    brightSamples = 0
                }
            } else {
                brightSamples = 0
            }
        } else {
            brightSamples = 0
            if exposureIndex >= Self.triggerExposureIndex {
                lowLightSamples += 1
                if lowLightSamples >= Self.samplesToTrigger {
                    isTriggered = true
                    lowLightSamples = 0
                }
            } else {
                lowLightSamples = 0
            }
        }
        return isTriggered
    }

    mutating func reset() {
        isTriggered = false
        lowLightSamples = 0
        brightSamples = 0
    }
}

enum CameraFlashMode: String, CaseIterable {
    case off = "关闭", on = "打开", auto = "自动"
    var next: Self { self == .off ? .on : self == .on ? .auto : .off }
    var avMode: AVCaptureDevice.FlashMode { self == .off ? .off : self == .on ? .on : .auto }
    var icon: String { self == .off ? "bolt.slash" : self == .on ? "bolt.fill" : "bolt.badge.a" }
}
final class SlowShutterSourceFrame: @unchecked Sendable {
    let sequenceID: UUID
    let image: CIImage
    let look: CaptureLook
    let diagnostics: PhotoCaptureDiagnostics?
    let location: PhotoLocation?
    init(sequenceID: UUID, image: CIImage, look: CaptureLook, diagnostics: PhotoCaptureDiagnostics?, location: PhotoLocation?) {
        self.sequenceID = sequenceID
        self.image = image; self.look = look; self.diagnostics = diagnostics; self.location = location
    }
}

enum PhotoCapturePurpose: Equatable {
    case standard
    case slowShutterSequence(UUID)
}

struct PhotoOptions {
    var format: PhotoFileFormat = .jpeg
    var resolution: PhotoResolution = .standard
    var hdr = false
    var adaptiveHighDynamic = false
    var live = false
    var nightMode = false
    var portraitMode = false
    var portraitBlurStrength = 0.5
    var copyright = ""
    var saveUnfilteredOriginal = false
    var silentShutter = false
    /// User-facing capture type stored in app-local photo diagnostics.
    var shootingType = "普通"
    var purpose: PhotoCapturePurpose = .standard
    /// 慢门使用独立的静态曝光请求，避免逐帧改动取景器的曝光时钟。
    var prefersManualExposureBracket = false
    var nightProfile: IndependentNightProfile = .balanced
    var nightBrightTone = false
    var nightHDRPhoto = false
    var usesHDRHEIF: Bool { format == .heif && hdr }
    /// 普通 HEIF+HDR 走系统处理源；只有 RAW/RAW+JPG/HEIF Pro 需要 RAW。
    var usesRAWCapture: Bool { format.needsRAW }
    var capturesLive: Bool { !usesHDRHEIF && live && (format == .jpeg || format == .heif) && resolution == .standard }
}
struct PhotoResource {
    let data: Data
    let filename: String
    var alternate = false
    var pairedVideo = false
}
struct CapturedPhoto {
    let preview: UIImage
    let resources: [PhotoResource]
    var diagnostics: PhotoCaptureDiagnostics? = nil
    var location: PhotoLocation? = nil
    var unfilteredOriginal: PhotoResource? = nil
}
enum CameraToolbarPanel { case format, ratio, tone, videoFormat, videoRatio, videoColor, videoCodec, slowShutterDuration }
