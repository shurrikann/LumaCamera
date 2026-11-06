import Foundation

/// User choices only. Recording, popup, focus-target and in-flight capture state are transient.
struct SavedCaptureState: Codable, Equatable {
    var version = 1
    var video = false
    var mode = "A"
    var photoMode = "A"
    // 可选以兼容旧存档；照片与视频分别记住最后一次使用的挡位。
    var videoMode: String? = nil
    var photoRatio = "4:3"
    var ratio = "4:3"
    var photoFormat = "JPG"
    var photoResolution = 12
    var flash = "关闭"
    var live = false
    // Optional so state files written before Night mode was introduced still decode.
    var nightMode: Bool? = nil
    var portraitMode: Bool? = nil
    var portraitBlurStrength: Double? = nil
    var virtualApertureEnabled: Bool? = nil
    var virtualAperture: Double? = nil
    var slowShutter: Bool? = nil
    var slowShutterPreset: String? = nil
    var slowShutterDuration: String? = nil
    // M 挡独立使用通用时长，另存 A 挡预设以便切回时恢复；旧存档缺失时安全迁移。
    var slowShutterAutomaticPreset: String? = nil
    var slowShutterAutomaticDuration: String? = nil
    var timeLapseEnabled: Bool? = nil
    var timeLapsePreset: String? = nil
    var timeLapseInterval: Int? = nil
    var timeLapseFrameCount: Int? = nil
    var slowMotionEnabled: Bool? = nil
    var cinematicVideoEnabled: Bool? = nil
    var dualCaptureEnabled: Bool? = nil
    var dualCaptureFrontWide: Bool? = nil
    var dualInsetLandscape: Bool? = nil
    var dualFrontWideBeforeLandscape: Bool? = nil
    var dualInsetX: Double? = nil
    var dualInsetY: Double? = nil
    var hdr = false
    var adaptiveHighDynamic: Bool? = nil
    var tone = ""
    var metering = ""
    var style = ""
    var intensity = 0.8
    var adjustments = FilterAdjustments()
    var manual = SavedManualCaptureState()
    var previousManual: SavedManualCaptureState?
    // 视频帧周期钳制之前的照片 M 挡参数；可选字段兼容旧存档。
    var photoManualBeforeVideo: SavedManualCaptureState?
    var automaticEV = 0.0
    var videoResolution = "hd1080"
    var videoFrameRate = 30
    var videoRatio = "16:9"
    var videoOpenGate: Bool? = nil
    var videoColorSpace = "SDR"
    var videoCodec = "HEVC"
    var proRes = "422 HQ"
    var logLUT: String?
    var burnLogLUT = false
    var toolPage = 0
    var lensID: String?
    var lastBackLensID: String?
    var zoom = 1.0
    var frontVideoCentering: Bool? = nil
    var frontAutoCentering = false
    var frontLandscapePhoto: Bool? = nil
}

struct SavedManualCaptureState: Codable, Equatable {
    var exposure = false
    var whiteBalance = false
    var focusLocked = false
    var iso = 100.0
    var shutter = log2(1.0 / 125)
    var wb = 5500.0
    var tint = 0.0
    var focus = 0.5
    var ev = 0.0
}
