import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import CoreImage
import ImageIO

struct SlowShutterSequenceProgress: Equatable {
    let completed: Int
    let total: Int
    var elapsedSeconds: Double? = nil
    var targetSeconds: Double? = nil
    var label: String {
        if let elapsedSeconds, let targetSeconds { return "\(min(Int(elapsedSeconds),Int(targetSeconds)))/\(Int(targetSeconds))秒" }
        return "\(completed)/\(total)"
    }

    /// 0...1 ring fill. Finite sequences use elapsed/target; infinite sequences
    /// make one full turn every 60 seconds while the centre counts up.
    var fraction: Double {
        if let elapsedSeconds {
            if let targetSeconds, targetSeconds > 0, targetSeconds < 1 {
                // Short exposures fill the ring over their real duration.
                return min(max(elapsedSeconds / targetSeconds, 0), 1)
            }
            // One full turn per second for durations >= 1s and for ∞.
            return elapsedSeconds.truncatingRemainder(dividingBy: 1)
        }
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    var secondsText: String {
        guard let elapsedSeconds else { return "\(completed)" }
        return "\(Int(min(elapsedSeconds, targetSeconds ?? elapsedSeconds)))s"
    }

    /// Shutter countdown: remaining seconds for finite sequences, elapsed time
    /// for ∞. Values under ten seconds keep one decimal.
    var countdownText: String {
        guard let elapsedSeconds else { return "\(completed)" }
        if let targetSeconds {
            let remaining = max(0, targetSeconds - elapsedSeconds)
            if remaining < 10 {
                return String(format: "%.1fs", remaining)
            }
            return "\(Int(ceil(remaining)))s"
        }
        let seconds = Int(elapsedSeconds)
        if seconds >= 60 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return "\(seconds)s"
    }
}

private struct SlowShutterSequenceRestore {
    let photoFormat: PhotoFileFormat
    let photoResolution: PhotoResolution
    let hdr: Bool
    let live: Bool
    let timerSeconds: Int
    let flashMode: CameraFlashMode
    let manualExposure: Bool
    let manualWB: Bool
    let manualFocus: Bool
    let iso: Double
    let shutter: Double
    let wb: Double
    let tint: Double
    let focus: Double
}

private final class SlowShutterCompositionInput: @unchecked Sendable {
    let frames: [SlowShutterSourceFrame]
    let format: PhotoFileFormat
    let presetTitle: String
    let blend: SlowShutterBlendMode
    let frameCount: Int
    let options: PhotoOptions
    let look: CaptureLook
    let location: PhotoLocation?
    let captureMode: String
    let streamingComposer: SlowShutterComposer?
    let captureSeconds: Double?
    init(frames: [SlowShutterSourceFrame], format: PhotoFileFormat, presetTitle: String,
         blend: SlowShutterBlendMode, frameCount: Int, options: PhotoOptions,
         look: CaptureLook, location: PhotoLocation?, captureMode: String, streamingComposer: SlowShutterComposer? = nil,
         captureSeconds: Double? = nil) {
        self.frames = frames; self.format = format; self.presetTitle = presetTitle
        self.blend = blend; self.frameCount = frameCount; self.options = options
        self.look = look; self.location = location
        self.captureMode = captureMode
        self.streamingComposer = streamingComposer
        self.captureSeconds = captureSeconds
    }
}

private struct SlowShutterSequenceState {
    let token: UUID
    let preset: SlowShutterPreset
    let presetTitle: String
    let spec: SlowShutterSequenceSpec
    let format: PhotoFileFormat
    let restore: SlowShutterSequenceRestore
    var frames: [SlowShutterSourceFrame] = []
    var completedFrames = 0
    var streamingComposer: SlowShutterComposer? = nil // 只在合成串行队列访问。
    var streamFramePending = false
    var finishRequested = false
    var firstSourceTime: TimeInterval? = nil
    var lastSourceTime: TimeInterval? = nil
    var lastPreviewTime: TimeInterval? = nil
}

@MainActor
final class CameraViewModel: ObservableObject {
    enum CaptureKind: Equatable { case photo, video }
    @Published private(set) var captureKind: CaptureKind = .photo {
        didSet {
            photoSubmodeRequest = UUID()
            photoSubmodePreparing = nil
            videoSubmodeRequest = UUID()
            videoSubmodePreparing = nil
            virtualApertureEnabled = false // 照片/视频切换不带入临时子模块。
            virtualApertureSliderVisible = false
            frontVideoCenteringRequested = false
            if camera.frontVideoCenteringEnabled { camera.setFrontVideoCentering(false) }
            if captureKind == .video {
                nightModeEnabled = false; nightCaptureRuntimeUnavailable = false
                portraitModeEnabled = false
                clearSlowShutterMode()
            } else {
                timeLapseEnabled = false
                slowMotionEnabled = false
                cinematicVideoEnabled = false
            }
            compatibleSubmodeLensIDs = nil
            // Pro测光选择只归属照片HEIF Pro；进入视频不沿用全局/点测光。
            camera.setMetering(effectiveMetering)
            reconcileNightMode()
        }
    }
    @Published private(set) var frontVideoCenteringRequested = false
    private var photoModeBeforeVideo: CameraShootingMode = .auto
    private var photoManualSettingsBeforeVideo: SavedManualCaptureState?
    private var videoModeBeforePhoto: CameraShootingMode = .auto
    private var photoRatioBeforeVideo: FrameRatio = .standard
    private var photoFormatBeforeVideo: PhotoFileFormat?
    private var photoResolutionBeforeVideo: PhotoResolution = .standard
    private var photoHDRBeforeVideo = false
    @Published private(set) var videoElapsed: TimeInterval = 0
    @Published private(set) var captureKindSwitching = false
    @Published private(set) var recordingCapacity: RecordingCapacity.Info?
    private var videoClock: Task<Void, Never>?
    func refreshRecordingCapacity() {
        let settings = VideoCaptureSettings(resolution: videoResolution, frameRate: videoFrameRate,
            colorSpace: videoColorSpace, codec: videoCodec, proRes: proResSpecification,
            bitratePreset: preferences.videoBitratePreset)
        let externalCapacity = rawVideoSelected ? externalVideoStorage.capacitySnapshot : nil
        recordingCapacity = RecordingCapacity.info(videoBitsPerSecond: Double(settings.bitRate),
                                                     externalCapacity: externalCapacity)
    }
    let locationService = CaptureLocationService()
    let camera: CameraEngine
    let dockKitTracking = DockKitTrackingController()
    let library: PhotoLibraryViewModel
    let gallery: GalleryViewModel
    let filters = FilterPickerViewModel()
    private var levelHapticGate = LevelHapticGate()
    private var activeDeviceID: String?
    private var lastAppliedFrontOrientation: Bool?
    private var lifecycleRequest = UUID()
    private var cameraActiveRequested = false
    private var pagerRequest = UUID()
    private var sliderEVRequest = UUID()
    private var subscriptions = Set<AnyCancellable>()
    @Published private(set) var dockKitAccessoryConnected = false
    @Published private(set) var dockKitTrackingEnabled = false
    @Published private(set) var dockKitTrackingUpdating = false
    private let preferencesStore: CapturePreferencesStore
    private var captureStateWriteTask: Task<Void, Never>?
    private var pendingStartupCaptureState: SavedCaptureState?
    private var startupCaptureRestoreTask: Task<Void, Never>?
    private var restoringCaptureState = false
    private var restoringAuxiliaryPreferences = false
    /// 当前视频格式实际支持的防抖档位；能力尚未发布时先全部开放，避免设置页闪烁。
    func isVideoStabilizationAvailable(_ option: VideoStabilizationPreference) -> Bool {
        let supported = camera.supportedVideoStabilizationPreferences
        return supported.isEmpty || supported.contains(option)
    }

    private func videoStabilizationFallback(for preference: VideoStabilizationPreference,
                                            supported: Set<VideoStabilizationPreference>) -> VideoStabilizationPreference? {
        guard !supported.isEmpty else { return nil }
        let chain: [VideoStabilizationPreference]
        switch preference {
        case .cinematic: chain = [.standard, .off]
        case .standard: chain = [.off]
        case .off: return nil
        }
        return chain.first(where: supported.contains)
    }

    private func reconcileVideoStabilizationPreference(_ supported: Set<VideoStabilizationPreference>) {
        guard !supported.isEmpty, !supported.contains(preferences.videoStabilization),
              let fallback = videoStabilizationFallback(for: preferences.videoStabilization, supported: supported) else { return }
        preferences.videoStabilization = fallback
    }

