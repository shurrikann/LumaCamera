import Foundation

struct CapturePreferences: Codable, Equatable {
    var focusLockMode = FocusLockMode.exposure
    var exposureLockEnabled = true
    var focusTrackingState = FocusTrackingState.off
    var silentShutter = false
    var recordLocation = false
    var copyright = ""
    var focusAssist = false
    var saveUnfilteredOriginal = false
    var saveCaptureSettings = true
    var lockVideoWhiteBalance = false
    var videoBitratePreset = VideoBitratePreset.systemDefault
    var videoStabilization = VideoStabilizationPreference.standard
    var auxiliaryWatermark = false
    var auxiliaryTimerSeconds = 0
    var auxiliaryGrid = false
    var auxiliaryHistogram = false
    var auxiliaryFocusPeaking = false
    var auxiliarySmoothPreview = false
    var auxiliaryLevel = false
    var auxiliaryPreviewQuarterTurns = 0
    var auxiliaryRecordingCapacity = false
    var auxiliaryAudioMeter = false
    var dockKitTrackingEnabled = false
    /// 仅为升级前已选调色盘的用户保留录像取景中的编辑样式。
    var videoFilterDialPad = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case focusLockMode, exposureLockEnabled, focusTrackingState, silentShutter, recordLocation, copyright, focusAssist, saveUnfilteredOriginal, saveCaptureSettings, lockVideoWhiteBalance, videoBitratePreset, videoStabilization
        case auxiliaryWatermark, auxiliaryTimerSeconds, auxiliaryGrid, auxiliaryHistogram, auxiliaryFocusPeaking, auxiliarySmoothPreview
        case auxiliaryLevel, auxiliaryPreviewQuarterTurns, auxiliaryRecordingCapacity, auxiliaryAudioMeter
        case dockKitTrackingEnabled
        case videoFilterDialPad = "filterDialPad"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        focusLockMode = try values.decodeIfPresent(FocusLockMode.self, forKey: .focusLockMode) ?? .exposure
        if let ae = try values.decodeIfPresent(Bool.self, forKey: .exposureLockEnabled) {
            exposureLockEnabled = ae
        } else {
            exposureLockEnabled = focusLockMode.locksExposure
        }
        if let tracking = try values.decodeIfPresent(FocusTrackingState.self, forKey: .focusTrackingState) {
            focusTrackingState = tracking
        } else {
            switch focusLockMode {
            case .exposure: focusTrackingState = .off
            case .focus, .exposureAndFocus: focusTrackingState = .locked
            case .tracking: focusTrackingState = .continuous
            }
        }
        silentShutter = try values.decodeIfPresent(Bool.self, forKey: .silentShutter) ?? false
        recordLocation = try values.decodeIfPresent(Bool.self, forKey: .recordLocation) ?? false
        copyright = try values.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        focusAssist = try values.decodeIfPresent(Bool.self, forKey: .focusAssist) ?? false
        saveUnfilteredOriginal = try values.decodeIfPresent(Bool.self, forKey: .saveUnfilteredOriginal) ?? false
        saveCaptureSettings = try values.decodeIfPresent(Bool.self, forKey: .saveCaptureSettings) ?? true
        lockVideoWhiteBalance = try values.decodeIfPresent(Bool.self, forKey: .lockVideoWhiteBalance) ?? false
        videoBitratePreset = try values.decodeIfPresent(VideoBitratePreset.self, forKey: .videoBitratePreset) ?? .systemDefault
        videoStabilization = try values.decodeIfPresent(VideoStabilizationPreference.self, forKey: .videoStabilization) ?? .standard
        auxiliaryWatermark = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryWatermark) ?? false
        auxiliaryTimerSeconds = try values.decodeIfPresent(Int.self, forKey: .auxiliaryTimerSeconds) ?? 0
        auxiliaryGrid = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryGrid) ?? false
        auxiliaryHistogram = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryHistogram) ?? false
        auxiliaryFocusPeaking = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryFocusPeaking) ?? false
        auxiliarySmoothPreview = try values.decodeIfPresent(Bool.self, forKey: .auxiliarySmoothPreview) ?? false
        auxiliaryLevel = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryLevel) ?? false
        auxiliaryPreviewQuarterTurns = try values.decodeIfPresent(Int.self, forKey: .auxiliaryPreviewQuarterTurns) ?? 0
        auxiliaryRecordingCapacity = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryRecordingCapacity) ?? false
        auxiliaryAudioMeter = try values.decodeIfPresent(Bool.self, forKey: .auxiliaryAudioMeter) ?? false
        dockKitTrackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .dockKitTrackingEnabled) ?? false
        videoFilterDialPad = try values.decodeIfPresent(Bool.self, forKey: .videoFilterDialPad) ?? false
    }
}
final class CapturePreferencesStore {
    private let defaults: UserDefaults?
    private let key = "capture.preferences.v1"
    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
    func load() -> CapturePreferences { defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(CapturePreferences.self,from:$0) } ?? CapturePreferences() }
    func save(_ value: CapturePreferences) { if let data = try? JSONEncoder().encode(value) { defaults?.set(data,forKey:key) } }
    func loadCaptureState() -> SavedCaptureState? {
        guard let data = defaults?.data(forKey: "capture.state.v1"),
              let value = try? JSONDecoder().decode(SavedCaptureState.self, from: data), value.version == 1 else { return nil }
        return value
    }
    func saveCaptureState(_ value: SavedCaptureState) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value), data != defaults?.data(forKey: "capture.state.v1") else { return }
        defaults?.set(data, forKey: "capture.state.v1")
    }
    func clearCaptureState() { defaults?.removeObject(forKey: "capture.state.v1") }
}
