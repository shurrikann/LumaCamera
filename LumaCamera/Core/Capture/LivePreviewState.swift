import AVFoundation
import CoreImage

/// Camera configuration crosses to the frame queue only as a locked immutable snapshot.
final class LivePreviewState {
    struct Snapshot {
        var userSwitchID: UUID?
        var macroRouteGeneration: UInt64 = 0
        var macroRouteChangePending = false
        /// 拍照临时借用的超广角输入属于系统微距，不等同用户选择 0.5×。
        var temporaryMacroPhysicalInput = false
        var running = false
        var manualMode = false
        var hdr = false
        var videoColorSpace: VideoColorSpace?
        var videoFrameRate: Int?
        /// 仅照片路线使用新前置传感器的固定方向校正；视频沿用已有方向策略。
        var nativeFrontPhotoSensor = false
        /// 新前置人物居中格式的零旋转缓冲按原生传感器朝向交付，不能按宽高猜测再转90度。
        var nativeFrontCenterStageSensor = false
        /// 实际传感器动态画幅独立于最终裁切方向；1:1 没有横竖方向，但输入仍可能是横幅。
        var nativeFrontSensorLandscape = false
        var logLUTCube: LogLUTCube?
        var acceptsFrames = true
        /// 夜景跨批次及慢门回退曝光期间保留有效取景，避免曝光切换帧覆盖画面。
        var nightCapturePreviewHold = false
        var latestFrameHostTime = -Double.infinity
        var framesNotBefore = -Double.infinity
        var macroNotBefore = -Double.infinity
        var warmupFrames = 0

        func acceptsFrame(time: Double) -> Bool {
            running && acceptsFrames && !nightCapturePreviewHold && time.isFinite && time >= framesNotBefore
        }
        var readingsGeneration: UInt64 = 0
        /// 用户恢复自动后短暂提高真实读数采样频率；不永久提高预览或后台处理频率。
        var readingsRefreshRevision: UInt64 = 0
        var readingsFastUntil = -Double.infinity
        var grainPhase = 0.0
        var look = CaptureLook()
        var revision: UInt64 = 0
        var quarterTurns = 0
        var histogram = false
        var focusPeaking = false
        var portraitPreviewEnabled = false
        /// 电影模式复用录制帧作为预览，避免同时连接两路视频帧输出。
        var previewFromRecordingOutput = false
        var portraitPreviewGeneration: UInt64 = 0
        var portraitBlurStrength = 0.5
        var metering = CameraMetering.system
        var mirrorFrontPreview = true
        var device: AVCaptureDevice?
        var extent = CGRect(x: 0, y: 0, width: 3, height: 4)
        #if DEBUG
        var intrinsicsForTesting = "unavailable"
        var rawBufferSizeForTesting = CGSize.zero
        var presentationSizeForTesting = CGSize.zero
        var cleanBufferRectForTesting = CGRect.zero
        #endif
    }
    private let lock = NSLock()
    private var value = Snapshot()
    private var recordingPreviewRenderPending = false
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    @discardableResult
    func beginMacroRouteChange() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value.macroRouteGeneration &+= 1
        value.macroRouteChangePending = true
        return value.macroRouteGeneration
    }
    func finishMacroRouteChange(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard value.macroRouteGeneration == generation else { return }
        value.macroRouteGeneration &+= 1
        value.macroRouteChangePending = false
    }
    func cancelMacroRouteChange() {
        lock.lock(); defer { lock.unlock() }
        value.macroRouteGeneration &+= 1
        value.macroRouteChangePending = false
    }
    func acceptsWarmFrame(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value.running, value.acceptsFrames, value.readingsGeneration == generation else { return false }
        if value.warmupFrames > 0 { value.warmupFrames -= 1; return false }
        return true
    }
    func update(_ mutation: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutation(&value)
    }

    /// 录制帧复用预览时只允许一个待渲染样本，避免高帧率下预览队列堆积。
    func beginRecordingPreviewRender() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !recordingPreviewRenderPending else { return false }
        recordingPreviewRenderPending = true
        return true
    }

    func finishRecordingPreviewRender() {
        lock.lock(); defer { lock.unlock() }
        recordingPreviewRenderPending = false
    }
}

enum LivePreviewCadence {
    static func minimumInterval(frameRate: Int?) -> Double {
        let rate = min(120, max(1, frameRate ?? 30))
        return 1.0 / Double(rate)
    }

    static func accepts(time: Double, lastFrameTime: Double, frameRate: Int?) -> Bool {
        time.isFinite && (time - lastFrameTime) >= minimumInterval(frameRate: frameRate) - 0.001
    }
}