    @Published var preferences = CapturePreferences() {
        didSet {
            preferencesStore.save(preferences)
            if preferences.focusAssist != oldValue.focusAssist { refreshFocusNavigatorPreference() }
            if preferences.videoBitratePreset != oldValue.videoBitratePreset, !restoringVideoSettings {
                synchronizeVideoSettings()
            }
            if preferences.videoStabilization != oldValue.videoStabilization {
                if !isVideoStabilizationAvailable(preferences.videoStabilization),
                   let fallback = videoStabilizationFallback(for: preferences.videoStabilization,
                       supported: camera.supportedVideoStabilizationPreferences) {
                    preferences.videoStabilization = fallback
                    return
                }
                camera.setVideoStabilizationPreference(preferences.videoStabilization)
            }
            if preferences.saveCaptureSettings != oldValue.saveCaptureSettings {
                if preferences.saveCaptureSettings { flushCaptureSettings() }
                else { captureStateWriteTask?.cancel(); preferencesStore.clearCaptureState() }
            }
            locationService.setActive(cameraActiveRequested && preferences.recordLocation)
        }
    }
    private let filterSettings: FilterSettingsStore
    private var restoringFilterSettings = false
    @Published var filterEditorTab = FilterEditorTab.color { didSet {
        if filterEditorTab != oldValue { dismissFilterNumericInput() }
    } }
    @Published private(set) var filterResetVisible = false
    @Published private(set) var filterNumericParameter: FilterParameter?
    @Published var filterNumericDraft = ""
    private var filterNumericBinding: Binding<Double>?
    @Published private(set) var filterResetRevision: UInt64 = 0
    private var filterResetStyle: FilmStyle?
    private var filterParameterEditing = false
    @Published var filterAdjustments = FilterAdjustments() { didSet { if !restoringFilterSettings { saveFilterSettings(); updateLook() } } }
    @Published var style = FilmStyle.original { didSet { if style != oldValue { dismissFilterNumericInput(); dismissFilterReset(); setFilterParameterEditing(false); filterSettings.select(style); restoreFilterSettings() }; updateLook() } }
    @Published var intensity = 0.8 { didSet { if !restoringFilterSettings { saveFilterSettings(); updateLook() } } }
    @Published var ratio = FrameRatio.standard { didSet { cancelFocus(); updateLook() } }
    private var restoringVideoSettings = false
    @Published var videoResolution = VideoResolution.hd1080 { didSet { if videoResolution != oldValue { synchronizeVideoSettings() } } }
    @Published var showsRecordingCapacity = false {
        didSet { persistAuxiliaryPreferences() }
    }
    @Published var showsAudioMeter = false {
        didSet { persistAuxiliaryPreferences() }
    }
    /// Match the current recording pipeline's 30 fps default in the picker.
    @Published var videoFrameRate = VideoFrameRate.fps30 { didSet { if videoFrameRate != oldValue { synchronizeVideoSettings() } } }
    @Published var videoRatio = VideoRatio.ratio16x9 {
        didSet {
            if captureKind == .video {
                ratio = videoRatio.frameRatio
                if videoRatio != oldValue { synchronizeVideoSettings() }
            }
        }
    }
    @Published var videoOpenGateEnabled = false {
        didSet { if videoOpenGateEnabled != oldValue { synchronizeVideoSettings() } }
    }
    @Published var videoColorSpace = VideoColorSpace.sdr { didSet { if videoColorSpace != oldValue { synchronizeVideoSettings() } } }
    @Published private(set) var logLUTPresets = LogLUTCubeRepository.presets()
    @Published private(set) var logLUTCategory: FilterCategory = .all
    @Published private(set) var logLUTFavorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "camera.favoriteLogLUTs") ?? [])
    @Published private(set) var logLUTThumbnails: [String: UIImage] = [:]
    @Published private(set) var logLUTThumbnailLoading: Set<String> = []
    @Published private(set) var logLUTLoading = false
    @Published private(set) var selectedLogLUTCube: LogLUTCube?
    @Published var selectedLogLUTID: String? = UserDefaults.standard.string(forKey: "camera.selectedLogVideoLUT") ?? LogLUTPreset.originalID {
        didSet {
            guard selectedLogLUTID != oldValue else { return }
            UserDefaults.standard.set(selectedLogLUTID, forKey: "camera.selectedLogVideoLUT")
            if selectedLogLUTID == LogLUTPreset.originalID { burnLogLUT = false }
            loadSelectedLogLUT()
        }
    }
    @Published var burnLogLUT = UserDefaults.standard.bool(forKey: "camera.burnLogVideoLUT") {
        didSet { UserDefaults.standard.set(burnLogLUT, forKey: "camera.burnLogVideoLUT") }
    }
    private var logLUTLoadRequest = UUID()
    private static let sharedLogLUTThumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private static let logLUTThumbnailQueue = DispatchQueue(label: "camera.logLUTThumbnails", qos: .userInitiated)
    private static let logLUTThumbnailContext = CIContext(options: [.cacheIntermediates: false])
    @Published var videoCodec = VideoCodec.hevc { didSet { if videoCodec != oldValue { synchronizeVideoSettings() } } }
    @Published var proResSpecification = ProResSpecification.hq { didSet { if proResSpecification != oldValue { synchronizeVideoSettings() } } }
    @Published private(set) var timeLapseEnabled = false
    @Published private(set) var selectedTimeLapsePreset: TimeLapsePreset?
    @Published private(set) var timeLapseInterval: TimeLapseInterval = .s1
    @Published private(set) var timeLapseFrameCount: TimeLapseFrameCount = .infinite
    @Published private(set) var slowMotionEnabled = false
    @Published private(set) var cinematicVideoEnabled = false
    @Published private(set) var videoSubmodePreparing: VideoSubmode?
    @Published private(set) var photoSubmodePreparing: PhotoSubmode?
    @Published private(set) var compatibleSubmodeLensIDs: Set<String>?
    private var photoSubmodeRequest = UUID()
    private var captureKindSwitchToken = UUID()
    private var pendingCaptureKindRequest: CaptureKind?
    private var pendingCaptureKindTask: Task<Void, Never>?
    private var videoSubmodeRequest = UUID()
    private var selectedSlowMotionCaptureRate: VideoFrameRate?
    let externalVideoStorage = ExternalVideoStorage.shared
    private var pendingStorageFallback = false
    var rawVideoSelected: Bool { videoCodec == .proRes && !proResSpecification.isSelectable }
    var timeLapseUnavailableReason: String? {
        guard captureKind == .video else { return "仅视频模式可用" }
        guard !camera.videoBusy else { return "录制中不能更改" }
        guard !camera.supportedVideoSettings.isEmpty else { return "当前镜头没有可用视频规格" }
        return nil
    }

    var slowMotionUnavailableReason: String? {
        guard captureKind == .video else { return "仅视频模式可用" }
        guard !camera.videoBusy else { return "录制中不能更改" }
        guard !slowMotionPlaybackSettings.isEmpty else { return "当前镜头没有可用的高帧率规格" }
        return nil
    }

    var cinematicVideoUnavailableReason: String? {
        guard captureKind == .video else { return "仅视频模式可用" }
        guard !camera.videoBusy else { return "录制中不能更改" }
        guard #available(iOS 26.0, *) else { return "需要 iOS 26 或更新版本" }
        guard !camera.cinematicVideoSettings.isEmpty else { return "当前镜头没有可用的电影模式规格" }
        return nil
    }

    private var slowMotionPlaybackSettings: [VideoCaptureSettings] {
        if let row = camera.videoSelectionCapabilities[camera.selectedLens] {
            return row.settings(for:.slowMotion,openGateEnabled:false)
        }
        return camera.slowMotionVideoSettings
    }

    private var slowMotionCaptureFormatsForSelection:[VideoCaptureSettings] {
        camera.videoSelectionCapabilities[camera.selectedLens]?.slowMotionCaptureRates ?? camera.slowMotionCaptureFormats
    }

    /// 规格弹窗展示当前镜头的传感器采集分辨率；回放帧率不会混入此列表。
    var slowMotionCaptureResolutionOptions: [VideoResolution] {
        let rate = slowMotionCaptureFrameRateForSelection
        return SlowMotionCapturePickerPolicy.resolutions(captureFormats: slowMotionCaptureFormatsForSelection,
            playbackSettings: slowMotionPlaybackSettings, colorSpace: videoColorSpace, codec: videoCodec).filter { resolution in
                slowMotionCaptureFormatsForSelection.contains { $0.resolution == resolution && $0.frameRate == rate && $0.colorSpace == videoColorSpace }
            }
    }

    /// 规格弹窗展示当前采集分辨率下真实支持的高帧率输入规格。
    var slowMotionCaptureFrameRateOptions: [VideoFrameRate] {
        SlowMotionCapturePickerPolicy.captureRates(for: videoResolution,
            captureFormats: slowMotionCaptureFormatsForSelection, playbackSettings: slowMotionPlaybackSettings,
            colorSpace: videoColorSpace, codec: videoCodec)
    }

    var slowMotionCaptureFrameRateForSelection: VideoFrameRate {
        if let selectedSlowMotionCaptureRate,
           slowMotionCaptureFrameRateOptions.contains(selectedSlowMotionCaptureRate) {
            return selectedSlowMotionCaptureRate
        }
        if let preferred = slowMotionPlaybackSettings.first(where: {
            $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
        })?.captureFrameRate, slowMotionCaptureFrameRateOptions.contains(preferred) {
            return preferred
        }
        return slowMotionCaptureFrameRateOptions.first ?? SlowMotionCapturePolicy.fallbackCaptureRate
    }

    var isPreparingSubmode: Bool { photoSubmodePreparing != nil || videoSubmodePreparing != nil || camera.dualCapturePreparing }

    private var selectedVideoSettings: VideoCaptureSettings {
        VideoCaptureSettings(resolution: videoResolution, frameRate: videoFrameRate,
            colorSpace: videoColorSpace, codec: videoCodec, proRes: proResSpecification,
            bitratePreset: preferences.videoBitratePreset)
    }

    private func currentVideoSubmodeCandidates(_ mode: VideoSubmode) -> [VideoCaptureSettings] {
        if let row = camera.videoSelectionCapabilities[camera.selectedLens] {
            return row.settings(for:mode,openGateEnabled:mode == .timeLapse && videoOpenGateEnabled)
        }
        switch mode {
        case .timeLapse:
            if videoOpenGateEnabled, !camera.openGateVideoSettings.isEmpty { return camera.openGateVideoSettings }
            return camera.supportedVideoSettings
        case .slowMotion: return slowMotionPlaybackSettings
        case .cinematic: return camera.cinematicVideoSettings
        }
    }

    /// 选择兼容规格时尽量保留当前设置；找不到时回退到设备能用的安全基线。
    private func applyVideoSubmodeSettings(_ mode: VideoSubmode, candidates: [VideoCaptureSettings],
                                           preserveOpenGate: Bool = true) -> VideoCaptureSettings? {
        let playbackRate = mode == .slowMotion && videoFrameRate != .fps120 ? videoFrameRate : .fps30
        guard let target = VideoSubmodeSettingsPolicy.compatibleSettings(candidates,
            preserving: selectedVideoSettings, defaultPlaybackRate: playbackRate) else { return nil }
        var codec = videoCodec
        if mode != .timeLapse || rawVideoSelected {
            if codec != .hevc && codec != .h264 { codec = .hevc }
        }
        if codec == .h264 && (target.colorSpace.usesTenBit || target.colorSpace.isLog) { codec = .hevc }
        let wasRestoring = restoringVideoSettings
        if mode == .slowMotion { selectedSlowMotionCaptureRate = target.captureFrameRate }
        restoringVideoSettings = true
        videoResolution = target.resolution
        videoFrameRate = target.frameRate
        videoColorSpace = target.colorSpace
        videoCodec = codec
        if codec != .proRes { proResSpecification = .hq }
        if mode != .timeLapse || !preserveOpenGate { videoOpenGateEnabled = false }
        if videoOpenGateEnabled && !VideoRatio.openGateAspectOptions.contains(videoRatio) {
            videoRatio = .ratio4x3
        }
        restoringVideoSettings = wasRestoring
        return target
    }

    /// 当前子模式因镜头能力异步刷新而失配时，在当前路线内切回最近的兼容规格。
    /// 用户主动切换子模式时若当前路线没有候选规格，仍由异步全镜头查询负责选择镜头。
    private func prepareVideoSubmode(_ mode: VideoSubmode) -> Bool {
        let candidates = currentVideoSubmodeCandidates(mode)
        let preserveOpenGate = mode == .timeLapse && videoOpenGateEnabled
            && !camera.openGateVideoSettings.isEmpty
        guard applyVideoSubmodeSettings(mode, candidates: candidates,
                                        preserveOpenGate: preserveOpenGate) != nil else { return false }
        if self.mode == .auto, currentPosition == .back, !rawVideoSelected {
            // 自动挡后置焦段由系统虚拟多摄承载，保留同一兼容路线内的焦段锚点。
            compatibleSubmodeLensIDs = Set(camera.lenses.filter { $0.device.position == .back }.map(\.id))
        } else {
            compatibleSubmodeLensIDs = camera.selectedLens.isEmpty ? [] : [camera.selectedLens]
        }
        return true
    }

    /// 开启时先检查当前路线；只有当前路线无兼容规格才异步查询其他镜头。
    private func toggleVideoSubmode(_ requested: VideoSubmode) {
        disableFrontVideoCenteringForManualChoice()
        if camera.dualCaptureEnabled {
            camera.setDualCaptureEnabled(false) { [weak self] success in
                guard let self, success else { return }
                self.restoreVideoSettingsAfterDualCapture()
                self.toggleVideoSubmode(requested)
            }
            return
        }
        guard captureKind == .video, !camera.videoBusy, !camera.dualCapturePreparing, videoSubmodePreparing == nil else { return }
        if virtualApertureEnabled { virtualApertureEnabled = false; updateLook() }
        if videoSubmodeIsEnabled(requested) {
            videoSubmodeRequest = UUID()
            videoSubmodePreparing = nil
            setVideoSubmode(requested, enabled: false)
            compatibleSubmodeLensIDs = nil
            finishVideoSubmodeChange()
            return
        }

        cameraSelectionFeedback()
        let request = UUID()
        videoSubmodeRequest = request
        if requested == .cinematic, !camera.cinematicVideoCaptureActive {
            videoSubmodePreparing = .cinematic
            camera.prepareCinematicInput { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self, self.videoSubmodeRequest == request, self.captureKind == .video else { return }
                    if success,
                       self.applyVideoSubmodeSettings(.cinematic,
                           candidates: self.currentVideoSubmodeCandidates(.cinematic)) != nil {
                        self.videoSubmodePreparing = nil
                        self.activateVideoSubmode(.cinematic)
                    } else {
                        self.videoSubmodePreparing = nil
                        self.setVideoSubmode(.cinematic, enabled: false)
                        self.camera.message = "当前镜头无法启用电影效果"
                    }
                }
            }
            return
        }
        let currentCandidates = currentVideoSubmodeCandidates(requested)
        let canKeepCurrentOpenGate = requested == .timeLapse && videoOpenGateEnabled
            && !camera.openGateVideoSettings.isEmpty
        let preserveCurrentOpenGate = requested != .timeLapse || !videoOpenGateEnabled || canKeepCurrentOpenGate
        // 电影效果需要 DualWide 等电影设备；不能仅因当前规格表有候选就直接
        // 在 TripleCamera 上启用，否则 AVFoundation 会反复 -11800 并卡住会话。
        if requested != .cinematic,
           applyVideoSubmodeSettings(requested, candidates: currentCandidates,
                                     preserveOpenGate: preserveCurrentOpenGate) != nil {
            let lensIDs: Set<String>
            if mode == .auto, currentPosition == .back, !rawVideoSelected {
                // A 挡后置焦段由同一个系统虚拟多摄路线承载，焦段锚点保持可选。
                lensIDs = Set(camera.lenses.filter { $0.device.position == .back }.map(\.id))
            } else {
                lensIDs = Set([camera.selectedLens])
            }
            compatibleSubmodeLensIDs = lensIDs
            activateVideoSubmode(requested)
            return
        }
        videoSubmodePreparing = requested
        if requested == .cinematic { scheduleVideoEntryWatchdog() }
        let wantsOpenGate = requested == .timeLapse && videoOpenGateEnabled
        camera.compatibleVideoSubmodeRoutes(for: requested, position: currentPosition,
                                             openGateEnabled: wantsOpenGate) { [weak self] routes in
            Task { @MainActor [weak self] in
                guard let self, self.videoSubmodeRequest == request,
                      self.captureKind == .video, !self.camera.videoBusy else { return }
                if routes.isEmpty && wantsOpenGate {
                    self.camera.compatibleVideoSubmodeRoutes(for: requested, position: self.currentPosition,
                                                              openGateEnabled: false) { [weak self] fallbackRoutes in
                        Task { @MainActor [weak self] in
                            guard let self, self.videoSubmodeRequest == request,
                                  self.captureKind == .video, !self.camera.videoBusy else { return }
                            self.finishVideoSubmodePreparation(request: request, mode: requested,
                                routes: fallbackRoutes, preserveOpenGate: false)
                        }
                    }
                    return
                }
                self.finishVideoSubmodePreparation(request: request, mode: requested,
                    routes: routes, preserveOpenGate: wantsOpenGate)
            }
        }
    }

    /// 在串行任务完成后应用兼容规格，并等待目标镜头真正就绪再开启子模式。
    private func finishVideoSubmodePreparation(request: UUID, mode requested: VideoSubmode,
                                               routes: [VideoSubmodeCaptureRoute], preserveOpenGate: Bool) {
        guard videoSubmodeRequest == request, captureKind == .video, !camera.videoBusy else { return }
        let flattened = routes.flatMap { route in route.settings.map { (route.lensID, $0) } }
        let playbackRate = requested == .slowMotion && videoFrameRate != .fps120 ? videoFrameRate : .fps30
        guard let target = VideoSubmodeSettingsPolicy.compatibleSettings(flattened.map(\.1),
                preserving: selectedVideoSettings, defaultPlaybackRate: playbackRate),
              let targetLensID = flattened.filter({ $0.1 == target }).min(by: { lhs, rhs in
                  let leftZoom = camera.lenses.first(where: { $0.id == lhs.0 })?.displayZoom ?? camera.currentZoom
                  let rightZoom = camera.lenses.first(where: { $0.id == rhs.0 })?.displayZoom ?? camera.currentZoom
                  return abs(leftZoom - camera.currentZoom) < abs(rightZoom - camera.currentZoom)
              })?.0,
              let targetLens = camera.lenses.first(where: { $0.id == targetLensID }) else {
            videoSubmodePreparing = nil
            camera.message = "当前设备没有可用的兼容拍摄规格"
            return
        }
        let matchingRoutes = Set(routes.filter { $0.settings.contains(target) }.map(\.lensID))
        guard applyVideoSubmodeSettings(requested, candidates: [target],
                                        preserveOpenGate: preserveOpenGate) != nil else {
            videoSubmodePreparing = nil
            camera.message = "当前设备没有可用的兼容拍摄规格"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 先等普通视频完成换路由，避免电影重配置抢在视频的首帧之前。
            if requested == .cinematic {
                while captureKindSwitching {
                    guard videoSubmodeRequest == request else { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard videoSubmodeRequest == request else { return }
            compatibleSubmodeLensIDs = matchingRoutes
            // 先启用子模式意图，再由相机队列一次性切到目标模式与镜头，避免
            // 普通镜头和电影专用镜头之间连续重建会话。
            activateVideoSubmode(requested, finish: false)
            synchronizeVideoSettings(preferredLensID: targetLens.id)
            var routeReady = false
            var cinematicConfiguredAt: TimeInterval?
            for _ in 0..<500 {
                guard videoSubmodeRequest == request else { return }
                if !camera.videoConfiguring && camera.ready {
                    switch requested {
                    case .slowMotion:
                        if let appliedRate = camera.videoSettings.captureFrameRate,
                           SlowMotionCapturePolicy.captureRates.contains(appliedRate) {
                            // 相机会话可能把 240 fps 请求回落到实际可用的 120 fps；以硬件最终应用值为准并同步选择器。
                            if selectedSlowMotionCaptureRate != appliedRate {
                                selectedSlowMotionCaptureRate = appliedRate
                            }
                            routeReady = true
                        }
                    case .cinematic:
                        let configured = camera.cinematicVideoCaptureActive
                            && camera.cinematicVideoSettings.contains {
                                $0.resolution == self.videoResolution && $0.frameRate == self.videoFrameRate
                                    && $0.colorSpace == self.videoColorSpace
                            }
                        if configured {
                            let threshold = cinematicConfiguredAt ?? CACurrentMediaTime()
                            cinematicConfiguredAt = threshold
                            routeReady = camera.latestRecordingPreviewFrameTime > threshold
                        } else { cinematicConfiguredAt = nil }
                    case .timeLapse:
                        routeReady = camera.videoSettings.captureFrameRate == nil
                    }
                    if routeReady { break }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard videoSubmodeRequest == request else { return }
            videoSubmodePreparing = nil
            if routeReady {
                // 目标规格已经提交并确认就绪，只收起面板；重复同步会再次重建电影管线。
                finishVideoSubmodeChange(synchronize: false)
            } else {
                setVideoSubmode(requested, enabled: false)
                camera.message = requested == .cinematic
                    ? "当前镜头无法启用电影效果"
                    : "当前镜头无法启用慢动作"
                synchronizeVideoSettings()
            }
        }
    }

    private func videoSubmodeIsEnabled(_ mode: VideoSubmode) -> Bool {
        switch mode {
        case .timeLapse: return timeLapseEnabled
        case .slowMotion: return slowMotionEnabled
        case .cinematic: return cinematicVideoEnabled
        }
    }

    private func setVideoSubmode(_ mode: VideoSubmode, enabled: Bool) {
        switch mode {
        case .timeLapse: timeLapseEnabled = enabled
        case .slowMotion: slowMotionEnabled = enabled
        case .cinematic: cinematicVideoEnabled = enabled
        }
        if mode == .slowMotion && !enabled { selectedSlowMotionCaptureRate = nil }
    }

    private func activateVideoSubmode(_ mode: VideoSubmode, finish: Bool = true) {
        setVideoSubmode(mode, enabled: true)
        if mode != .timeLapse { timeLapseEnabled = false }
        if mode != .slowMotion { slowMotionEnabled = false }
        if mode != .cinematic { cinematicVideoEnabled = false }
        if mode == .timeLapse, selectedTimeLapsePreset == nil {
            selectedTimeLapsePreset = .traffic
            timeLapseInterval = TimeLapsePreset.traffic.recommendedInterval
            timeLapseFrameCount = TimeLapsePreset.traffic.recommendedFrameCount
        }
        if finish { finishVideoSubmodeChange() }
        refreshVideoSubmodeLensCompatibility(for: mode)
    }

    /// 在相机串行队列按设备格式确认 M 挡下真正兼容的物理镜头。
    private func refreshVideoSubmodeLensCompatibility(for requested: VideoSubmode) {
        guard captureKind == .video, videoSubmodeIsEnabled(requested), !camera.selectedLens.isEmpty else { return }
        let position = currentPosition
        // A 挡后置倍率锚点使用同一虚拟多摄输入，能力跟随当前虚拟路线。
        if mode == .auto, position == .back, !rawVideoSelected {
            compatibleSubmodeLensIDs = Set(camera.lenses.filter { $0.device.position == .back }.map(\.id))
            return
        }
        let request = videoSubmodeRequest
        let captureMode = mode
        let selected = selectedVideoSettings
        let openGate = requested == .timeLapse && videoOpenGateEnabled
        camera.compatibleVideoSubmodeRoutes(for: requested, position: position,
                                             openGateEnabled: openGate) { [weak self] routes in
            Task { @MainActor [weak self] in
                guard let self, self.videoSubmodeRequest == request,
                      self.captureKind == .video, self.videoSubmodeIsEnabled(requested),
                      self.mode == captureMode, self.currentPosition == position,
                      self.videoResolution == selected.resolution,
                      self.videoFrameRate == selected.frameRate,
                      self.videoColorSpace == selected.colorSpace else { return }
                let matching = VideoSubmodeSettingsPolicy.compatibleLensIDs(in: routes, matching: selected)
                if !matching.isEmpty {
                    self.compatibleSubmodeLensIDs = matching
                    // 电影可把前置变焦限制到固定倍率；进入后改选真正支持的取景，
                    // 退出子模块再恢复普通宽窄选择，不让按钮保留虚假的选中状态。
                    if position == .front, !matching.contains(self.camera.selectedLens),
                       self.camera.ready, !self.camera.videoBusy,
                       let target = self.camera.lenses.first(where: { matching.contains($0.id) }) {
                        self.selectFocalLength(target)
                    }
                } else if !self.camera.selectedLens.isEmpty {
                    // 能力回报短暂缺失时仅保留当前路线，避免误开放未确认焦段。
                    self.compatibleSubmodeLensIDs = [self.camera.selectedLens]
                }
            }
        }
    }

    private func finishVideoSubmodeChange(synchronize: Bool = true) {
        if synchronize { synchronizeVideoSettings() }
        restoreDeviceParameters()
        withAnimation(AppTheme.popupAnimation) { shootingModes = false }
        scheduleCaptureStateSave()
    }

    /// 开关视频慢动作；按当前镜头实际能力选择 240 fps 或 120 fps 采集。
    func toggleSlowMotionMode() { toggleVideoSubmode(.slowMotion) }

    /// 在视频模式启停延时采集；默认采用一秒间隔，必要时先换到可用镜头规格。
    func toggleTimeLapseMode() { toggleVideoSubmode(.timeLapse) }

    /// 启用系统电影效果；不兼容时按相机声明切换镜头和安全规格。
    func toggleCinematicVideoMode() { toggleVideoSubmode(.cinematic) }

    /// 更换延时采样档位；采集时锁定，避免一段视频中途改变时间轴倍率。
    func selectTimeLapsePreset(_ preset: TimeLapsePreset) {
        guard timeLapseEnabled, captureKind == .video, !camera.videoBusy, !rawVideoSelected else { return }
        cameraSelectionFeedback()
        if selectedTimeLapsePreset == preset {
            selectedTimeLapsePreset = nil
            timeLapseInterval = .s1
            timeLapseFrameCount = .f120
            scheduleCaptureStateSave()
            return
        }
        selectedTimeLapsePreset = preset
        timeLapseInterval = preset.recommendedInterval
        timeLapseFrameCount = preset.recommendedFrameCount
        scheduleCaptureStateSave()
    }

    func selectTimeLapseInterval(_ interval: TimeLapseInterval) {
        guard timeLapseEnabled, captureKind == .video, !camera.videoBusy, !rawVideoSelected else { return }
        cameraSelectionFeedback()
        timeLapseInterval = interval
        if selectedTimeLapsePreset?.recommendedInterval != interval { selectedTimeLapsePreset = nil }
        scheduleCaptureStateSave()
    }

    func selectTimeLapseFrameCount(_ count: TimeLapseFrameCount) {
        guard timeLapseEnabled, captureKind == .video, !camera.videoBusy, !rawVideoSelected else { return }
        cameraSelectionFeedback()
        timeLapseFrameCount = count
        if selectedTimeLapsePreset?.recommendedFrameCount != count { selectedTimeLapsePreset = nil }
        scheduleCaptureStateSave()
    }

    #if DEBUG
    /// 真机测试结束时恢复延时摄影开关和预设，避免测试污染用户的持久化拍摄状态。
    func restoreTimeLapseStateForTesting(enabled: Bool, preset: TimeLapsePreset?) {
        timeLapseEnabled = enabled && captureKind == .video && !rawVideoSelected
        selectedTimeLapsePreset = preset
        scheduleCaptureStateSave()
    }

    #endif

    func canSelectProRes(_ specification: ProResSpecification) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy else { return false }
        return proResSpecificationOptions.contains(specification)
    }
    var proResSpecificationOptions:[ProResSpecification] {
        ProResSpecification.allCases.filter { specification in
        if camera.dualCaptureEnabled {
            return videoCodec == .proRes
                && dualSupportedSettings.contains { $0.resolution == videoResolution && $0.frameRate == videoFrameRate
                    && $0.colorSpace == videoColorSpace && $0.codec == .proRes && $0.proRes == specification }
        }
        return videoCodec == .proRes && !videoOpenGateEnabled && !slowMotionEnabled && !cinematicVideoEnabled
            && !((timeLapseEnabled || virtualApertureEnabled || frontVideoCenteringRequested) && !specification.isSelectable)
            && VideoCaptureSettings(codec: .proRes, proRes: specification).hardwareEncoderAvailable
            && (specification.isSelectable || (externalVideoStorage.available && !(camera.videoSelectionCapabilities[camera.selectedLens]?.raw ?? camera.rawVideoSettings).isEmpty))
        }
    }
    var videoResolutionText: String { videoResolution.title }
    var videoFrameRateText: String { String(videoFrameRate.rawValue) }
    func selectProResSpecification(_ specification: ProResSpecification) {
        guard canSelectProRes(specification) else { return }
        proResSpecification = specification
    }

    /// 双拍按已验证组合与当前硬件能力开放；退出恢复进入前的普通视频规格。
    private var videoSettingsBeforeDualCapture: (VideoResolution, VideoFrameRate, VideoColorSpace, VideoCodec, VideoRatio, Bool, ProResSpecification)?
    var dualCaptureAvailable: Bool {
        captureKind == .video && AVCaptureMultiCamSession.isMultiCamSupported
    }
    private var dualSupportedSettings: [VideoCaptureSettings] {
        camera.dualCaptureSupportedSettings.isEmpty ? DualCapturePolicy.validatedSettings : camera.dualCaptureSupportedSettings
    }
    private func dualMatchesSelection(_ candidate: VideoCaptureSettings, resolution: VideoResolution? = nil,
                                      rate: VideoFrameRate? = nil, color: VideoColorSpace? = nil, codec: VideoCodec? = nil) -> Bool {
        let codec = codec ?? videoCodec
        return candidate.resolution == (resolution ?? videoResolution) && candidate.frameRate == (rate ?? videoFrameRate)
            && candidate.colorSpace == (color ?? videoColorSpace) && candidate.codec == codec
            && (codec != .proRes || candidate.proRes == proResSpecification)
    }
    private var isFrontVideoTrackingPosition: Bool {
        camera.dualCaptureEnabled ? camera.dualCaptureMainIsFront : currentPosition == .front
    }

    var frontVideoCenteringVisible: Bool {
        captureKind == .video && isFrontVideoTrackingPosition
            && (camera.frontVideoCenteringAvailable || frontVideoCenteringRequested)
    }
    func toggleFrontVideoCentering() {
        guard captureKind == .video, isFrontVideoTrackingPosition, camera.ready,
              !camera.videoBusy, !camera.dualCapturePreparing,
              !camera.frontVideoCenteringPreparing else { return }
        cancelVideoEntryWatchdog()
        cameraSelectionFeedback()
        endZoomDial(); cancelFocus(); startFocalTransition(fadeDuration: 0.14)
        frontVideoCenteringRequested.toggle()
        if frontVideoCenteringRequested {
            // 官方格式能力决定可用规格；先退出互斥子模式，再选择同一前置超广角设备的广幅取景。
            timeLapseEnabled = false; slowMotionEnabled = false; cinematicVideoEnabled = false
            selectedSlowMotionCaptureRate = nil; videoSubmodeRequest = UUID(); compatibleSubmodeLensIDs = nil
            if rawVideoSelected || videoOpenGateEnabled {
                restoringVideoSettings = true; videoCodec = .hevc; videoOpenGateEnabled = false
                videoColorSpace = .sdr; videoResolution = .hd1080; videoFrameRate = .fps30
                restoringVideoSettings = false
            }
            synchronizeVideoSettings()
        }
        camera.setFrontVideoCentering(frontVideoCenteringRequested, transitionID: focalTransitionID)
        scheduleCaptureStateSave()
    }
    private func disableFrontVideoCenteringForManualChoice() {
        guard frontVideoCenteringRequested || camera.frontVideoCenteringEnabled else { return }
        frontVideoCenteringRequested = false
        camera.setFrontVideoCentering(false)
        scheduleCaptureStateSave()
    }

    func toggleDualCapture(frontWide: Bool? = nil) {
        guard captureKind == .video, !camera.videoBusy, !camera.dualCapturePreparing,
              camera.dualCaptureEnabled || dualCaptureAvailable else { return }
        cancelVideoEntryWatchdog()
        endZoomDial(); cancelFocus()
        cameraSelectionFeedback()
        startFocalTransition(fadeDuration: 0.14)
        if camera.dualCaptureEnabled {
            if frontVideoCenteringRequested || camera.frontVideoCenteringEnabled {
                frontVideoCenteringRequested = false
                camera.setFrontVideoCentering(false)
            }
            camera.setDualCaptureEnabled(false) { [weak self] _ in
                guard let self else { return }
                self.restoreVideoSettingsAfterDualCapture()
            }
        } else {
            videoSettingsBeforeDualCapture = (videoResolution, videoFrameRate, videoColorSpace, videoCodec, videoRatio, videoOpenGateEnabled, proResSpecification)
            timeLapseEnabled = false; slowMotionEnabled = false; cinematicVideoEnabled = false
            virtualApertureEnabled = false
            compatibleSubmodeLensIDs = nil
            restoringVideoSettings = true
            let current = selectedVideoSettings
            let target = DualCapturePolicy.validatedSettings.first(where: { DualCapturePolicy.matches($0, current) }) ?? VideoCaptureSettings()
            videoResolution = target.resolution; videoFrameRate = target.frameRate; videoColorSpace = target.colorSpace
            videoCodec = target.codec; proResSpecification = target.proRes
            if !VideoRatio.aspectOptions.contains(videoRatio) { videoRatio = .ratio16x9 }
            videoOpenGateEnabled = false
            restoringVideoSettings = false
            ratio = videoRatio.frameRatio
            updateLook()
            // 视频前置固定超广角；双拍前置主画面也不再从存档恢复 1×。
            let wide = frontWide ?? true
            restoredDualFrontWide = nil
            camera.setDualCaptureEnabled(true, settings: VideoCaptureSettings(resolution: videoResolution, frameRate: videoFrameRate,
                colorSpace: videoColorSpace, codec: videoCodec, proRes: proResSpecification, bitratePreset: preferences.videoBitratePreset),
                ratio: videoRatio.frameRatio, frontWide: wide) { [weak self] success in
                guard let self else { return }
                if !success { self.restoreVideoSettingsAfterDualCapture() }
                else {
                    self.applyExposure(); self.applyWhiteBalance()
                    self.camera.setFocus(position: self.manualFocus ? self.focus : nil)
                }
                self.camera.completeUserPreviewSwitch(self.focalTransitionID)
            }
        }
    }
    private func restoreVideoSettingsAfterDualCapture() {
        guard let saved = videoSettingsBeforeDualCapture else { return }
        videoSettingsBeforeDualCapture = nil
        restoringVideoSettings = true
        videoResolution = saved.0; videoFrameRate = saved.1; videoColorSpace = saved.2
        videoCodec = saved.3; videoRatio = saved.4; videoOpenGateEnabled = saved.5; proResSpecification = saved.6
        restoringVideoSettings = false
        if captureKind == .video { ratio = videoRatio.frameRatio; synchronizeVideoSettings() }
        applyExposure(); applyWhiteBalance(); camera.setFocus(position: manualFocus ? focus : nil)
        camera.completeUserPreviewSwitch(focalTransitionID)
    }
    func swapDualCaptureCameras() {
        guard camera.dualCaptureEnabled else { return }
        // 横幅小窗需要前置广角；前置主画面固定超广角，不再提供焦段切换。
        if camera.dualCaptureMainIsFront && camera.dualCaptureInsetLandscape {
            dualFrontWideBeforeLandscape = camera.dualCaptureFrontWide
            camera.setDualCaptureFrontWide(true)
        } else if !camera.dualCaptureMainIsFront && camera.dualCaptureInsetLandscape,
                  let previousWide = dualFrontWideBeforeLandscape {
            camera.setDualCaptureFrontWide(previousWide)
            dualFrontWideBeforeLandscape = nil
        }
        cameraSelectionFeedback()
        startFocalTransition(fadeDuration: 0.12)
        camera.swapDualCaptureCameras(transitionID: focalTransitionID)
        applyExposure(); applyWhiteBalance(); camera.setFocus(position: manualFocus ? focus : nil)
    }

    @Published private(set) var dualInsetAspectChanging = false
    private var dualFrontWideBeforeLandscape: Bool?
    private var restoredDualFrontWide: Bool? // 下次手动开启时使用存档的小窗倍率，不自动启动会话。

    /// 与前置照片横幅类似：横幅强制广角，返回竖幅恢复进入前倍率；不旋转人物像素。
    func toggleDualCaptureInsetAspect() {
        guard camera.dualCaptureEnabled, camera.ready, !camera.videoBusy, !camera.videoConfiguring,
              !camera.dualCapturePreparing, !dualInsetAspectChanging else { return }
        let landscape = !camera.dualCaptureInsetLandscape
        if camera.dualCaptureMainIsFront {
            // 此时横竖切换的是后置小窗，不应更改前置主画面的焦段。
            cameraSelectionFeedback()
            camera.setDualCaptureInsetLandscape(landscape, ratio: videoRatio.frameRatio)
            scheduleCaptureStateSave()
            return
        }
        let previousWide = camera.dualCaptureFrontWide
        let targetWide = landscape ? true : (dualFrontWideBeforeLandscape ?? false)
        dualInsetAspectChanging = true
        cameraSelectionFeedback()
        startFocalTransition(fadeDuration: 0.12)
        camera.setDualCaptureFrontWide(targetWide) { [weak self] success in
            guard let self else { return }
            self.dualInsetAspectChanging = false
            if success, self.camera.dualCaptureEnabled {
                if landscape { self.dualFrontWideBeforeLandscape = previousWide }
                self.camera.setDualCaptureInsetLandscape(landscape, ratio: self.videoRatio.frameRatio)
                self.scheduleCaptureStateSave()
            }
            self.camera.completeUserPreviewSwitch(self.focalTransitionID)
        }
    }

    func moveDualCaptureInset(from origin: CGRect, translation: CGSize) {
        guard camera.dualCaptureEnabled, !camera.dualCapturePreparing, !camera.videoConfiguring, !dualInsetAspectChanging else { return }
        let rect = DualCaptureInsetLayout.translated(origin, displayTranslation: translation,
            ratio: videoRatio.frameRatio.portraitRatio, turns: previewQuarterTurns)
        camera.setDualCaptureInsetRect(legalDualInsetRect(rect))
        scheduleCaptureStateSave()
    }

    // 使用真实界面几何而不是机型/画幅硬编码；这些数据在Release也采集，测试字典仅用于断言。
    @Published private(set) var focusNavigatorRect = CGRect(x: 0.68, y: 0.18, width: 0.3, height: 0.3)
    var focusNavigatorLayoutRect: CGRect {
        let size = CGSize(width: 0.3, height: 0.3 * ratio.portraitRatio / 0.75)
        return legalDualInsetRect(CGRect(origin: focusNavigatorRect.origin, size: size), previewRatio: ratio.portraitRatio)
    }
    func moveFocusNavigator(from origin: CGRect, translation: CGSize) {
        // 主画幅变化后的第一帧就使用新比例，不等待几何回调再校正小窗形状。
        let shaped = CGRect(origin: origin.origin, size: CGSize(width: 0.3, height: 0.3 * ratio.portraitRatio / 0.75))
        let target = DualCaptureInsetLayout.translated(shaped, displayTranslation: translation, ratio: ratio.portraitRatio, turns: previewQuarterTurns)
        focusNavigatorRect = legalDualInsetRect(target, previewRatio: ratio.portraitRatio)
    }
    private var dualInsetPreviewFrame = CGRect.zero
    private var dualInsetControlFrames: [String: CGRect] = [:]
    private var dualInsetRepairPending = false
    private static let dualInsetObstacleKeys: Set<String> = ["mode", "tools", "lenses", "shootingMode", "macro", "portraitDepth", "portraitDepthPanel", "modeIndicators", "topToolbar", "histogram", "videoHUD", "recordingTimer", "virtualApertureBar"]
    func reportDualInsetPreviewFrame(_ rect: CGRect) {
        guard rect != dualInsetPreviewFrame else { return }
        dualInsetPreviewFrame = rect; scheduleDualInsetPlacementRepair()
    }
    private var captureControlGeometryOwners: [String: UUID] = [:]
    /// 交叉淡出期间旧视图可能晚释放；位置记录只归当前挂载的控件所有。
    func claimCaptureControlGeometry(_ key: String, owner: UUID) { captureControlGeometryOwners[key] = owner }
    func updateCaptureControlGeometry(_ key: String, owner: UUID, rect: CGRect?) {
        guard captureControlGeometryOwners[key] == owner else { return }
        reportDualInsetControlFrame(key, rect: rect)
        #if DEBUG
        captureButtonFramesForTesting[key] = rect
        #endif
        if rect == nil { captureControlGeometryOwners.removeValue(forKey: key) }
    }
    func reportDualInsetControlFrame(_ key: String, rect: CGRect?) {
        guard Self.dualInsetObstacleKeys.contains(key), dualInsetControlFrames[key] != rect else { return }
        dualInsetControlFrames[key] = key == "virtualApertureBar" ? rect.map { $0.offsetBy(dx: 0, dy: CameraControlLayout.upperButtonOffset(diameter: max(16, $0.height - 4))) } : rect
        if key == "tools" {
            // overlay的offset不改变外层布局框；从辅助按钮实际框推导上方子模块按钮的视觉框。
            dualInsetControlFrames["shootingModeVisual"] = rect.map { $0.offsetBy(dx: 0, dy: CameraControlLayout.upperButtonOffset(diameter: $0.height)) }
        }
        scheduleDualInsetPlacementRepair()
    }
    private func legalDualInsetRect(_ rect: CGRect, previewRatio: CGFloat? = nil) -> CGRect {
        let preview = dualInsetPreviewFrame
        guard preview.width > 0, preview.height > 0 else { return rect }
        // 录像只释放已隐藏的操作按钮，直方图、声音/容量及计时仍然是障碍。
        let obstacles: [CGRect] = dualInsetControlFrames.compactMap { key, frame in
            if camera.videoRecording && !["histogram", "videoHUD", "recordingTimer"].contains(key)
                && !(key == "lenses" && !zoomDialVisible && !camera.dualCaptureEnabled) { return nil }
            if key == "histogram" && !showHistogram { return nil }
            if key == "virtualApertureBar" && !virtualApertureEnabled { return nil }
            if key == "videoHUD" && !showsRecordingCapacity && !showsAudioMeter { return nil }
            if key == "recordingTimer" && !camera.videoRecording { return nil }
            let expanded = frame.insetBy(dx: -6, dy: -6).intersection(preview)
            guard !expanded.isNull, !expanded.isEmpty else { return nil }
            return CGRect(x: (expanded.minX - preview.minX) / preview.width,
                          y: (expanded.minY - preview.minY) / preview.height,
                          width: expanded.width / preview.width, height: expanded.height / preview.height)
        }
        return DualCaptureInsetLayout.avoiding(rect, ratio: previewRatio ?? videoRatio.frameRatio.portraitRatio, turns: previewQuarterTurns, obstacles: obstacles)
    }
    /// 合并一次布局事务内的多份几何，避免更新视图时发布变化；恢复按钮和改变小窗尺寸后也重新避让。
    func scheduleDualInsetPlacementRepair() {
        guard !dualInsetRepairPending else { return }
        dualInsetRepairPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dualInsetRepairPending = false
            if self.camera.focusNavigatorActive {
                let old = self.focusNavigatorRect
                let size = CGSize(width: 0.3, height: 0.3 * self.ratio.portraitRatio / 0.75)
                let rect = CGRect(x: old.minX, y: old.minY, width: size.width, height: size.height)
                let legal = self.legalDualInsetRect(rect, previewRatio: self.ratio.portraitRatio)
                if self.focusNavigatorRect != legal { self.focusNavigatorRect = legal }
            }
            guard self.camera.dualCaptureEnabled else { return }
            let original = self.camera.dualCaptureInsetRect, legal = self.legalDualInsetRect(self.camera.dualCaptureInsetRect)
            if abs(original.minX - legal.minX) > 0.00001 || abs(original.minY - legal.minY) > 0.00001 {
                self.camera.setDualCaptureInsetRect(legal)
                self.scheduleCaptureStateSave()
            }
        }
    }

    private func synchronizeVideoSettings(preferredLensID: String? = nil) {
        guard !restoringVideoSettings else { return }
        // UI禁选之外也保护存档/程序赋值，避免只在取景有星芒而文件静默漏处理。
        if captureKind == .video, virtualApertureEnabled, !videoFiltersEnabled {
            restoringVideoSettings = true
            videoColorSpace = .sdr
            if rawVideoSelected { videoCodec = .hevc }
            restoringVideoSettings = false
        }
        if camera.ready, videoSubmodePreparing == nil, slowMotionEnabled, !slowMotionPlaybackSettings.contains(where: {
            $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
        }) {
            if !prepareVideoSubmode(.slowMotion) { slowMotionEnabled = false }
        }
        if camera.ready, videoSubmodePreparing == nil, cinematicVideoEnabled, !camera.cinematicVideoSettings.contains(where: {
            $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
        }) {
            if !prepareVideoSubmode(.cinematic) { cinematicVideoEnabled = false }
        }
        if captureKind == .video && !filterControlsEnabled && panel == .film {
            filters.showStrength = false
            withAnimation(AppTheme.popupAnimation) { panel = nil }
        }
        if captureKind == .video, camera.ready, !camera.videoBusy {
            startFocalTransition(fadeDuration: 0.14)
        }
        if rawVideoSelected {
            restoringVideoSettings = true
            videoResolution = .uhd4K; videoColorSpace = .sdr; videoRatio = .ratio16x9; videoOpenGateEnabled = false
            restoringVideoSettings = false
            // RAW 需要保留原始帧时间戳，因此自动退出与其不兼容的延时采集。
            timeLapseEnabled = false
            slowMotionEnabled = false
            cinematicVideoEnabled = false
        }
        camera.setVideoSettings(VideoCaptureSettings(resolution: videoResolution, frameRate: videoFrameRate,
            captureFrameRate: slowMotionEnabled
                ? slowMotionCaptureFrameRateForSelection : nil,
            colorSpace: videoColorSpace, codec: videoCodec, proRes: proResSpecification,
            bitratePreset: preferences.videoBitratePreset), openGate: videoOpenGateEnabled,
            cinematicVideo: cinematicVideoEnabled, preferredLensID: preferredLensID, dualRatio: videoRatio.frameRatio)
        if captureKind == .video { camera.completeUserPreviewSwitch(focalTransitionID) }
        refreshRecordingCapacity()
        updateLook()
        refreshSubmodeLensCompatibility()
    }
    func supportsVideoFrameRate(_ rate: VideoFrameRate) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy else { return false }
        return videoFrameRateOptions.contains(rate)
    }
    func supportsVideoResolution(_ resolution: VideoResolution) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy else { return false }
        return videoResolutionOptions.contains(resolution)
    }

    /// 可见项只取决于稳定能力和当前组合；忙碌/录制仅禁用点击，不能清空选项造成闪烁。
    var videoResolutionOptions:[VideoResolution] {
        if camera.dualCaptureEnabled { return VideoResolution.allCases.filter { value in dualSupportedSettings.contains { dualMatchesSelection($0,resolution:value) } } }
        if slowMotionEnabled { return slowMotionCaptureResolutionOptions }
        return VideoResolution.allCases.filter { value in videoCapabilitiesForCurrentRatio.contains {
            $0.resolution == value && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
        } }
    }
    var videoFrameRateOptions:[VideoFrameRate] {
        if camera.dualCaptureEnabled { return VideoFrameRate.allCases.filter { value in dualSupportedSettings.contains { dualMatchesSelection($0,rate:value) } } }
        // 规格弹窗按低到高展示采集帧率；240 放在 120 后面。
        if slowMotionEnabled { return slowMotionCaptureFrameRateOptions.sorted { $0.rawValue < $1.rawValue } }
        return VideoFrameRate.allCases.filter { value in videoCapabilitiesForCurrentRatio.contains {
            $0.resolution == videoResolution && $0.frameRate == value && $0.colorSpace == videoColorSpace
        } }
    }

    /// 只切换能保留当前帧率的电影分辨率。
    func selectVideoResolution(_ resolution: VideoResolution) {
        guard supportsVideoResolution(resolution) else { return }
        if slowMotionEnabled {
            selectSlowMotionCaptureResolution(resolution)
            return
        }
        guard cinematicVideoEnabled else { videoResolution = resolution; return }
        let candidates = videoCapabilitiesForCurrentRatio.filter {
            $0.resolution == resolution && $0.colorSpace == videoColorSpace
        }
        guard let target = candidates.first(where: { $0.frameRate == videoFrameRate })
                ?? VideoSubmodeSettingsPolicy.closestSupported(candidates, to: selectedVideoSettings) else { return }
        applyCinematicSelection(target)
    }

    /// 只切换能保留当前分辨率的电影帧率。
    func selectVideoFrameRate(_ frameRate: VideoFrameRate) {
        guard supportsVideoFrameRate(frameRate) else { return }
        if slowMotionEnabled {
            selectSlowMotionCaptureFrameRate(frameRate)
            return
        }
        guard cinematicVideoEnabled else { videoFrameRate = frameRate; return }
        let candidates = videoCapabilitiesForCurrentRatio.filter {
            $0.frameRate == frameRate && $0.colorSpace == videoColorSpace
        }
        guard let target = candidates.first(where: { $0.resolution == videoResolution })
                ?? VideoSubmodeSettingsPolicy.closestSupported(candidates, to: selectedVideoSettings) else { return }
        applyCinematicSelection(target)
    }

    /// 慢动作分辨率选择同步更新采集规格；输出回放帧率保留在内部设置中。
    private func selectSlowMotionCaptureResolution(_ resolution: VideoResolution) {
        let rates = SlowMotionCapturePickerPolicy.captureRates(for: resolution,
            captureFormats: slowMotionCaptureFormatsForSelection, playbackSettings: slowMotionPlaybackSettings,
            colorSpace: videoColorSpace, codec: videoCodec)
        guard let captureRate = rates.contains(slowMotionCaptureFrameRateForSelection)
                ? slowMotionCaptureFrameRateForSelection : rates.first else { return }
        applySlowMotionCaptureSelection(resolution: resolution, captureRate: captureRate)
    }

    /// 慢动作帧率按钮改变的是传感器采集率；若现有回放帧率过高，则内部降到最近兼容档。
    private func selectSlowMotionCaptureFrameRate(_ captureRate: VideoFrameRate) {
        guard slowMotionCaptureFrameRateOptions.contains(captureRate) else { return }
        applySlowMotionCaptureSelection(resolution: videoResolution, captureRate: captureRate)
    }

    private func applySlowMotionCaptureSelection(resolution: VideoResolution, captureRate: VideoFrameRate) {
        let playbackCandidates = slowMotionPlaybackSettings.filter {
            $0.resolution == resolution && $0.colorSpace == videoColorSpace
                && $0.frameRate.rawValue < captureRate.rawValue
        }
        guard !playbackCandidates.isEmpty else { return }
        let playback = playbackCandidates.first(where: { $0.frameRate == videoFrameRate })
            ?? playbackCandidates.min {
                abs($0.frameRate.rawValue - videoFrameRate.rawValue)
                    < abs($1.frameRate.rawValue - videoFrameRate.rawValue)
            }!
        let wasRestoring = restoringVideoSettings
        restoringVideoSettings = true
        videoResolution = resolution
        videoFrameRate = playback.frameRate
        selectedSlowMotionCaptureRate = captureRate
        restoringVideoSettings = wasRestoring
        synchronizeVideoSettings()
        scheduleCaptureStateSave()
    }

    /// 同一组可用性数据原子更新两个规格，避免中间状态触发电影模式回退。
    private func applyCinematicSelection(_ settings: VideoCaptureSettings) {
        let wasRestoring = restoringVideoSettings
        restoringVideoSettings = true
        videoResolution = settings.resolution
        videoFrameRate = settings.frameRate
        restoringVideoSettings = wasRestoring
        synchronizeVideoSettings()
        scheduleCaptureStateSave()
    }
    func supportsVideoColorSpace(_ space: VideoColorSpace) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy else { return false }
        return videoColorSpaceOptions.contains(space)
    }
    var videoColorSpaceOptions:[VideoColorSpace] {
        VideoColorSpace.allCases.filter { space in
            if virtualApertureEnabled && space != .sdr && space != .p3 { return false }
            if camera.dualCaptureEnabled { return dualSupportedSettings.contains { dualMatchesSelection($0,color:space) } }
            if rawVideoSelected && videoOpenGateEnabled { return false }
            if videoCodec == .h264 && (space.usesTenBit || space.isLog) { return false }
            if slowMotionEnabled {
                return slowMotionCaptureFormatsForSelection.contains {
                    $0.resolution == videoResolution && $0.frameRate == slowMotionCaptureFrameRateForSelection && $0.colorSpace == space
                } && slowMotionPlaybackSettings.contains {
                    $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == space
                }
            }
            return videoCapabilitiesForCurrentRatio.contains {
                $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == space
            }
        }
    }
    private func videoCandidates(for lensID:String)->[VideoCaptureSettings]? {
        guard let row = camera.videoSelectionCapabilities[lensID] else { return nil }
        if rawVideoSelected { return videoOpenGateEnabled ? []:row.raw }
        if cinematicVideoEnabled { return row.cinematic }
        if slowMotionEnabled { return row.settings(for:.slowMotion,openGateEnabled:false) }
        if frontVideoCenteringRequested { return row.centerStage }
        return videoOpenGateEnabled ? row.openGate:row.ordinary
    }
    private func videoLensSupportsCurrentSelection(_ lens:CameraLens)->Bool {
        if virtualApertureEnabled && !supportsVirtualApertureLens(lens) { return false }
        guard let values = videoCandidates(for:lens.id) else { return true }
        if slowMotionEnabled {
            return camera.videoSelectionCapabilities[lens.id]?.slowMotionCaptureRates.contains {
                $0.resolution == videoResolution && $0.frameRate == slowMotionCaptureFrameRateForSelection && $0.colorSpace == videoColorSpace
            } == true
        }
        return values.contains { $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace }
    }
    private var videoCapabilitiesForCurrentRatio: [VideoCaptureSettings] {
        if camera.dualCaptureEnabled { return dualSupportedSettings }
        if let values = videoCandidates(for:camera.selectedLens) { return values }
        if frontVideoCenteringRequested { return camera.frontVideoCenteringSettings }
        if rawVideoSelected { return videoOpenGateEnabled ? [] : camera.rawVideoSettings }
        if cinematicVideoEnabled { return camera.cinematicVideoSettings }
        if slowMotionEnabled { return slowMotionPlaybackSettings }
        return videoOpenGateEnabled ? camera.openGateVideoSettings : camera.supportedVideoSettings
    }
    var supportsVideoOpenGate: Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy, !rawVideoSelected,
              !camera.dualCaptureEnabled, !frontVideoCenteringRequested, !slowMotionEnabled, !cinematicVideoEnabled, videoCodec == .hevc else { return false }
        return videoOpenGateAvailable
    }
    var videoOpenGateAvailable:Bool {
        guard !rawVideoSelected, !camera.dualCaptureEnabled, !frontVideoCenteringRequested,
              !slowMotionEnabled, !cinematicVideoEnabled, videoCodec == .hevc else { return false }
        return (camera.videoSelectionCapabilities[camera.selectedLens]?.openGate ?? camera.openGateVideoSettings).contains {
            $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
        }
    }
    func supportsVideoRatio(_ value: VideoRatio) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, VideoRatio.aspectOptions.contains(value), !camera.videoBusy, !rawVideoSelected else { return false }
        return videoRatioOptions.contains(value)
    }
    var videoRatioOptions:[VideoRatio] {
        if rawVideoSelected { return [] }
        return videoOpenGateEnabled ? VideoRatio.openGateAspectOptions:VideoRatio.aspectOptions
    }
    func supportsVideoCodec(_ codec: VideoCodec) -> Bool {
        guard videoSubmodePreparing == nil, !camera.dualCapturePreparing, !camera.videoBusy else { return false }
        return videoCodecOptions.contains(codec)
    }
    var videoCodecOptions:[VideoCodec] { VideoCodec.allCases.filter { videoCodecIsAvailable($0) } }
    private func videoCodecIsAvailable(_ codec:VideoCodec)->Bool {
        guard VideoCaptureSettings(codec: codec).hardwareEncoderAvailable else { return false }
        if camera.dualCaptureEnabled { return dualSupportedSettings.contains { dualMatchesSelection($0, codec: codec) } }
        if (slowMotionEnabled || cinematicVideoEnabled) && codec == .proRes { return false }
        if slowMotionEnabled && codec != .hevc && codec != .h264 { return false }
        if videoOpenGateEnabled { return codec == .hevc && videoOpenGateAvailable }
        if codec == .h264 && (videoColorSpace.usesTenBit || videoColorSpace.isLog) { return false }
        if cinematicVideoEnabled || slowMotionEnabled {
            return videoCapabilitiesForCurrentRatio.contains {
                $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace
            }
        }
        return videoCapabilitiesForCurrentRatio.contains { $0.resolution == videoResolution && $0.frameRate == videoFrameRate && $0.colorSpace == videoColorSpace }
    }
    func selectVideoRatio(_ next: VideoRatio) {
        if next == .openGate { setVideoOpenGateEnabled(true); return }
        guard supportsVideoRatio(next), videoRatio != next else { return }
        videoRatio = next
    }
    var videoOpenGateRatioSupported: Bool {
        VideoRatio.openGateAspectOptions.contains(videoRatio)
    }

    func setVideoOpenGateEnabled(_ enabled: Bool) {
        guard videoSubmodePreparing == nil, !camera.videoBusy, enabled != videoOpenGateEnabled else { return }
        guard !enabled || (!cinematicVideoEnabled && !slowMotionEnabled) else { return }
        if enabled && !supportsVideoOpenGate { return }
        if enabled && !videoOpenGateRatioSupported { return }
        let wasRestoring = restoringVideoSettings
        restoringVideoSettings = true
        videoOpenGateEnabled = enabled
        if enabled && !VideoRatio.openGateAspectOptions.contains(videoRatio) {
            videoRatio = .ratio4x3
        }
        restoringVideoSettings = wasRestoring
        if !wasRestoring { synchronizeVideoSettings() }
    }
    @Published private(set) var previewQuarterTurns = 0 {
        didSet { persistAuxiliaryPreferences() }
    }
    func rotatePreview() {
        previewQuarterTurns = (previewQuarterTurns + 1) % 4
        cancelFocus()
        camera.rotatePreview(quarterTurns: previewQuarterTurns)
    }
    @Published var grid = false { didSet { persistAuxiliaryPreferences() } }
    @Published var focusPeaking = false {
        didSet {
            camera.enableFocusPeaking(focusPeaking)
            persistAuxiliaryPreferences()
        }
    }
    @Published var smoothPreview = false {
        didSet {
            camera.setPreviewExposureAssist(smoothPreview)
            persistAuxiliaryPreferences()
        }
    }
    @Published var level = false { didSet { persistAuxiliaryPreferences() } }
    @Published var border = false {
        didSet {
            if border { adaptiveHighDynamic = false }
            updateLook(); synchronizeHDRPreview()
            persistAuxiliaryPreferences()
        }
    }
    @Published var flashMode = CameraFlashMode.off {
        didSet {
            if isPreparingSubmode, flashMode != oldValue { flashMode = oldValue; return }
            if nightModeEnabled, flashMode != .off { flashMode = .off; return }
            reconcileNightMode()
        }
    }
    // Compatibility for callers that only need on/off.
    var flash: Bool { get { flashMode == .on } set { flashMode = newValue ? .on : .off } }
    @Published var toolbarPanel: CameraToolbarPanel?
    @Published var photoFormat = PhotoFileFormat.jpeg {
        didSet {
            if photoFormat != .heifPro { adaptiveHighDynamic = false }
            if photoFormat != .heif && photoFormat != .heifPro && hdr { hdr = false }
            if virtualApertureEnabled && (photoFormat == .raw || photoFormat == .rawJPEG) {
                photoFormat = camera.availablePhotoFormats.contains(.heif) ? .heif : .jpeg; return
            }
            if let activePhotoSubmode, !photoFormatIsAllowed(photoFormat, for: activePhotoSubmode) {
                photoFormat = preferredPhotoFormat(for: activePhotoSubmode)
                return
            }
            if photoFormat != .heifPro, toolbarPanel == .tone { toolbarPanel = nil }
            // 切出Pro立即归还系统测光，清掉全局补偿；保留Pro选择供切回时恢复。
            if captureKind == .photo, (oldValue == .heifPro) != (photoFormat == .heifPro) {
                camera.setMetering(effectiveMetering)
            }
            if !filtersEnabled && panel == .film { panel = nil }
            updateLook()
            synchronizeLiveAudio()
            synchronizeHDRPreview()
            reconcileBurstMode()
            reconcileNightMode()
            reconcilePortraitParameters()
        }
    }
    /// HDR 与滤镜互斥：HDR 只允许在原片、无滤镜调整时开启。
    var filterActive: Bool { style != .original || !filterAdjustments.isNeutral }
    var filtersEnabled: Bool { photoFormat != .raw && !(captureKind == .photo && hdr) }
    var videoFiltersEnabled: Bool {
        captureKind == .video && !rawVideoSelected && (videoColorSpace == .sdr || videoColorSpace == .p3)
    }
    var logVideoLUTControlsEnabled: Bool {
        captureKind == .video && !rawVideoSelected && videoColorSpace.isLog
    }
    var filterControlsEnabled: Bool {
        captureKind == .video ? (videoFiltersEnabled || logVideoLUTControlsEnabled) : filtersEnabled
    }
    var selectedLogLUTPreset: LogLUTPreset? {
        guard let selectedLogLUTID else { return nil }
        if selectedLogLUTID == LogLUTPreset.originalID { return .original }
        return logLUTPresets.first { $0.id == selectedLogLUTID }
    }
    var logLUTOptions: [LogLUTPreset] {
        if logLUTCategory == .favorites { return logLUTPresets.filter { logLUTFavorites.contains($0.id) } }
        return [.original] + logLUTPresets
    }

    func selectLogLUTCategory(_ category: FilterCategory) {
        logLUTCategory = category
    }

    func toggleLogLUTFavorite(_ id: String) {
        guard logLUTPresets.contains(where: { $0.id == id }) else { return }
        if logLUTFavorites.contains(id) { logLUTFavorites.remove(id) }
        else { logLUTFavorites.insert(id) }
        UserDefaults.standard.set(logLUTPresets.filter { logLUTFavorites.contains($0.id) }.map(\.id),
                                  forKey: "camera.favoriteLogLUTs")
    }

    func selectLogLUT(_ id: String) {
        guard logVideoLUTControlsEnabled, logLUTOptions.contains(where: { $0.id == id }) else { return }
        selectedLogLUTID = id
    }

    private func loadSelectedLogLUT() {
        let request = UUID()
        logLUTLoadRequest = request
        guard let id = selectedLogLUTID else {
            selectedLogLUTCube = nil
            logLUTLoading = false
            camera.updateVideoLogLUT(nil)
            return
        }
        if id == LogLUTPreset.originalID {
            selectedLogLUTCube = nil
            logLUTLoading = false
            camera.updateVideoLogLUT(nil)
            return
        }
        guard let preset = logLUTPresets.first(where: { $0.id == id }) else {
            selectedLogLUTID = LogLUTPreset.originalID
            return
        }
        logLUTLoading = true
        Self.logLUTThumbnailQueue.async { [weak self] in
            let result = Result { try LogLUTCubeRepository.load(preset) }
            DispatchQueue.main.async {
                guard let self, self.logLUTLoadRequest == request else { return }
                self.logLUTLoading = false
                switch result {
                case .success(let cube):
                    self.selectedLogLUTCube = cube
                    self.camera.updateVideoLogLUT(cube)
                case .failure(let error):
                    self.selectedLogLUTCube = nil
                    self.camera.updateVideoLogLUT(nil)
                    self.camera.message = "Log 滤镜载入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func prepareLogLUTThumbnail(for preset: LogLUTPreset) {
        guard preset.id != LogLUTPreset.originalID,
              logLUTThumbnails[preset.id] == nil,
              !logLUTThumbnailLoading.contains(preset.id) else { return }
        if let cached = Self.sharedLogLUTThumbnails.object(forKey: preset.id as NSString) {
            logLUTThumbnails[preset.id] = cached
            return
        }
        logLUTThumbnailLoading.insert(preset.id)
        let thumbnailContext = Self.logLUTThumbnailContext
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: UIImage? = autoreleasepool {
                guard let photo = UIImage(named: "FilterLandscape"),
                      let sourceImage = CIImage(image: photo) else { return nil }
                let square = FrameRatio.square.crop(sourceImage)
                let size: CGFloat = 112
                let sample = square.transformed(by: CGAffineTransform(scaleX: size / square.extent.width,
                                                                       y: size / square.extent.width))
                return LogLUTCubeRepository.thumbnail(for: preset, source: sample, context: thumbnailContext)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.logLUTThumbnailLoading.remove(preset.id)
                guard let image else { return }
                let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                Self.sharedLogLUTThumbnails.setObject(image, forKey: preset.id as NSString, cost: cost)
                self.logLUTThumbnails[preset.id] = image
            }
        }
    }
    var effectiveCaptureLook: CaptureLook {
        if captureKind == .video {
            guard videoFiltersEnabled else { return CaptureLook(style: .original, intensity: 0, ratio: videoRatio.frameRatio) }
            return CaptureLook(style: style, intensity: intensity, ratio: videoRatio.frameRatio, adjustments: filterAdjustments,
                               virtualAperture: virtualApertureEnabled && currentPosition == .back ? virtualAperture : nil)
        }
        let photoLandscape = currentPosition == .front && camera.frontPhotoLandscapeEnabled
            && camera.frontPhotoAspectRatioSwitchAvailable && ratio != .square && photoFormat != .raw
        if hdr {
            // HDR与滤镜互斥：保留用户已选滤镜，仅本次拍摄临时使用原片。
            // HEIF Pro 的 Pro 影调独立于滤镜保留；影调在 HDR 的 SDR 基底上处理后再恢复高光。
            return CaptureLook(style: .original, intensity: 0, ratio: ratio,
                               landscape: photoLandscape, border: border,
                               tone: photoFormat == .heifPro ? tone : .natural,
                               adjustments: FilterAdjustments(), virtualAperture: nil,
                               nightPreviewAssist: false).forOutput(photoFormat)
        }
        return CaptureLook(style: style, intensity: intensity, ratio: ratio,
                           landscape: photoLandscape,
                           border: border, tone: photoFormat == .heifPro ? tone : .natural,
                           adjustments: filterAdjustments,
                           virtualAperture: virtualApertureEnabled && currentPosition == .back ? virtualAperture : nil,
                           nightPreviewAssist: nightModeEnabled).forOutput(photoFormat)
    }
    var canToggleFrontPhotoAspectRatio: Bool {
        captureKind == .photo && currentPosition == .front && photoFormat != .raw
            && camera.frontPhotoAspectRatioSwitchAvailable && ratio != .square
    }
    @Published var photoResolution = PhotoResolution.standard { didSet {
        if let activePhotoSubmode, !photoResolutionIsAllowed(photoResolution, for: activePhotoSubmode) {
            photoResolution = .standard
            return
        }
        if photoResolution == .high && captureKind == .photo && mode == .manual {
            manualExposure = false
            applyExposure()
        }
        if photoResolution == .high { endZoomDial(); finishPreviewPinchZoom() }
        synchronizeLiveAudio()
        reconcileBurstMode()
        reconcileNightMode()
        reconcilePortraitParameters()
        synchronizeHighResolutionPhotoRoute()
    } }
    /// 首版复用普通HEIF Pro的RAW管线；不干预手动曝光，也不混入其他合成子模式。
    @Published var adaptiveHighDynamic = false { didSet { scheduleCaptureStateSave() } }
    var adaptiveHighDynamicAvailable: Bool {
        captureKind == .photo && photoFormat == .heifPro && activePhotoSubmode == nil
            && !border && camera.availablePhotoFormats.contains(.heifPro) && !isPreparingSubmode
    }
    func setAdaptiveHighDynamic(_ enabled:Bool) {
        guard !enabled || adaptiveHighDynamicAvailable else { return }
        guard enabled != adaptiveHighDynamic else { return }
        cameraSelectionFeedback(); adaptiveHighDynamic = enabled
    }
    @Published var hdr = false { didSet {
        if hdr && (nightModeEnabled || burstModeEnabled || portraitModeEnabled) { hdr = false; return }
        if hdr && photoFormat == .heif && !camera.supportsHighResolutionHEIFHDR { photoResolution = .standard }
        if hdr != oldValue { beginHDRPreviewTransition() }
        synchronizeHDRPreview(); synchronizeLiveAudio()
        reconcileBurstMode()
        reconcileNightMode()
        reconcilePortraitParameters()
        updateLook()
    } }
    private func beginHDRPreviewTransition() {
        guard cameraActiveRequested, captureKind == .photo, photoFormat == .heif, !border else { return }
        startFocalTransition(fadeDuration: 0.16)
        let request = focalTransitionID
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<120 {
                if self.focalTransitionID != request { return }
                if !self.camera.hdrPreviewConfiguring { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            // 相机在配置结束后还会保持约0.28秒的稳定帧门，等新帧替换旧快照后再淡出。
            try? await Task.sleep(for: .milliseconds(340))
            guard self.focalTransitionID == request else { return }
            self.finishFocalTransition()
        }
    }

    private func synchronizeHDRPreview() {
        // HDR只作用于成片；取景保持SDR。
        camera.setHEIFHDRPipeline(false)
        camera.setHEIFHDRPreview(false)
    }
    @Published private(set) var livePhotoEnabled = false {
        didSet { reconcileNightMode() }
    }
    var livePhotoAvailable: Bool {
        !slowShutterEnabled && !portraitModeEnabled && !nightModeEnabled && !burstModeEnabled && !virtualApertureEnabled && !hdr && (photoFormat == .jpeg || photoFormat == .heif) && photoResolution == .standard && camera.supportsLivePhoto
    }
    var canToggleLivePhoto: Bool {
        // 关闭始终允许；开启还必须满足当前格式/分辨率/HDR/模式与硬件能力。
        photoSubmodePreparing == nil && (livePhotoEnabled || livePhotoAvailable)
    }
    var capturesLivePhoto: Bool { livePhotoEnabled && livePhotoAvailable }
    func toggleLivePhoto() {
        guard canToggleLivePhoto else { return }
        dismissPopupsForLive()
        livePhotoEnabled.toggle()
        synchronizeLiveAudio(requestPermission: livePhotoEnabled)
        cameraImpactFeedback(.light)
    }
    private func synchronizeLiveAudio(requestPermission: Bool = false) {
        camera.setLivePhotoPreviewRequested(captureKind == .photo && livePhotoEnabled && !hdr && (photoFormat == .jpeg || photoFormat == .heif) && photoResolution == .standard && cameraActiveRequested)
        camera.setLiveAudioEnabled(captureKind == .photo && capturesLivePhoto && cameraActiveRequested, requestPermission: requestPermission)
    }
    private func reconcileCaptureCapabilities() {
        guard camera.ready, pendingStartupCaptureState == nil, !photoStateRestorePending else { return }
        // A video format and an in-progress return route cannot invalidate the
        // saved photo choices. Reconcile once the final photo graph has settled.
        if captureKind == .photo && !captureKindSwitching && !camera.videoConfiguring {
            if !camera.availablePhotoFormats.contains(photoFormat) { photoFormat = .jpeg; hdr = false }
            if !camera.availableResolutions.contains(photoResolution) {
                let awaitingHighRoute = photoResolution == .high && mode == .auto && currentPosition == .back
                if !awaitingHighRoute { photoResolution = .standard }
            }
            if photoFormat == .heif && !camera.supportsHEIFHDR { hdr = false }
            if !camera.supportsFlash { flashMode = .off }
        }
        synchronizeLiveAudio()
        reconcileNightMode()
        reconcilePortraitMode()
        if captureKind == .video, slowMotionEnabled, slowMotionUnavailableReason != nil {
            slowMotionEnabled = false
            synchronizeVideoSettings()
        }
    }

    private func dismissPopupsForLive() {
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) {
            toolbarPanel = nil; functions = false; tools = false; shootingModes = false; panel = nil
        }
    }
    @Published var tone = PhotoTone.natural { didSet { updateLook() } }
    @Published var metering = CameraMetering.system { didSet { camera.setMetering(effectiveMetering) } }
    /// 选中值与生效值分开：非HEIF Pro格式始终使用系统测光，不改M挡手动曝光参数。
    var effectiveMetering: CameraMetering { captureKind == .photo && photoFormat == .heifPro ? metering : .system }
    /// 全局测光时主读数显示设备总补偿；滑条仍操作用户EV，分项在测光面板明确显示。
    var usesGlobalMeteringReadout: Bool { effectiveMetering == .global && camera.globalMeteringReadout.automatic }
    var displayedExposureBias: Double { usesGlobalMeteringReadout ? camera.globalMeteringReadout.actual : ev }

    var photoOptions: PhotoOptions {
        let shootingType: String
        if burstCaptureActive {
            shootingType = "连拍"
        } else if nightCaptureEligible {
            shootingType = "夜景"
        } else if slowShutterEnabled {
            shootingType = selectedSlowShutterPreset?.title.replacingOccurrences(of: "\\n", with: "") ?? "慢门"
        } else if portraitModeEnabled {
            shootingType = "人像"
        } else {
            shootingType = virtualApertureEnabled ? "虚拟光圈" : "普通"
        }
        return PhotoOptions(format: photoFormat, resolution: photoResolution,
                     hdr: hdr && (photoFormat == .heifPro || photoFormat == .heif) && !border,
                     adaptiveHighDynamic: adaptiveHighDynamic && adaptiveHighDynamicAvailable,
                     live: capturesLivePhoto, nightMode: nightCaptureEligible, portraitMode: portraitModeEnabled,
                     portraitBlurStrength: portraitBlurStrength,
                     copyright: preferences.copyright, saveUnfilteredOriginal: preferences.saveUnfilteredOriginal,
                     silentShutter: preferences.silentShutter, shootingType: shootingType,
                     // 普通 M 挡也把曝光绑定到静态请求，避免视频往返后系统照片处理采用旧 AE。
                     prefersManualExposureBracket: slowShutterEnabled || (mode == .manual && manualExposure),
                     nightProfile: independentNightProfile,
                     nightHDRPhoto: nightHDRPhotoEnabled)
    }

    @Published private(set) var burstModeEnabled = false {
        didSet {
            if !burstModeEnabled { burstCaptureCount = 0 }
            reconcileNightMode()
        }
    }
    @Published private(set) var burstCaptureActive = false { didSet { reconcileNightMode() } }
    @Published private(set) var burstCaptureCount = 0
    private var burstCaptureTask: Task<Void, Never>?
    private var videoEntryWatchdog: Task<Void, Never>?
    private var pendingCinematicStart = false
    private var pendingVideoEntryAfterRecovery: Task<Void, Never>?
    private var videoRouteFailureRetries = 0
    private var photoStateRestorePending = false
    private var photoStateRestoreTask: Task<Void, Never>?
    #if DEBUG
    var photoStateRestorePendingForTesting: Bool { photoStateRestorePending }
    #endif
    private var burstCaptureRequest = UUID()

    @Published private(set) var slowShutterEnabled = false
    @Published private(set) var slowShutterDuration: SlowShutterDuration = .s1
    @Published private(set) var selectedSlowShutterPreset: SlowShutterPreset?
    // 只记住本轮慢门的 A 挡选择，不让 M 挡的通用时长覆盖它。
    private var slowShutterAutomaticPreset: SlowShutterPreset?
    private var slowShutterAutomaticDuration: SlowShutterDuration = .s1
    @Published private(set) var slowShutterSequenceProgress: SlowShutterSequenceProgress?
    @Published private(set) var slowShutterComposing = false
    @Published private(set) var slowShutterAccumulationPreview:SlowShutterAccumulationPreview?
    private var slowShutterSequence: SlowShutterSequenceState?
    private var slowShutterCompositionToken: UUID?
    private var slowShutterFrameWatchdog: Task<Void, Never>?
    private var slowShutterPreviewID:UUID?
    private var slowShutterPreviewTask:Task<Void,Never>?
    private var slowShutterPendingPreview:SlowShutterAccumulationPreview?
    private var slowShutterLastPreviewPublishedAt:TimeInterval?
    private let slowShutterCompositionQueue = DispatchQueue(label: "camera.slowShutter.composition", qos: .userInitiated)
    #if DEBUG
    var retainedSlowShutterSourcesForTesting: Int { slowShutterSequence?.frames.count ?? 0 }
    #endif

    /// During any slow-shutter capture, hide the A/M, assist, submodule,
    /// preset and lens controls; the shutter and remaining UI stay available.
    var slowShutterCaptureHidesControls: Bool {
        captureKind == .photo && slowShutterSequenceProgress != nil && !slowShutterComposing
    }

    var canEditSlowShutterDuration: Bool {
        slowShutterEnabled && slowShutterSequence == nil && !slowShutterComposing
            && !camera.capturing && !camera.shutterBusy
    }

    var availableSlowShutterDurations: [SlowShutterDuration] {
        guard let preset = selectedSlowShutterPreset else { return SlowShutterDuration.allCases }
        return SlowShutterDuration.allCases.filter { preset.allows($0) }
    }

    func selectSlowShutterDuration(_ duration: SlowShutterDuration) {
        guard canEditSlowShutterDuration, availableSlowShutterDurations.contains(duration),
              duration != slowShutterDuration else { return }
        cameraSelectionFeedback()
        slowShutterDuration = duration
    }

    /// M-mode ranges are preset-limited only after one of the five presets is
    /// actually selected; merely enabling slow shutter leaves the hardware range.
    var hasActiveSlowShutterPreset: Bool {
        slowShutterEnabled && selectedSlowShutterPreset != nil
    }

    var slowShutterShutterRange: ClosedRange<Double> {
        guard hasActiveSlowShutterPreset, let selectedSlowShutterPreset else { return camera.shutterRange }
        if let range = selectedSlowShutterPreset.shutterRange(limitedTo: camera.shutterRange) { return range }
        return camera.ready ? camera.shutterRange : selectedSlowShutterPreset.shutterLog2Range
    }

    /// M-mode slider range: limited to the selected preset's suggested ISO and
    /// the current hardware range. Sequence metering intentionally uses the
    /// full hardware range separately.
    var slowShutterISORange: ClosedRange<Double> {
        guard hasActiveSlowShutterPreset, let selectedSlowShutterPreset else { return camera.isoRange }
        if let range = selectedSlowShutterPreset.manualISORange(limitedTo: camera.isoRange) { return range }
        return camera.ready ? camera.isoRange : selectedSlowShutterPreset.suggestedISORange
    }

    private var slowShutterCaptureISORange: ClosedRange<Double> {
        guard slowShutterEnabled, let preset = selectedSlowShutterPreset else { return camera.isoRange }
        return preset.isoRange(limitedTo: camera.isoRange) ?? camera.isoRange
    }

    func isSlowShutterPresetSupported(_ preset: SlowShutterPreset) -> Bool {
        guard camera.ready else { return true }
        return preset.supports(hardwareShutter: camera.shutterRange, hardwareISO: camera.isoRange)
    }

    var photoSubmodeActive: Bool { captureKind == .photo && activePhotoSubmode != nil }

    private var activePhotoSubmode: PhotoSubmode? {
        guard captureKind == .photo else { return nil }
        if nightModeEnabled { return .night }
        if portraitModeEnabled { return .portrait }
        if burstModeEnabled { return .burst }
        if slowShutterEnabled { return .slowShutter }
        return nil
    }

    /// 仅展示真正启用的子模块；规格适配尚未完成或智拍占位点击不伪装成已开启。
    var shootingModeButtonSymbol: String {
        // Photo entry is a camera by default, then follows the selected
        // submodule's semantic icon; the popup options keep those icons too.
        if captureKind == .photo {
            if virtualApertureEnabled { return "camera.aperture" }
            if smartCaptureEnabled { return "sparkles" }
            return activePhotoSubmode?.symbol ?? "camera.fill"
        }
        if camera.dualCaptureEnabled { return "rectangle.on.rectangle" }
        if virtualApertureEnabled { return "camera.aperture" }
        if timeLapseEnabled { return VideoSubmode.timeLapse.symbol }
        if slowMotionEnabled { return VideoSubmode.slowMotion.symbol }
        if cinematicVideoEnabled { return VideoSubmode.cinematic.symbol }
        return "video"
    }

    var shootingSubmodeEnabled: Bool {
        captureKind == .photo ? (virtualApertureEnabled || smartCaptureEnabled || activePhotoSubmode != nil)
            : camera.dualCaptureEnabled || virtualApertureEnabled || timeLapseEnabled || slowMotionEnabled || cinematicVideoEnabled
    }

    var fixedHighResolutionFocalsOnly: Bool { captureKind == .photo && photoResolution == .high }
    var cinematicAutomaticControls: Bool { captureKind == .video && cinematicVideoEnabled }
    var displayedManualParameters: [CameraParameter] {
        cinematicAutomaticControls ? [.ev, .wb, .tint] : CameraParameter.allCases
    }
    var fixedCinematicFocalsOnly:Bool { captureKind == .video && cinematicVideoEnabled && currentPosition == .back }
    var displayedFocalPosition: AVCaptureDevice.Position {
        if camera.dualCaptureEnabled { return camera.dualCaptureMainIsFront ? .front : .back }
        return currentPosition
    }

    func isFocalSelected(_ lens: CameraLens) -> Bool {
        guard camera.dualCaptureEnabled else { return camera.selectedLens == lens.id }
        if camera.dualCaptureMainIsFront {
            guard lens.device.position == .front else { return false }
            // 双拍前置广角启用时，选中广角档位。
            return camera.dualCaptureFrontWide ? lens.frontFraming == .wide : lens.frontFraming == .standard
        }
        return lens.device.position == .back && camera.selectedLens == lens.id
    }

    @Published private(set) var dualMainFocalPreset: CGFloat?

    private func updateDualMainPreset(_ value: CGFloat) {
        guard camera.dualCaptureEnabled, !camera.dualCaptureMainIsFront else { return }
        let back = displayedFocalLenses.filter { $0.device.position == .back }
        dualMainFocalPreset = back.min(by: {
            abs($0.displayZoom - value) < abs($1.displayZoom - value)
        })?.displayZoom
    }

    private func applyZoomValue(_ value: CGFloat) {
        if camera.dualCaptureEnabled {
            updateDualMainPreset(value)
            camera.setDualCaptureMainZoom(value)
        } else {
            camera.setContinuousZoom(value)
        }
    }

    var displayedFocalLenses:[CameraLens] {
        camera.lenses.filter { $0.device.position == displayedFocalPosition
            && (!fixedCinematicFocalsOnly || abs($0.displayZoom-1)<0.001 || abs($0.displayZoom-2)<0.001)
            && (!fixedHighResolutionFocalsOnly || camera.highResolutionLensIDs.contains($0.id))
            && (captureKind != .video || camera.dualCaptureEnabled || videoLensSupportsCurrentSelection($0))
            && (!camera.videoRecording || (camera.dualCaptureEnabled ? camera.dualCaptureMainZoomRange : camera.videoRecordingZoomRange)?.contains($0.displayZoom) == true)
            && (!virtualApertureEnabled || supportsVirtualApertureLens($0))
            && (!camera.dualCaptureEnabled || camera.dualCaptureMainIsFront || $0.displayZoom >= 0.999) }
    }
    /// 子模块互斥；镜头与当前规格能力从会话发布的静态表读取，不在视图重绘时扫描 AVFoundation 格式。
    func canSelectFocalLength(_ lens: CameraLens) -> Bool {
        guard !camera.dualCapturePreparing, slowShutterSequence == nil else { return false }
        if captureKind == .video, lens.device.position == .front { return false }
        if camera.videoRecording {
            guard let range = camera.dualCaptureEnabled ? camera.dualCaptureMainZoomRange : camera.videoRecordingZoomRange, range.contains(lens.displayZoom) else { return false }
        }
        if fixedCinematicFocalsOnly && abs(lens.displayZoom-1)>0.001 && abs(lens.displayZoom-2)>0.001 { return false }
        if fixedHighResolutionFocalsOnly && (!camera.highResolutionLensIDs.contains(lens.id) || camera.highResolutionPhotoConfiguring) { return false }
        if camera.dualCaptureEnabled {
            guard !dualInsetAspectChanging, captureKind == .video else { return false }
            if camera.dualCaptureMainIsFront {
                return lens.device.position == .front && lens.frontFraming != nil
            }
            return lens.device.position == .back && lens.displayZoom >= 0.999
        }
        guard photoSubmodePreparing == nil, videoSubmodePreparing == nil else { return false }
        if captureKind == .video, !camera.videoSelectionCapabilities.isEmpty {
            return videoLensSupportsCurrentSelection(lens)
        }
        if virtualApertureEnabled { return supportsVirtualApertureLens(lens) }
        guard let activePhotoSubmode else {
            if captureKind == .video, let compatibleSubmodeLensIDs {
                return compatibleSubmodeLensIDs.contains(lens.id)
            }
            return true
        }
        // Slow shutter is a parameter-only photo mode: every current-position
        // lens can take a still, and the preset is revalidated after the route
        // changes. Do not gate lens switching on a per-route capability table
        // that may be missing non-active crop lenses.
        if activePhotoSubmode == .slowShutter { return true }
        return camera.photoLensCapabilities[lens.id]?.supports(activePhotoSubmode)
            ?? (lens.id == camera.selectedLens && currentPhotoRouteSupports(activePhotoSubmode))
    }

    private func photoFormatIsAllowed(_ format: PhotoFileFormat, for mode: PhotoSubmode) -> Bool {
        switch mode {
        case .night: return NightCapturePolicy.supportedFormats.contains(format)
        case .burst: return PhotoBurstPolicy.supportedFormats.contains(format)
        case .portrait:
            return PortraitCapturePolicy.supports(format: format, resolution: photoResolution,
                live: false, hdr: false, proRAWAvailable: camera.supportsProRAW)
        case .slowShutter: return true
        }
    }

    private func photoResolutionIsAllowed(_ resolution: PhotoResolution, for mode: PhotoSubmode) -> Bool {
        switch mode {
        case .night, .burst: return resolution == .standard
        case .portrait:
            return PortraitCapturePolicy.supports(format: photoFormat, resolution: resolution,
                live: false, hdr: false, proRAWAvailable: camera.supportsProRAW)
        case .slowShutter: return camera.availableResolutions.contains(resolution)
        }
    }

    private func preferredPhotoFormat(for mode: PhotoSubmode) -> PhotoFileFormat {
        let routeFormats = camera.availablePhotoFormats
        let allowed = PhotoSubmodeSettingsPolicy.formats(for: mode)
        if allowed.contains(photoFormat), routeFormats.contains(photoFormat), photoFormatIsAllowed(photoFormat, for: mode) {
            return photoFormat
        }
        return allowed.first(where: routeFormats.contains) ?? .jpeg
    }

    private func currentPhotoRouteSupports(_ mode: PhotoSubmode) -> Bool {
        if let lens = camera.photoLensCapabilities[camera.selectedLens] {
            return lens.supports(mode)
        }
        switch mode {
        case .night: return camera.supportsNightCapture
        case .portrait: return camera.supportsPortraitCapture
        case .burst, .slowShutter: return true
        }
    }

    /// 预置子模块需要的格式后，先用当前镜头；当前路由不支持时才选同朝向的兼容焦段。
    private func preparePhotoSubmode(_ mode: PhotoSubmode) -> CameraLens? {
        guard camera.ready, !camera.capturing, !camera.videoBusy, captureKind == .photo else { return nil }
        let samePosition = camera.lenses.filter { $0.device.position == currentPosition }
        let compatible = samePosition.filter { camera.photoLensCapabilities[$0.id]?.supports(mode) == true }
        let targetLens = compatible.first(where: { $0.id == camera.selectedLens })
            ?? compatible.min(by: { abs($0.displayZoom - camera.currentZoom) < abs($1.displayZoom - camera.currentZoom) })
            ?? (currentPhotoRouteSupports(mode) ? camera.lenses.first(where: { $0.id == camera.selectedLens }) : nil)
        guard let targetLens else { return nil }

        // 先结束冲突模式，再设置不会被旧模式 didSet 限制的目标参数。
        stopBurstCapture()
        burstModeEnabled = false
        portraitModeEnabled = false
        nightModeEnabled = false
        nightCaptureRuntimeUnavailable = false
        resetNightEnvironmentGate()
        clearSlowShutterMode()
        if mode == .night {
            cancelCountdown()
        }

        let targetCapabilities = camera.photoLensCapabilities[targetLens.id]
        let targetFormats = targetLens.id == camera.selectedLens
            ? Set(camera.availablePhotoFormats)
            : targetCapabilities?.formats ?? Set(camera.availablePhotoFormats)
        let format = PhotoSubmodeSettingsPolicy.preferredFormat(for: mode, requested: photoFormat,
            supported: targetFormats.intersection(Set(PhotoSubmodeSettingsPolicy.formats(for: mode))))
        guard let format else { return nil }
        if photoFormat != format { photoFormat = format }
        let targetResolutions = targetCapabilities?.resolutions ?? Set(camera.availableResolutions)
        let chosenResolution = PhotoSubmodeSettingsPolicy.resolution(for: mode, requested: photoResolution,
                                                                      supported: targetResolutions)
        if let chosenResolution, chosenResolution != photoResolution { photoResolution = chosenResolution }
        else if chosenResolution == nil { photoResolution = .standard }

        hdr = false
        livePhotoEnabled = false
        synchronizeLiveAudio()
        if mode == .night || mode == .burst {
            flashMode = .off
            if timerSeconds != 0 { timerSeconds = 0 }
            cancelCountdown()
        }
        return targetLens
    }

    private func togglePhotoSubmode(_ requested: PhotoSubmode) {
        if smartCaptureEnabled {
            smartCaptureEnabled = false
            stopSmartCaptureAnalysis()
        }
        adaptiveHighDynamic = false
        if virtualApertureEnabled { virtualApertureEnabled = false; updateLook() }
        if activePhotoSubmode == requested {
            photoSubmodeRequest = UUID()
            photoSubmodePreparing = nil
            if requested == .portrait { preparePortraitPreviewTransition() }
            setPhotoSubmode(requested, enabled: false)
            withAnimation(AppTheme.popupAnimation) { shootingModes = false }
            refreshSubmodeLensCompatibility()
            scheduleCaptureStateSave()
            return
        }
        guard let targetLens = preparePhotoSubmode(requested) else {
            if camera.ready && captureKind == .photo && !camera.capturing && !camera.videoBusy {
                camera.message = "当前镜头没有可用的兼容拍摄规格"
            }
            return
        }
        cameraSelectionFeedback()
        let request = UUID()
        photoSubmodeRequest = request
        if targetLens.id == camera.selectedLens {
            activatePreparedPhotoSubmode(requested)
            withAnimation(AppTheme.popupAnimation) { shootingModes = false }
            refreshSubmodeLensCompatibility()
            scheduleCaptureStateSave()
            return
        }

        photoSubmodePreparing = requested
        startFocalTransition()
        camera.selectLens(targetLens, transitionID: focalTransitionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<400 {
                guard !Task.isCancelled, self.photoSubmodeRequest == request else { return }
                if self.camera.ready && self.camera.selectedLens == targetLens.id { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard self.photoSubmodeRequest == request else { return }
            let routeReady = self.camera.ready && self.camera.selectedLens == targetLens.id
            self.photoSubmodePreparing = nil
            guard routeReady, self.currentPhotoRouteSupports(requested) else {
                self.camera.message = "镜头切换未完成，拍摄设置已保留"
                return
            }
            self.activatePreparedPhotoSubmode(requested)
            withAnimation(AppTheme.popupAnimation) { self.shootingModes = false }
            self.refreshSubmodeLensCompatibility()
            self.scheduleCaptureStateSave()
        }
    }

    /// 相机切换完成后再正式启用模式，防止异步能力回报把刚开启的模式立即清除。
    private func activatePreparedPhotoSubmode(_ mode: PhotoSubmode) {
        if mode == .portrait { preparePortraitPreviewTransition() }
        setPhotoSubmode(mode, enabled: true)
        if mode == .portrait, smartPortraitPendingRequest == photoSubmodeRequest {
            portraitAutoEnabledBySmartCapture = true; smartPortraitPendingRequest = nil
        }
    }

    private func setPhotoSubmode(_ mode: PhotoSubmode, enabled: Bool) {
        switch mode {
        case .slowShutter:
            // 退出子模块必须同时清空预设、曝光辅助和未完成序列，不能只隐藏按钮条。
            if enabled {
                slowShutterEnabled = true
                livePhotoEnabled = false
                synchronizeLiveAudio()
            } else {
                clearSlowShutterMode()
                if toolbarPanel == .slowShutterDuration { toolbarPanel = nil }
            }
        case .night:
            if enabled, self.mode == .manual { setMode(.auto) }
            guard !enabled || self.mode == .auto else { return }
            nightModeEnabled = enabled
            nightCaptureRuntimeUnavailable = false
            resetNightEnvironmentGate()
        case .portrait: portraitModeEnabled = enabled
        case .burst:
            if !enabled { stopBurstCapture() }
            burstModeEnabled = enabled
        }
    }

    private func refreshSubmodeLensCompatibility() {
        if let mode = activePhotoSubmode {
            compatibleSubmodeLensIDs = Set(camera.lenses.compactMap { lens in
                camera.photoLensCapabilities[lens.id]?.supports(mode) == true ? lens.id : nil
            })
            return
        }
        guard captureKind == .video else { compatibleSubmodeLensIDs = nil; return }
        let activeMode: VideoSubmode?
        if slowMotionEnabled { activeMode = .slowMotion }
        else if cinematicVideoEnabled { activeMode = .cinematic }
        else if timeLapseEnabled { activeMode = .timeLapse }
        else { activeMode = nil }
        guard let activeMode else { compatibleSubmodeLensIDs = nil; return }
        let requested = selectedVideoSettings
        let matching: ([VideoCaptureSettings]) -> Bool = { settings in
            settings.contains { $0.resolution == requested.resolution && $0.frameRate == requested.frameRate
                && $0.colorSpace == requested.colorSpace }
        }
        if self.mode == .auto, currentPosition == .back, matching(videoCapabilitiesForCurrentRatio) {
            // A 挡后置焦段都走同一系统虚拟多摄输入，能力由当前虚拟路由统一声明。
            compatibleSubmodeLensIDs = Set(camera.lenses.filter { $0.device.position == .back }.map(\.id))
            return
        }
        if self.mode == .manual || currentPosition == .front {
            // 保留已扫描确认的兼容镜头；切换到兼容镜头后继续开放同一兼容集合。
            // 前置宽窄共用输入，但必须按前置路线重查，不能把上一后置子模块的 ID 过滤成空集。
            let currentIsSupported = matching(videoCapabilitiesForCurrentRatio) && !camera.selectedLens.isEmpty
            if let existing = compatibleSubmodeLensIDs,
               existing.contains(camera.selectedLens), currentIsSupported {
                compatibleSubmodeLensIDs = Set(existing.filter { id in
                    camera.lenses.first(where: { $0.id == id })?.device.position == currentPosition
                })
            } else {
                compatibleSubmodeLensIDs = currentIsSupported ? [camera.selectedLens] : []
            }
            refreshVideoSubmodeLensCompatibility(for: activeMode)
            return
        }
        if let existing = compatibleSubmodeLensIDs {
            // 子模块启用时记录所选规格确实支持的路线；后续参数刷新只过滤缓存 ID，不再扫描硬件格式。
            compatibleSubmodeLensIDs = Set(existing.filter { id in
                guard let lens = camera.lenses.first(where: { $0.id == id }) else { return false }
                return lens.device.position == currentPosition
            })
            return
        }
        compatibleSubmodeLensIDs = matching(videoCapabilitiesForCurrentRatio) && !camera.selectedLens.isEmpty
            ? [camera.selectedLens] : []
    }

    func toggleSlowShutterMode() {
        // Slow shutter presets are an A-mode computational feature. Entering
        // from M switches to A first so presets and adaptive exposure agree.
        if !slowShutterEnabled, mode != .auto { setMode(.auto) }
        togglePhotoSubmode(.slowShutter)
        if slowShutterEnabled {
            selectedSlowShutterPreset = nil
            slowShutterAutomaticPreset = nil
            slowShutterAutomaticDuration = .s1
            slowShutterDuration = .s1
        }
    }

    func showSmartCaptureStatus() {
        toggleSmartCaptureMode()
    }

    #if DEBUG
    func setSmartCaptureForTesting(_ enabled: Bool) {
        guard smartCaptureEnabled != enabled else { return }
        toggleSmartCaptureMode()
    }
    #endif

    @Published private(set) var smartCaptureEnabled = false
    @Published private(set) var smartSuggestion: SmartCaptureSuggestion?
    @Published private(set) var smartCompositionGuide: SmartCompositionGuide?
    @Published private(set) var smartCompositionCandidates:[SmartCompositionGuide] = []
    private let smartSubjectTracker = SmartSubjectTracker() // 只在smartCaptureQueue访问。
    private var smartTrackingEpoch = UUID()
    @Published private(set) var smartFramingRecommendation: SmartFramingRecommendation?
    @Published private(set) var smartFramingInProgress = false
    @Published private(set) var smartFramingComplete = false
    @Published private(set) var smartFramingFeedbackVisible = false
    @Published private(set) var smartAlignmentLatched = false
    private var smartFramingFeedbackTask: Task<Void,Never>?
    private var smartAutoFramingGate = SmartAutoFramingGate()
    private var smartFramingWork: SmartFramingWork?
    private var smartFramingTask: Task<Void,Never>?
    private var smartPortraitPendingRequest: UUID?
    private var smartRecommendationRangePolicy = SmartRecommendationRangePolicy()
    private var smartRecommendationRangeAllowed = true
    #if DEBUG
    var smartAnalysisOverrideForTesting = false
    var smartFramingEvaluatorForTesting: ((UIImage,SmartCompositionGuide,CGFloat,ClosedRange<CGFloat>,SmartFramingWork)->SmartFramingEvaluator.Evaluation)?
    private(set) var smartAutoFramingCountForTesting = 0
    struct SmartTrackingSample {
        let publishedAt: Double
        let requestToPublication: Double
        let processingSeconds: Double
        let detectedScene: Bool
        let verifiedCandidates: Int
        let displayedCandidates: Int
        let retainedCandidates: Int
        let recommendationsAllowed: Bool
        let objectTrackedCandidates: Int
        let appearanceVerifiedCandidates: Int
    }
    private(set) var smartTrackingSamplesForTesting: [SmartTrackingSample] = []
    func resetSmartTrackingSamplesForTesting() { smartTrackingSamplesForTesting.removeAll(keepingCapacity: true) }
    func injectSmartCompositionForTesting(_ guide:SmartCompositionGuide?) {
        smartRecommendationRangeAllowed = true // 注入测试明确绕过实景范围判断。
        smartCompositionGuide = guide; updateSmartFraming(for:guide)
    }
    func injectSmartCandidatesForTesting(_ candidates:[SmartCompositionGuide]) {
        smartRecommendationRangeAllowed = true
        let selected = SmartSubjectTracker.selectedID(candidates:candidates,previous:smartCompositionGuide?.subjectID,
            retained:Set(candidates.compactMap(\.subjectID)))
        publishSmartComposition(candidates.first { $0.subjectID == selected },candidates:candidates)
    }
    func injectSmartTrackingForTesting(_ result:SmartSubjectTracker.Result,bypassRangePolicy:Bool = true) {
        if bypassRangePolicy { smartRecommendationRangeAllowed = true }
        publishSmartComposition(result.selected,candidates:result.candidates)
    }
    func injectSmartRangeForTesting(_ readings:CameraReadings?,macro:Bool) {
        applySmartRecommendationRange(readings,macro:macro)
    }
    var smartPortraitAutoForTesting:Bool { portraitAutoEnabledBySmartCapture }
    func injectSmartSuggestionForTesting(_ suggestion:SmartCaptureSuggestion) { smartSuggestion = presentedSmartSuggestion(suggestion) }
    #endif
    private var smartCaptureTask: Task<Void, Never>?
    private var smartCaptureGeneration = UUID()
    private var smartSuggestionPausedUntil: CFAbsoluteTime = 0
    private var smartAnalysisInFlight = false
    private var portraitAutoEnabledBySmartCapture = false
    private var smartPortraitMissingChecks = 0
    private var smartCurrentSceneSignature: String?
    private var suppressedSmartSuggestionSignature: String?
    private var suppressedSuggestionMissingChecks = 0
    private var smartCompositionStabilizer = SmartCompositionStabilizer()
    private var smartSubjectContinuity = SmartSubjectContinuity()
    private let smartCaptureQueue = DispatchQueue(label: "camera.smart-capture", qos: .userInitiated)
    // 仅在smartCaptureQueue访问；低频场景检测不阻塞每次跟踪都重复跑显著性/人脸。
    private let smartSceneAnalysisState = SmartSceneAnalysisState()
    private var smartAIAdvisoryTask: Task<Void,Never>?
    private var smartAIAdvisoryBatch = ""

    func toggleSmartCaptureMode() {
        guard captureKind == .photo, camera.ready, !camera.capturing, !camera.videoBusy,
              photoSubmodePreparing == nil, videoSubmodePreparing == nil else { return }
        cameraSelectionFeedback()
        if !smartCaptureEnabled {
            // 智拍与手动预设互斥：先退出当前预设，再进入智拍。
            if virtualApertureEnabled { toggleVirtualAperture() }
            if let active = activePhotoSubmode { togglePhotoSubmode(active) }
            adaptiveHighDynamic = false
            smartCaptureEnabled = true
            startSmartCaptureAnalysis()
        } else {
            smartCaptureEnabled = false
            stopSmartCaptureAnalysis()
        }
    }

    /// 状态快照用于丢弃页面、格式、镜头或倍率变化前启动的异步结果。
    private var smartContext: String {
        "\(mode)|\(currentPosition)|\(ratio)|\(photoFormat)|\(photoResolution)|\(hdr)|\(camera.selectedLens)|\(camera.currentZoom)|\(previewQuarterTurns)|\(effectiveCaptureLook.landscape)"
    }
    private var smartCaptureAnalysisAllowed: Bool {
        let autoPortrait = portraitAutoEnabledBySmartCapture && portraitModeEnabled && activePhotoSubmode == .portrait
        return smartCaptureEnabled && cameraActiveRequested && captureKind == .photo && !review && !settings
            && !camera.capturing && !camera.videoBusy && !popupVisible && toolbarPanel == nil && panel == nil
            && camera.ready && !camera.highResolutionPhotoConfiguring && !camera.shutterBusy && !isPreparingSubmode && !virtualApertureEnabled && (activePhotoSubmode == nil || autoPortrait)
    }
    private var smartAutomaticAllowed: Bool {
        smartCaptureAnalysisAllowed && activePhotoSubmode == nil && smartRecommendationRangeAllowed
            && !camera.targetLockActive && !zoomDialVisible && previewPinchOrigin == nil
    }
    private func interruptSmartFraming() {
        smartAlignmentLatched = false
        smartAIAdvisoryTask?.cancel(); smartAIAdvisoryTask = nil; smartAIAdvisoryBatch = ""
        smartFramingFeedbackTask?.cancel(); smartFramingFeedbackTask = nil; smartFramingFeedbackVisible = false
        smartFramingWork?.cancel(); smartFramingWork = nil
        smartFramingTask?.cancel(); smartFramingTask = nil
        smartFramingInProgress = false; smartFramingRecommendation = nil
        smartAutoFramingGate.interrupt()
    }
    private func rearmSmartAfterPhoto() {
        guard smartCaptureEnabled else { return }
        interruptSmartFraming(); smartAutoFramingGate.reset(); smartFramingComplete = false
        // 保留仍有效的点位；不清空缩略图或重建画面，同场景下一张也能重新对齐。
    }
    private func refreshSmartRecommendationRange() {
        applySmartRecommendationRange(camera.readings,macro:camera.macroActive)
    }
    private func applySmartRecommendationRange(_ readings:CameraReadings?,macro:Bool) {
        let allowed = smartRecommendationRangePolicy.update(position:readings?.recommendationFocusPosition,
            adjusting:readings?.adjustingFocus ?? true,macro:macro,
            deviceID:readings?.recommendationFocusDeviceID,sampleTime:readings?.sampleHostTime)
        guard allowed != smartRecommendationRangeAllowed else { return }
        smartRecommendationRangeAllowed = allowed
        interruptSmartFraming(); smartAutoFramingGate.reset(); smartFramingComplete = false
        smartCompositionGuide = nil; smartCompositionCandidates = []; smartCompositionStabilizer.reset()
        smartTrackingEpoch = UUID()
        if !allowed { camera.endSmartFocusHold() } // 归还既有AF，避免保持在旧近焦点而不能恢复中远景判断。
    }
    var smartDisplayedCompositionGuide: SmartCompositionGuide? { smartCompositionGuide ?? smartCompositionCandidates.first }
    private func requestSmartAIAdvice(image:CGImage,candidates:[SmartCompositionGuide],trackingContext:String,
                                      context:String,generation:UUID) {
        guard !smartFramingInProgress, !smartFramingComplete, !candidates.isEmpty else { return }
        let batch = trackingContext + candidates.compactMap(\.subjectID).map(\.uuidString).sorted().joined()
        guard batch != smartAIAdvisoryBatch else { return }
        smartAIAdvisoryTask?.cancel(); smartAIAdvisoryBatch = batch
        let started = CACurrentMediaTime(), tracker = smartSubjectTracker
        smartAIAdvisoryTask = Task { @MainActor [weak self] in
            let advice = await SmartLocalCompositionAI.shared.advise(image:image,candidates:candidates)
            guard !Task.isCancelled, let self, let advice, CACurrentMediaTime()-started <= 3,
                  self.smartCaptureGeneration == generation, self.smartContext == context,
                  self.smartAIAdvisoryBatch == batch, self.smartCaptureAnalysisAllowed,
                  !self.smartFramingInProgress, !self.smartFramingComplete else { return }
            self.smartCaptureQueue.async { tracker.applyAdvice(advice,context:trackingContext) }
        }
    }
    private func updateSmartFraming(for guide: SmartCompositionGuide?) {
        guard smartAutomaticAllowed else { interruptSmartFraming(); return }
        guard !smartFramingInProgress else { return }
        if guide == nil || (guide?.trackingVerified == true && (guide?.alignmentDistance ?? 0) > SmartCompositionGuide.alignmentRadius * 1.6) {
            smartAlignmentLatched = false
        }
        let shouldFrame = smartAutoFramingGate.update(guide,at:CACurrentMediaTime())
        if smartAutoFramingGate.alignmentConfirmed { smartAlignmentLatched = true }
        let wasComplete = smartFramingComplete
        smartFramingComplete = smartAutoFramingGate.completed
        if wasComplete, !smartFramingComplete {
            smartFramingFeedbackTask?.cancel(); smartFramingFeedbackTask = nil
            smartFramingFeedbackVisible = false
        }
        guard shouldFrame, let guide, let source = camera.preview else { return }
        let work = SmartFramingWork(), context = smartContext, generation = smartCaptureGeneration
        let zoom = camera.currentZoom
        let range:ClosedRange<CGFloat> = photoResolution == .high ? zoom...zoom : zoomRange
        let look = effectiveCaptureLook, aspect = look.landscape ? 1/look.ratio.portraitRatio : look.ratio.portraitRatio
        smartFramingWork = work; smartFramingInProgress = true
        #if DEBUG
        let override = smartFramingEvaluatorForTesting
        #endif
        smartCaptureQueue.async { [weak self] in
            guard !work.isCancelled else { return }
            guard let image = SmartCaptureAnalyzer.visibleImage(source,aspect:aspect) else {
                DispatchQueue.main.async { if self?.smartFramingWork === work { self?.interruptSmartFraming() } }; return
            }
            let result:SmartFramingEvaluator.Evaluation
            #if DEBUG
            if let override { result = override(image,guide,zoom,range,work) }
            else { result = SmartFramingEvaluator.evaluate(image:image,guide:guide,currentZoom:zoom,range:range,work:work) }
            #else
            result = SmartFramingEvaluator.evaluate(image:image,guide:guide,currentZoom:zoom,range:range,work:work)
            #endif
            DispatchQueue.main.async {
                guard let self, !work.isCancelled, self.smartFramingWork === work else { return }
                guard self.smartCaptureGeneration == generation, self.smartContext == context, self.smartAutomaticAllowed else {
                    self.interruptSmartFraming(); return
                }
                self.finishAutomaticSmartFraming(result,guide:guide,work:work,generation:generation)
            }
        }
    }
    private func publishSmartComposition(_ guide:SmartCompositionGuide?,candidates:[SmartCompositionGuide]) {
        guard smartRecommendationRangeAllowed else { return }
        let now = CACurrentMediaTime()
        // 先做主体身份迟滞，再做提示阶段迟滞；新主体不能靠单帧胜出替换白点。
        let stable = smartSubjectContinuity.update(guide, at: now)
        if let next = stable?.subjectID, let previous = smartCompositionGuide?.subjectID, previous != next {
            smartAlignmentLatched = false
            smartCompositionStabilizer.reset()
            if smartFramingComplete, candidates.contains(where: { $0.subjectID == previous }) {
                // 同一批中对齐另一个候选是新一轮；自身变焦重新提名后旧UUID不在本批，不重复触发。
                smartAutoFramingGate.reset(); smartFramingComplete = false
                smartFramingFeedbackTask?.cancel(); smartFramingFeedbackTask = nil; smartFramingFeedbackVisible = false
            } else { smartAutoFramingGate.interrupt() }
        }
        smartCompositionCandidates = activePhotoSubmode == nil ? candidates : []
        smartCompositionGuide = activePhotoSubmode == nil
            ? smartCompositionStabilizer.update(stable, at: now) : nil
        // 未对齐阶段不额外发起AF扫描；对齐后的单次对焦继续由finishAutomaticSmartFraming提交。
        updateSmartFraming(for: stable == nil ? nil : smartCompositionGuide)
    }
    private func finishAutomaticSmartFraming(_ result:SmartFramingEvaluator.Evaluation,guide:SmartCompositionGuide,work:SmartFramingWork,generation:UUID) {
        // 没有可评分裁切也要完成主体对焦和反馈；只有可靠评分才允许改变倍率。
        let recommendation = result.scores.isEmpty ? nil : result.recommendation
        let targetZoom = recommendation?.zoom ?? camera.currentZoom
        let focusTarget = SmartFramingRecommendation.focusPoint(for:guide,from:camera.currentZoom,to:targetZoom)
        let position = currentPosition, format = photoFormat, resolution = photoResolution, frameRatio = ratio, captureMode = mode
        if let recommendation {
            smartFramingRecommendation = recommendation
            camera.setContinuousZoom(recommendation.zoom,smooth:true)
        }
        #if DEBUG
        smartAutoFramingCountForTesting += 1
        #endif
        smartFramingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 等官方变焦爬坡真正结束，再对焦到主体在新视野中的投影位置；不依据界面提前显示的倍率。
            try? await Task.sleep(for:.milliseconds(220))
            for _ in 0..<25 {
                guard !Task.isCancelled, !work.isCancelled, self.smartCaptureGeneration == generation,
                      self.smartAutomaticAllowed, self.currentPosition == position, self.photoFormat == format,
                      self.photoResolution == resolution, self.ratio == frameRatio, self.mode == captureMode,
                      abs(self.camera.currentZoom-targetZoom) < 0.04 else { self.interruptSmartFraming(); return }
                let settled:Bool = await withCheckedContinuation { continuation in self.camera.smartZoomSettled { continuation.resume(returning:$0) } }
                if settled {
                    // 用户授权M挡智拍也自动取景/对焦；只释放手动焦点，不重写曝光或白平衡。
                    self.manualFocus = false
                    self.camera.focus(at:focusTarget,smartSingleShot:true)
                    self.smartAutoFramingGate.finish() // 只封住当前对齐轮；拍完照即开启下一轮。
                    self.smartFramingComplete = true; self.smartFramingFeedbackVisible = true; self.smartFramingInProgress = false
                    // 完成勾选短暂出现后消失，让用户看清最终取景再手动拍照。
                    self.smartFramingFeedbackTask?.cancel()
                    self.smartFramingFeedbackTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for:.milliseconds(250))
                        guard !Task.isCancelled, let self, self.smartCaptureGeneration == generation else { return }
                        self.smartFramingFeedbackVisible = false; self.smartFramingFeedbackTask = nil
                    }
                    self.smartFramingRecommendation = nil; self.smartFramingWork = nil; self.smartFramingTask = nil
                    return
                }
                try? await Task.sleep(for:.milliseconds(80))
            }
            self.interruptSmartFraming()
        }
    }

    private func presentedSmartSuggestion(_ suggestion:SmartCaptureSuggestion?) -> SmartCaptureSuggestion? {
        SmartCaptureSuggestionPolicy.presented(suggestion,format:photoFormat,resolution:photoResolution,available:Set(camera.availablePhotoFormats))
    }

    func applySmartSuggestion() {
        guard mode == .auto, let suggestion = smartSuggestion,
              camera.ready, !camera.highResolutionPhotoConfiguring, !camera.shutterBusy, !camera.capturing, !camera.videoBusy else { return }
        guard let actual = presentedSmartSuggestion(suggestion), actual.actionTitle != nil else { return }
        // 用户刚换格式/分辨率时，先更新建议文字；不按过期文案悄悄降规格。
        guard actual == suggestion else { smartSuggestion = actual; return }
        cameraSelectionFeedback()
        suppressedSmartSuggestionSignature = smartCurrentSceneSignature
        suppressedSuggestionMissingChecks = 0
        if smartCaptureEnabled { toggleSmartCaptureMode() }
        let params = suggestion.parameters
        var appliedPortrait = false
        if params.mode == .portrait, !portraitModeEnabled {
            togglePortraitMode()
            appliedPortrait = portraitModeEnabled
        }
        // 逆光人像没有blur字段，也必须记录来源；异步切镜后再确认开启。
        if params.mode == .portrait {
            if appliedPortrait { portraitAutoEnabledBySmartCapture = true }
            else if photoSubmodePreparing == .portrait { smartPortraitPendingRequest = photoSubmodeRequest }
        }
        if let blur = params.portraitBlur, portraitModeEnabled { portraitBlurStrength = min(max(blur, 0), 1) }
        if let delta = params.evDelta {
            ev = min(max(ev + delta, -5), 5)
            applyExposure()
        }
        if params.hdr == true {
            if (photoFormat == .heif || photoFormat == .heifPro), !border {
                hdr = true
            }
        }
        dismissSmartSuggestion()
    }

    func dismissSmartSuggestion() {
        // Closing or applying a recommendation suppresses this scene, not just
        // this exact frame; changing parameters will not bring it back.
        if suppressedSmartSuggestionSignature == nil {
            suppressedSmartSuggestionSignature = smartCurrentSceneSignature
        }
        suppressedSuggestionMissingChecks = 0
        smartSuggestion = nil
        smartSuggestionPausedUntil = CACurrentMediaTime() + 2
    }

    private func startSmartCaptureAnalysis() {
        smartRecommendationRangePolicy.reset()
        smartCaptureTask?.cancel()
        let generation = UUID()
        smartCaptureGeneration = generation
        smartCaptureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.smartCaptureEnabled else { return }
                self.refreshSmartSuggestion(generation: generation)
                let process = ProcessInfo.processInfo
                let interval = SmartCaptureCadence.interval(
                    hasVisibleGuide: self.smartCompositionGuide != nil,
                    analysisAllowed: self.smartCaptureAnalysisAllowed,
                    lowPower: process.isLowPowerModeEnabled,
                    thermalSerious: process.thermalState == .serious || process.thermalState == .critical)
                try? await Task.sleep(for: .milliseconds(max(16, Int(interval * 1000))))
            }
        }
    }

    private func stopSmartCaptureAnalysis() {
        camera.endSmartFocusHold()
        smartCaptureTask?.cancel()
        smartCaptureTask = nil
        interruptSmartFraming(); smartAutoFramingGate.reset(); smartFramingComplete = false
        smartCaptureGeneration = UUID()
        smartSuggestion = nil
        smartCompositionGuide = nil; smartCompositionCandidates = []
        smartFramingRecommendation = nil
        smartCompositionStabilizer.reset()
        smartSubjectContinuity.reset()
        smartPortraitMissingChecks = 0
        suppressedSmartSuggestionSignature = nil
        suppressedSuggestionMissingChecks = 0
        smartCurrentSceneSignature = nil
    }

    private func refreshSmartSuggestion(generation: UUID) {
        #if DEBUG
        if smartAnalysisOverrideForTesting { return }
        #endif
        if smartCaptureAnalysisAllowed { refreshSmartRecommendationRange() }
        guard smartCaptureAnalysisAllowed, generation == smartCaptureGeneration,
              !smartAnalysisInFlight, !smartFramingInProgress, camera.preview != nil else {
            if !smartCaptureAnalysisAllowed {
                interruptSmartFraming(); smartSuggestion = nil; smartCompositionGuide = nil; smartCompositionCandidates = []
                smartTrackingEpoch = UUID(); smartCompositionStabilizer.reset()
            }
            return
        }
        let context = smartContext, look = effectiveCaptureLook, recommendationsAllowed = smartRecommendationRangeAllowed
        let trackingEpoch = smartTrackingEpoch
        let tracker = smartSubjectTracker, sceneState = smartSceneAnalysisState
        let trackingContext = "\(generation)|\(smartTrackingEpoch)|\(context)"
        let aspect = look.landscape ? 1/look.ratio.portraitRatio : look.ratio.portraitRatio
        let readings = camera.readings
        let active = activePhotoSubmode
        smartAnalysisInFlight = true
        #if DEBUG
        let requestedAt = CACurrentMediaTime()
        #endif
        camera.readSmartAnalysisPreview { [weak self] neutral in
            guard let self else { return }
            guard let source = neutral, self.smartCaptureGeneration == generation, self.smartCaptureAnalysisAllowed else {
                self.smartAnalysisInFlight = false; return
            }
            self.smartCaptureQueue.async { [weak self] in
            #if DEBUG
            let processingStarted = CACurrentMediaTime()
            #endif
            guard let image = SmartCaptureAnalyzer.visibleImage(source,aspect:aspect) else {
                DispatchQueue.main.async { self?.smartAnalysisInFlight = false }; return
            }
            guard let self else { return }
            let detected = sceneState.context != trackingContext
                || CACurrentMediaTime() - sceneState.timestamp >= 0.8 || sceneState.result == nil
            let analysis: SmartCaptureResult
            if detected {
                analysis = SmartCaptureAnalyzer.analyze(image:image,readings:readings,activeSubmode:active,
                    nominateComposition: recommendationsAllowed && !tracker.hasTrackedTargets(context: trackingContext))
                sceneState.context = trackingContext
                sceneState.timestamp = CACurrentMediaTime()
                sceneState.result = analysis
            } else { analysis = sceneState.result! }
            let tracked = recommendationsAllowed ? image.cgImage.map { tracker.update(image:$0,candidates:detected ? analysis.candidates : [],context:trackingContext) } : nil
            #if DEBUG
            let processingSeconds = CACurrentMediaTime() - processingStarted
            #endif
            let result = SmartCaptureResult(suggestion:analysis.suggestion,composition:tracked?.selected,hasPerson:analysis.hasPerson,candidates:tracked?.candidates ?? [])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.smartAnalysisInFlight = false
                guard self.smartCaptureAnalysisAllowed, self.smartContext == context,
                      self.smartCaptureGeneration == generation, self.smartTrackingEpoch == trackingEpoch else { return }
                #if DEBUG
                self.smartTrackingSamplesForTesting.append(.init(publishedAt:CACurrentMediaTime(),
                    requestToPublication:CACurrentMediaTime()-requestedAt,processingSeconds:processingSeconds,
                    detectedScene:detected,verifiedCandidates:result.candidates.filter(\.trackingVerified).count,
                    displayedCandidates:result.candidates.count,retainedCandidates:tracked?.retainedCount ?? 0,
                    recommendationsAllowed:recommendationsAllowed,objectTrackedCandidates:tracked?.objectTrackedCount ?? 0,
                    appearanceVerifiedCandidates:tracked?.appearanceVerifiedCount ?? 0))
                if self.smartTrackingSamplesForTesting.count > 120 { self.smartTrackingSamplesForTesting.removeFirst() }
                #endif
                self.publishSmartComposition(result.composition,candidates:result.candidates)
                if let cg = image.cgImage {
                    self.requestSmartAIAdvice(image:cg,candidates:result.candidates,trackingContext:trackingContext,
                                              context:context,generation:generation)
                }
                // 建议抑制和人物离开计数只跟随真实场景检测，关闭建议也不暂停点位跟踪。
                guard detected, CACurrentMediaTime() >= self.smartSuggestionPausedUntil else { return }
                let suggestion = self.presentedSmartSuggestion(result.suggestion)
                let signature = suggestion.map { suggestion in
                    let target = result.composition.map { "\(Int($0.target.x * 10)):\(Int($0.target.y * 10))" } ?? "-"
                    return "\(suggestion.kind.rawValue)|\(result.hasPerson)|\(target)"
                }
                self.smartCurrentSceneSignature = signature
                if self.portraitAutoEnabledBySmartCapture && self.portraitModeEnabled {
                    // 从A切到M后只作参考，不因人物离开而自动改动人像拍摄状态。
                    guard self.mode == .auto else { self.smartPortraitMissingChecks = 0; self.smartSuggestion = nil; return }
                    if result.hasPerson {
                        self.smartPortraitMissingChecks = 0
                    } else {
                        self.smartPortraitMissingChecks += 1
                        if self.smartPortraitMissingChecks >= 2, !self.camera.capturing {
                            self.portraitAutoEnabledBySmartCapture = false
                            self.smartPortraitMissingChecks = 0
                            if self.portraitModeEnabled { self.togglePortraitMode() }
                        }
                    }
                    self.smartSuggestion = nil
                    return
                }
                if let suppressed = self.suppressedSmartSuggestionSignature {
                    if signature == suppressed {
                        self.suppressedSuggestionMissingChecks = 0
                        self.smartSuggestion = nil
                    } else if signature != nil {
                        self.suppressedSmartSuggestionSignature = nil
                        self.suppressedSuggestionMissingChecks = 0
                        self.smartSuggestion = suggestion
                    } else {
                        // The scene no longer matches any recommendation. Two
                        // stable misses count as a scene change; a later scene
                        // with the same kind is then a new recommendation.
                        self.suppressedSuggestionMissingChecks += 1
                        if self.suppressedSuggestionMissingChecks >= 2 {
                            self.suppressedSmartSuggestionSignature = nil
                            self.suppressedSuggestionMissingChecks = 0
                        }
                        self.smartSuggestion = nil
                    }
                } else if self.smartSuggestion != suggestion {
                    self.smartSuggestion = suggestion
                }
            }
        }
        }
    }

    @Published private(set) var virtualApertureEnabled = false
    @Published private(set) var isAdjustingDepthControl = false
    @Published var virtualApertureSliderVisible = false {
        didSet {
            if virtualApertureSliderVisible { scheduleSliderAutoHide() }
            else if !portraitDepthSliderVisible { cancelSliderAutoHide() }
        }
    }
    var depthControlPopupVisible: Bool {
        captureKind == .photo && toolPage == 0 && !popupVisible && toolbarPanel == nil && panel == nil
            && !settings && !review
            && ((virtualApertureEnabled && virtualApertureSliderVisible)
                || (portraitModeEnabled && portraitDepthSliderVisible))
    }

    func dismissDepthControls() {
        cancelSliderAutoHide()
        isAdjustingDepthControl = false
        portraitDepthSliderVisible = false
        virtualApertureSliderVisible = false
        setFilterParameterEditing(false)
    }

    private var sliderAutoHideTask: Task<Void, Never>?
    @Published var virtualAperture = VirtualApertureRenderer.defaultValue {
        didSet {
            let safe = VirtualApertureRenderer.clamped(virtualAperture)
            if virtualAperture != safe { virtualAperture = safe; return }
            // 连拖只更新轻量look；导航能力由开关/路由变更刷新，避免每次滑动重复提交配置。
            camera.updateLook(effectiveCaptureLook, photoFormat: photoFormat); scheduleCaptureStateSave()
            if virtualApertureSliderVisible { scheduleSliderAutoHide() }
        }
    }
    var virtualAperturePosition: Double {
        get { VirtualApertureRenderer.position(for: virtualAperture) }
        set { virtualAperture = VirtualApertureRenderer.value(at: newValue) }
    }
    var virtualApertureText: String { VirtualApertureRenderer.label(virtualAperture) }
    private func cancelSliderAutoHide() {
        sliderAutoHideTask?.cancel()
        sliderAutoHideTask = nil
    }

    private func scheduleSliderAutoHide() {
        cancelSliderAutoHide()
        guard !isAdjustingDepthControl, portraitDepthSliderVisible || virtualApertureSliderVisible else { return }
        sliderAutoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            withAnimation(AppTheme.popupAnimation) {
                self.isAdjustingDepthControl = false
                self.portraitDepthSliderVisible = false
                self.virtualApertureSliderVisible = false
                self.setFilterParameterEditing(false)
            }
            self.cancelSliderAutoHide()
        }
    }

    func setDepthControlEditing(_ editing: Bool) {
        isAdjustingDepthControl = editing
        if portraitDepthSliderVisible || virtualApertureSliderVisible { scheduleSliderAutoHide() }
    }

    func noteSliderInteraction() {
        if portraitDepthSliderVisible || virtualApertureSliderVisible { scheduleSliderAutoHide() }
    }

    func toggleVirtualApertureSlider() {
        // 照片工具栏与视频侧边入口共用展开动作；视频录制中仍可调整渲染强度。
        guard virtualApertureEnabled, !camera.capturing, (!camera.videoBusy || camera.videoRecording) else { return }
        let opening = !virtualApertureSliderVisible
        closePopups()
        cameraImpactFeedback(.light)
        withAnimation(AppTheme.popupAnimation) { virtualApertureSliderVisible = opening }
    }

    /// 点按数值恢复默认；已经是默认值时不重复反馈或提交渲染。
    func resetVirtualAperture() {
        guard virtualApertureEnabled, !camera.capturing, !camera.videoBusy, !camera.macroActive,
              abs(virtualAperture - VirtualApertureRenderer.defaultValue) > 0.000001 else { return }
        cameraSelectionFeedback()
        virtualAperture = VirtualApertureRenderer.defaultValue
    }
    func toggleVirtualAperture() {
        if smartCaptureEnabled {
            smartCaptureEnabled = false
            stopSmartCaptureAnalysis()
            adaptiveHighDynamic = false
        }
        guard camera.ready, !camera.capturing, !camera.videoBusy, photoSubmodePreparing == nil,
              videoSubmodePreparing == nil, !camera.dualCapturePreparing else { return }
        if camera.dualCaptureEnabled {
            camera.setDualCaptureEnabled(false) { [weak self] success in
                guard let self, success else { return }
                self.restoreVideoSettingsAfterDualCapture(); self.toggleVirtualAperture()
            }
            return
        }
        if captureKind == .video && !virtualApertureEnabled { disableFrontVideoCenteringForManualChoice() }
        cameraSelectionFeedback()
        if virtualApertureEnabled {
            virtualApertureEnabled = false
            virtualApertureSliderVisible = false
        } else {
            guard VirtualApertureRenderer.available else { camera.message = "星芒处理暂不可用，请重新启动应用。"; return }
            if captureKind == .photo {
                if let active = activePhotoSubmode { setPhotoSubmode(active, enabled: false) }
                // 软件效果不能写入原始DNG；照片沿用可处理格式与原曝光值。
                if photoFormat == .raw || photoFormat == .rawJPEG { photoFormat = camera.availablePhotoFormats.contains(.heif) ? .heif : .jpeg }
                livePhotoEnabled = false
            } else {
                // 复用现有SDR/P3逐帧处理后一次编码；其他子模块及RAW/Log等先回到兼容默认规格。
                let needsDefault = timeLapseEnabled || slowMotionEnabled || cinematicVideoEnabled || !videoFiltersEnabled
                videoSubmodeRequest = UUID(); compatibleSubmodeLensIDs = nil
                timeLapseEnabled = false; slowMotionEnabled = false; cinematicVideoEnabled = false
                selectedSlowMotionCaptureRate = nil
                if needsDefault {
                    restoringVideoSettings = true
                    videoResolution = .hd1080; videoFrameRate = .fps30; videoColorSpace = .sdr
                    videoCodec = .hevc; videoOpenGateEnabled = false
                    if !VideoRatio.aspectOptions.contains(videoRatio) { videoRatio = .ratio16x9 }
                    restoringVideoSettings = false
                }
                synchronizeVideoSettings()
            }
            virtualApertureEnabled = true
            virtualApertureSliderVisible = false
            if let current = camera.lenses.first(where: { $0.id == camera.selectedLens }), !supportsVirtualApertureLens(current),
               let main = camera.lenses.first(where: { $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera && abs($0.displayZoom - 1) < 0.01 }) {
                selectFocalLength(main)
            }
        }
        withAnimation(AppTheme.popupAnimation) { shootingModes = false }
        refreshSubmodeLensCompatibility(); updateLook(); scheduleCaptureStateSave()
    }
    private func supportsVirtualApertureLens(_ lens: CameraLens) -> Bool {
        lens.device.position == .back && [.builtInWideAngleCamera, .builtInTelephotoCamera].contains(lens.device.deviceType)
    }

    func selectSlowShutterPreset(_ preset: SlowShutterPreset) {
        guard slowShutterEnabled, captureKind == .photo, mode == .auto, !camera.videoBusy,
              slowShutterSequence == nil, !slowShutterComposing,
              isSlowShutterPresetSupported(preset) else { return }
        cameraSelectionFeedback()
        if selectedSlowShutterPreset == preset {
            selectedSlowShutterPreset = nil
            slowShutterAutomaticPreset = nil
            slowShutterAutomaticDuration = .s1
            if mode == .auto { slowShutterDuration = .s1 }
            applySlowShutterExposurePolicy()
            scheduleHardwareControlsUpdate()
            scheduleCaptureStateSave()
            return
        }
        selectedSlowShutterPreset = preset
        slowShutterDuration = preset.defaultCaptureDuration
        // 先启用短曝光预览，再更新手动值，避免先提交长曝光又立即切回自动预览。
        applySlowShutterExposurePolicy()
        if mode == .manual {
            applySlowShutterPresetToManualExposure(preset, resetToSuggestion: true)
        }
        scheduleHardwareControlsUpdate()
    }

    private func applySlowShutterPresetToManualExposure(_ preset: SlowShutterPreset, resetToSuggestion: Bool) {
        if preset.sequenceSpec != nil {
            // 五种预设的M挡自动曝光都可自适应；手动值在该预设允许范围内保留，不强行套建议值。
            parameter = .shutter
            if manualExposure {
                let shutterRange = slowShutterShutterRange
                let isoRange = slowShutterISORange
                shutter = min(max(shutter, shutterRange.lowerBound), shutterRange.upperBound)
                iso = min(max(iso, isoRange.lowerBound), isoRange.upperBound)
                applyExposure()
            }
            return
        }
        let shutterRange = preset.shutterRange(limitedTo: camera.shutterRange) ?? preset.shutterLog2Range
        let isoRange = preset.isoRange(limitedTo: camera.isoRange) ?? preset.suggestedISORange
        manualExposure = true
        if resetToSuggestion {
            shutter = min(max(log2(preset.suggestedShutterSeconds), shutterRange.lowerBound), shutterRange.upperBound)
            iso = min(max(preset.suggestedISO, isoRange.lowerBound), isoRange.upperBound)
        } else {
            shutter = min(max(shutter, shutterRange.lowerBound), shutterRange.upperBound)
            iso = min(max(iso, isoRange.lowerBound), isoRange.upperBound)
        }
        parameter = .shutter
        applyExposure()
    }

    private func clearSlowShutterMode() {
        // 合成在后台仍属于未完成的慢门任务；关闭模式也必须使其结果失效。
        if slowShutterSequence != nil || slowShutterComposing { cancelSlowShutterSequence() }
        slowShutterEnabled = false
        selectedSlowShutterPreset = nil
        slowShutterAutomaticPreset = nil
        slowShutterAutomaticDuration = .s1
        camera.setSlowShutterPreviewOptimization(false)
        camera.setAutomaticExposureDurationLimit(nil)
    }

    private func applySlowShutterExposurePolicy() {
        // 序列独占已锁定的曝光；输入切换发布能力时不得重新套用 A 挡自动曝光策略。
        guard slowShutterSequence == nil else { return }
        camera.setSlowShutterPreviewOptimization(
            captureKind == .photo && slowShutterEnabled)
        guard captureKind == .photo, slowShutterEnabled, mode == .auto,
              let preset = selectedSlowShutterPreset else {
            camera.setAutomaticExposureDurationLimit(nil)
            return
        }
        // A mode keeps ISO automatic and gives AE a preset-specific maximum duration.
        // In bright scenes, the system remains free to choose a shorter exposure.
        camera.setAutomaticExposureDurationLimit(preset.shutterSeconds.upperBound)
    }

    @Published private(set) var nightModeEnabled = false
    @Published private(set) var nightCaptureRuntimeUnavailable = false
    /// 用户侧固定三帧；保留可变属性供内部诊断覆盖，不再读写旧实验设置。
    @Published var independentNightProfile: IndependentNightProfile = .standard
    @Published var nightHDRPhotoEnabled = false
    /// 实验用：跳过环境触发，开启夜景就进入独立夜景，便于逐项试拍；不持久化，重启自动关闭。
    @Published var forceIndependentNightEnabled = false {
        didSet { syncIndependentNightRoute() }
    }
    @Published private(set) var nightEnvironmentTriggered = false
    private var nightEnvironmentGate = NightCaptureEnvironmentGate()

    @Published private(set) var portraitModeEnabled = false {
        didSet {
            let transitionID = portraitPreviewTransitionID
            portraitPreviewTransitionID = nil
            camera.setPortraitCaptureEnabled(portraitModeEnabled, transitionID: transitionID)
            if portraitModeEnabled { livePhotoEnabled = false }
            if !portraitModeEnabled { portraitDepthSliderVisible = false }
            synchronizePortraitPreview()
        }
    }
    @Published var portraitBlurStrength = 0.5 {
        didSet {
            let normalized = PortraitPhotoRenderer.normalizedStrength(portraitBlurStrength)
            if portraitBlurStrength != normalized {
                portraitBlurStrength = normalized
                return
            }
            synchronizePortraitPreview()
            if !restoringCaptureState { scheduleCaptureStateSave() }
            if portraitDepthSliderVisible { scheduleSliderAutoHide() }
        }
    }
    @Published var portraitDepthSliderVisible = false {
        didSet {
            synchronizePortraitPreview()
            if portraitDepthSliderVisible { scheduleSliderAutoHide() }
            else if !virtualApertureSliderVisible { cancelSliderAutoHide() }
        }
    }

    private func synchronizePortraitPreview() {
        // 系统虚拟多摄进入微距时不运行人像预览分割，避免隐藏的景深滑块仍消耗相机处理资源。
        let macroActive = mode == .auto && camera.macroActive
        // 人像取景不依赖滑块是否展开，收起滑块时仍保持所选虚化，避免画面突然变清晰。
        let enabled = portraitModeEnabled && captureKind == .photo
            && cameraActiveRequested && camera.ready && !macroActive
        camera.setPortraitPreview(enabled: enabled, blurStrength: portraitBlurStrength)
    }

    func togglePortraitDepthSlider() {
        // 微距期间也允许打开滑杆；预览分割仍由 synchronizePortraitPreview 暂停。
        guard portraitModeEnabled, captureKind == .photo, !camera.capturing else { return }
        let opening = !portraitDepthSliderVisible
        closePopups()
        cameraImpactFeedback(.light)
        withAnimation(AppTheme.popupAnimation) { portraitDepthSliderVisible = opening }
    }

    func dismissPortraitDepthSliderForMacro() {
        guard mode == .auto, camera.macroActive, portraitDepthSliderVisible else { return }
        withAnimation(AppTheme.popupAnimation) { portraitDepthSliderVisible = false }
    }

    var portraitUnavailableReason: String? {
        guard captureKind == .photo else { return "仅照片模式可用" }
        guard camera.ready else { return "相机准备中" }
        guard camera.supportsPortraitCapture else { return "当前镜头不支持人像深度效果" }
        guard !Set(camera.availablePhotoFormats).intersection(
            PortraitCapturePolicy.availableFormats(proRAWAvailable: camera.supportsProRAW)
        ).isEmpty else {
            return "当前镜头没有兼容的人像照片格式"
        }
        return nil
    }

    func togglePortraitMode() {
        smartPortraitPendingRequest = nil
        portraitAutoEnabledBySmartCapture = false
        togglePhotoSubmode(.portrait)
    }

    private func reconcilePortraitMode() {
        guard portraitModeEnabled, captureKind == .photo, camera.ready, !camera.supportsPortraitCapture else { return }
        portraitModeEnabled = false
        synchronizeLiveAudio()
    }

    private var portraitPreviewTransitionID: UUID?

    /// 人像开关会更新照片输出图；保留旧预览帧，并在新帧到达后淡出，遮住配置期间的黑帧。
    private func preparePortraitPreviewTransition() {
        startFocalTransition(fadeDuration: 0.14)
        portraitPreviewTransitionID = camera.ready && camera.preview != nil ? focalTransitionID : nil
    }

    private func reconcilePortraitParameters() {
        guard portraitModeEnabled else { return }
        if !PortraitCapturePolicy.supports(format: photoFormat, resolution: photoResolution, live: false,
                                            hdr: hdr, proRAWAvailable: camera.supportsProRAW)
            || !camera.availablePhotoFormats.contains(photoFormat) {
            photoFormat = camera.availablePhotoFormats.contains(.heif) ? .heif : .jpeg
        }
        if hdr { hdr = false }
        if livePhotoEnabled { livePhotoEnabled = false }
    }

    var nightUnavailableReason: String? {
        guard captureKind == .photo else { return "仅照片模式可用" }
        guard !portraitModeEnabled else { return "人像模式开启时不可用" }
        guard camera.ready else { return "相机准备中" }
        guard camera.supportsNightCapture else { return "当前镜头不支持三帧曝光包围" }
        guard NightCapturePolicy.supportedFormats.contains(photoFormat), camera.availablePhotoFormats.contains(photoFormat) else { return "夜景合成仅支持 JPG／HEIF" }
        guard photoResolution == .standard else { return "夜景合成仅支持标准分辨率" }
        guard !livePhotoEnabled else { return "Live 开启时夜景合成不可用" }
        guard !hdr else { return "HDR 开启时夜景合成不可用" }
        guard timerSeconds == 0, countdown == nil else { return "倒计时开启时夜景合成不可用" }
        guard flashMode == .off else { return "闪光灯开启时夜景合成不可用" }
        guard !burstModeEnabled, !burstCaptureActive else { return "连拍时夜景合成不可用" }
        guard NightCapturePolicy.supports(format: photoFormat, resolution: photoResolution,
                                          live: livePhotoEnabled, hdr: hdr,
                                          timerSeconds: timerSeconds, manualMode: mode == .manual,
                                          flashMode: flashMode,
                                          maximumBracketedCapturePhotoCount: camera.supportsNightCapture ? NightCapturePolicy.frameCount : 0) else {
            return "当前拍摄参数不支持夜景合成"
        }
        return nil
    }

    var nightCaptureAvailable: Bool {
        nightCaptureEligible && nightEnvironmentTriggered
    }

    private var nightCaptureEligible: Bool {
        nightModeEnabled && !nightCaptureRuntimeUnavailable && nightUnavailableReason == nil
    }

    var nightIndicatorState: NightIndicatorState {
        NightIndicatorState.resolve(isEnabled: nightModeEnabled,
                                    captureSupported: !nightCaptureRuntimeUnavailable && nightUnavailableReason == nil,
                                    environmentTriggered: nightEnvironmentTriggered)
    }

    func toggleNightMode() {
        if !nightModeEnabled, mode != .auto { setMode(.auto) }
        guard !nightModeEnabled || mode == .auto else { return }
        togglePhotoSubmode(.night)
    }

    private func reconcileNightMode() {
        syncIndependentNightRoute()
        if captureKind != .photo {
            nightModeEnabled = false
            nightCaptureRuntimeUnavailable = false
        } else if nightCaptureRuntimeUnavailable && nightUnavailableReason == nil {
            // A route or setting change can make the previously rejected capture valid again.
            nightCaptureRuntimeUnavailable = false
        }
        if !nightCaptureEligible { resetNightEnvironmentGate() }
    }

    var showsNightIndicator: Bool { nightModeEnabled }
    var nightIndicatorIsSupported: Bool {
        nightIndicatorState == .waitingForLowLight || nightIndicatorState == .triggered
    }
    var nightIndicatorIsTriggered: Bool { nightIndicatorState == .triggered }

    #if DEBUG
    /// 测试注入“环境已触发”，用于验证触发后才会启用的独立夜景路线。
    func forceNightEnvironmentTriggeredForTesting(_ triggered: Bool) {
        nightEnvironmentTriggered = triggered
        syncIndependentNightRoute()
    }
    #endif

    private func resetNightEnvironmentGate() {
        nightEnvironmentGate.reset()
        nightEnvironmentTriggered = false
        syncIndependentNightRoute()
    }

    private func updateNightEnvironment(_ readings: CameraReadings?) {
        guard nightCaptureEligible, let readings else {
            resetNightEnvironmentGate()
            return
        }
        nightEnvironmentTriggered = nightEnvironmentGate.update(
            iso: readings.iso,
            seconds: readings.seconds,
            exposureBiasEV: NightManualExposurePolicy.meteringBias(userBias:ev,
                customExposure:readings.customExposure,offsetEV:readings.exposureTargetOffsetEV) ?? .nan
        )
        syncIndependentNightRoute()
    }

    /// 独立夜景必须同时满足：用户开启夜景、环境已触发、照片模式且A挡。
    private func syncIndependentNightRoute() {
        camera.setIndependentNightModeActive(nightModeEnabled && captureKind == .photo
            && mode == .auto && (nightEnvironmentTriggered || forceIndependentNightEnabled))
    }

    private func exitNightModeBecauseCaptureBecameUnavailable() {
        guard nightModeEnabled else { return }
        nightCaptureRuntimeUnavailable = true
        resetNightEnvironmentGate()
    }

    var burstUnavailableReason: String? {
        guard captureKind == .photo else { return "仅限照片模式" }
        guard !portraitModeEnabled else { return "人像模式开启时不可用" }
        guard camera.availablePhotoFormats.contains(photoFormat), PhotoBurstPolicy.supportedFormats.contains(photoFormat) else {
            return "仅支持 JPG／HEIF"
        }
        guard photoResolution == .standard else { return "仅支持 12MP" }
        guard !hdr && !photoOptions.usesHDRHEIF else { return "关闭 HDR 后可用" }
        guard !livePhotoEnabled else { return "关闭 Live 后可用" }
        guard timerSeconds == 0 && countdown == nil else { return "请先关闭倒计时" }
        return nil
    }

    func canSelectPhotoFormat(_ format: PhotoFileFormat) -> Bool {
        captureKind == .photo && photoSubmodePreparing == nil && camera.availablePhotoFormats.contains(format)
            && (!virtualApertureEnabled || (format != .raw && format != .rawJPEG))
            && (!burstModeEnabled || PhotoBurstPolicy.supportedFormats.contains(format))
            && (!nightModeEnabled || NightCapturePolicy.supportedFormats.contains(format))
            && (!portraitModeEnabled || PortraitCapturePolicy.supports(
                format: format, resolution: photoResolution, live: false, hdr: hdr,
                proRAWAvailable: camera.supportsProRAW
            ))
    }

    private func synchronizeHighResolutionPhotoRoute() {
        let requested = captureKind == .photo
            && photoResolution == .high && currentPosition == .back
        camera.setHighResolutionPhotoRequested(requested)
    }

    func canSelectPhotoResolution(_ resolution: PhotoResolution) -> Bool {
        captureKind == .photo && photoSubmodePreparing == nil && camera.availableResolutions.contains(resolution)
            && (resolution != .high || mode == .manual)
            && (resolution != .high || currentPosition == .back)
            && (resolution != .high || !hdr || photoFormat != .heif || camera.supportsHighResolutionHEIFHDR)
            && (!burstModeEnabled || resolution == .standard)
            && (!nightModeEnabled || resolution == .standard)
            && (!portraitModeEnabled || PortraitCapturePolicy.supports(
                format: photoFormat, resolution: resolution, live: false, hdr: hdr,
                proRAWAvailable: camera.supportsProRAW
            ))
    }

    func toggleBurstMode() {
        togglePhotoSubmode(.burst)
    }

    func startBurstCapture() {
        guard burstModeEnabled, !burstCaptureActive, burstUnavailableReason == nil,
              camera.ready, !camera.videoBusy else { return }
        burstCaptureActive = true
        cameraImpactFeedback(.medium)
        let request = UUID()
        burstCaptureRequest = request
        burstCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.burstCaptureActive && self.burstCaptureRequest == request {
                guard self.camera.ready, self.captureKind == .photo, self.burstUnavailableReason == nil else { break }
                // 连拍只保留一张在飞；否则松手时队列里还会残留多张，
                // 用户感知为“松开快门后仍在连拍”。
                if !self.camera.shutterBusy,
                   self.camera.pendingPhotoCount == 0,
                   self.camera.hasCaptureCapacity(for: self.photoOptions),
                   self.library.canAcceptNewCapture {
                    self.camera.capture(flashMode: self.flashMode, options: self.photoOptions)
                }
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { break }
            }
            if self.burstCaptureRequest == request {
                self.burstCaptureActive = false
                self.burstCaptureTask = nil
            }
        }
    }

    func stopBurstCapture() {
        burstCaptureRequest = UUID()
        burstCaptureActive = false
        burstCaptureTask?.cancel()
        burstCaptureTask = nil
    }

    private func reconcileBurstMode() {
        guard burstModeEnabled, burstUnavailableReason != nil else { return }
        stopBurstCapture()
        withAnimation(AppTheme.popupAnimation) { burstModeEnabled = false }
    }

    func toggleToolbarPanel(_ next: CameraToolbarPanel) {
        // 触感必须在任何状态/会话重配前触发，避免主线程负载或音频会话把这一次反馈吞掉。
        CameraHaptics.impact(.light)
        dismissDepthControls()
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            toolbarPanel = toolbarPanel == next ? nil : next
            functions = false; tools = false; shootingModes = false
            if panel == .manual { panel = nil }
        }
    }
    /// UIKit-backed paging can write its selection while SwiftUI is laying out the page.
    func updateToolPageFromPager(_ page: Int) {
        guard (0...1).contains(page) else { return }
        let request = UUID()
        pagerRequest = request
        guard page != toolPage else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pagerRequest == request, self.toolPage != page else { return }
            self.dismissDepthControls()
            self.toolPage = page
        }
    }

    /// UIKit may echo a slider value during SwiftUI layout. Defer real changes and drop stale writes.
    func updateAutomaticEVFromSlider(_ value: Double) {
        guard value.isFinite, mode == .auto, !camera.capturing else { return }
        let next = min(max(value, exposureCompensationRange.lowerBound), exposureCompensationRange.upperBound)
        let request = UUID()
        sliderEVRequest = request
        guard next != ev else { return }
        let previous = ev
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sliderEVRequest == request, self.mode == .auto,
                  !self.camera.capturing, self.ev == previous else { return }
            self.ev = next
            self.applyExposure()
        }
    }

    func selectRatio(_ next: FrameRatio) {
        guard FrameRatio.photoOptions.contains(next) else { return }
        guard ratio != next else { return }
        ratio = next
    }

    @Published var panel: CameraPanel?
    private typealias ManualSettings = SavedManualCaptureState
    private var savedManualSettings: ManualSettings?
    private var automaticEV = 0.0
    #if DEBUG
    var previewFrameForTesting = CGRect.zero
    var toolbarFrameForTesting = CGRect.zero
    var toolbarBackdropFrameForTesting = CGRect.zero
    var histogramFrameForTesting = CGRect.zero
    @Published var histogramFrame = CGRect.zero
    var recordingHUDFrameForTesting = CGRect.zero
    var levelFrameForTesting = CGRect.zero
    var logLUTInfoFrameForTesting = CGRect.zero
    var logLUTTitleFrameForTesting = CGRect.zero
    var popupFrameForTesting: CGRect = .zero
    var filterDialPadFrameForTesting: CGRect = .zero
    var captureButtonFramesForTesting: [String: CGRect] = [:]

    /// 为界面回归构造“人像开启、景深滑块打开”的状态，无需启动真实人像拍摄流。
    func setPortraitDepthControlsForTesting(enabled: Bool, sliderVisible: Bool) {
        portraitModeEnabled = enabled
        portraitDepthSliderVisible = sliderVisible
    }

    func setVirtualApertureControlsForTesting(enabled: Bool, sliderVisible: Bool) {
        virtualApertureEnabled = enabled
        virtualApertureSliderVisible = sliderVisible
    }

    #endif
    @Published var mode = CameraShootingMode.auto {
        didSet {
            if mode != .manual && photoResolution == .high {
                photoResolution = .standard
            }
            reconcileNightMode()
        }
    }
    @Published var toolPage = 0
    @Published var functions = false
    @Published var tools = false
    @Published var shootingModes = false
    @Published var zoomDialVisible = false
    private var videoZoomAutoHideTask: Task<Void, Never>?
    var hidesFocalStripForZoomDial: Bool { zoomDialVisible }
    @Published private(set) var resumeTransitionImage: UIImage?
    @Published private(set) var resumeTransitionOpacity = 1.0
    private var resumeTransitionRequest = UUID()
    private var resumeTransitionFinishing = false
    @Published private(set) var focalTransitionImage: UIImage?
    @Published private(set) var focalTransitionOpacity = 1.0
    @Published private(set) var focalTransitionBlur = 0.0
    private var focalTransitionID = UUID()
    private var awaitingFocalFrame = false
    private var focalFadeDuration: TimeInterval = 0.18
    private var zoomDragOrigin: CGFloat?
    private var zoomDragTranslation: CGFloat = 0
    private var previewPinchOrigin: CGFloat?
    private var lastZoomDetentFeedback: TimeInterval = 0

    var previewPinchActive: Bool { previewPinchOrigin != nil }

    func updateFrontFramingForOrientation(isLandscape: Bool) {
        guard !camera.demo, !camera.dualCaptureEnabled, !camera.dualCapturePreparing else { return }
        if captureKind == .video, currentPosition == .front { lastAppliedFrontOrientation = isLandscape; return }
        if frontVideoCenteringRequested { lastAppliedFrontOrientation = isLandscape; return }
        guard currentPosition == .front else {
            lastAppliedFrontOrientation = nil
            return
        }
        // 用户通过宽高比明确选择横幅时，保留其广角构图；方向自动构图不能抢走该选择。
        if captureKind == .photo && camera.frontPhotoLandscapeEnabled {
            lastAppliedFrontOrientation = isLandscape
            return
        }
        guard camera.ready, !camera.capturing, !camera.videoBusy, !camera.videoRecording,
              lastAppliedFrontOrientation != isLandscape else { return }
        let desiredFraming = FrontCameraFramingPolicy.target(isLandscape: isLandscape)
        guard let selected = camera.lenses.first(where: { $0.id == camera.selectedLens }) else { return }
        if selected.frontFraming == desiredFraming {
            lastAppliedFrontOrientation = isLandscape
            return
        }
        guard let target = camera.lenses.first(where: {
            $0.device.position == .front && $0.frontFraming == desiredFraming
        }), canSelectFocalLength(target) else { return }
        lastAppliedFrontOrientation = isLandscape
        startFocalTransition(fadeDuration: 0.14)
        camera.selectLens(target, transitionID: focalTransitionID, preservingFrontAutoCentering: true)
    }

    func selectFocalLength(_ lens: CameraLens) {
        cancelFocus()
        guard camera.ready, !camera.capturing, (!camera.videoBusy || camera.videoRecording), canSelectFocalLength(lens) else { return }
        if captureKind == .video && camera.videoRecording && !camera.dualCaptureEnabled {
            var target = lens.displayZoom
            if (mode == .auto || mode == .manual || fixedCinematicFocalsOnly), lens.device.position == .back, abs(lens.displayZoom - 1) < 0.001, camera.selectedLens == lens.id {
                target = nextMainFocalZoom()
            }
            zoomSelectionFeedback()
            camera.setContinuousZoom(target, smooth: true)
            endZoomDial()
            return
        }
        if photoResolution == .high {
            // 48MP仅在三个受支持原生焦段切换；当前1×不执行24/35mm轮换。
            if camera.selectedLens == lens.id && abs(camera.currentZoom-lens.displayZoom) < 0.015 { return }
        }
        // 视频前置固定超广角，不再接受焦段/超广角切换；人物追踪内部直接选广角。
        if captureKind == .video, lens.device.position == .front { return }
        // 人物追踪已经强制使用前置超广角；再次点同一个“超广角”不能先关追踪再重配。
        if lens.device.position == .front, camera.selectedLens == lens.id { return }
        camera.endSmartFocusHold()
        zoomSelectionFeedback()
        endZoomDial()
        if camera.dualCaptureEnabled {
            if !camera.dualCaptureMainIsFront, lens.device.position == .back {
                var target = lens.displayZoom
                if abs(lens.displayZoom - 1) < 0.001 {
                    target = nextMainFocalZoom()
                }
                dualMainFocalPreset = lens.displayZoom
                camera.setDualCaptureMainZoom(target)
                return
            }
        }
        // A deliberate front framing choice takes precedence over automatic composition,
        // including a tap on the framing currently recommended by the monitor.
        if lens.device.position == .front && camera.frontAutoCenteringEnabled {
            camera.setFrontAutoCentering(false)
        }
        if !fixedHighResolutionFocalsOnly, (mode == .auto || mode == .manual || fixedCinematicFocalsOnly || capturesLivePhoto), lens.device.position == .back, abs(lens.displayZoom - 1) < 0.001,
           camera.selectedLens == lens.id {
            startFocalTransition()
            camera.setContinuousZoom(nextMainFocalZoom(), transitionID: focalTransitionID)
            flash = false
            return
        }
        guard camera.selectedLens != lens.id || abs(camera.currentZoom - lens.displayZoom) > 0.001 else { return }
        startFocalTransition()
        camera.selectLens(lens, transitionID: focalTransitionID)
        flash = false
    }

    func toggleFrontPhotoAspectRatio() {
        guard captureKind == .photo, camera.ready, !camera.capturing, !camera.videoBusy,
              canToggleFrontPhotoAspectRatio else { return }
        zoomSelectionFeedback()
        endZoomDial()
        camera.toggleFrontPhotoWideAspect(selectedLensID:camera.selectedLens,displayZoom:camera.currentZoom)
    }

    private var mainFocalPresets: [CGFloat] { [1, 28.0 / 24.0, 35.0 / 24.0] }

    /// 24 → 28 → 35 → 24 mm，保持同一颗后置主摄，不切物理镜头。
    private func nextMainFocalZoom() -> CGFloat {
        let value = camera.currentZoom
        if abs(value - 1) < 0.02 { return 28.0 / 24.0 }
        if abs(value - 28.0 / 24.0) < 0.02 { return 35.0 / 24.0 }
        if abs(value - 35.0 / 24.0) < 0.02 { return 1 }
        if value < 28.0 / 24.0 { return 28.0 / 24.0 }
        if value < 35.0 / 24.0 { return 35.0 / 24.0 }
        return 1
    }

    private var mainFocalTitle: String? {
        let value = camera.currentZoom
        if abs(value - 1) < 0.02 { return "24mm" }
        if abs(value - 28.0 / 24.0) < 0.02 { return "28mm" }
        if abs(value - 35.0 / 24.0) < 0.02 { return "35mm" }
        return nil
    }

    func focalButtonTitle(for lens: CameraLens) -> String {
        if camera.dualCaptureEnabled, !camera.dualCaptureMainIsFront, lens.device.position == .back {
            guard camera.selectedLens == lens.id else { return lens.title }
            if abs(lens.displayZoom - 1) < 0.001 {
                return mainFocalTitle ?? zoomText
            }
            // 选中的最近固定档显示实际倍率，例如 2.6× 命中 2× 时显示 2.6×。
            return zoomText
        }
        if fixedHighResolutionFocalsOnly || (fixedCinematicFocalsOnly && abs(lens.displayZoom-1)>0.001) { return lens.title }
        guard camera.selectedLens == lens.id else { return lens.title }
        if (mode == .auto || mode == .manual || fixedCinematicFocalsOnly || capturesLivePhoto), lens.device.position == .back, abs(lens.displayZoom - 1) < 0.001,
           let title = mainFocalTitle { return title }
        return zoomText
    }

    func selectDemoFocalLength() {
        guard camera.ready, !camera.capturing else { return }
        zoomSelectionFeedback()
        endZoomDial()
        guard abs(camera.currentZoom - 1) > 0.001 else { return }
        startFocalTransition()
        camera.setContinuousZoom(1)
    }

    private func startFocalTransition(fadeDuration: TimeInterval = 0.18) {
        focalFadeDuration = fadeDuration
        focalTransitionID = UUID()
        let request = focalTransitionID
        focalTransitionImage = camera.preview
        focalTransitionOpacity = 1
        awaitingFocalFrame = focalTransitionImage != nil
        focalTransitionBlur = 0
        if !UIAccessibility.isReduceMotionEnabled {
            withAnimation(.easeOut(duration: 0.12)) { focalTransitionBlur = 2 }
        }
        // A failed switch must never leave a frozen snapshot over the live preview.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.focalTransitionID == request else { return }
            self.finishFocalTransition()
        }
    }

    private func finishFocalTransition() {
        guard awaitingFocalFrame else { return }
        awaitingFocalFrame = false
        let request = focalTransitionID
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.1 : focalFadeDuration
        withAnimation(.easeInOut(duration: duration)) { focalTransitionOpacity = 0 }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.02))
            guard let self, self.focalTransitionID == request else { return }
            self.focalTransitionImage = nil
        }
    }
    private var zoomDetents = ZoomDialDetents()
    private let zoomTickFeedback = UIImpactFeedbackGenerator(style: .light)
    private let zoomAnchorFeedback = UIImpactFeedbackGenerator(style: .medium)

    func zoomSelectionFeedback() {
        zoomAnchorFeedback.impactOccurred(intensity: 0.8)
        zoomAnchorFeedback.prepare()
    }
    var zoomText: String { String(format: "%.1f×", Double(camera.currentZoom)) }
    var zoomRange: ClosedRange<CGFloat> {
        if camera.dualCaptureEnabled {
            return camera.dualCaptureMainZoomRange ?? (camera.dualCaptureMainIsFront ? 1...1.6 : 1...8)
        }
        let base: ClosedRange<CGFloat> = camera.videoRecording ? (camera.videoRecordingZoomRange ?? camera.continuousZoomRange) : (camera.demo ? 1...5 : camera.continuousZoomRange)
        if fixedCinematicFocalsOnly {
            let lower = max(1,min(3,base.lowerBound)), upper = min(3,max(1,base.upperBound))
            return lower...max(lower,upper)
        }
        return virtualApertureEnabled ? min(max(1, base.lowerBound), base.upperBound)...base.upperBound : base
    }

    /// Maps pinch magnification to the same continuous zoom route used by the wheel and preset buttons.
    /// Rebasing at a device limit makes reversing the pinch respond immediately.
    func updatePreviewPinchZoom(scale: CGFloat) {
        guard !fixedHighResolutionFocalsOnly else { return }
        guard scale.isFinite, scale > 0 else { return }
        guard camera.ready, !camera.capturing, (!camera.videoBusy || camera.videoRecording), canAdjustCurrentLens, !zoomDialVisible,
              !focusLockPickerVisible, toolbarPanel == nil, panel == nil, !functions, !tools, !shootingModes else {
            finishPreviewPinchZoom()
            return
        }
        if previewPinchOrigin == nil {
            previewPinchOrigin = camera.currentZoom
            zoomDetents.reset(at: camera.currentZoom)
            zoomTickFeedback.prepare()
            zoomAnchorFeedback.prepare()
        }
        guard let origin = previewPinchOrigin else { return }
        let requested = origin * scale
        guard requested.isFinite, requested > 0 else { return }
        let target = min(max(requested, zoomRange.lowerBound), zoomRange.upperBound)
        applyZoomValue(target)
        if target != requested { previewPinchOrigin = target / scale }
        provideZoomDetentFeedback(for: target)
    }

    func finishPreviewPinchZoom() {
        previewPinchOrigin = nil
    }

    private func provideZoomDetentFeedback(for value: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        switch zoomDetents.move(to: value) {
        case .tick:
            guard now - lastZoomDetentFeedback >= 1.0 / 24 else { return }
            lastZoomDetentFeedback = now
            zoomTickFeedback.impactOccurred(intensity: 0.35)
            zoomTickFeedback.prepare()
        case .anchor:
            guard now - lastZoomDetentFeedback >= 1.0 / 32 else { return }
            lastZoomDetentFeedback = now
            zoomSelectionFeedback()
        case nil: break
        }
    }

    /// Opening from any focal button preserves the selected lens and current magnification.
    func openZoomDial() { beginZoomDial(at: camera.currentZoom) }

    private var canAdjustCurrentLens: Bool {
        // 双拍主副交换不改变单摄 selectedLens；连续变焦按当前主画面的有效范围开放。
        if camera.dualCaptureEnabled { return !camera.dualCapturePreparing && camera.dualCaptureMainZoomRange != nil }
        guard let lens = camera.lenses.first(where: { $0.id == camera.selectedLens }) else { return true }
        return canSelectFocalLength(lens)
    }

    func beginZoomDial(at value: CGFloat) {
        guard !fixedHighResolutionFocalsOnly else { return }
        guard !camera.dualCapturePreparing else { return }
        guard camera.ready, !camera.capturing, (!camera.videoBusy || camera.videoRecording), canAdjustCurrentLens else { return }
        guard zoomDragOrigin == nil else { return }
        videoZoomAutoHideTask?.cancel(); videoZoomAutoHideTask = nil
        cancelFocus()
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            functions = false; tools = false; shootingModes = false; panel = nil; toolbarPanel = nil
            zoomDialVisible = true
        }
        zoomDragOrigin = value
        zoomDragTranslation = 0
        zoomDetents.reset(at: value)
        zoomTickFeedback.prepare()
        zoomAnchorFeedback.prepare()
        applyZoomValue(value)
        scheduleZoomAutoHide()
    }
    func dragZoomDial(translation: CGFloat, width: CGFloat) {
        guard zoomDialVisible, let origin = zoomDragOrigin, translation.isFinite else { return }
        // Rebase at each event so overshooting a limit never creates a dead zone on reversal.
        let value = ContinuousZoomPolicy.draggedValue(origin: origin, translation: translation - zoomDragTranslation, width: width, range: zoomRange)
        zoomDragOrigin = value
        zoomDragTranslation = translation
        applyZoomValue(value)
        provideZoomDetentFeedback(for: value)
    }
    /// Finishes only this drag; the wheel remains available for the next gesture.
    func finishZoomDrag() {
        zoomDragOrigin = nil
        scheduleZoomAutoHide()
    }

    private func scheduleZoomAutoHide() {
        videoZoomAutoHideTask?.cancel(); videoZoomAutoHideTask = nil
        guard zoomDialVisible else { return }
        videoZoomAutoHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.zoomDialVisible, self.zoomDragOrigin == nil else { return }
            self.endZoomDial()
        }
    }
    func endZoomDial() {
        videoZoomAutoHideTask?.cancel(); videoZoomAutoHideTask = nil
        withAnimation(AppTheme.popupAnimation) { zoomDialVisible = false }
        zoomDragOrigin = nil
    }

    @Published var showHistogram = false {
        didSet {
            camera.enableHistogram(showHistogram)
            persistAuxiliaryPreferences()
        }
    }
    @Published var timerSeconds = 0 { didSet {
        if isPreparingSubmode, timerSeconds != oldValue { timerSeconds = oldValue; return }
        if (nightModeEnabled || burstModeEnabled) && timerSeconds != 0 { timerSeconds = 0; return }
        persistAuxiliaryPreferences(); reconcileBurstMode(); reconcileNightMode()
    } }
    @Published var countdown: Int? { didSet { reconcileNightMode() } }
    private var captureTask: Task<Void, Never>?
    private var countdownID = UUID()
    @Published var lastBackLensID: String?
    @Published var parameter = CameraParameter.ev
    /// 相机弹窗内的按钮不触发触感；设置页与拍照主界面不受影响。
    private var cameraPopupOpen: Bool {
        panel != nil || toolbarPanel != nil || functions || tools || shootingModes
    }
    private func cameraSelectionFeedback() {
        guard !cameraPopupOpen else { return }
        CameraHaptics.selectionChanged()
    }
    private func cameraImpactFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard !cameraPopupOpen else { return }
        CameraHaptics.impact(style)
    }
    private var manualModeSettleTask: Task<Void, Never>?
    private var manualModeRouteSettling = false
    @Published var manualExposure = false { didSet {
        if manualExposure && mode == .manual && fixedHighResolutionFocalsOnly {
            photoResolution = .standard
        }
    } }
    @Published var manualWB = false
    @Published var manualFocus = false
    @Published var iso = 100.0
    @Published var shutter = log2(1.0 / 125)
    @Published var whiteBalanceTint = 0.0
    @Published var wb = 5500.0
    @Published var focus = 0.5
    let exposureCompensationRange: ClosedRange<Double> = -5...5
    @Published var ev = 0.0
    @Published var review = false
    private(set) var reviewCapture = false
    private(set) var reviewVideoID: String?
    func openLibrary() {
        guard !review, !camera.videoBusy, !library.videoSaving else { return }
        closePopups()
        cancelCountdown()
        resumeTransitionRequest = UUID()
        resumeTransitionFinishing = false
        resumeTransitionImage = camera.preview
        resumeTransitionOpacity = 1
        gallery.refresh()
        reviewVideoID = library.consumeVideoReview()
        reviewCapture = reviewVideoID == nil && library.consumeCaptureReview()
        review = true
    }
    func presentSettings() { closePopups(); settings = true }
    func openParameter(_ next: CameraParameter) {
        guard displayedManualParameters.contains(next) else { return }
        closePopups()
        parameter = next
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            panel = .manual
        }
    }
    @Published var settings = false
    @Published var focusPoint: CGPoint?
    private var focusTask: Task<Void, Never>?


    init(camera: CameraEngine, library: PhotoLibraryViewModel, gallery: GalleryViewModel, filterSettings: FilterSettingsStore? = nil, preferencesStore: CapturePreferencesStore? = nil) {
        self.camera = camera
        self.library = library
        self.gallery = gallery
        self.preferencesStore = preferencesStore ?? CapturePreferencesStore()
        let initialPreferences = self.preferencesStore.load()
        self.preferences = initialPreferences
        camera.setVideoStabilizationPreference(initialPreferences.videoStabilization)
        self.filterSettings = filterSettings ?? FilterSettingsStore()
        dockKitTracking.$accessoryConnected.removeDuplicates().sink { [weak self] in
            self?.dockKitAccessoryConnected = $0
        }.store(in: &subscriptions)
        dockKitTracking.$trackingEnabled.removeDuplicates().sink { [weak self] in
            self?.dockKitTrackingEnabled = $0
        }.store(in: &subscriptions)
        dockKitTracking.$isUpdating.removeDuplicates().sink { [weak self] in
            self?.dockKitTrackingUpdating = $0
        }.store(in: &subscriptions)
        dockKitTracking.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            self?.camera.message = "云台追踪失败：\(message)"
        }.store(in: &subscriptions)
        camera.onSlowShutterSourceFrame = { [weak self] frame in
            self?.handleSlowShutterSourceFrame(frame)
        }
        camera.onCaptureDelivered = { [weak self] _ in
            guard let self, self.burstModeEnabled, self.captureKind == .photo else { return }
            self.burstCaptureCount += 1
        }
        camera.onVideoRouteFailure = { [weak self] message in
            guard let self, self.captureKind == .video else { return }
            self.cancelVideoEntryWatchdog()
            self.videoSubmodePreparing = nil
            self.videoSubmodeRequest = UUID()
            self.setVideoSubmode(.timeLapse, enabled: false)
            self.setVideoSubmode(.slowMotion, enabled: false)
            self.setVideoSubmode(.cinematic, enabled: false)
            // -11819/-11800 可能是前置切换后的瞬时系统错误；首次失败自动重建会话并重试视频，
            // 不立刻把用户踢回照片。连续第二次失败才显示错误并退出。
            #if DEBUG
            print("VIDEO-ROUTE-FAIL retries=\(self.videoRouteFailureRetries) message=\(message) kind=\(self.captureKind) front=\(self.currentPosition == .front)")
            #endif
            if self.videoRouteFailureRetries == 0 {
                self.videoRouteFailureRetries = 1
                self.camera.message = nil
                self.camera.retrySessionRecovery()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for _ in 0..<160 {
                        if self.camera.ready, !self.camera.recoveringSession, !self.camera.videoConfiguring { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard self.captureKind == .video, self.camera.ready,
                          !self.camera.recoveringSession, !self.camera.videoConfiguring else {
                        self.camera.message = message
                        return
                    }
                    self.camera.setVideoMode(true)
                    self.synchronizeVideoSettings()
                    self.scheduleVideoEntryWatchdog()
                    // 恢复成功且重新进入视频后清零；否则一次旧失败会永久占掉后续重试机会。
                    for _ in 0..<120 {
                        if self.camera.ready, !self.camera.recoveringSession, !self.camera.videoConfiguring { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if self.captureKind == .video, self.camera.ready,
                       !self.camera.recoveringSession, !self.camera.videoConfiguring {
                        self.videoRouteFailureRetries = 0
                    }
                }
                return
            }
            self.captureKindSwitching = false
            self.captureKind = .photo
            self.ratio = FrameRatio.photoOptions.contains(self.photoRatioBeforeVideo) ? self.photoRatioBeforeVideo : .standard
            self.camera.setVideoMode(false)
            self.camera.message = message
            self.scheduleCaptureStateSave()
        }
        camera.onVideoRecorded = { [weak self, weak library, weak camera] result in
            switch result {
            case .success(let url):
                // RAW stays on the external disk; Photos does not own or delete it.
                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    let badges = VideoCaptureBadges.forRecording(colorSpace: self?.videoColorSpace ?? .sdr,
                        burnedLogLUT: (self?.burnLogLUT ?? false)
                            && self?.selectedLogLUTCube != nil,
                        look: self?.effectiveCaptureLook ?? CaptureLook(),
                        logLUTID: self?.selectedLogLUTID)
                    library?.saveVideo(at: url, badges: badges)
                }
            case .failure(let error):
                if !(error is CancellationError) { camera?.message = "录像失败：\(error.localizedDescription)" }
            }
        }
        camera.$videoRecording.removeDuplicates().sink { [weak self] recording in
            self?.synchronizeVideoClock(recording: recording)
        }.store(in: &subscriptions)
        camera.$supportedVideoStabilizationPreferences.removeDuplicates().sink { [weak self] supported in
            self?.reconcileVideoStabilizationPreference(supported)
        }.store(in: &subscriptions)
        externalVideoStorage.$available.dropFirst().sink { [weak self] available in
            guard let self else { return }
            self.objectWillChange.send()
            if !available && self.rawVideoSelected {
                self.pendingStorageFallback = true
                if self.camera.videoBusy { self.camera.stopVideoRecording() }
                else { self.pendingStorageFallback = false; self.videoCodec = .hevc }
            }
        }.store(in: &subscriptions)
        camera.$videoBusy.removeDuplicates().sink { [weak self] busy in
            guard let self, !busy, self.pendingStorageFallback else { return }
            self.pendingStorageFallback = false; self.videoCodec = .hevc
        }.store(in: &subscriptions)
        camera.$videoSettings.sink { [weak self] settings in
            guard let self else { return }
            self.restoringVideoSettings = true
            self.videoResolution = settings.resolution
            self.videoFrameRate = settings.frameRate
            self.videoColorSpace = settings.colorSpace
            self.videoCodec = settings.codec
            self.proResSpecification = settings.proRes
            self.restoringVideoSettings = false
            self.refreshRecordingCapacity()
            // 更换前后镜头时，系统可能先回落到实际支持的规格，再发布最终设置。
            // 按最终规格刷新兼容集合，避免沿用旧分辨率扫描后只剩当前一个取景按钮。
            DispatchQueue.main.async { [weak self] in self?.refreshSubmodeLensCompatibility() }
        }.store(in: &subscriptions)
        camera.$supportedVideoSettings.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.camera.ready, self.captureKind == .video,
                      self.videoSubmodePreparing == nil else { return }
                self.refreshSubmodeLensCompatibility()
                guard self.slowMotionEnabled else { return }
                let current = self.videoCapabilitiesForCurrentRatio.contains {
                    $0.resolution == self.videoResolution && $0.frameRate == self.videoFrameRate
                        && $0.colorSpace == self.videoColorSpace
                }
                if !current {
                    if !self.prepareVideoSubmode(.slowMotion) { self.slowMotionEnabled = false }
                    self.synchronizeVideoSettings()
                    self.scheduleCaptureStateSave()
                }
            }
        }.store(in: &subscriptions)
        camera.$cinematicVideoSettings.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                // 子模式切换本身会异步发布新能力；准备期间忽略中间能力快照，
                // 避免回调再次启动同一个会话重配置。
                guard let self, self.camera.ready, self.captureKind == .video,
                      self.videoSubmodePreparing == nil else { return }
                self.refreshSubmodeLensCompatibility()
                guard self.cinematicVideoEnabled else { return }
                let current = self.camera.cinematicVideoSettings.contains {
                    $0.resolution == self.videoResolution && $0.frameRate == self.videoFrameRate
                        && $0.colorSpace == self.videoColorSpace
                }
                if !current {
                    if !self.prepareVideoSubmode(.cinematic) { self.cinematicVideoEnabled = false }
                    self.synchronizeVideoSettings()
                    self.scheduleCaptureStateSave()
                }
            }
        }.store(in: &subscriptions)
        style = self.filterSettings.selectedStyle
        restoreFilterSettings()
        library.$message.dropFirst().compactMap { $0 }.sink { [weak self] message in
            guard let self, !self.review else { return }
            self.camera.message = message
        }.store(in: &subscriptions)
        camera.$roll.dropFirst().sink { [weak self] roll in
            guard let self else { return }
            if self.levelHapticGate.update(roll: CameraLevelReading(roll: roll).tilt, time: CACurrentMediaTime(), enabled: self.level && self.camera.ready && !self.review && !self.settings) {
                cameraImpactFeedback(.light)
            }
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(camera.$currentZoom, camera.$ready, camera.$videoRecording).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshFocusNavigatorPreference() }
        }.store(in: &subscriptions)
        camera.$deliveredPhotoRevision.dropFirst().sink { [weak self] _ in
            self?.rearmSmartAfterPhoto()
        }.store(in: &subscriptions)
        camera.$capturing.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshFocusNavigatorPreference() }
        }.store(in: &subscriptions)
        camera.$focusNavigatorActive.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyExposure(); self.applyWhiteBalance(); self.camera.setFocus(position: self.manualFocus ? self.focus : nil)
                self.scheduleDualInsetPlacementRepair()
            }
        }.store(in: &subscriptions)
        camera.locationProvider = { [weak self] in guard let self, self.preferences.recordLocation else { return nil }; return self.locationService.snapshot() }
        restoreAuxiliaryPreferences()
        camera.$preview.dropFirst().sink { [weak self] image in
            guard let self else { return }
            if !self.review, self.cameraActiveRequested, self.camera.ready,
               let image, let previous = self.resumeTransitionImage, image !== previous {
                self.finishResumeTransition()
            }
            guard self.awaitingFocalFrame else { return }
            if image != nil && self.camera.demo && self.camera.ready { self.finishFocalTransition() }
        }.store(in: &subscriptions)
        camera.$userSwitchFrameID.compactMap { $0 }.sink { [weak self] id in
            guard let self, self.awaitingFocalFrame, self.focalTransitionID == id else { return }
            self.finishFocalTransition()
        }.store(in: &subscriptions)
        camera.$targetExposureLockActive.combineLatest(camera.$targetFocusLockActive).dropFirst().sink { [weak self] ae, af in
            if !ae && !af {
                DispatchQueue.main.async { [weak self] in self?.scheduleFocusDismissal() }
            }
        }.store(in: &subscriptions)
        camera.$capturing.combineLatest(camera.$pendingPhotoCount)
            .sink { [weak library] capturing, pending in library?.captureInProgress = capturing || pending > 0 }
            .store(in: &subscriptions)
        #if DEBUG && targetEnvironment(simulator)
        // Simulator-only launch options for layout review; do not affect physical-device capture.
        let arguments = ProcessInfo.processInfo.arguments
        mode = arguments.contains("--preview-manual") ? .manual : .auto
        panel = arguments.contains("--preview-filters") ? .film : nil
        filters.showStrength = arguments.contains("--preview-filter-strength")
        toolPage = arguments.contains("--preview-readouts") ? 1 : 0
        ratio = arguments.contains("--preview-wide") ? .wide : .standard
        if let value = arguments.first(where: { $0.hasPrefix("--preview-ratio-value=") })?.dropFirst("--preview-ratio-value=".count),
           let selectedRatio = FrameRatio(rawValue: String(value)), FrameRatio.photoOptions.contains(selectedRatio) { ratio = selectedRatio }
        review = arguments.contains("--preview-gallery") || arguments.contains("--preview-photo") || arguments.contains("--preview-editor") || arguments.contains("--preview-photo-info")
        if let raw = arguments.first(where: { $0.hasPrefix("--preview-filter-tab=") })?.dropFirst("--preview-filter-tab=".count),
           let tab = FilterEditorTab.allCases.first(where: { $0.id == raw || String(describing: $0) == raw }) { filterEditorTab = tab; panel = .film; filters.showStrength = true }
        if arguments.contains("--preview-format") { toolbarPanel = .format }
        if arguments.contains("--preview-ratio") { toolbarPanel = .ratio }
        if arguments.contains("--preview-tone") { toolbarPanel = .tone }
        functions = arguments.contains("--preview-functions")
        tools = arguments.contains("--preview-tools")
        if arguments.contains("--preview-tools") || arguments.contains("--preview-histogram") { showHistogram = true }
        if arguments.contains("--preview-peaking") { focusPeaking = true }
        if arguments.contains("--preview-manual-flags") {
            mode = .manual; manualExposure = true; manualWB = true; manualFocus = true
        }
        if arguments.contains("--preview-parameter") {
            mode = .manual
            panel = .manual
            parameter = .wb
        }
        if arguments.contains("--preview-focus-parameter") { mode = .manual; panel = .manual; parameter = .focus; manualFocus = true; focus = 0.5 }
        if arguments.contains("--preview-zoom") { zoomDialVisible = true }
        if arguments.contains("--preview-tint") {
            mode = .manual; panel = .manual; parameter = .tint; manualWB = true; whiteBalanceTint = 18
        }
        if let selected = arguments.first(where: { $0.hasPrefix("--preview-style=") })?.dropFirst("--preview-style=".count),
           let film = FilmStyle(rawValue: String(selected)), FilmStyle.availableStyles.contains(film) { style = film }
        if arguments.contains("--preview-shutter") {
            mode = .manual; panel = .manual; parameter = .shutter
        }
        #endif
        Publishers.Merge(camera.$isoRange.map { _ in () }, camera.$shutterRange.map { _ in () })
            .dropFirst().sink { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.camera.dualCaptureEnabled, self.mode == .manual, self.manualExposure else { return }
                    // 主副画面交换后按当前主镜头约束显示值，不能只在硬件端静默裁切ISO/快门。
                    let iso = min(max(self.iso, self.camera.isoRange.lowerBound), self.camera.isoRange.upperBound)
                    let shutter = min(max(self.shutter, self.camera.shutterRange.lowerBound), self.camera.shutterRange.upperBound)
                    guard iso != self.iso || shutter != self.shutter else { return }
                    self.iso = iso; self.shutter = shutter; self.applyExposure()
                }
            }.store(in: &subscriptions)
        camera.$dualCaptureFrontWide.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleCaptureStateSave() }
        }.store(in: &subscriptions)
        // 退出图时enabled会先变false，preparing稍后才结束；只观察enabled会丢掉最终恢复。
        camera.$dualCaptureEnabled.combineLatest(camera.$dualCapturePreparing)
            .filter { !$0.1 }.map { $0.0 }.removeDuplicates().dropFirst().sink { [weak self] enabled in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.camera.dualCaptureEnabled == enabled, !self.camera.dualCapturePreparing else { return }
                if !enabled { self.restoreVideoSettingsAfterDualCapture() }
                self.scheduleCaptureStateSave()
            }
        }.store(in: &subscriptions)
        camera.$ready.dropFirst().filter { $0 }.sink { [weak self] _ in
            // A restarted session may reset device configuration without changing lens ID.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.camera.ready, self.cameraActiveRequested, !self.review, !self.settings else { return }
                if self.beginStartupCaptureRestorationIfNeeded() { return }
                self.restoreDeviceParameters()
                self.reconcileCaptureCapabilities()
                if self.frontVideoCenteringRequested, self.captureKind == .video, self.currentPosition == .front,
                   !self.camera.frontVideoCenteringEnabled, !self.camera.frontVideoCenteringPreparing {
                    self.camera.setFrontVideoCentering(true)
                }
            }
        }.store(in: &subscriptions)
        camera.$selectedLens.dropFirst().removeDuplicates().sink { [weak self] id in
            guard let self, self.pendingStartupCaptureState == nil else { return }
            if let lens = self.camera.lenses.first(where: { $0.id == id }) {
                if lens.device.position == .back { self.lastBackLensID = id }
                if self.hdr && self.photoFormat == .heif && !self.camera.supportsHEIFHDR { self.hdr = false }
                if !self.camera.availablePhotoFormats.contains(self.photoFormat) { self.photoFormat = .jpeg; self.hdr = false }
                if !self.camera.availableResolutions.contains(self.photoResolution) { self.photoResolution = .standard }
            }
            self.refreshSubmodeLensCompatibility()
            // @Published在赋值前发送；下一轮再按新位置刷新星芒，避免前置切主摄后look仍为空。
            if self.virtualApertureEnabled {
                DispatchQueue.main.async { [weak self] in self?.updateLook() }
            }
        }.store(in: &subscriptions)
        camera.$photoLensCapabilities.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshSubmodeLensCompatibility() }
        }.store(in: &subscriptions)
        camera.$lenses.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshSubmodeLensCompatibility() }
        }.store(in: &subscriptions)
        // Logical 1/2/4/8 labels may change while A mode keeps the same virtual input.
        // Only a real input replacement needs focus/exposure/white-balance restoration.
        camera.$activeCaptureDeviceID.dropFirst().removeDuplicates().sink { [weak self] id in
            guard !id.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingStartupCaptureState == nil, self.camera.activeCaptureDeviceID == id else { return }
                self.didChangeLensDevice(id, isoRange: self.camera.isoRange, shutterRange: self.camera.shutterRange)
            }
        }.store(in: &subscriptions)
        camera.$supportsLivePhoto.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.reconcileCaptureCapabilities() }
        }.store(in: &subscriptions)
        camera.$supportsNightCapture.dropFirst().removeDuplicates().sink { [weak self] supported in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.camera.ready else { return }
                if !supported { self.exitNightModeBecauseCaptureBecameUnavailable() }
                else { self.reconcileNightMode() }
            }
        }.store(in: &subscriptions)
        camera.$supportsPortraitCapture.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.camera.ready else { return }
                self.reconcilePortraitMode()
            }
        }.store(in: &subscriptions)
        camera.$readings.dropFirst().sink { [weak self] readings in
            DispatchQueue.main.async { [weak self] in self?.updateNightEnvironment(readings) }
        }.store(in: &subscriptions)
        camera.$ready.dropFirst().removeDuplicates().sink { [weak self] ready in
            guard ready else { return }
            DispatchQueue.main.async { [weak self] in
                self?.reconcileNightMode()
                self?.refreshSubmodeLensCompatibility()
            }
        }.store(in: &subscriptions)
        // 人像取景独立于滑块；微距、会话恢复和模式切换也必须同步暂停/恢复分割。
        Publishers.MergeMany([
            camera.$ready.map { _ in () }.eraseToAnyPublisher(),
            camera.$macroActive.map { _ in () }.eraseToAnyPublisher(),
            $mode.map { _ in () }.eraseToAnyPublisher(),
            $captureKind.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in
            self?.synchronizePortraitPreview()
        }.store(in: &subscriptions)
        camera.onLivePhotoUnavailable = { [weak self] in
            guard let self else { return }
            // 临时不可用只停止本次 Live，不清除用户的开启选择。
            self.synchronizeLiveAudio()
        }
        camera.$supportsHighResolutionHEIFHDR.removeDuplicates().sink { [weak self] supported in
            guard let self, !supported, self.hdr, self.photoFormat == .heif, self.photoResolution == .high else { return }
            self.photoResolution = .standard
        }.store(in: &subscriptions)
        camera.onNightCaptureUnavailable = { [weak self] in
            DispatchQueue.main.async { self?.exitNightModeBecauseCaptureBecameUnavailable() }
        }
        camera.onPortraitCaptureUnavailable = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.portraitModeEnabled = false
                self.synchronizeLiveAudio()
            }
        }
        camera.$availablePhotoFormats.sink { [weak self] formats in
            guard let self, self.pendingStartupCaptureState == nil, !formats.contains(self.photoFormat) else { return }
            self.photoFormat = .jpeg; self.hdr = false
        }.store(in: &subscriptions)
        camera.onHardwareAdjustment = { [weak self] id, value in self?.handleHardwareAdjustment(id: id, value: value) }
        camera.onHardwareControlsActivated = { [weak self] in
            guard let self, self.cameraActiveRequested, !self.review, !self.settings else { return }
            self.closePopups()
        }
        objectWillChange.sink { [weak self] in self?.scheduleHardwareControlsUpdate() }.store(in: &subscriptions)
        Publishers.MergeMany([
            camera.$ready.map { _ in () }.eraseToAnyPublisher(),
            camera.$currentZoom.map { _ in () }.eraseToAnyPublisher(),
            camera.$continuousZoomRange.map { _ in () }.eraseToAnyPublisher(),
            camera.$isoRange.map { _ in () }.eraseToAnyPublisher(),
            camera.$shutterRange.map { _ in () }.eraseToAnyPublisher(),
            camera.$shutterBusy.map { _ in () }.eraseToAnyPublisher(),
            camera.$readings.map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.scheduleHardwareControlsUpdate() }.store(in: &subscriptions)
        updateLook()
        loadSelectedLogLUT()
        camera.enableHistogram(showHistogram)
        if preferences.saveCaptureSettings, let saved = self.preferencesStore.loadCaptureState() {
            pendingStartupCaptureState = saved
            restoreCaptureState(saved)
        } else if !preferences.saveCaptureSettings {
            self.preferencesStore.clearCaptureState()
            restoreCaptureState(SavedCaptureState())
        }
        objectWillChange.sink { [weak self] in self?.scheduleCaptureStateSave() }.store(in: &subscriptions)
        Publishers.MergeMany([
            camera.$currentZoom.map { _ in () }.eraseToAnyPublisher(),
            camera.$selectedLens.map { _ in () }.eraseToAnyPublisher(),
            camera.$frontPhotoLandscapeEnabled.map { _ in () }.eraseToAnyPublisher(),
            camera.$frontPhotoAspectRatioSwitchAvailable.map { _ in () }.eraseToAnyPublisher()
        ]).dropFirst().sink { [weak self] in self?.scheduleCaptureStateSave() }.store(in: &subscriptions)
        Publishers.MergeMany([
            camera.$frontPhotoLandscapeEnabled.map { _ in () }.eraseToAnyPublisher(),
            camera.$frontPhotoAspectRatioSwitchAvailable.map { _ in () }.eraseToAnyPublisher(),
            $nightModeEnabled.map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in DispatchQueue.main.async { self?.updateLook() } }.store(in: &subscriptions)
    }

    private func persistAuxiliaryPreferences() {
        guard !restoringAuxiliaryPreferences else { return }
        var updated = preferences
        updated.auxiliaryWatermark = border
        updated.auxiliaryTimerSeconds = min(max(timerSeconds, 0), 60)
        updated.auxiliaryGrid = grid
        updated.auxiliaryHistogram = showHistogram
        updated.auxiliaryFocusPeaking = focusPeaking
        updated.auxiliarySmoothPreview = smoothPreview
        updated.auxiliaryLevel = level
        updated.auxiliaryPreviewQuarterTurns = ((previewQuarterTurns % 4) + 4) % 4
        updated.auxiliaryRecordingCapacity = showsRecordingCapacity
        updated.auxiliaryAudioMeter = showsAudioMeter
        if updated != preferences { preferences = updated }
    }

    private func restoreAuxiliaryPreferences() {
        restoringAuxiliaryPreferences = true
        border = preferences.auxiliaryWatermark
        timerSeconds = min(max(preferences.auxiliaryTimerSeconds, 0), 60)
        grid = preferences.auxiliaryGrid
        showHistogram = preferences.auxiliaryHistogram
        focusPeaking = preferences.auxiliaryFocusPeaking
        smoothPreview = preferences.auxiliarySmoothPreview
        level = preferences.auxiliaryLevel
        previewQuarterTurns = ((preferences.auxiliaryPreviewQuarterTurns % 4) + 4) % 4
        showsRecordingCapacity = preferences.auxiliaryRecordingCapacity
        showsAudioMeter = preferences.auxiliaryAudioMeter
        restoringAuxiliaryPreferences = false
        camera.rotatePreview(quarterTurns: previewQuarterTurns)
        camera.enableHistogram(showHistogram)
        camera.enableFocusPeaking(focusPeaking)
        camera.setPreviewExposureAssist(smoothPreview)
        updateLook()
        synchronizeHDRPreview()
    }

    /// Lifecycle callbacks can run during SwiftUI's view-update transaction.
    /// Defer published state changes, and ignore obsolete requests after rapid navigation.
    func setCameraActive(_ active: Bool) {
        camera.noteLifecycleRequest(active: active, context: [
            "mode": mode.rawValue, "kind": captureKind == .photo ? "photo" : "video",
            "format": photoFormat.rawValue, "ratio": ratio.rawValue,
            "slowShutter": String(slowShutterEnabled), "preset": selectedSlowShutterPreset?.rawValue ?? "none",
            "zoomAtRequest": String(Double(camera.currentZoom))
        ])
        if !active {
            // 后台休眠期间不能让入口 watchdog 继续计时，否则回前台会误报“视频启动超时”。
            cancelVideoEntryWatchdog()
            pendingVideoEntryAfterRecovery?.cancel()
            pendingVideoEntryAfterRecovery = nil
        }
        if !active { cancelSlowShutterSequence() }
        if !active { stopBurstCapture() }
        if !active && !review { dismissDepthControls() }
        if !active && camera.videoBusy { camera.stopVideoRecording() }
        if !active && !review { closePopups() }
        cameraActiveRequested = active
        if active {
            CameraHaptics.prepare()
            zoomTickFeedback.prepare()
            zoomAnchorFeedback.prepare()
        }
        synchronizePortraitPreview()
        if active {
            if preferences.dockKitTrackingEnabled || dockKitTracking.accessoryConnected {
                dockKitTracking.startMonitoring()
                dockKitTracking.setTrackingEnabled(preferences.dockKitTrackingEnabled)
            }
        } else {
            dockKitTracking.stopMonitoring()
        }
        locationService.setActive(active && preferences.recordLocation)
        let request = UUID()
        lifecycleRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycleRequest == request else { return }
            self.synchronizeLiveAudio()
            self.camera.setVideoMode(self.captureKind == .video && (active || self.camera.dualCaptureEnabled))
            if active {
                if self.smartCaptureEnabled { self.startSmartCaptureAnalysis() }
                // 前台恢复的排队回调不能把刚启动的慢门序列重新切回虚拟A挡输入。
                let captureManualRoute = self.mode == .manual || self.slowShutterSequence != nil
                self.camera.setManualMode(captureManualRoute, customExposure: captureManualRoute && self.manualExposure)
                self.camera.start()
                if self.resumeTransitionImage != nil {
                    let token = self.resumeTransitionRequest
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, self.resumeTransitionRequest == token, !self.review else { return }
                        self.finishResumeTransition()
                    }
                }
                self.restoreDeviceParameters()
                self.updateLook()
                self.camera.enableHistogram(self.showHistogram)
                self.camera.enableFocusPeaking(self.focusPeaking)
            } else {
                self.stopSmartCaptureAnalysis()
                self.cancelFocus()
                self.cancelCountdown()
                self.endZoomDial()
                self.setFilterParameterEditing(false)
                self.camera.stop()
            }
        }
    }

    func toggleDockKitTracking() {
        setDockKitTrackingEnabled(!preferences.dockKitTrackingEnabled)
    }

    func setDockKitTrackingEnabled(_ enabled: Bool) {
        guard !dockKitTrackingUpdating, preferences.dockKitTrackingEnabled != enabled else { return }
        CameraHaptics.impact(.light)
        var updated = preferences
        updated.dockKitTrackingEnabled = enabled
        preferences = updated
        if enabled {
            if cameraActiveRequested {
                dockKitTracking.startMonitoring()
                dockKitTracking.setTrackingEnabled(true, reportFailure: true)
            }
        } else {
            dockKitTracking.stopMonitoring()
        }
    }

    /// 将取景器点选位置交给 DockKit，先按预览画面的 aspect-fill 裁切换算到视频坐标。
    func selectDockKitSubject(at point: CGPoint, surfaceSize: CGSize) {
        guard dockKitAccessoryConnected, dockKitTrackingEnabled,
              let sourceSize = camera.preview.map({ CGSize(width: $0.size.width, height: $0.size.height) }),
              let unitPoint = DockKitPreviewMapping.unitPoint(point, surfaceSize: surfaceSize, sourceImageSize: sourceSize) else { return }
        dockKitTracking.selectSubject(at: unitPoint)
    }

    /// 将用户拖出的取景框换算为 DockKit 规范化视频区域。
    func setDockKitTrackingRegion(_ rect: CGRect, surfaceSize: CGSize) {
        guard dockKitAccessoryConnected, dockKitTrackingEnabled,
              let sourceSize = camera.preview.map({ CGSize(width: $0.size.width, height: $0.size.height) }),
              let unitRect = DockKitPreviewMapping.unitRect(rect, surfaceSize: surfaceSize, sourceImageSize: sourceSize) else { return }
        dockKitTracking.setRegionOfInterest(unitRect)
    }

    private func finishResumeTransition() {
        guard resumeTransitionImage != nil, !resumeTransitionFinishing else { return }
        resumeTransitionFinishing = true
        let token = resumeTransitionRequest
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.28
        withAnimation(.easeInOut(duration: duration)) { resumeTransitionOpacity = 0 }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.03))
            guard let self, self.resumeTransitionRequest == token else { return }
            self.resumeTransitionImage = nil; self.resumeTransitionFinishing = false
        }
    }

    private func restoreDeviceParameters() {
        // 慢门序列临时切物理路线产生 ready 通知，但不能按界面 A 挡把曝光改回自动。
        guard slowShutterSequence == nil else { return }
        if mode == .manual, slowShutterEnabled, let preset = selectedSlowShutterPreset {
            if let shutterRange = preset.shutterRange(limitedTo: camera.shutterRange),
               let isoRange = preset.isoRange(limitedTo: camera.isoRange) {
                manualExposure = true
                shutter = min(max(shutter, shutterRange.lowerBound), shutterRange.upperBound)
                iso = min(max(iso, isoRange.lowerBound), isoRange.upperBound)
            } else if camera.ready {
                selectedSlowShutterPreset = nil
            }
        }
        let manual = mode == .manual
        camera.setExposure(iso: manual && manualExposure && !cinematicAutomaticControls ? iso : nil,
                           seconds: manual && manualExposure && !cinematicAutomaticControls ? pow(2, shutter) : nil, bias: ev)
        applySlowShutterExposurePolicy()
        camera.setWhiteBalance(kelvin: manual && manualWB ? wb : nil, tint: manual && manualWB ? whiteBalanceTint : 0)
        // A user may lock a target on the first ready frame before this deferred
        // restoration runs. Do not turn that new lock back into automatic focus/metering.
        if !camera.targetFocusLockActive, !camera.smartFocusHolding { camera.setFocus(position: manual && manualFocus ? focus : nil) }
        if !camera.targetLockActive { camera.setMetering(effectiveMetering) }
    }

    #if DEBUG
    func restoreDeviceParametersForTesting() { restoreDeviceParameters() }
    #endif

    @Published var focusLockPickerVisible = false
    var focusLockMode: FocusLockMode {
        preferences.focusLockMode.locksFocus && !camera.demo && !camera.supportsTargetFocusLock ? .exposure : preferences.focusLockMode
    }
    func toggleFocusLockPicker() {
        guard focusPoint != nil, camera.targetLockActive else { return }
        let opening = !focusLockPickerVisible
        closePopups()
        withAnimation(AppTheme.popupAnimation) { focusLockPickerVisible = opening }
    }
    func selectFocusLockMode(_ mode: FocusLockMode) {
        guard camera.ready, !camera.capturing, !mode.locksFocus || camera.demo || camera.supportsTargetFocusLock else { return }
        preferences.focusLockMode = mode
        withAnimation(AppTheme.popupAnimation) { focusLockPickerVisible = false }
        lockFocusExposure()
    }

    private var focusViewportSize = CGSize.zero
    func focusPreview(at point: CGPoint, size: CGSize, lockExposure: Bool = false) {
        guard camera.ready, !camera.capturing,
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        // A single tap must not disturb an active or pending AE lock.
        guard lockExposure || !camera.targetLockActive else { return }
        camera.unlockTargetExposure()
        manualFocus = false
        let target = CGPoint(x: min(max(point.x, 25), max(25, size.width - 25)),
                             y: min(max(point.y, 25), max(25, size.height - 25)))
        focusViewportSize = size
        camera.focus(at: CGPoint(x: target.x / size.width, y: target.y / size.height), lockExposure: lockExposure && focusLockMode.locksExposure, lockFocus: lockExposure && focusLockMode.locksFocus)
        focusPoint = target
        if lockExposure {
            focusTask?.cancel(); focusTask = nil
            cameraImpactFeedback(.light)
        } else { scheduleFocusDismissal() }
    }

    func lockFocusExposure() {
        guard let point = focusPoint, camera.ready, !camera.capturing,
              focusViewportSize.width > 0, focusViewportSize.height > 0 else { return }
        focusTask?.cancel(); focusTask = nil
        camera.focus(at: CGPoint(x: point.x / focusViewportSize.width, y: point.y / focusViewportSize.height), lockExposure: focusLockMode.locksExposure, lockFocus: focusLockMode.locksFocus)
        cameraImpactFeedback(.light)
    }

    func unlockFocusExposure() {
        withAnimation(AppTheme.popupAnimation) { focusLockPickerVisible = false }
        camera.unlockTargetExposure()
        scheduleFocusDismissal()
    }

    func beginFocusEVAdjustment() { focusTask?.cancel(); focusTask = nil }
    func adjustFocusEV(_ value: Double) {
        guard focusPoint != nil, value.isFinite, camera.ready, !camera.capturing else { return }
        let next = min(max((value * 10).rounded() / 10, exposureCompensationRange.lowerBound), exposureCompensationRange.upperBound)
        guard next != ev else { return }
        ev = next
        applyExposure()
    }
    func finishFocusEVAdjustment() { scheduleFocusDismissal() }

    private func scheduleFocusDismissal() {
        focusTask?.cancel(); focusTask = nil
        guard focusPoint != nil, !camera.targetLockActive else { return }
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, !self.camera.targetLockActive else { return }
            self.focusPoint = nil
        }
    }

    func parameterIcon(_ value: CameraParameter) -> String {
        switch value {
        case .ev: return "plusminus"
        case .iso: return "camera.aperture"
        case .shutter: return "timer"
        case .wb: return "thermometer.medium"
        case .tint: return "drop.halffull"
        case .focus: return "viewfinder"
        }
    }

    func parameterTitle(_ value: CameraParameter) -> String {
        switch value {
        case .ev: return "曝光"
        case .iso: return "ISO"
        case .shutter: return "快门"
        case .wb: return "白平衡"
        case .tint: return "色调"
        case .focus: return "对焦"
        }
    }

    func setMode(_ next: CameraShootingMode) {
        sliderEVRequest = UUID()
        guard slowShutterSequence == nil else { return }
        guard !camera.capturing, !camera.videoBusy, countdown == nil, !isPreparingSubmode else { return }
        if next == .manual, nightModeEnabled { setPhotoSubmode(.night, enabled: false) }
        if next != mode {
            camera.endSmartFocusHold()
            if smartCaptureEnabled {
                interruptSmartFraming(); smartAutoFramingGate.reset(); smartFramingComplete = false
            }
        }
        if slowShutterEnabled, next != mode {
            // A→M 固定从 1s 开始；M→A 恢复上次预设及合法时长，无预设则回到 1s。
            if next == .manual {
                slowShutterAutomaticPreset = selectedSlowShutterPreset
                slowShutterAutomaticDuration = slowShutterDuration
                selectedSlowShutterPreset = nil
                slowShutterDuration = .s1
            } else {
                selectedSlowShutterPreset = slowShutterAutomaticPreset
                if let preset = selectedSlowShutterPreset {
                    slowShutterDuration = preset.allows(slowShutterAutomaticDuration)
                        ? slowShutterAutomaticDuration : preset.defaultCaptureDuration
                } else { slowShutterDuration = .s1 }
            }
            if toolbarPanel == .slowShutterDuration { toolbarPanel = nil }
            scheduleHardwareControlsUpdate()
            scheduleCaptureStateSave()
        }
        if captureKind == .video, timeLapseEnabled, next != mode {
            // Timelapse presets are A-mode shortcuts; M starts with a light,
            // quick manual default and no preset highlight.
            selectedTimeLapsePreset = nil
            timeLapseInterval = .s1
            timeLapseFrameCount = .f120
            scheduleCaptureStateSave()
        }
        let previousMode = mode
        if next != mode {
            cameraSelectionFeedback()
            startFocalTransition()
        }
        cancelFocus()
        endZoomDial()
        if mode == .manual && next == .auto {
            savedManualSettings = ManualSettings(exposure: manualExposure, whiteBalance: manualWB, focusLocked: manualFocus,
                                                 iso: iso, shutter: shutter, wb: wb, tint: whiteBalanceTint, focus: focus, ev: ev)
        } else if mode == .auto && next == .manual {
            automaticEV = ev
        }
        withAnimation(.easeInOut(duration: 0.22)) { mode = next; panel = nil }
        synchronizeHighResolutionPhotoRoute()
        let destinationUsesCustomExposure = next == .manual && !fixedHighResolutionFocalsOnly && (
            (savedManualSettings?.exposure ?? manualExposure)
                || (slowShutterEnabled && selectedSlowShutterPreset != nil)
        )
        camera.setManualMode(next == .manual, customExposure: destinationUsesCustomExposure)
        manualModeSettleTask?.cancel()
        manualModeSettleTask = nil
        manualModeRouteSettling = previousMode == .auto && next == .manual
        if manualModeRouteSettling {
            manualModeSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1000))
                guard let self, !Task.isCancelled, self.mode == .manual else { return }
                self.manualModeRouteSettling = false
                // 路由稳定后一次性把用户在这 1 秒内调好的最新值应用到物理镜头。
                self.applyExposure()
                if self.manualWB { self.applyWhiteBalance() }
                if self.manualFocus { self.camera.setFocus(position: self.focus) }
            }
        }
        refreshSubmodeLensCompatibility()
        if next == .auto {
            manualExposure = false; manualWB = false; manualFocus = false
            ev = automaticEV
            applyExposure(); camera.setWhiteBalance(kelvin: nil); camera.setFocus(position: nil)
        } else {
            // M→M 的媒体重配应沿用当前参数，不能被更早一次 A/M 切换的快照覆盖。
            if previousMode == .auto, let saved = savedManualSettings {
                // A-mode virtual-camera limits must not overwrite the remembered physical M-mode values.
                iso = saved.iso
                shutter = saved.shutter
                wb = saved.wb; whiteBalanceTint = saved.tint; focus = saved.focus; ev = saved.ev
                manualExposure = saved.exposure && !fixedHighResolutionFocalsOnly; manualWB = saved.whiteBalance; manualFocus = saved.focusLocked
            }
            if slowShutterEnabled, let preset = selectedSlowShutterPreset {
                applySlowShutterPresetToManualExposure(preset, resetToSuggestion: false)
            } else {
                applyExposure()
            }
            applyWhiteBalance()
            camera.setFocus(position: manualFocus ? focus : nil)
        }
        applySlowShutterExposurePolicy()
        if awaitingFocalFrame { camera.completeUserPreviewSwitch(focalTransitionID) }
    }

    func shutterText(_ seconds: Double) -> String {
        CameraNumericText.shutter(seconds)
    }

    var parameterCanEdit: Bool {
        guard camera.ready, !camera.demo else { return false }
        switch parameter {
        case .ev: return true
        case .iso, .shutter: return camera.supportsExposure && !cinematicAutomaticControls
        case .focus: return camera.supportsFocus && !(captureKind == .video && cinematicVideoEnabled)
        case .wb, .tint: return camera.supportsWB
        }
    }

    var currentParameterNumber: Double {
        guard parameterAutomatic, let readings = camera.readings?.validated else { return parameterBinding.wrappedValue }
        switch parameter {
        case .iso: return readings.iso
        case .shutter: return log2(max(readings.seconds, 0.000001))
        case .wb: return readings.kelvin
        case .tint: return readings.tint ?? whiteBalanceTint
        case .focus: return readings.focus
        case .ev: return ev
        }
    }

    var parameterDisplay: String {
        let value = currentParameterNumber
        guard value.isFinite else { return "—" }
        switch parameter {
        case .iso: return CameraNumericText.integer(value)
        case .shutter: return shutterText(pow(2, value))
        case .wb: return CameraNumericText.integer(value) == "—" ? "—" : CameraNumericText.integer(value) + "K"
        case .tint: return String(format: "%+.0f", value)
        case .focus: return String(format: "%.2f", value)
        case .ev: return String(format: "%+.1f EV", value)
        }
    }

    var editableParameterBinding: Binding<Double> {
        Binding(get: { [self] in currentParameterNumber }, set: { [self] value in
            guard parameterCanEdit, value.isFinite else { return }
            switch parameter {
            case .iso, .shutter:
                if !manualExposure { synchronizeExposureValues() }
                manualExposure = true
            case .wb, .tint:
                if !manualWB { synchronizeWhiteBalanceValues() }
                manualWB = true
            case .focus: manualFocus = true
            case .ev: manualExposure = false
            }
            let range = parameterRange
            let boundedValue = min(max(value, range.lowerBound), range.upperBound)
            parameterBinding.wrappedValue = parameter == .shutter
                ? CameraShutterStops.snappedLog2Duration(boundedValue, in: range)
                : boundedValue
        })
    }

    var whiteBalancePresetValues: [Double] { [2800, 4000, 5500, 6500, 7500] }

    func activateParameterAuto() {
        switch parameter {
        case .iso, .shutter: manualExposure = false; applyExposure()
        case .wb, .tint: manualWB = false; camera.setWhiteBalance(kelvin: nil)
        case .focus: manualFocus = false; camera.setFocus(position: nil)
        case .ev: manualExposure = false; ev = 0; applyExposure()
        }
    }

    var popupVisible: Bool { functions || tools || shootingModes || panel == .manual }

    func closePopups() {
        dismissDepthControls()
        dismissFilterNumericInput()
        dismissFilterReset(); setFilterParameterEditing(false)
        flushFilterSettings()
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) { functions = false; tools = false; shootingModes = false; panel = nil; toolbarPanel = nil; focusLockPickerVisible = false }
    }

    func openTools(feedback: Bool = true) {
        dismissDepthControls()
        if feedback { cameraImpactFeedback(.light) }
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            tools = true; functions = false; shootingModes = false; panel = nil; toolbarPanel = nil
        }
    }

    func openFunctions() {
        dismissDepthControls()
        guard !camera.videoBusy else { return }
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            functions = true; tools = false; shootingModes = false; panel = nil; toolbarPanel = nil
        }
    }

    func openShootingModes() {
        dismissDepthControls()
        guard !camera.videoBusy else { return }
        endZoomDial()
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            shootingModes = true; functions = false; tools = false; panel = nil; toolbarPanel = nil
        }
    }

    var shootingFeatures: [(title: String, icon: String)] {
        [("视频", "video.fill"), ("照片", "camera.fill")]
    }

    /// 模式按钮立即反馈；正在配置/收尾时排队，不能静默吞掉用户点击。
    func requestCaptureKind(_ kind: CaptureKind) {
        guard kind != captureKind else {
            pendingCaptureKindRequest = nil
            pendingCaptureKindTask?.cancel()
            pendingCaptureKindTask = nil
            return
        }
        CameraHaptics.impact(.light)
        if kind == .photo {
            cancelVideoEntryWatchdog()
            pendingVideoEntryAfterRecovery?.cancel()
            pendingVideoEntryAfterRecovery = nil
        }
        guard camera.videoBusy || library.videoSaving else {
            pendingCaptureKindRequest = nil
            pendingCaptureKindTask?.cancel()
            pendingCaptureKindTask = nil
            setCaptureKind(kind)
            return
        }
        pendingCaptureKindRequest = kind
        pendingCaptureKindTask?.cancel()
        pendingCaptureKindTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<240 {
                if !self.camera.videoBusy, !self.library.videoSaving { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.pendingCaptureKindRequest == kind,
                  !self.camera.videoBusy, !self.library.videoSaving else { return }
            self.pendingCaptureKindRequest = nil
            self.pendingCaptureKindTask = nil
            self.setCaptureKind(kind)
        }
    }

    func setCaptureKind(_ kind: CaptureKind) {
        if kind == .photo { cancelVideoEntryWatchdog() }
        if kind == .video, camera.recoveringSession || !camera.ready {
            scheduleVideoEntryAfterRecovery()
            return
        }
        let cancellingCinematicPreparation = kind == .photo && videoSubmodePreparing == .cinematic
        // 返回照片可以取消正在准备的视频子模式；不能因为 preparing 状态静默无响应。
        guard kind != captureKind,
              !camera.videoBusy, !library.videoSaving,
              kind == .photo || !isPreparingSubmode || cancellingCinematicPreparation else { closePopups(); return }
        if kind == .photo, camera.dualCaptureEnabled {
            camera.setDualCaptureEnabled(false) { [weak self] success in
                guard let self, success else { return }
                self.restoreVideoSettingsAfterDualCapture()
                self.setCaptureKind(kind)
            }
            return
        }
        // 旧照片请求不能跨模式存活，否则会在新模式弹“拍照超时”。
        camera.cancelPendingPhotoCapturesForModeSwitch()
        if kind == .video { videoRouteFailureRetries = 0 }
        captureKindSwitching = true
        let switchToken = UUID(); captureKindSwitchToken = switchToken
        let previousPreview = camera.preview
        let configuration = camera.beginCaptureKindConfiguration()
        startFocalTransition(fadeDuration: 0.14)
        defer {
            camera.finishCaptureKindConfiguration(configuration, transitionID: focalTransitionID)
            finishCaptureKindSwitch(token: switchToken, previousPreview: previousPreview)
        }
        stopBurstCapture()
        burstModeEnabled = false
        closePopups()
        cancelCountdown()
        if kind == .video {
            photoModeBeforeVideo = mode
            photoManualSettingsBeforeVideo = mode == .manual
                ? SavedManualCaptureState(exposure: manualExposure, whiteBalance: manualWB, focusLocked: manualFocus,
                    iso: iso, shutter: shutter, wb: wb, tint: whiteBalanceTint, focus: focus, ev: ev)
                : nil
            photoRatioBeforeVideo = FrameRatio.photoOptions.contains(ratio) ? ratio : .standard
            photoFormatBeforeVideo = photoFormat
            photoResolutionBeforeVideo = photoResolution
            photoHDRBeforeVideo = hdr
            ratio = videoRatio.frameRatio
        } else {
            videoModeBeforePhoto = mode
            recordingCapacity = nil
            // 离开视频即退出所有视频子模式；否则残留的 cinematicVideoEnabled
            // 会在照片路线提交后再次把输入切回 DualWide。
            videoSubmodeRequest = UUID()
            videoSubmodePreparing = nil
            setVideoSubmode(.timeLapse, enabled: false)
            setVideoSubmode(.slowMotion, enabled: false)
            setVideoSubmode(.cinematic, enabled: false)
            compatibleSubmodeLensIDs = nil
            pendingCinematicStart = false
            photoStateRestorePending = true
            ratio = FrameRatio.photoOptions.contains(photoRatioBeforeVideo) ? photoRatioBeforeVideo : .standard
        }
        withAnimation(AppTheme.popupAnimation) { captureKind = kind }
        if kind == .video, smartCaptureEnabled {
            smartCaptureEnabled = false
            stopSmartCaptureAnalysis()
        }
        synchronizeHighResolutionPhotoRoute()
        if kind == .video {
            // 先退出照片子模块，再恢复视频自己的挡位，避免被照片夜景等限制拦截。
            setMode(videoModeBeforePhoto)
            // Restore the photo HDR format before choosing the video preset;
            // restoring it afterwards would overwrite the 1080p configuration.
            // 视频输出图不能沿用照片 HDR/HLG 管线；只关预览标志不够，
            // 必须同时关闭 HEIFHDRPipeline，否则会以照片格式/输出组合启动视频并报 -11800。
            camera.setHEIFHDRPreview(false)
            camera.setHEIFHDRPipeline(false)
            synchronizeLiveAudio()
            // 必须先进入视频模式，再提交视频规格；反过来 setVideoSettings 会被
            // videoModeRequested=false 的 guard 丢弃，视频就可能用照片格式启动而报未就绪。
            camera.setVideoMode(cameraActiveRequested)
            synchronizeVideoSettings()
            scheduleVideoEntryWatchdog()
        } else {
            cancelVideoEntryWatchdog()
            // Remove recording outputs before probing native Live support. Probing
            // against the video graph can wrongly disable the user's Live setting.
            // Queue route restoration before reapplying M values so their exposure
            // isn't clamped to the video's selected frame interval.
            camera.setVideoMode(false)
            // 照片保存的是自己的挡位，视频 M 挡不能覆盖原来的照片 A 挡。
            setMode(photoModeBeforeVideo)
            // 视频输入会把快门钳制到帧周期；不能用这个临时范围覆盖照片 M 挡的长曝光。
            if mode == .manual, let saved = photoManualSettingsBeforeVideo {
                iso = saved.iso; shutter = saved.shutter
                wb = saved.wb; whiteBalanceTint = saved.tint; focus = saved.focus; ev = saved.ev
                manualExposure = saved.exposure; manualWB = saved.whiteBalance; manualFocus = saved.focusLocked
                restoreDeviceParameters()
            }
            synchronizeLiveAudio()
            // 视频不提供照片格式/HDR；返回照片时恢复进入视频前的选择，避免静默变 SDR/JPEG。
            if let format = photoFormatBeforeVideo, camera.availablePhotoFormats.contains(format) {
                photoFormat = format
                photoResolution = photoResolutionBeforeVideo
                if format == .heif || format == .heifPro { hdr = photoHDRBeforeVideo }
            }
            synchronizeHDRPreview()
        }
        updateLook()
    }

    /// 视频结束后的能力发布是异步的；在最终照片路线可用后再恢复照片格式/HDR。
    private func restorePhotoStateAfterVideo(retryIfNeeded: Bool = true) {
        guard let format = photoFormatBeforeVideo else { photoStateRestorePending = false; return }
        guard captureKind == .photo else { return }
        guard camera.availablePhotoFormats.contains(format) else {
            photoStateRestorePending = true
            if retryIfNeeded { schedulePhotoStateRestore() }
            return
        }
        if photoFormat != format { photoFormat = format }
        if photoResolution != photoResolutionBeforeVideo { photoResolution = photoResolutionBeforeVideo }
        if format == .heif || format == .heifPro {
            if hdr != photoHDRBeforeVideo { hdr = photoHDRBeforeVideo }
            else { synchronizeHDRPreview(); updateLook() }
        }
        photoStateRestorePending = false
        photoStateRestoreTask?.cancel(); photoStateRestoreTask = nil
    }

    /// 视频退出后能力表是异步发布的；在 HEIF/HDR 重新可用前不能让协调器清掉用户选择。
    private func schedulePhotoStateRestore() {
        photoStateRestoreTask?.cancel()
        photoStateRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                guard self.photoStateRestorePending, self.captureKind == .photo else { return }
                self.restorePhotoStateAfterVideo(retryIfNeeded: false)
                if !self.photoStateRestorePending { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.photoStateRestorePending = false
            self.reconcileCaptureCapabilities()
        }
    }

    /// 前置切换/会话恢复期间用户点了视频：等恢复完成再进入，不能把停止中的会话当视频入口。
    private func scheduleVideoEntryAfterRecovery() {
        guard pendingVideoEntryAfterRecovery == nil else { return }
        pendingVideoEntryAfterRecovery = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingVideoEntryAfterRecovery = nil }
            for _ in 0..<240 {
                if self.camera.ready, !self.camera.recoveringSession, !self.camera.videoConfiguring { break }
                if self.camera.recoveryFailed { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.captureKind == .photo,
                  self.camera.ready, !self.camera.recoveringSession, !self.camera.videoConfiguring else { return }
            self.setCaptureKind(.video)
        }
    }

    private func cancelVideoEntryWatchdog() {
        videoEntryWatchdog?.cancel()
        videoEntryWatchdog = nil
    }

    #if DEBUG
    func armVideoEntryWatchdogForTesting() { scheduleVideoEntryWatchdog() }
    var videoEntryWatchdogActiveForTesting: Bool { videoEntryWatchdog != nil }
    #endif

    /// 视频/电影进入配置可能被 AVFoundation 卡住；超时后必须回到可用界面。
    private func scheduleVideoEntryWatchdog() {
        cancelVideoEntryWatchdog()
        videoEntryWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.captureKind == .video else { return }
            // 正常换画幅/居中/规格配置也会短暂停止预览；这不是入口卡死，
            // 不能触发强制退出，否则用户切前置画幅时会误报视频超时并冻结。
            if self.captureKindSwitching || self.camera.videoConfiguring || self.camera.recoveringSession
                || self.camera.dualCapturePreparing
                || self.videoSubmodePreparing != nil || self.camera.frontVideoCenteringPreparing
                || (self.camera.videoBusy && !self.camera.videoRecording) {
                self.scheduleVideoEntryWatchdog()
                return
            }
            let cinematicPreviewStalled = self.cinematicVideoEnabled && !self.camera.videoBusy
                && CACurrentMediaTime() - self.camera.latestRecordingPreviewFrameTime > 1
            if self.videoSubmodePreparing == .cinematic || cinematicPreviewStalled {
                self.videoSubmodePreparing = nil
                self.videoSubmodeRequest = UUID()
                self.setVideoSubmode(.cinematic, enabled: false)
                self.compatibleSubmodeLensIDs = nil
                self.synchronizeVideoSettings()
                self.camera.message = "电影预览启动超时，正在恢复普通视频。"
                self.scheduleVideoEntryWatchdog()
                return
            }
            // ready 只有在目标输出图真正交付新帧后才发布；它才是“视频入口成功”的唯一权威信号。
            if self.camera.ready {
                self.cancelVideoEntryWatchdog()
                return
            }
            if self.cinematicVideoEnabled && !self.camera.cinematicVideoCaptureActive {
                self.videoSubmodePreparing = nil
                self.videoSubmodeRequest = UUID()
                self.setVideoSubmode(.cinematic, enabled: false)
                self.synchronizeVideoSettings()
                self.camera.message = "电影效果无法启用，已返回普通视频。"
                return
            }
            self.abortStuckVideoRoute(message: "视频启动超时，已退出视频模式。")
        }
    }

    private func abortStuckVideoRoute(message: String) {
        cancelVideoEntryWatchdog()
        videoSubmodePreparing = nil
        videoSubmodeRequest = UUID()
        setVideoSubmode(.timeLapse, enabled: false)
        setVideoSubmode(.slowMotion, enabled: false)
        setVideoSubmode(.cinematic, enabled: false)
        // 超时路径不能走 setCaptureKind 的 videoBusy guard，否则会停在视频图并冻结预览。
        captureKindSwitching = false
        camera.setVideoMode(false)
        captureKind = .photo
        ratio = FrameRatio.photoOptions.contains(photoRatioBeforeVideo) ? photoRatioBeforeVideo : .standard
        restorePhotoStateAfterVideo()
        camera.message = message
        scheduleCaptureStateSave()
        let abortedAt = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.captureKind == .photo, !self.captureKindSwitching,
                  !self.camera.recoveringSession, !self.camera.videoConfiguring,
                  self.camera.latestPreviewFrameTime < abortedAt else { return }
            self.camera.retrySessionRecovery()
        }
    }

    private func finishCaptureKindSwitch(token: UUID, previousPreview: UIImage?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                self.camera.afterPendingSessionTasks { continuation.resume() }
            }
            let deadline = CACurrentMediaTime() + 2.0
            while CACurrentMediaTime() < deadline {
                guard self.captureKindSwitchToken == token else { return }
                if self.camera.ready, self.camera.preview !== previousPreview,
                   !self.camera.recoveringSession, !self.camera.videoConfiguring {
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard self.captureKindSwitchToken == token else { return }
            if self.captureKind == .photo {
                self.restorePhotoStateAfterVideo()
            }
            self.captureKindSwitching = false
            self.reconcileCaptureCapabilities()
        }
    }

    func toggleVideoRecording() {
        guard captureKind == .video, !captureKindSwitching else { return }
        if camera.videoRecording {
            camera.stopVideoRecording()
        } else if videoShutterEnabled {
            if cinematicVideoEnabled, !camera.cinematicVideoCaptureActive {
                startCinematicWhenReady()
                return
            }
            videoElapsed = 0
            camera.startVideoRecording(aspect: videoRatio.frameRatio, copyright: preferences.copyright, look: effectiveCaptureLook,
                                       logLUTCube: selectedLogLUTCube,
                                       burnLogLUT: logVideoLUTControlsEnabled && burnLogLUT,
                                       logLUTName: selectedLogLUTPreset?.displayName,
                                       lockWhiteBalance: preferences.lockVideoWhiteBalance,
                                       timeLapsePreset: timeLapseEnabled ? selectedTimeLapsePreset : nil,
                                       timeLapseEnabled: timeLapseEnabled,
                                       timeLapseInterval: timeLapseEnabled ? timeLapseInterval.seconds : nil,
                                       timeLapseFrameLimit: timeLapseEnabled ? timeLapseFrameCount.target : nil,
                                       cinematicVideo: cinematicVideoEnabled)
        }
    }

    /// 电影 UI 已开启但系统图尚未激活时，快门先完成设备/格式准备再自动开拍。
    private func startCinematicWhenReady() {
        guard !pendingCinematicStart, !camera.videoConfiguring else { return }
        pendingCinematicStart = true
        videoSubmodePreparing = .cinematic
        camera.prepareCinematicInput { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingCinematicStart = false }
                self.videoSubmodePreparing = nil
                guard success else {
                    self.camera.message = "当前镜头无法启用电影效果"
                    return
                }
                self.synchronizeVideoSettings()
                for _ in 0..<250 {
                    if self.camera.cinematicVideoCaptureActive, !self.camera.videoConfiguring { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard self.camera.cinematicVideoCaptureActive, !self.camera.videoConfiguring else {
                    self.camera.message = "电影效果尚未准备好，请稍后重试。"
                    return
                }
                self.toggleVideoRecording()
            }
        }
    }

    private func synchronizeVideoClock(recording: Bool) {
        videoClock?.cancel(); videoClock = nil
        guard recording else { endZoomDial(); return }
        videoElapsed = 0
        let start = CACurrentMediaTime()
        videoClock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.videoElapsed = CACurrentMediaTime() - start
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    /// 等系统实际激活后再允许开拍，不能把用户开关意图当作已生效的录像状态。
    private var frontVideoCenteringStarting: Bool { camera.frontVideoCenteringPreparing || (frontVideoCenteringRequested && !camera.frontVideoCenteringActive) }
    var videoShutterBusy: Bool { camera.videoConfiguring || videoSubmodePreparing == .cinematic || frontVideoCenteringStarting || (camera.videoBusy && !camera.videoRecording) || library.videoSaving || (logVideoLUTControlsEnabled && burnLogLUT && logLUTLoading) }
    var videoShutterEnabled: Bool {
        camera.videoRecording || (camera.ready && !camera.videoBusy && !camera.videoConfiguring && !frontVideoCenteringStarting && !library.videoSaving && !captureKindSwitching
            && videoSubmodePreparing != .cinematic
            && !camera.capturing && camera.pendingPhotoCount == 0
            && !(logVideoLUTControlsEnabled && burnLogLUT && (logLUTLoading || selectedLogLUTCube == nil)))
    }

    func flipCamera() {
        if photoResolution == .high { photoResolution = .standard }
        synchronizeHighResolutionPhotoRoute()
        guard !virtualApertureEnabled else { return }
        if camera.dualCaptureEnabled {
            camera.setDualCaptureEnabled(false) { [weak self] success in
                guard let self, success else { return }
                self.restoreVideoSettingsAfterDualCapture()
                Task { @MainActor [weak self] in
                    for _ in 0..<150 {
                        guard let self else { return }
                        if self.camera.ready && !self.camera.videoConfiguring { self.flipCamera(); return }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            return
        }
        guard !camera.videoBusy else { return }
        disableFrontVideoCenteringForManualChoice()
        cancelFocus()
        endZoomDial()
        guard camera.ready, !camera.capturing, let lens = oppositeLens else { return }
        // 视频前置保持照片的标准取景作为逻辑镜头；实际设备倍率由视频配置强制 wide。
        let target = captureKind == .video && lens.device.position == .front
            ? (camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard } ?? lens)
            : lens
        cancelCountdown()
        // 前后切镜沿用旧帧轻微模糊、新路由出帧后淡出的路径。
        // 新画面已确认后缩短收尾，避免后置管线较慢时额外叠加完整焦段淡出时长。
        startFocalTransition(fadeDuration: 0.10)
        camera.selectLens(target, transitionID: focalTransitionID); flash = false; focusPoint = nil
    }

    private var hardwareControlsUpdatePending = false
    private func scheduleHardwareControlsUpdate() {
        guard !hardwareControlsUpdatePending else { return }
        hardwareControlsUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hardwareControlsUpdatePending = false
            self.camera.updateHardwareControls(self.hardwareControlSpecs,
                enabled: self.cameraActiveRequested && !self.review && !self.settings && self.camera.ready && !self.camera.shutterBusy)
        }
    }

    var hardwareControlSpecs: [CameraHardwareControlSpec] {
        if mode == .auto {
            if fixedHighResolutionFocalsOnly { return [] }
            return [CameraHardwareControlSpec(id: "A.zoom", title: "变焦", icon: "plus.magnifyingglass",
                range: Float(zoomRange.lowerBound)...Float(zoomRange.upperBound), value: Float(camera.currentZoom))]
        }
        return [CameraParameter.shutter, .iso, .focus, .ev, .wb, .tint].compactMap { item in
            guard !(captureKind == .video && cinematicVideoEnabled && item == .focus) else { return nil }
            let range: ClosedRange<Double>, value: Double
            let live = camera.readings?.validated
            switch item {
            case .shutter: range = manualPhotoShutterRange; value = manualExposure ? shutter : log2(max(live?.seconds ?? pow(2, shutter), 0.000001))
            case .iso: range = manualPhotoISORange; value = manualExposure ? iso : live?.iso ?? iso
            case .focus: range = 0...1; value = manualFocus ? focus : live?.focus ?? focus
            case .ev: range = exposureCompensationRange; value = ev
            case .wb: range = 2500...9000; value = manualWB ? wb : live?.kelvin ?? wb
            case .tint: range = -150...150; value = manualWB ? whiteBalanceTint : live?.tint ?? whiteBalanceTint
            }
            guard range.lowerBound < range.upperBound else { return nil }
            var spec = CameraHardwareControlSpec(id: "M." + item.rawValue, title: parameterTitle(item), icon: parameterIcon(item),
                range: Float(range.lowerBound)...Float(range.upperBound), value: Float(value))
            if item == .shutter {
                var stops = CameraShutterStops.log2Durations(in: range).reversed().map(Float.init)
                if stops.count < 2 { stops = [Float(range.upperBound), Float(range.lowerBound)] }
                spec.choices = stops
                spec.choiceTitles = spec.choices.map { shutterText(pow(2, Double($0))) }
            }
            return spec
        }
    }

    func handleHardwareAdjustment(id: String, value: Float) {
        guard cameraActiveRequested, !review, !settings, camera.ready, !camera.shutterBusy, value.isFinite else { return }
        if id == "A.zoom" {
            guard mode == .auto else { return }
            camera.setContinuousZoom(min(max(CGFloat(value), zoomRange.lowerBound), zoomRange.upperBound))
        } else {
            guard mode == .manual, id.hasPrefix("M."), let item = CameraParameter(rawValue: String(id.dropFirst(2))) else { return }
            let previous = parameter
            parameter = item
            editableParameterBinding.wrappedValue = Double(value)
            parameter = previous
        }
    }

    func handleHardwareCapture(phase: AVCaptureEventPhase) {
        guard phase == .ended, cameraActiveRequested, !review, !settings else { return }
        if captureKind == .video { toggleVideoRecording() } else { takePhoto() }
    }

    func takePhoto() {
        guard captureKind == .photo else { toggleVideoRecording(); return }
        if photoFormat.needsRAW,
           currentPosition == .front || !camera.availablePhotoFormats.contains(photoFormat) {
            // 前置和无 RAW 的路由在切镜瞬间可能仍保留 RAW 选择；快门时自动回退，
            // 不能把已经按下的快门变成一条“请选择其他格式”的错误。
            photoFormat = camera.availablePhotoFormats.contains(.heif) ? .heif : .jpeg
            adaptiveHighDynamic = false
            hdr = false
        }
        guard !captureKindSwitching, !slowShutterComposing else { return }
        if slowShutterSequence != nil {
            finishSlowShutterSequenceEarly()
            return
        }
        if slowShutterEnabled {
            if let preset = selectedSlowShutterPreset, let spec = preset.sequenceSpec {
                startSlowShutterSequence(preset, spec: spec)
            } else {
                // No preset still means the user selected a slow-shutter
                // duration; use a neutral average-blend sequence.
                startSlowShutterSequence(nil, spec: SlowShutterSequenceSpec(
                    frameCount: max(2, Int((slowShutterDuration.seconds ?? 60) * 10)),
                    totalDuration: slowShutterDuration.seconds ?? 60,
                    blend: .average,
                    captureDuration: slowShutterDuration.seconds,
                    minimumFrames: 2))
            }
            return
        }
        closePopups()
        if countdown != nil { cancelCountdown(); return }
        guard camera.ready, !camera.highResolutionPhotoConfiguring, !camera.shutterBusy,
              camera.hasCaptureCapacity(for: photoOptions), library.canAcceptNewCapture else { return }
        guard timerSeconds > 0 else { camera.capture(flashMode: flashMode, options: photoOptions); return }
        let delay = timerSeconds
        let id = UUID()
        countdownID = id
        countdown = delay
        captureTask = Task { @MainActor [self] in
            for remaining in stride(from: delay, through: 1, by: -1) {
                guard !Task.isCancelled, countdownID == id else { return }
                countdown = remaining
                do { try await Task.sleep(for: .seconds(1)) }
                catch { if countdownID == id { countdown = nil }; return }
            }
            guard !Task.isCancelled, countdownID == id, camera.ready else {
                if countdownID == id { countdown = nil }
                return
            }
            countdown = nil
            camera.capture(flashMode: flashMode, options: photoOptions)
            captureTask = nil
        }
    }

    func cancelFocus() { focusLockPickerVisible = false; focusTask?.cancel(); focusTask = nil; focusPoint = nil; camera.unlockTargetExposure() }

    func cancelCountdown() {
        countdownID = UUID()
        captureTask?.cancel(); captureTask = nil; countdown = nil
    }

    private func startSlowShutterSequence(_ preset: SlowShutterPreset?, spec: SlowShutterSequenceSpec) {
        guard !slowShutterComposing, camera.ready, !camera.capturing, !camera.shutterBusy,
              camera.hasCaptureCapacity(for: photoOptions), library.canAcceptNewCapture else { return }
        guard let readings = camera.readings?.validated else {
            camera.message = "无法读取当前曝光，请稍后重试。"
            return
        }
        let exposurePreset = preset ?? .silkyWater
        let plan: AdaptiveSlowShutterExposurePlan?
        if preset == nil {
            // 无预设M挡使用完整硬件范围，不能暗中套用流水的曝光范围/最少帧。
            let exposure = AdaptiveWaterExposurePolicy.plan(meteredISO: readings.iso, meteredSeconds: readings.seconds,
                isoRange: camera.isoRange, shutterRange: camera.shutterRange,
                manualISO: mode == .manual && manualExposure ? iso : nil,
                manualSeconds: mode == .manual && manualExposure ? pow(2, shutter) : nil)
            plan = exposure.map { .init(iso: $0.iso, spec: SlowShutterSequenceSpec(frameCount: spec.frameCount,
                totalDuration: $0.seconds * Double(spec.frameCount), blend: spec.blend,
                exposureOverride: $0.seconds, captureDuration: spec.captureDuration, minimumFrames: spec.minimumFrames)) }
        } else {
            plan = AdaptiveSlowShutterExposurePolicy.plan(preset:exposurePreset,
            meteredISO:readings.iso,meteredSeconds:readings.seconds,hardwareISO:camera.isoRange,hardwareShutter:camera.shutterRange,
            manualISO:mode == .manual && manualExposure ? iso : nil,
            manualSeconds:mode == .manual && manualExposure ? pow(2,shutter) : nil)
        }
        guard let plan
        else { camera.message = "当前曝光无法在该预设与镜头范围内完成合成。"; return }
        let spec = plan.spec.applying(slowShutterDuration)
        let frameExposure = spec.frameExposureSeconds
        let shutterTarget = log2(frameExposure)
        let allowedShutter = slowShutterShutterRange
        guard allowedShutter.contains(shutterTarget) else {
            camera.message = "当前镜头不支持该预设的单帧曝光。"
            return
        }
        let allowedISO = slowShutterCaptureISORange
        let targetISO = plan.iso
        guard allowedISO.contains(targetISO) else {
            camera.message = "当前曝光超出该预设范围，请切到 M 挡或调整光线。"
            return
        }
        let format: PhotoFileFormat = (photoFormat == .jpeg || photoFormat == .heif) ? photoFormat : .jpeg
        let restore = SlowShutterSequenceRestore(
            photoFormat: photoFormat, photoResolution: photoResolution, hdr: hdr, live: livePhotoEnabled,
            timerSeconds: timerSeconds, flashMode: flashMode,
            manualExposure: manualExposure, manualWB: manualWB, manualFocus: manualFocus,
            iso: iso, shutter: shutter, wb: wb, tint: whiteBalanceTint, focus: focus)
        photoFormat = format
        photoResolution = .standard
        hdr = false
        livePhotoEnabled = false
        flashMode = .off
        timerSeconds = 0
        iso = min(max(targetISO, allowedISO.lowerBound), allowedISO.upperBound)
        shutter = shutterTarget
        manualExposure = true
        if !manualWB { wb = readings.kelvin; whiteBalanceTint = readings.tint ?? 0 }
        if !manualFocus { focus = readings.focus }
        manualWB = true
        manualFocus = true
        // A 挡虚拟多摄不能保证支持 custom 曝光；序列暂借 M 挡的物理输入路线，
        // 界面仍保留 A 挡。结束/取消统一按 restoreSlowShutterSequence 恢复自动路线。
        camera.setManualMode(true, customExposure: true)
        // 序列始终使用短曝光取景；支持时将真实快门/ISO绑定到单张静态包围请求，
        // 不支持时才临时切换曝光并等待系统完成，避免用预览参数冒充成片。
        camera.setSlowShutterSequencePreviewAssist(true, iso: iso, seconds: pow(2, shutter))
        camera.setSlowShutterPreviewOptimization(false)
        camera.setAutomaticExposureDurationLimit(nil)
        applyExposure()
        applyWhiteBalance()
        camera.setFocus(position: focus)
        selectedSlowShutterPreset = preset
        let presetTitle = preset?.title.replacingOccurrences(of: "\n", with: "") ?? "慢门"
        slowShutterSequence = SlowShutterSequenceState(token: UUID(), preset: exposurePreset,
                                                       presetTitle: presetTitle, spec: spec,
                                                       format: format, restore: restore)
        if exposurePreset.usesStreamingComposition {
            slowShutterSequence?.streamingComposer = SlowShutterComposer(blend: spec.blend, materializeFrames: true)
        }
        slowShutterSequenceProgress = SlowShutterSequenceProgress(completed:0,total:spec.frameCount,
            elapsedSeconds:0,targetSeconds:spec.captureDuration)
        let sequenceToken = slowShutterSequence?.token
        resetSlowShutterPreviewDelivery(id:sequenceToken)
        if let sequenceToken,let image = camera.preview {
            slowShutterAccumulationPreview = .init(id:sequenceToken,image:image,revision:0)
        } else { slowShutterAccumulationPreview = nil }
        Task { @MainActor [weak self] in
            // 先让先前排队的前台/后台生命周期回调提交到会话队列，避免首帧被旧stop取消。
            await Task.yield()
            guard let self else { return }
            await withCheckedContinuation { c in self.camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<150 {
                guard self.slowShutterSequence?.token == sequenceToken else { return }
                if self.camera.ready && !self.camera.shutterBusy && self.camera.pendingPhotoCount == 0 {
                    self.captureNextSlowShutterFrame(); return
                }
                try? await Task.sleep(for:.milliseconds(20))
            }
            if self.slowShutterSequence?.token == sequenceToken {
                self.failSlowShutterSequence("慢门拍摄准备超时，请稍后重试。")
            }
        }
    }

    private func captureNextSlowShutterFrame() {
        guard let state = slowShutterSequence else { return }
        var options = photoOptions
        options.format = state.format
        options.resolution = .standard
        options.hdr = false
        options.live = false
        options.nightMode = false
        options.portraitMode = false
        options.saveUnfilteredOriginal = false
        options.purpose = .slowShutterSequence(state.token)
        options.shootingType = state.presetTitle + "（多帧）"
        guard camera.hasCaptureCapacity(for: options) else {
            failSlowShutterSequence("相机处理队列已满，慢门合成已停止。")
            return
        }
        camera.capture(flashMode: .off, options: options)
        scheduleSlowShutterWatchdog()
    }

    private func scheduleSlowShutterWatchdog() {
        slowShutterFrameWatchdog?.cancel()
        guard let state = slowShutterSequence else { return }
        let token = state.token
        let expectedCount = state.completedFrames
        slowShutterFrameWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self,
                  self.slowShutterSequence?.token == token,
                  self.slowShutterSequence?.completedFrames == expectedCount else { return }
            self.failSlowShutterSequence("慢门拍摄等待超时，请检查相机状态。")
        }
    }

    private func handleSlowShutterSourceFrame(_ frame: SlowShutterSourceFrame?) {
        guard var state = slowShutterSequence else { return }
        guard let frame else {
            failSlowShutterSequence("慢门帧拍摄失败。")
            return
        }
        // 迟到源帧不得进入用户取消后新建的序列。
        guard frame.sequenceID == state.token else { return }
        let receivedAt = CACurrentMediaTime()
        if state.firstSourceTime == nil { state.firstSourceTime = receivedAt }
        state.lastSourceTime = receivedAt
        // 按本预设检查实际曝光，不能拿短曝光预览冒充真实源帧。
        if let exif = frame.image.properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber,
           abs(exposure.doubleValue - state.spec.frameExposureSeconds) > max(0.00005, state.spec.frameExposureSeconds * 0.02) {
            failSlowShutterSequence(String(format:"相机未应用慢门曝光（实际%.6f秒，预期%.6f秒），已停止本次合成。", exposure.doubleValue, state.spec.frameExposureSeconds))
            return
        }
        slowShutterFrameWatchdog?.cancel()
        slowShutterFrameWatchdog = nil
        if let composer = state.streamingComposer {
            // 只保留首帧的原始拍摄信息；不把整个长序列的解码源图放在内存中。
            if state.frames.isEmpty { state.frames.append(frame) }
            state.streamFramePending = true
            let rendersPreview = state.lastPreviewTime == nil || receivedAt-(state.lastPreviewTime ?? 0)>=0.5
            if rendersPreview { state.lastPreviewTime = receivedAt }
            let previewLook = effectiveCaptureLook
            slowShutterSequence = state
            let token = state.token
            slowShutterCompositionQueue.async { [weak self] in
                let (succeeded,preview) = autoreleasepool { () -> (Bool,UIImage?) in
                    let succeeded = composer.add(frame.image)
                    return (succeeded,succeeded && rendersPreview ? composer.renderPreview(look:previewLook):nil)
                }
                DispatchQueue.main.async {
                    guard let self, var current = self.slowShutterSequence, current.token == token else { return }
                    guard succeeded else { self.failSlowShutterSequence("慢门逐帧合并失败。"); return }
                    current.streamFramePending = false
                    current.completedFrames += 1
                    self.slowShutterSequence = current
                    if let preview {
                        self.enqueueSlowShutterPreview(.init(id:token,image:preview,revision:current.completedFrames))
                    }
                    self.advanceSlowShutterSequence()
                }
            }
        } else {
            state.frames.append(frame)
            state.completedFrames += 1
            slowShutterSequence = state
            advanceSlowShutterSequence()
        }
    }

    private func advanceSlowShutterSequence() {
        guard let state = slowShutterSequence else { return }
        let elapsed = state.firstSourceTime.map { CACurrentMediaTime() - $0 } ?? 0
        slowShutterSequenceProgress = SlowShutterSequenceProgress(completed:state.completedFrames,total:state.spec.frameCount,
            elapsedSeconds:elapsed,targetSeconds:state.spec.captureDuration)
        // 合并耗时不能冒充采样跨度；以首末原生源帧交付时间判断，必要时再采一帧。
        let sampledSpan = (state.lastSourceTime ?? 0)-(state.firstSourceTime ?? 0)
        let durationReached = state.spec.captureDuration.map { sampledSpan >= $0 && state.completedFrames >= state.spec.minimumFrames } ?? false
        if state.completedFrames >= state.spec.frameCount || state.finishRequested || durationReached {
            finishSlowShutterSequence()
        } else {
            // 源帧回调已在硬件完成、容量释放之后交付；逐帧合并也已完成。
            // 直接提交下一张，不再额外插入固定 60 毫秒空档。
            captureNextSlowShutterFrame()
        }
    }

    private func resetSlowShutterPreviewDelivery(id:UUID? = nil) {
        slowShutterPreviewTask?.cancel();slowShutterPreviewTask=nil
        slowShutterPendingPreview=nil;slowShutterLastPreviewPublishedAt=nil;slowShutterPreviewID=id
    }

    /// 以真正的主线程发布时间限频；只保留最新一张，不阻塞继续采集。
    private func enqueueSlowShutterPreview(_ preview:SlowShutterAccumulationPreview) {
        guard slowShutterPreviewID == preview.id else {return}
        slowShutterPendingPreview=preview
        guard slowShutterPreviewTask == nil else {return}
        let delay=max(0,0.5-(CACurrentMediaTime()-(slowShutterLastPreviewPublishedAt ?? -.infinity)))
        if delay == 0 {publishPendingSlowShutterPreview(id:preview.id);return}
        let id=preview.id
        slowShutterPreviewTask=Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(delay))
            guard !Task.isCancelled,let self,self.slowShutterPreviewID == id else {return}
            self.slowShutterPreviewTask=nil
            self.publishPendingSlowShutterPreview(id:id)
        }
    }

    private func publishPendingSlowShutterPreview(id:UUID) {
        guard slowShutterPreviewID == id,let preview=slowShutterPendingPreview else {return}
        slowShutterPendingPreview=nil
        slowShutterLastPreviewPublishedAt=CACurrentMediaTime()
        slowShutterAccumulationPreview=preview
        // @Published会在赋值前通知订阅者；同步取消后不能让外层赋值重新留下旧画面。
        if slowShutterPreviewID != id,slowShutterAccumulationPreview?.id == id {slowShutterAccumulationPreview=nil}
    }

    private func finishSlowShutterSequenceEarly() {
        guard let state = slowShutterSequence else { return }
        if state.streamFramePending || camera.shutterBusy || camera.pendingPhotoCount > 0 {
            // 等原生出片及正在合并的这一帧完成，再恢复输入，避免曝光中途切换路线。
            slowShutterSequence?.finishRequested = true
            return
        }
        if state.completedFrames == 0 { cancelSlowShutterSequence(); return }
        finishSlowShutterSequence()
    }

    private func finishSlowShutterSequence() {
        slowShutterFrameWatchdog?.cancel()
        slowShutterFrameWatchdog = nil
        guard let state = slowShutterSequence else { return }
        slowShutterSequence = nil
        slowShutterComposing = true
        let token = UUID()
        slowShutterCompositionToken = token
        slowShutterSequenceProgress = SlowShutterSequenceProgress(completed: state.completedFrames, total: state.spec.frameCount)
        var options = photoOptions
        options.format = state.format
        options.resolution = .standard
        options.hdr = false
        options.live = false
        options.nightMode = false
        options.portraitMode = false
        options.saveUnfilteredOriginal = false
        options.purpose = .standard
        options.shootingType = state.presetTitle + "（多帧）"
        let input = SlowShutterCompositionInput(
            frames: state.frames, format: state.format, presetTitle: state.presetTitle,
            blend: state.spec.blend, frameCount: state.completedFrames, options: options,
            // 使用首帧快门时确定的方向与画幅，避免横持源帧被按竖幅二次裁切。
            look: state.frames.first?.look ?? effectiveCaptureLook, location: state.frames.first?.location,
            captureMode: mode == .auto ? "A" : "M", streamingComposer: state.streamingComposer,
            captureSeconds:state.spec.captureDuration == nil ? nil : state.firstSourceTime.map { CACurrentMediaTime() - $0 })
        let previewSequenceID = state.token
        restoreSlowShutterSequence(state.restore)
        slowShutterCompositionQueue.async { [weak self] in
            let result = Self.composeSlowShutter(input)
            DispatchQueue.main.async {
                guard let self, self.slowShutterCompositionToken == token else { return }
                self.resetSlowShutterPreviewDelivery()
                self.slowShutterCompositionToken = nil
                self.slowShutterComposing = false
                self.slowShutterSequenceProgress = nil
                switch result {
                case .success(let photo):
                    self.slowShutterAccumulationPreview = .init(id:previewSequenceID,image:photo.preview,revision:input.frameCount+1,isFinal:true)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.65) {
                        if self.slowShutterAccumulationPreview?.id == previewSequenceID { self.slowShutterAccumulationPreview = nil }
                    }
                    self.library.acceptCapture(photo, automaticallySave: true)
                case .failure(let error):
                    self.slowShutterAccumulationPreview = nil
                    self.camera.message = "慢门合成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func composeSlowShutter(_ input: SlowShutterCompositionInput) -> Result<CapturedPhoto, Error> {
        do {
            let context = CIContext(options: [.cacheIntermediates: false])
            let composer = input.streamingComposer ?? SlowShutterComposer(blend: input.blend, context: context)
            let sourceMetadata = input.frames.first?.image.properties
            if input.streamingComposer == nil {
                for frame in input.frames { composer.add(frame.image) }
            }
            guard composer.frameCount == input.frameCount else { throw PhotoEncodingError.encoding }
            guard var merged = composer.result else { throw PhotoEncodingError.encoding }
            if let sourceMetadata { merged = merged.settingProperties(sourceMetadata) }
            var look = input.look
            // 慢门源帧可能仍以传感器横向像素交付，而拍摄方向是竖屏。
            // 若直接交给 PhotoEncoder，会按竖幅把 4000×3000 裁成 2250×3000。
            // 先按首帧目标方向归一化，再做画幅裁切，保留完整约12MP。
            let targetLandscape = look.landscape
            let pixelLandscape = merged.extent.width > merged.extent.height
            if targetLandscape != pixelLandscape {
                merged = merged.oriented(.right)
            }
            look.landscape = merged.extent.width > merged.extent.height
            var photo = try PhotoEncoder.encode(source: merged, raw: nil, look: look, options: input.options,
                                                context: context, location: input.location)
            // Preserve the per-frame diagnostics (parameters, filter, lens) from
            // the first frame; otherwise the detail sheet shows only two rows.
            var diagnostics = input.frames.first?.diagnostics ?? PhotoCaptureDiagnostics()
            // A 挡临时借用物理手动路线不改变用户拍摄挡位，真实曝光仍取首帧 EXIF。
            diagnostics.parameters?.mode = input.captureMode
            diagnostics.add("拍摄模式", input.captureMode)
            diagnostics.add("慢门合成", "\(input.presetTitle) · \(composer.effectiveFrameCount) 帧")
            diagnostics.add("合成方式", input.blend == .handheldAlignedLighten ? (composer.usedSingleFrameFallback ? "背景对齐不足，使用清晰单帧" : "手持背景对齐亮部叠加") : input.blend == .lighten ? "亮部叠加"
                : input.blend == .handheldAlignedMotionBlur ? (composer.usedSingleFrameFallback ? "背景对齐不足，使用清晰单帧" : "背景锁定 + 运动轨迹增强")
                : input.blend == .subjectAlignedPanning ? (composer.usedSingleFrameFallback ? "中央主体对齐不足，使用清晰单帧" : "主体锁定 + 背景方向模糊")
                : input.blend == .subjectAlignedAverage ? (composer.usedSingleFrameFallback ? "中央主体对齐不足，使用清晰单帧" : "中央主体对齐平均")
                : input.blend == .handheldAlignedAverage ? (composer.usedSingleFrameFallback ? "背景对齐不足，使用清晰单帧" : "手持全画面对齐平均") : "多帧平均")
            if input.blend == .subjectAlignedAverage || input.blend == .subjectAlignedPanning
                || input.blend == .handheldAlignedAverage || input.blend == .handheldAlignedMotionBlur
                || input.blend == .handheldAlignedLighten {
                diagnostics.add("实际采集", "\(input.frameCount) 帧")
            }
            if input.blend == .handheldAlignedAverage || input.blend == .handheldAlignedMotionBlur
                || input.blend == .handheldAlignedLighten || input.blend == .subjectAlignedAverage
                || input.blend == .subjectAlignedPanning {
                diagnostics.add("对齐剔除", "\(composer.rejectedFrameCount) 帧")
            }
            if let seconds = input.captureSeconds { diagnostics.add("采集时长",String(format:"%.2f 秒",seconds)) }
            if let exif = sourceMetadata?[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let seconds = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
                diagnostics.add("累计曝光", String(format: "%.3g 秒（%d 帧）", seconds.doubleValue * Double(composer.effectiveFrameCount), composer.effectiveFrameCount))
            }
            photo.diagnostics = diagnostics
            return .success(photo)
        } catch {
            return .failure(error)
        }
    }

    private func failSlowShutterSequence(_ message: String) {
        resetSlowShutterPreviewDelivery()
        slowShutterAccumulationPreview = nil
        slowShutterFrameWatchdog?.cancel()
        slowShutterFrameWatchdog = nil
        guard let state = slowShutterSequence else { return }
        slowShutterSequence = nil
        slowShutterSequenceProgress = nil
        restoreSlowShutterSequence(state.restore)
        camera.message = message
    }

    private func cancelSlowShutterSequence() {
        resetSlowShutterPreviewDelivery()
        slowShutterAccumulationPreview = nil
        slowShutterFrameWatchdog?.cancel()
        slowShutterFrameWatchdog = nil
        if slowShutterComposing {
            slowShutterCompositionToken = nil
            slowShutterComposing = false
            slowShutterSequenceProgress = nil
            return
        }
        guard let state = slowShutterSequence else { return }
        slowShutterSequence = nil
        slowShutterSequenceProgress = nil
        restoreSlowShutterSequence(state.restore)
        camera.message = "已取消慢门合成。"
    }

    private func restoreSlowShutterSequence(_ restore: SlowShutterSequenceRestore) {
        // 先释放原物理输入的序列帧时长，再恢复 A/M 路线，避免长曝光时长带入切镜事务。
        camera.clearSlowShutterSequenceCaptureExposure()
        // 普通慢门辅助先接管，再释放序列辅助，避免恢复 M 挡的瞬间提交一次
        // 无人等待的长曝光，随后又被自动预览覆盖，阻塞下一次格式/预设切换。
        applySlowShutterExposurePolicy()
        camera.setSlowShutterSequencePreviewAssist(false, iso: nil, seconds: nil)
        photoFormat = restore.photoFormat
        photoResolution = restore.photoResolution
        hdr = restore.hdr
        livePhotoEnabled = restore.live
        timerSeconds = restore.timerSeconds
        flashMode = restore.flashMode
        manualExposure = restore.manualExposure
        manualWB = restore.manualWB
        manualFocus = restore.manualFocus
        iso = restore.iso
        shutter = restore.shutter
        wb = restore.wb
        whiteBalanceTint = restore.tint
        focus = restore.focus
        camera.setManualMode(mode == .manual, customExposure: mode == .manual && manualExposure)
        applyExposure()
        applyWhiteBalance()
        camera.setFocus(position: manualFocus ? focus : nil)
        applySlowShutterExposurePolicy()
    }

    func togglePanel(_ requested: CameraPanel) {
        guard requested != .film || filterControlsEnabled else { return }
        endZoomDial()
        if requested == .film && panel != .film {
            filters.showStrength = false
            if !logVideoLUTControlsEnabled && !filters.styles.contains(style) { filters.category = .all }
        }
        withAnimation(AppTheme.popupAnimation) {
            focusLockPickerVisible = false
            functions = false; tools = false; shootingModes = false; toolbarPanel = nil
            panel = panel == requested ? nil : requested
        }
    }

    func selectFilterCategory(_ category: FilterCategory) {
        filters.category = category
        if let first = filters.styles.first, !filters.styles.contains(style) { style = first }
    }

    func toggleFilterFavorite() {
        filters.toggleFavorite(style)
        if filters.category == .favorites { selectFilterCategory(.favorites) }
    }

    func swipeFilter(translation: CGSize) {
        guard filterControlsEnabled, !logVideoLUTControlsEnabled, !camera.videoBusy, panel == .film, abs(translation.width) >= 44,
              abs(translation.width) > abs(translation.height) * 1.25 else { return }
        let choices = filters.styles
        guard !choices.isEmpty else { return }
        guard let current = choices.firstIndex(of: style) else { style = choices[0]; return }
        let next = min(max(current + (translation.width < 0 ? 1 : -1), 0), choices.count - 1)
        style = choices[next]
    }

    var currentPosition: AVCaptureDevice.Position {
        camera.lenses.first(where: { $0.id == camera.selectedLens })?.device.position ?? .back
    }

    var oppositeLens: CameraLens? {
        if currentPosition == .back {
            return camera.lenses.first(where: { $0.device.position == .front })
        }
        return camera.lenses.first(where: { $0.id == lastBackLensID && $0.device.position == .back })
            ?? camera.lenses.first(where: { $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera })
            ?? camera.lenses.first(where: { $0.device.position == .back })
    }

    func parameterIsManual(_ item: CameraParameter) -> Bool {
        guard mode == .manual else { return false }
        switch item {
        case .shutter, .iso: return manualExposure
        case .wb, .tint: return manualWB
        case .focus: return manualFocus
        case .ev: return false // Compensation applies to automatic exposure; it has no manual switch.
        }
    }

    var parameterAutomatic: Bool {
        switch parameter {
        case .ev: return !manualExposure
        case .iso, .shutter: return !manualExposure
        case .wb, .tint: return !manualWB
        case .focus: return !manualFocus
        }
    }

    var parameterRange: ClosedRange<Double> {
        switch parameter {
        case .ev: return exposureCompensationRange
        case .iso: return manualPhotoISORange
        case .shutter: return manualPhotoShutterRange
        case .wb: return 2500...9000
        case .tint: return -150...150
        case .focus: return 0...1
        }
    }

    var manualPhotoISORange: ClosedRange<Double> {
        nightModeEnabled && captureKind == .photo && mode == .manual
            ? NightManualExposurePolicy.isoRange(hardware:camera.isoRange) : slowShutterISORange
    }
    var manualPhotoShutterRange: ClosedRange<Double> {
        nightModeEnabled && captureKind == .photo && mode == .manual
            ? NightManualExposurePolicy.shutterRange(hardware:camera.shutterRange) : slowShutterShutterRange
    }

    /// 每个刻度对应实际参数的一格；慢门预设改变范围时同步重新生成刻度。
    var parameterTickValues: [Double] {
        CameraRulerTickValues.values(for: parameter, in: parameterRange)
    }

    var parameterBinding: Binding<Double> {
        Binding(get: { [self] in
            switch parameter {
            case .ev: return ev
            case .iso: return iso
            case .shutter: return shutter
            case .wb: return wb
            case .tint: return whiteBalanceTint
            case .focus: return focus
            }
        }, set: { [self] value in
            guard value.isFinite else { return }
            switch parameter {
            case .ev: ev = value; applyExposure()
            case .iso: iso = value; applyExposure()
            case .shutter: shutter = value; applyExposure()
            case .wb: wb = min(max(value, 2500), 9000); applyWhiteBalance()
            case .tint: whiteBalanceTint = min(max(value, -150), 150); applyWhiteBalance()
            case .focus: focus = value; camera.setFocus(position: manualFocus ? focus : nil)
            }
        })
    }

    func toggleAutomatic() {
        switch parameter {
        case .ev: activateParameterAuto()
        case .iso, .shutter:
            if !manualExposure { synchronizeExposureValues() }
            manualExposure.toggle(); applyExposure()
        case .wb, .tint:
            if !manualWB { synchronizeWhiteBalanceValues() }
            manualWB.toggle(); applyWhiteBalance()
        case .focus:
            if !manualFocus, let readings = camera.readings?.validated { focus = readings.focus }
            manualFocus.toggle(); camera.setFocus(position: manualFocus ? focus : nil)
        }
    }

    func synchronizeWhiteBalanceValues() {
        guard let readings = camera.readings?.validated else { return }
        if readings.kelvin > 0 { wb = min(max(readings.kelvin, 2500), 9000) }
        if let tint = readings.tint { whiteBalanceTint = min(max(tint, -150), 150) }
    }

    func applyWhiteBalance() {
        camera.setWhiteBalance(kelvin: manualWB ? wb : nil, tint: manualWB ? whiteBalanceTint : 0)
    }

    func synchronizeExposureValues() {
        guard let readings = camera.readings?.validated else { return }
        iso = min(max(readings.iso, manualPhotoISORange.lowerBound), manualPhotoISORange.upperBound)
        shutter = min(max(log2(max(readings.seconds, 0.000001)), manualPhotoShutterRange.lowerBound), manualPhotoShutterRange.upperBound)
    }

    func applyExposure() {
        if manualModeRouteSettling { return }
        if manualExposure && nightModeEnabled && captureKind == .photo && mode == .manual {
            // 所有入口（刻度、实体按键、恢复设置）共用范围，不能只限制屏幕滑块。
            iso = min(max(iso,manualPhotoISORange.lowerBound),manualPhotoISORange.upperBound)
            shutter = min(max(shutter,manualPhotoShutterRange.lowerBound),manualPhotoShutterRange.upperBound)
        }
        camera.setExposure(iso:manualExposure && !cinematicAutomaticControls ? iso:nil,seconds:manualExposure && !cinematicAutomaticControls ? pow(2,shutter):nil,bias:ev)
    }

    /// Both preset taps and continuous zoom publish the new device's capabilities here.
    /// Keep automatic/manual choices; only fit numeric exposure values to the new lens.
    func didChangeLensDevice(_ id: String, isoRange: ClosedRange<Double>, shutterRange: ClosedRange<Double>) {
        guard activeDeviceID != id else { return }
        activeDeviceID = id
        // 输入替换属于序列准备过程，已锁定参数由序列管理，不重新应用普通预设策略。
        guard slowShutterSequence == nil else { return }
        let presetISO = slowShutterEnabled ? selectedSlowShutterPreset?.isoRange(limitedTo: isoRange) : nil
        let presetShutter = slowShutterEnabled ? selectedSlowShutterPreset?.shutterRange(limitedTo: shutterRange) : nil
        if slowShutterEnabled, selectedSlowShutterPreset != nil, presetISO == nil || presetShutter == nil {
            selectedSlowShutterPreset = nil
        }
        let effectiveISO = presetISO ?? isoRange
        let effectiveShutter = presetShutter ?? shutterRange
        iso = min(max(iso, effectiveISO.lowerBound), effectiveISO.upperBound)
        shutter = min(max(shutter, effectiveShutter.lowerBound), effectiveShutter.upperBound)
        applyExposure()
        applyWhiteBalance()
        camera.setFocus(position: manualFocus ? focus : nil)
        camera.setMetering(effectiveMetering)
        applySlowShutterExposurePolicy()
    }

    func resetParameters() {
        manualExposure = false; manualWB = false; manualFocus = false; ev = 0
        iso = min(max(100, slowShutterISORange.lowerBound), slowShutterISORange.upperBound)
        shutter = min(max(log2(1.0 / 125), slowShutterShutterRange.lowerBound), slowShutterShutterRange.upperBound)
        applyExposure(); camera.setWhiteBalance(kelvin: nil); camera.setFocus(position: nil)
    }

    private func saveFilterSettings() {
        filterSettings.set(SavedFilterSettings(intensity: intensity, adjustments: filterAdjustments), for: style)
    }
    private func restoreFilterSettingsForOriginal() {
        restoringFilterSettings = true
        style = .original
        intensity = 0.8
        filterAdjustments = FilterAdjustments()
        restoringFilterSettings = false
    }

    private func restoreFilterSettings() {
        let saved = filterSettings.settings(for: style)
        restoringFilterSettings = true
        intensity = saved.intensity; filterAdjustments = saved.adjustments
        restoringFilterSettings = false
    }
    func flushFilterSettings() { filterSettings.flush(); flushCaptureSettings() }
    func setFilterParameterEditing(_ editing: Bool) {
        guard editing != filterParameterEditing else { return }
        filterParameterEditing = editing
        camera.setFilterParameterEditing(editing)
        if !editing { updateLook(); flushFilterSettings() }
    }
    func presentFilterReset() {
        setFilterParameterEditing(false)
        filterResetStyle = style; filterResetVisible = true
    }
    func dismissFilterReset() { filterResetVisible = false; filterResetStyle = nil }
    func confirmFilterReset() {
        guard filterResetVisible, filterResetStyle == style else { dismissFilterReset(); return }
        resetCurrentFilter()
        CameraHaptics.success()
    }
    func resetCurrentFilter() {
        dismissFilterNumericInput()
        setFilterParameterEditing(false)
        dismissFilterReset()
        filterResetRevision &+= 1
        restoringFilterSettings = true
        intensity = 0.8; filterAdjustments = FilterAdjustments()
        restoringFilterSettings = false
        saveFilterSettings(); flushFilterSettings(); updateLook()
    }
    /// 分类还原仅处理当前页参数；推进代次，防止还原前的滑动/输入事件再次写回。
    func resetCurrentFilterTab() {
        guard filterControlsEnabled, !camera.videoBusy, !filterResetVisible else { return }
        dismissFilterNumericInput()
        setFilterParameterEditing(false)
        filterResetRevision &+= 1
        var next = filterAdjustments
        for parameter in filterEditorTab.parameters where parameter != .strength {
            next[parameter] = parameter.defaultValue
        }
        restoringFilterSettings = true
        if filterEditorTab.parameters.contains(.strength) { intensity = FilterParameter.strength.defaultValue / 100 }
        filterAdjustments = next
        restoringFilterSettings = false
        saveFilterSettings(); flushFilterSettings(); updateLook()
    }
    func filterParameterText(_ parameter: FilterParameter) -> String {
        if parameter == .strength && style == .original { return "—" }
        return parameter.text(filterParameterBinding(parameter).wrappedValue)
    }
    /// 拍照固定使用调色盘，录像取景延续升级前保存的编辑样式。
    var usesFilterDialPad: Bool { captureKind == .photo || preferences.videoFilterDialPad }

    /// 输入框只编辑草稿，确认时才经受保护的参数绑定提交，取消不会改写配方。
    func presentFilterNumericInput(_ parameter: FilterParameter) {
        guard usesFilterDialPad, filterControlsEnabled, !camera.videoBusy,
              panel == .film, filters.showStrength, !(parameter == .strength && style == .original) else { return }
        setFilterParameterEditing(false)
        dismissFilterReset()
        let binding = filterParameterBinding(parameter)
        filterNumericBinding = binding
        filterNumericDraft = String(binding.wrappedValue)
        filterNumericParameter = parameter
    }
    var filterNumericValue: Double? { filterNumericParameter?.inputValue(from: filterNumericDraft) }
    func restoreFilterNumericDraft() {
        guard let parameter = filterNumericParameter else { return }
        filterNumericDraft = String(parameter.defaultValue)
    }
    func confirmFilterNumericInput() {
        guard let value = filterNumericValue, let binding = filterNumericBinding else { return }
        binding.wrappedValue = value
        flushFilterSettings()
        dismissFilterNumericInput()
    }
    func dismissFilterNumericInput() {
        filterNumericParameter = nil; filterNumericBinding = nil; filterNumericDraft = ""
    }
    func filterParameterBinding(_ parameter: FilterParameter) -> Binding<Double> {
        let revision = filterResetRevision, selectedStyle = style
        return Binding(get: { [self] in parameter == .strength ? (style == .original ? 0 : intensity * 100) : filterAdjustments[parameter] },
                set: { [self] value in
                    guard filterControlsEnabled, !camera.videoBusy, !filterResetVisible, revision == filterResetRevision, style == selectedStyle else { return }
                    if parameter == .strength { if style != .original { intensity = parameter.clamped(value) / 100 } }
                    else { filterAdjustments[parameter] = value }
                })
    }
    /// 二维盘一次提交两项独立参数；沿用旧滑条的重置、格式与录制保护。
    /// 不联动改写柔光/卤化，也不改变基础滤镜浓度的作用范围。
    func filterParameterPairBinding(_ x: FilterParameter, _ y: FilterParameter) -> Binding<CGPoint> {
        let revision = filterResetRevision, selectedStyle = style, selectedTab = filterEditorTab
        return Binding(get: { [self] in CGPoint(x: filterAdjustments[x], y: filterAdjustments[y]) },
                       set: { [self] point in
            guard filterControlsEnabled, !camera.videoBusy, !filterResetVisible,
                  revision == filterResetRevision, style == selectedStyle, filterEditorTab == selectedTab,
                  x != .strength, y != .strength, point.x.isFinite, point.y.isFinite else { return }
            var next = filterAdjustments
            next[x] = Double(point.x); next[y] = Double(point.y)
            guard next != filterAdjustments else { return }
            filterAdjustments = next
        })
    }
    func updateLook() { camera.updateLook(effectiveCaptureLook, photoFormat: photoFormat); refreshFocusNavigatorPreference() }
    func refreshFocusNavigatorPreference() {
        camera.configureFocusNavigator(enabled: preferences.focusAssist, zoom: camera.currentZoom, ratio: ratio.portraitRatio,
            allowed: captureKind == .photo && !portraitModeEnabled && !slowShutterEnabled && !nightModeEnabled && !camera.dualCaptureEnabled)
    }

    private func captureStateSnapshot() -> SavedCaptureState {
        var state = SavedCaptureState()
        state.video = captureKind == .video; state.mode = mode.rawValue
        state.photoMode = photoModeBeforeVideo.rawValue; state.photoRatio = photoRatioBeforeVideo.rawValue
        state.videoMode = (captureKind == .video ? mode : videoModeBeforePhoto).rawValue
        state.ratio = ratio.rawValue; state.photoFormat = photoFormat.rawValue; state.photoResolution = photoResolution.rawValue
        state.flash = flashMode.rawValue; state.live = livePhotoEnabled; state.hdr = hdr; state.nightMode = false
        state.adaptiveHighDynamic = adaptiveHighDynamic
        state.portraitMode = portraitModeEnabled
        state.portraitBlurStrength = portraitBlurStrength
        state.slowShutter = slowShutterEnabled
        state.slowShutterPreset = selectedSlowShutterPreset?.rawValue
        state.slowShutterDuration = slowShutterDuration.rawValue
        state.slowShutterAutomaticPreset = (mode == .auto ? selectedSlowShutterPreset : slowShutterAutomaticPreset)?.rawValue
        state.slowShutterAutomaticDuration = (mode == .auto ? slowShutterDuration : slowShutterAutomaticDuration).rawValue
        state.timeLapseEnabled = timeLapseEnabled
        state.timeLapsePreset = selectedTimeLapsePreset?.rawValue
        state.timeLapseInterval = timeLapseInterval.rawValue
        state.timeLapseFrameCount = timeLapseFrameCount.rawValue
        state.slowMotionEnabled = slowMotionEnabled
        state.cinematicVideoEnabled = cinematicVideoEnabled
        state.tone = tone.rawValue; state.metering = metering.rawValue
        state.style = style.rawValue; state.intensity = intensity; state.adjustments = filterAdjustments
        state.manual = SavedManualCaptureState(exposure: manualExposure, whiteBalance: manualWB, focusLocked: manualFocus,
            iso: iso, shutter: shutter, wb: wb, tint: whiteBalanceTint, focus: focus, ev: ev)
        state.previousManual = savedManualSettings; state.automaticEV = automaticEV
        state.photoManualBeforeVideo = captureKind == .video ? photoManualSettingsBeforeVideo : nil
        // 双拍属于本次手动开启的会话状态，不随“保存拍摄设置”在下次冷启动自动进入。
        state.virtualApertureEnabled = virtualApertureEnabled
        state.virtualAperture = virtualAperture
        state.dualCaptureEnabled = false
        state.dualCaptureFrontWide = restoredDualFrontWide ?? camera.dualCaptureFrontWide
        state.dualInsetLandscape = camera.dualCaptureInsetLandscape
        state.dualFrontWideBeforeLandscape = dualFrontWideBeforeLandscape
        state.dualInsetX = Double(camera.dualCaptureInsetRect.minX); state.dualInsetY = Double(camera.dualCaptureInsetRect.minY)
        state.videoResolution = videoResolution.rawValue; state.videoFrameRate = videoFrameRate.rawValue
        state.videoRatio = videoRatio.rawValue; state.videoOpenGate = videoOpenGateEnabled; state.videoColorSpace = videoColorSpace.rawValue
        state.videoCodec = videoCodec.rawValue; state.proRes = proResSpecification.rawValue
        state.logLUT = selectedLogLUTID; state.burnLogLUT = burnLogLUT
        state.toolPage = toolPage
        state.lensID = camera.selectedLens.isEmpty ? nil : camera.selectedLens
        state.lastBackLensID = lastBackLensID
        state.zoom = Double(camera.currentZoom); state.frontAutoCentering = false
        state.frontVideoCentering = frontVideoCenteringRequested
        state.frontLandscapePhoto = camera.frontPhotoLandscapeEnabled
        return state
    }

    private func scheduleCaptureStateSave() {
        guard preferences.saveCaptureSettings, !restoringCaptureState, pendingStartupCaptureState == nil else { return }
        captureStateWriteTask?.cancel()
        captureStateWriteTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flushCaptureSettings()
        }
    }

    func flushCaptureSettings() {
        captureStateWriteTask?.cancel(); captureStateWriteTask = nil
        guard preferences.saveCaptureSettings, !restoringCaptureState, pendingStartupCaptureState == nil else { return }
        preferencesStore.saveCaptureState(captureStateSnapshot())
    }

    #if DEBUG
    var startupCaptureRestorationPendingForTesting: Bool {
        pendingStartupCaptureState != nil || startupCaptureRestoreTask != nil || restoringCaptureState
    }
    /// 硬件回归复用唯一可见会话，只重置内存拍摄状态，避免创建相互争用相机的测试引擎。
    func resetCaptureStateForTesting() {
        closePopups(); settings = false; review = false
        library.resetDiagnosticStateForTesting()
        camera.message = nil
        pendingStartupCaptureState = nil
        photoManualSettingsBeforeVideo = nil
        restoreCaptureState(SavedCaptureState())
        camera.setManualMode(false)
        camera.setVideoMode(false)
    }
    #endif

    private func restoreCaptureState(_ state: SavedCaptureState) {
        restoringCaptureState = true; restoringVideoSettings = true
        func number(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        captureKind = state.video ? .video : .photo
        virtualAperture = VirtualApertureRenderer.clamped(state.virtualAperture ?? VirtualApertureRenderer.defaultValue)
        virtualApertureEnabled = (state.virtualApertureEnabled ?? false)
            && (!state.video || ((state.videoColorSpace == VideoColorSpace.sdr.rawValue || state.videoColorSpace == VideoColorSpace.p3.rawValue)
                && !(state.videoCodec == VideoCodec.proRes.rawValue && !(ProResSpecification(rawValue: state.proRes)?.isSelectable ?? false))
                && state.timeLapseEnabled != true && state.slowMotionEnabled != true && state.cinematicVideoEnabled != true))
        mode = CameraShootingMode(rawValue: state.mode) ?? .auto
        photoModeBeforeVideo = CameraShootingMode(rawValue: state.photoMode) ?? .auto
        photoManualSettingsBeforeVideo = state.photoManualBeforeVideo
        // 旧存档若停在视频，当前 mode 即视频挡位；停在照片则沿用默认 A 挡。
        videoModeBeforePhoto = CameraShootingMode(rawValue: state.videoMode ?? (state.video ? state.mode : "A")) ?? .auto
        let restoredPhotoRatio = FrameRatio(rawValue: state.photoRatio) ?? .standard
        photoRatioBeforeVideo = FrameRatio.photoOptions.contains(restoredPhotoRatio) ? restoredPhotoRatio : .standard
        videoResolution = VideoResolution(rawValue: state.videoResolution) ?? .hd1080
        videoFrameRate = VideoFrameRate(rawValue: state.videoFrameRate) ?? .fps30
        let restoredVideoRatio = VideoRatio(rawValue: state.videoRatio) ?? .ratio16x9
        let legacyOpenGate = restoredVideoRatio == .openGate
        videoRatio = legacyOpenGate ? .ratio4x3 : restoredVideoRatio
        videoOpenGateEnabled = state.videoOpenGate ?? legacyOpenGate
        if videoOpenGateEnabled && !VideoRatio.openGateAspectOptions.contains(videoRatio) { videoRatio = .ratio4x3 }
        videoColorSpace = VideoColorSpace(rawValue: state.videoColorSpace) ?? .sdr
        videoCodec = VideoCodec(rawValue: state.videoCodec) ?? .hevc
        proResSpecification = ProResSpecification(rawValue: state.proRes) ?? .hq
        if !proResSpecification.isSelectable && !externalVideoStorage.available {
            videoCodec = .hevc; proResSpecification = .hq
        }
        let restoredRatio = FrameRatio(rawValue: state.ratio) ?? .standard
        ratio = captureKind == .video ? videoRatio.frameRatio : (FrameRatio.photoOptions.contains(restoredRatio) ? restoredRatio : .standard)
        photoFormat = PhotoFileFormat(rawValue: state.photoFormat) ?? .jpeg
        photoResolution = PhotoResolution(rawValue: state.photoResolution) ?? .standard
        let restoringPortrait = captureKind == .photo && (state.portraitMode ?? false)
        if restoringPortrait {
            if !PortraitCapturePolicy.supports(format: photoFormat, resolution: photoResolution, live: false,
                                                hdr: false, proRAWAvailable: camera.supportsProRAW) {
                photoFormat = .heif
            }
        }
        hdr = state.hdr && (photoFormat == .heif || photoFormat == .heifPro) && !preferences.auxiliaryWatermark
        adaptiveHighDynamic = state.adaptiveHighDynamic == true && photoFormat == .heifPro && !restoringPortrait
            && !preferences.auxiliaryWatermark && state.nightMode != true && state.slowShutter != true
        if restoringPortrait { hdr = false }
        flashMode = CameraFlashMode(rawValue: state.flash) ?? .off
        livePhotoEnabled = state.live
        if restoringPortrait { livePhotoEnabled = false }
        // 夜景拍照功能已取消：旧存档中的夜景开关不再恢复。
        nightModeEnabled = false
        nightCaptureRuntimeUnavailable = false
        slowShutterEnabled = captureKind == .photo && (state.slowShutter ?? false)
        selectedSlowShutterPreset = slowShutterEnabled
            ? state.slowShutterPreset.flatMap(SlowShutterPreset.init(rawValue:))
            : nil
        slowShutterAutomaticPreset = slowShutterEnabled
            ? (state.slowShutterAutomaticPreset ?? state.slowShutterPreset).flatMap(SlowShutterPreset.init(rawValue:)) : nil
        slowShutterAutomaticDuration = (state.slowShutterAutomaticDuration ?? state.slowShutterDuration)
            .flatMap(SlowShutterDuration.init(rawValue:)) ?? slowShutterAutomaticPreset?.defaultCaptureDuration ?? .s1
        if mode == .manual { selectedSlowShutterPreset = nil }
        let restoredSlowDuration = state.slowShutterDuration.flatMap(SlowShutterDuration.init(rawValue:))
        if let preset = selectedSlowShutterPreset {
            slowShutterDuration = restoredSlowDuration.flatMap { preset.allows($0) ? $0 : nil }
                ?? preset.defaultCaptureDuration
        } else {
            slowShutterDuration = restoredSlowDuration ?? .s1
        }
        if restoringPortrait { slowShutterEnabled = false; selectedSlowShutterPreset = nil }
        timeLapseEnabled = captureKind == .video && (state.timeLapseEnabled ?? false) && !rawVideoSelected
        selectedTimeLapsePreset = state.timeLapsePreset.flatMap(TimeLapsePreset.init(rawValue:))
        let restoredInterval = state.timeLapseInterval.flatMap(TimeLapseInterval.init(rawValue:))
        let restoredFrames = state.timeLapseFrameCount.flatMap(TimeLapseFrameCount.init(rawValue:))
        timeLapseInterval = restoredInterval ?? selectedTimeLapsePreset?.recommendedInterval ?? .s1
        timeLapseFrameCount = restoredFrames ?? selectedTimeLapsePreset?.recommendedFrameCount ?? .f120
        slowMotionEnabled = captureKind == .video && (state.slowMotionEnabled ?? false)
            && !timeLapseEnabled && !rawVideoSelected
        cinematicVideoEnabled = captureKind == .video && (state.cinematicVideoEnabled ?? false)
            && !timeLapseEnabled && !slowMotionEnabled && !rawVideoSelected && !videoOpenGateEnabled
        portraitModeEnabled = restoringPortrait
        portraitBlurStrength = number(state.portraitBlurStrength ?? 0.5, 0...1, 0.5)
        portraitDepthSliderVisible = false
        tone = PhotoTone(rawValue: state.tone) ?? .natural; metering = CameraMetering(rawValue: state.metering) ?? .system
        let selected = FilmStyle(rawValue: state.style) ?? .original
        style = FilmStyle.availableStyles.contains(selected) ? selected : .original
        restoringFilterSettings = true
        intensity = number(state.intensity, 0...1, 0.8); filterAdjustments = state.adjustments
        restoringFilterSettings = false
        if preferences.saveCaptureSettings { filterSettings.set(SavedFilterSettings(intensity: intensity, adjustments: filterAdjustments), for: style) }
        let manual = state.manual
        manualExposure = manual.exposure && !fixedHighResolutionFocalsOnly; manualWB = manual.whiteBalance; manualFocus = manual.focusLocked
        iso = number(manual.iso, 1...128000, 100); shutter = number(manual.shutter, -24...5, log2(1.0 / 125))
        wb = number(manual.wb, 2500...9000, 5500); whiteBalanceTint = number(manual.tint, -150...150, 0)
        focus = number(manual.focus, 0...1, 0.5); ev = number(manual.ev, -5...5, 0)
        savedManualSettings = state.previousManual; automaticEV = number(state.automaticEV, -5...5, 0)
        selectedLogLUTID = state.logLUT ?? LogLUTPreset.originalID
        burnLogLUT = state.burnLogLUT && selectedLogLUTID != LogLUTPreset.originalID
        toolPage = min(max(state.toolPage, 0), 1)
        if !preferences.saveCaptureSettings {
            preferences.videoBitratePreset = .systemDefault
            preferences.videoStabilization = .standard
        }
        lastBackLensID = state.lastBackLensID
        restoringVideoSettings = false; restoringCaptureState = false
        synchronizeVideoSettings(); synchronizeHDRPreview(); synchronizeLiveAudio(); updateLook()
        reconcileNightMode()
    }

    private func beginStartupCaptureRestorationIfNeeded() -> Bool {
        guard let state = pendingStartupCaptureState else { return false }
        guard startupCaptureRestoreTask == nil else { return true }
        startupCaptureRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startupCaptureRestoreTask = nil }
            // 前置窄幅倍率可能随原生格式改变，旧双拍存档后备到前置入口，但不自动建立双拍会话。
            let restoredLens = (state.video && state.frontVideoCentering == true
                ? self.camera.lenses.first(where: { $0.device.position == .front && $0.frontFraming == .wide }) : nil)
                ?? self.camera.lenses.first(where: { $0.id == state.lensID })
                ?? (state.dualCaptureEnabled == true
                    ? self.camera.lenses.first(where: { $0.device.position == .front && $0.frontFraming == .standard }) : nil)
            if let lens = restoredLens, self.camera.selectedLens != lens.id {
                self.camera.selectLens(lens)
                for _ in 0..<250 {
                    if self.camera.ready { break }
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard self.cameraActiveRequested else { return }
                }
            }
            guard self.cameraActiveRequested, self.camera.ready else { return }
            self.camera.setContinuousZoom(CGFloat(state.zoom.isFinite ? min(max(state.zoom, 0.5), 40) : 1))
            await withCheckedContinuation { continuation in self.camera.flushRestoredZoom { continuation.resume() } }
            guard self.cameraActiveRequested else { return }
            self.pendingStartupCaptureState = nil
            if (state.frontLandscapePhoto ?? false), self.currentPosition == .front {
                self.camera.setFrontPhotoLandscapeEnabled(true)
            }
            self.iso = min(max(self.iso, self.camera.isoRange.lowerBound), self.camera.isoRange.upperBound)
            self.shutter = min(max(self.shutter, self.camera.shutterRange.lowerBound), self.camera.shutterRange.upperBound)
            self.activeDeviceID = self.camera.activeCaptureDeviceID
            self.restoreDeviceParameters()
            self.reconcileCaptureCapabilities()
            // 保留小窗构图偏好，但忽略旧存档中开启双拍的标志；启动只建立普通单摄会话。
            let initial = DualCaptureInsetLayout.initial
            self.camera.setDualCaptureInsetRect(CGRect(x: state.dualInsetX ?? Double(initial.minX),
                y: state.dualInsetY ?? Double(initial.minY), width: initial.width, height: initial.height))
            self.dualFrontWideBeforeLandscape = state.dualFrontWideBeforeLandscape
            self.restoredDualFrontWide = state.dualCaptureFrontWide
            self.camera.setDualCaptureInsetLandscape(state.dualInsetLandscape ?? false, ratio: self.videoRatio.frameRatio)
            if state.video, state.frontVideoCentering == true, self.currentPosition == .front {
                self.frontVideoCenteringRequested = true
                self.camera.setFrontVideoCentering(true)
            }
            self.flushCaptureSettings()
        }
        return true
    }

    func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }

}
