import AVFoundation
import Combine
import CoreImage
import ImageIO
import UIKit
import simd

final class CameraEngine: NSObject, ObservableObject {
    @Published private(set) var preview: UIImage?
    @Published private(set) var nightPreviewReveal: NightPreviewReveal?
    @Published private(set) var userSwitchFrameID: UUID?
    private var startPending = false // main queue; protects a queued start from stale recovery notifications
    private var configuredLiveCaptureRoute: String?
    private var reusableInputs: [String: AVCaptureDeviceInput] = [:] // session queue
    @Published private(set) var ready = false
    @Published private(set) var activeCaptureDeviceID = ""
    @Published private(set) var targetExposureLockActive = false
    @Published private(set) var targetExposureLocked = false
    @Published private(set) var targetFocusLockActive = false
    @Published private(set) var targetFocusLocked = false
    var targetLockActive: Bool { targetExposureLockActive || targetFocusLockActive }
    var targetLocked: Bool { targetLockActive && (!targetExposureLockActive || targetExposureLocked) && (!targetFocusLockActive || targetFocusLocked) }
    private var targetFocusLockRequested = false // session queue
    private let targetExposureRevision = PreviewRevision()
    private var targetLockRequested = false
    private var targetSensorPoint = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var capturing = false
    @Published private(set) var shutterBusy = false
    private var liveCaptureToken: UUID?
    @Published private(set) var pendingPhotoCount = 0
    @Published private(set) var deliveredPhotoRevision: UInt64 = 0
    @Published private(set) var pendingCaptureWeight = 0
    private var hardwareTokens = Set<UUID>() // main queue
    // 终结只允许一次；超时清理后的迟到结果不能重复减计数、交付或堵住有序结果队列。
    private var pendingCaptureTokens = Set<UUID>() // main queue
    // 覆盖硬件采集、后台合成及等待有序交付的整个夜景请求生命周期。
    private var nightCaptureTokens = Set<UUID>() // main queue
    private var cancelledNightCaptureTokens = Set<UUID>() // main queue
    private var shutterToken: UUID?
    private var nextCaptureSequence: UInt64 = 0
    private var nextDeliverySequence: UInt64 = 0
    private struct CompletedCapture {
        let token: UUID
        let weight: Int
        let photo: CapturedPhoto?
        let message: String?
        let notifiesFailure: Bool
        let completion: (CapturedPhoto?) -> Void
    }
    private var completedCaptures: [UInt64: CompletedCapture] = [:] // main queue
    @Published private(set) var demo = false
    @Published private(set) var denied = false
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLens = ""
    @Published private(set) var currentZoom: CGFloat = 1
    private(set) var continuousZoomActive = false
    @Published private(set) var continuousZoomRange: ClosedRange<CGFloat> = 1...1
    private let zoomRevision = PreviewRevision()
    private let capabilityRevision = PreviewRevision()
    private struct ZoomRequest {
        let value: CGFloat
        let position: AVCaptureDevice.Position
        let revision: UInt64
        var transitionID: UUID? = nil
        var smooth = false
    }
    private lazy var zoomThrottle = LatestValueThrottle<ZoomRequest>(queue: queue, interval: 1.0 / 60) { [weak self] in self?.applyContinuousZoom($0) }
    @Published private(set) var isoRange: ClosedRange<Double> = 25...1600
    @Published private(set) var shutterRange: ClosedRange<Double> = -12 ... -1
    @Published private(set) var supportsExposure = false
    @Published private(set) var supportsFocus = false
    @Published private(set) var supportsTargetFocusLock = false
    @Published private(set) var supportsWB = false
    @Published private(set) var supportsFlash = false
    @Published private(set) var roll = 0.0
    @Published private(set) var hdrPreviewActive = false
    @Published private(set) var hdrPreviewConfiguring = false
    @Published private(set) var supportsHEIFHDR = false
    @Published private(set) var supportedVideoStabilizationPreferences: Set<VideoStabilizationPreference> = []
    @Published private(set) var supportsHighResolutionHEIFHDR = true
    private var reducedHDRResolutionDevices: Set<String> = [] // 只记录实际出片观测，不推断整机能力。
    @Published private(set) var macroActive = false
    @Published private(set) var timeLapseCapturedFrames = 0
    @Published private(set) var frontAutoCenteringAvailable = false
    @Published private(set) var frontAutoCenteringEnabled = false
    @Published private(set) var frontVideoCenteringAvailable = false
    @Published private(set) var frontVideoCenteringEnabled = false
    @Published private(set) var frontVideoCenteringActive = false
    @Published private(set) var frontVideoCenteringPreparing = false
    @Published private(set) var frontVideoCenteringSettings: [VideoCaptureSettings] = []
    private var frontVideoCenteringRequested = false // session queue
    private var frontVideoCenteringObservation: NSKeyValueObservation?
    private let frontVideoCenteringRevision = PreviewRevision()
    @Published private(set) var frontPhotoAspectRatioSwitchAvailable = false
    @Published private(set) var frontPhotoLandscapeEnabled = false
    @Published private(set) var globalMeteringReadout = GlobalMeteringReadout()
    @Published private(set) var readings: CameraReadings?
    @Published private(set) var histogram: [Double] = []
    @Published private(set) var availablePhotoFormats: [PhotoFileFormat] = [.heif, .jpeg, .tiff]
    @Published private(set) var availableResolutions: [PhotoResolution] = [.standard]
    @Published private(set) var highResolutionLensIDs: Set<String> = []
    @Published private(set) var videoSelectionCapabilities: [String:VideoLensCaptureCapabilities] = [:]
    @Published private(set) var highResolutionPhotoZoomLocked = false
    @Published private(set) var highResolutionPhotoConfiguring = false
    private var highResolutionPhotoConfigGeneration = UUID() // main queue
    @Published private(set) var supportsLivePhoto = false
    @Published private(set) var supportsNightCapture = false
    /// 应用人像入口能力（原生蒙版或可用的软件分割），不等于原生 depth/matte 支持标志。
    @Published private(set) var supportsPortraitCapture = false
    @Published private(set) var photoLensCapabilities: [String: PhotoLensCaptureCapabilities] = [:]
    @Published private(set) var openGatePortraitRatio: CGFloat = 3.0 / 4.0
    @Published private(set) var supportsProRAW = false
    @Published private(set) var recoveringSession = false
    @Published private(set) var recoveryFailed = false
    private var runRequested = false // main-queue lifecycle intent
    private let recoveryRevision = PreviewRevision()
    @Published var message: String?

    var onHardwareAdjustment: ((String, Float) -> Void)?
    var onHardwareControlsActivated: (() -> Void)?
    private lazy var hardwareControls = CameraHardwareControls(session: session, queue: queue,
        action: { [weak self] id, value in
            DispatchQueue.main.async { self?.onHardwareAdjustment?(id, value) }
        }, activated: { [weak self] in
            DispatchQueue.main.async { self?.onHardwareControlsActivated?() }
        })

    func updateHardwareControls(_ specs: [CameraHardwareControlSpec], enabled: Bool) {
        queue.async { self.hardwareControls.update(specs, enabled: enabled && self.dualCaptureSource == nil) }
    }


    #if DEBUG
    func hardwareControlIdentifiersForTesting(_ completion: @escaping ([String]) -> Void) {
        queue.async { let ids = self.hardwareControls.identifiersForTesting; DispatchQueue.main.async { completion(ids) } }
    }

    func setVideoRecordingForTesting(_ recording: Bool, zoomRange: ClosedRange<CGFloat>? = nil) {
        videoRecordingZoomRange = recording ? zoomRange : nil
        videoRecording = recording
    }
    func setMacroActiveForTesting(_ active: Bool) {
        macroActive = active
    }
    #endif

    @Published private(set) var dualCaptureEnabled = false
    @Published private(set) var dualCapturePreparing = false
    @Published private(set) var dualCaptureFrontWide = false
    @Published private(set) var dualCaptureMainIsFront = false
    @Published private(set) var dualCaptureMainZoomRange: ClosedRange<CGFloat>?
    @Published private(set) var dualCaptureInsetLandscape = false
    @Published private(set) var dualCaptureInsetRect = DualCaptureInsetLayout.initial
    @Published private(set) var dualCaptureSupportedSettings: [VideoCaptureSettings] = []
    private var dualCaptureRatio: FrameRatio = .wide // session queue
    private var dualFrontWideRequested = false // session queue
    private struct DualInsetUpdate {
        let source: DualCaptureSource
        let rect: CGRect
        let revision: UInt64
    }
    private lazy var dualInsetThrottle = LatestValueThrottle<DualInsetUpdate>(queue: recordingQueue, interval: 1.0 / 60) { [weak self] update in
        guard self?.dualCaptureRevision.matches(update.revision) == true else { return }
        update.source.setInsetRect(update.rect)
    }
    private var dualCaptureSource: DualCaptureSource? // session queue
    private var dualMainIsFront = false // session queue
    private let dualCaptureRevision = PreviewRevision()
    private var dualControlDevice: AVCaptureDevice? { // session queue
        guard let source = dualCaptureSource else { return focusNavigatorGraph?.main ?? input?.device }
        return dualMainIsFront ? source.front : source.rear
    }

    /// 双拍使用独立图；先停止单摄，失败则拆除双摄并恢复原图，绝不同时占用两套相机会话。
    func setDualCaptureEnabled(_ enabled: Bool, settings: VideoCaptureSettings? = nil, ratio: FrameRatio? = nil,
                               frontWide: Bool? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !videoBusy, !capturing, !dualCapturePreparing else { completion(false); return }
        dualCapturePreparing = true
        ready = false
        let revision = dualCaptureRevision.advance()
        let requested = settings ?? videoSettings
        let requestedRatio = ratio ?? .wide
        let requestedWide = dualCaptureInsetLandscape ? true : (frontWide ?? dualCaptureFrontWide)
        let inset = DualCaptureInsetLayout.resized(dualCaptureInsetRect, landscape: dualCaptureInsetLandscape,
                                                   ratio: requestedRatio.portraitRatio)
        queue.async { [self] in
            let previousSettings = self.dualCaptureSource == nil ? nil : self.requestedVideoSettings
            let previousRatio = self.dualCaptureRatio, previousWide = self.dualFrontWideRequested
            let previousMain = self.dualMainIsFront
            do {
                if enabled {
                    guard self.videoModeRequested else { throw DualCaptureSource.Failure.unsupported }
                    self.stopFocusNavigatorOnQueue()
                    self.zoomThrottle.cancel(); _ = self.zoomRevision.advance()
                    self.stopFrontSmartFraming()
                    let preserveFrontVideoCentering = self.frontVideoCenteringRequested
                    self.stopFrontVideoCentering(clearRequest: false)
                    if self.session.isRunning { self.session.stopRunning() }
                    guard let configuration = DualCapturePolicy.configuration(for: requested, frontWide: requestedWide) else {
                        throw DualCaptureSource.Failure.unsupported
                    }
                    self.dualInsetThrottle.cancel()
                    self.dualCaptureSource?.release(); self.dualCaptureSource = nil
                    let source = try DualCaptureSource(frameQueue: self.recordingQueue, ratio: requestedRatio, audio: true, configuration: configuration)
                    self.dualCaptureSource = source; self.dualMainIsFront = previousMain
                    DispatchQueue.main.async { self.dualCaptureMainIsFront = previousMain }
                    self.publishDualMainZoomRange()
                    self.requestedVideoSettings = requested; self.requestedCinematicVideo = false; self.requestedVideoOpenGate = false
                    self.dualCaptureRatio = requestedRatio; self.dualFrontWideRequested = requestedWide
                    self.recordingQueue.sync {
                        source.setInsetRect(inset)
                        if previousMain { source.swap() }
                    }
                    self.publishDualControlCapabilities(previousMain ? source.front : source.rear)
                    source.onError = { [weak self] text in
                        DispatchQueue.main.async {
                            guard let self, self.runRequested, self.dualCaptureRevision.matches(revision),
                                  self.dualCaptureEnabled || self.dualCapturePreparing else { return }
                            self.message = text
                            if self.videoBusy { self.stopVideoRecording() }
                            Task { @MainActor [weak self] in
                                for _ in 0..<250 {
                                    guard let self, self.dualCaptureRevision.matches(revision) else { return }
                                    if !self.videoBusy && !self.dualCapturePreparing {
                                        self.setDualCaptureEnabled(false)
                                        return
                                    }
                                    try? await Task.sleep(for: .milliseconds(20))
                                }
                            }
                        }
                    }
                    source.onVideo = { [weak self] frame in
                        guard let self, self.dualCaptureRevision.matches(revision) else { return }
                        self.movieRecorder?.appendVideo(frame)
                        guard self.livePreviewState.beginRecordingPreviewRender() else { return }
                        self.previewQueue.async {
                            defer { self.livePreviewState.finishRecordingPreviewRender() }
                            self.renderPreviewFrame(frame)
                        }
                    }
                    source.onAudio = { [weak self] frame in
                        guard let self, self.dualCaptureRevision.matches(revision) else { return }
                        self.movieRecorder?.appendAudio(frame); self.updateAudioLevels(frame)
                    }
                    self.readingsGeneration &+= 1
                    self.syncPreviewState()
                    self.livePreviewState.update { $0.acceptsFrames = true; $0.framesNotBefore = -Double.infinity; $0.warmupFrames = 0 }
                    if self.wantsRunning {
                        try source.start()
                        self.configureRecordingHaptics()
                    }
                    if preserveFrontVideoCentering {
                        // 普通前置视频开启的追踪在切换到双拍后延续到双拍前置设备。
                        self.frontVideoCenteringRequested = true
                        self.refreshFrontVideoCentering(source.front)
                    }
                } else {
                    self.releaseDualCaptureOnQueue()
                    if self.wantsRunning { self.session.startRunning() }
                    self.syncPreviewState()
                }
                let supported = enabled ? DualCapturePolicy.supportedSettings() : []
                DispatchQueue.main.async {
                    if enabled {
                        self.dualCaptureInsetRect = inset
                        self.videoSettings = requested
                        self.dualCaptureFrontWide = requestedWide
                        self.dualCaptureSupportedSettings = supported
                    }
                    self.dualCaptureEnabled = enabled
                    self.dualCapturePreparing = false
                    self.ready = false
                    completion(true)
                }
                // 就绪仍由新帧验证，不能仅凭startRunning返回便允许录制。
                self.verifyRecoveredFrames(token: self.recoveryRevision.current, attempt: 0, startedAt: CACurrentMediaTime())
            } catch {
                // 规格替换失败先恢复上一套已运行组合，不能把失败规格留在界面或丢失双拍意图。
                if let previousSettings, enabled {
                    self.dualCaptureSource?.release(); self.dualCaptureSource = nil
                    self.requestedVideoSettings = previousSettings
                    self.report("该双拍组合暂时不可用，已恢复此前规格。" + error.localizedDescription)
                    DispatchQueue.main.async {
                        self.dualCapturePreparing = false
                        self.setDualCaptureEnabled(true, settings: previousSettings, ratio: previousRatio, frontWide: previousWide) { _ in completion(false) }
                    }
                    return
                }
                self.releaseDualCaptureOnQueue()
                if self.wantsRunning { self.session.startRunning() }
                self.syncPreviewState()
                self.report(error.localizedDescription)
                DispatchQueue.main.async { self.dualCaptureEnabled = false; self.dualCapturePreparing = false; completion(false) }
                self.verifyRecoveredFrames(token: self.recoveryRevision.current, attempt: 0, startedAt: CACurrentMediaTime())
            }
        }
    }

    private func applyDualCaptureSettings(_ settings: VideoCaptureSettings, ratio: FrameRatio, revision: UInt64) {
        guard videoSettingsRevision.matches(revision), dualCaptureEnabled, !videoBusy else { return }
        if dualCapturePreparing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.applyDualCaptureSettings(settings, ratio: ratio, revision: revision)
            }
            return
        }
        let inset = DualCaptureInsetLayout.resized(dualCaptureInsetRect, landscape: dualCaptureInsetLandscape, ratio: ratio.portraitRatio)
        queue.async {
            guard self.videoSettingsRevision.matches(revision), let source = self.dualCaptureSource else { return }
            guard DualCapturePolicy.configuration(for: settings, frontWide: self.dualFrontWideRequested) != nil, ratio != .openGate else {
                let actual = self.requestedVideoSettings
                DispatchQueue.main.async { self.videoSettings = actual; self.videoConfiguring = false }
                return
            }
            let old = self.requestedVideoSettings
            let sameSource = old.resolution == settings.resolution && old.frameRate == settings.frameRate && old.colorSpace == settings.colorSpace
            if sameSource {
                self.requestedVideoSettings = settings; self.dualCaptureRatio = ratio
                self.recordingQueue.async {
                    source.setRatio(ratio); source.setInsetRect(inset)
                    self.queue.async {
                        self.readingsGeneration &+= 1; self.syncPreviewState()
                        DispatchQueue.main.async {
                            if self.videoSettingsRevision.matches(revision) { self.dualCaptureInsetRect = inset; self.videoSettings = settings; self.videoConfiguring = false }
                        }
                    }
                }
            } else {
                let wide = self.dualFrontWideRequested
                DispatchQueue.main.async {
                    guard self.videoSettingsRevision.matches(revision) else { return }
                    self.setDualCaptureEnabled(true, settings: settings, ratio: ratio, frontWide: wide) { _ in
                        if self.videoSettingsRevision.matches(revision) { self.videoConfiguring = false }
                    }
                }
            }
        }
    }

    func setDualCaptureInsetRect(_ value: CGRect) {
        let rect = DualCaptureInsetLayout.clamped(value)
        dualCaptureInsetRect = rect
        queue.async {
            guard let source = self.dualCaptureSource else { return }
            self.dualInsetThrottle.submit(DualInsetUpdate(source: source, rect: rect, revision: self.dualCaptureRevision.current))
        }
    }
    /// 画幅状态与编码共用同一矩形；相机倍率切换成功后再提交，避免失败时误报横幅已开启。
    func setDualCaptureInsetLandscape(_ landscape: Bool, ratio: FrameRatio) {
        dualCaptureInsetLandscape = landscape
        setDualCaptureInsetRect(DualCaptureInsetLayout.resized(dualCaptureInsetRect, landscape: landscape, ratio: ratio.portraitRatio))
    }
    func setDualCaptureFrontWide(_ wide: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        guard dualCaptureEnabled, !dualCapturePreparing, (!videoBusy || videoRecording) else { completion(false); return }
        queue.async {
            guard let source = self.dualCaptureSource else { DispatchQueue.main.async { completion(false) }; return }
            do {
                try source.front.lockForConfiguration()
                source.front.videoZoomFactor = min(max(wide ? 1 : 1.6, source.front.minAvailableVideoZoomFactor), source.front.maxAvailableVideoZoomFactor)
                source.front.unlockForConfiguration()
                self.dualFrontWideRequested = wide
                self.readingsGeneration &+= 1; self.syncPreviewState()
                DispatchQueue.main.async { self.dualCaptureFrontWide = wide; completion(true) }
            } catch {
                self.report("切换双拍前置画幅失败：" + error.localizedDescription)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func releaseDualCaptureOnQueue() {
        _ = dualCaptureRevision.advance()
        dualInsetThrottle.cancel()
        dualZoomThrottle.cancel()
        dualCaptureSource?.release(); dualCaptureSource = nil; dualMainIsFront = false
        DispatchQueue.main.async { self.dualCaptureMainIsFront = false; self.dualCaptureMainZoomRange = nil }
        // 恢复单摄的格式/连接和用户参数，不能沿用双拍临时的1080p格式。
        // configureConnections 在视频路由内部会自己管理 begin/commit；这里再包一层
        // 会形成嵌套事务，双拍退出+前置4:3时触发 -11819。
        if configured, let device = input?.device {
            configureConnections(device: device)
            publishCapabilities(device, lensID: selectedLens)
        }
        DispatchQueue.main.async { self.dualCaptureEnabled = false }
    }

    // 连续手势只保留最新目标；不逐事件排队，也不因纯倍率变化使预览读数代次失效。
    private struct DualZoomRequest {
        let value: CGFloat
        let revision: UInt64
        let front: Bool
    }
    private lazy var dualZoomThrottle = LatestValueThrottle<DualZoomRequest>(queue: queue, interval: 1.0 / 30) { [weak self] request in
        guard let self, self.dualCaptureRevision.matches(request.revision),
              self.dualMainIsFront == request.front, let source = self.dualCaptureSource else { return }
        source.setMainZoom(request.value, front: request.front)
    }

    func setDualCaptureMainZoom(_ zoom: CGFloat) {
        guard dualCaptureEnabled, !dualCapturePreparing, zoom.isFinite,
              let range = dualCaptureMainZoomRange else { return }
        let actual = min(max(zoom, range.lowerBound), range.upperBound)
        if abs(currentZoom - actual) > 0.0001 { currentZoom = actual }
        if !dualCaptureMainIsFront,
           let anchor = lenses.filter({ $0.device.position == .back && $0.displayZoom >= 0.999 })
            .min(by: { abs($0.displayZoom - actual) < abs($1.displayZoom - actual) }), selectedLens != anchor.id {
            selectedLens = anchor.id
        }
        // 主副切换/退出使旧请求失效，避免旧手势修改新的主画面。
        dualZoomThrottle.submit(DualZoomRequest(value: actual, revision: dualCaptureRevision.current, front: dualCaptureMainIsFront))
    }

    private func publishDualMainZoomRange() {
        guard let source = dualCaptureSource else { return }
        let device = dualMainIsFront ? source.front : source.rear
        let range = device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
        let actual = device.videoZoomFactor
        DispatchQueue.main.async { self.dualCaptureMainZoomRange = range; self.currentZoom = actual }
    }

    func swapDualCaptureCameras(transitionID: UUID? = nil) {
        guard dualCaptureEnabled, !dualCapturePreparing else { return }
        queue.async {
            guard let source = self.dualCaptureSource else { return }
            self.dualZoomThrottle.cancel()
            self.dualMainIsFront.toggle()
            let frontIsMain = self.dualMainIsFront
            DispatchQueue.main.async { self.dualCaptureMainIsFront = frontIsMain }
            self.publishDualMainZoomRange()
            self.publishDualControlCapabilities(self.dualMainIsFront ? source.front : source.rear)
            self.recordingQueue.async {
                source.swap()
                self.queue.async {
                    self.readingsGeneration &+= 1; self.syncPreviewState()
                    if let transitionID { self.markUserPreviewSwitch(transitionID) }
                }
            }
        }
    }

    private func publishDualControlCapabilities(_ device: AVCaptureDevice) {
        let revision = dualCaptureRevision.current
        let iso = Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO)
        let minimum = max(device.activeFormat.minExposureDuration.seconds, 1.0 / 16000)
        let maximum = max(minimum, min(device.activeFormat.maxExposureDuration.seconds, 1.0 / Double(requestedVideoSettings.frameRate.rawValue)))
        let shutter = log2(minimum)...log2(maximum)
        let exposure = device.isExposureModeSupported(.custom)
        let focus = device.isLockingFocusWithCustomLensPositionSupported
        let whiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        DispatchQueue.main.async {
            guard self.dualCaptureRevision.matches(revision) else { return }
            self.isoRange = iso; self.shutterRange = shutter
            self.supportsExposure = exposure; self.supportsFocus = focus; self.supportsWB = whiteBalance
        }
    }

    #if DEBUG
    func dualCaptureStateForTesting(_ completion: @escaping ([String: String]) -> Void) {
        queue.async {
            guard let source = self.dualCaptureSource, let device = self.dualControlDevice else {
                DispatchQueue.main.async { completion([:]) }; return
            }
            let base = ["ordinaryRunning": "\(self.session.isRunning)", "dualRunning": "\(source.session.isRunning)",
                          "frontMain": "\(self.dualMainIsFront)", "mainZoom": "\(device.videoZoomFactor)", "iso": "\(device.iso)",
                          "seconds": "\(device.exposureDuration.seconds)", "exposure": "\(device.exposureMode.rawValue)",
                          "wb": "\(device.whiteBalanceMode.rawValue)", "focus": "\(device.focusMode.rawValue)"]
            self.recordingQueue.async {
                var values = base
                values["sourceID"] = source.identifierForTesting.uuidString
                values["frames"] = "\(source.frameCount)"; values["skew"] = "\(source.maximumPairSkew)"
                values["insetX"] = "\(source.insetRect.minX)"; values["insetY"] = "\(source.insetRect.minY)"
                values["frontZoom"] = "\(source.front.videoZoomFactor)"
                values["frontFPS"] = "\(1 / source.front.activeVideoMinFrameDuration.seconds)"
                let result = values
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    func dualCaptureErrorCallbackForTesting(_ completion: @escaping (((String) -> Void)?) -> Void) {
        queue.async {
            let handler = self.dualCaptureSource?.onError
            DispatchQueue.main.async { completion(handler) }
        }
    }
    #endif

    @Published private(set) var focusNavigatorImage: UIImage?
    @Published private(set) var focusNavigatorRegion = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
    @Published private(set) var focusNavigatorActive = false
    @Published private(set) var focusNavigatorUnavailableReason: String?
    private var focusNavigatorGraph: FocusNavigatorGraph?
    private var focusNavigatorWanted = false
    private var focusNavigatorZoom: CGFloat = 1
    private var focusNavigatorRatio: CGFloat = 0.75
    private var focusNavigatorAllowed = true
    private var focusNavigatorScheduled = false
    private var focusNavigatorFailedSignature: String?
    private let focusNavigatorRevision = PreviewRevision()

    func configureFocusNavigator(enabled: Bool, zoom: CGFloat, ratio: CGFloat, allowed: Bool = true) {
        queue.async {
            if self.focusNavigatorWanted != enabled { self.focusNavigatorFailedSignature = nil }
            self.focusNavigatorWanted = enabled; self.focusNavigatorZoom = zoom
            self.focusNavigatorRatio = ratio; self.focusNavigatorAllowed = allowed
            self.scheduleFocusNavigatorRefresh()
        }
    }
    private func scheduleFocusNavigatorRefresh() {
        guard !focusNavigatorScheduled, focusNavigatorWanted || focusNavigatorGraph != nil else { return }
        focusNavigatorScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) {
            self.focusNavigatorScheduled = false; self.refreshFocusNavigatorOnQueue()
        }
    }
    private func refreshFocusNavigatorOnQueue() {
        let desired = focusNavigatorWanted && focusNavigatorZoom >= 8 && focusNavigatorAllowed && wantsRunning && !videoModeRequested
            && input?.device.position == .back && dualCaptureSource == nil && !heifHDRPipelineRequested
        guard desired else {
            if !recordingBusyOnQueue { stopFocusNavigatorOnQueue() }
            else { DispatchQueue.main.async { self.focusNavigatorImage = nil } }
            return
        }
        if let graph = focusNavigatorGraph {
            let region = graph.region(zoom: focusNavigatorZoom, ratio: focusNavigatorRatio)
            DispatchQueue.main.async { self.focusNavigatorRegion = region }
            return
        }
        guard configured, captureContexts.isEmpty, !recordingBusyOnQueue, let oldInput = input else { return }
        let signature = "\(videoModeRequested)-\(requestedVideoSettings)-\(manualMode)-\(oldInput.device.uniqueID)"
        guard signature != focusNavigatorFailedSignature else { return }
        guard hdrPreviewSource == nil else { return }
        let base = lensCatalog.first { $0.device.deviceType == .builtInTelephotoCamera }.map { $0.displayZoom / $0.zoomFactor } ?? 4
        let generation = focusNavigatorRevision.advance()
        do {
            var selected: FocusNavigatorGraph?
            var lastFailure: Error = FocusNavigatorGraph.Failure.unsupported
            // 广角优先；预算不足时只降低辅助路负载，不降低主路采集规格。
            for (type, fps) in [(AVCaptureDevice.DeviceType.builtInWideAngleCamera, 15), (.builtInUltraWideCamera, 15),
                                (.builtInWideAngleCamera, 5), (.builtInUltraWideCamera, 5)] {
                do {
                    selected = try FocusNavigatorGraph(originalSession: session, originalInput: oldInput,
                        zoom: focusNavigatorZoom, mainBase: base,
                        navigationType: type, navigationFPS: fps, frameQueue: focusNavigatorQueue, primaryQueue: recordingQueue)
                    break
                } catch { lastFailure = error }
            }
            guard let graph = selected else { throw lastFailure }
            focusNavigatorGraph = graph
            readingsGeneration &+= 1
            graph.onVideo = { [weak self] frame in
                guard let self, self.focusNavigatorRevision.matches(generation), self.livePreviewState.beginRecordingPreviewRender() else { return }
                self.previewQueue.async {
                    defer { self.livePreviewState.finishRecordingPreviewRender() }
                    guard self.focusNavigatorRevision.matches(generation) else { return }
                    self.renderPreviewFrame(frame)
                }
            }
            graph.onFrame = { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.focusNavigatorRevision.matches(generation),
                          self.currentZoom >= 8, self.runRequested else { return }
                    self.focusNavigatorImage = image
                }
            }
            graph.onError = { [weak self] in self?.queue.async { [weak self] in
                guard let self else { return }
                guard self.focusNavigatorRevision.matches(generation) else { return }
                self.focusNavigatorFailedSignature = signature
                DispatchQueue.main.async { if self.videoBusy { self.stopVideoRecording() } }
                self.stopFocusNavigatorOnQueue()
            } }
            syncPreviewState(); try graph.start(); configureRecordingHaptics()
            let region = graph.region(zoom: focusNavigatorZoom, ratio: focusNavigatorRatio)
            DispatchQueue.main.async {
                guard self.focusNavigatorRevision.matches(generation) else { return }
                self.focusNavigatorActive = true; self.focusNavigatorRegion = region; self.focusNavigatorUnavailableReason = nil
            }
        } catch {
            stopFocusNavigatorOnQueue()
            if wantsRunning && !session.isRunning { session.startRunning() }
            focusNavigatorFailedSignature = signature
            DispatchQueue.main.async { self.focusNavigatorUnavailableReason = error.localizedDescription }
        }
    }
    private var recordingBusyOnQueue: Bool { movieRecorder != nil || recordingFinishing }
    private func stopFocusNavigatorOnQueue() {
        guard let graph = focusNavigatorGraph else { return }
        _ = focusNavigatorRevision.advance()
        focusNavigatorGraph = nil
        let lockedWhiteBalance = graph.main.whiteBalanceMode == .locked
        let gains = graph.main.deviceWhiteBalanceGains
        let lockedFocus = graph.main.focusMode == .locked
        let lensPosition = graph.main.lensPosition
        graph.restore()
        readingsGeneration &+= 1
        // 静态请求必须使用原照片路由的真实手动曝光，不能仅保留UI数字。
        let restored = graph.originalInput.device
        if (try? restored.lockForConfiguration()) != nil {
            // 恢复照片格式后使用导航期间的最新倍率，不能回到进入导航时保存的旧倍率。
            let base = restored.isVirtualDevice ? CameraLensCatalog.displayMultiplier(restored)
                : (lensCatalog.first { $0.device.uniqueID == restored.uniqueID }.map { $0.displayZoom / $0.zoomFactor } ?? 1)
            restored.videoZoomFactor = min(max(focusNavigatorZoom / base, restored.minAvailableVideoZoomFactor), restored.maxAvailableVideoZoomFactor)
            if manualMode, customExposureRequested, let values = manualExposureValues, restored.isExposureModeSupported(.custom) {
                let format = restored.activeFormat
                let seconds = min(max(values.seconds, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
                let iso = min(max(values.iso, format.minISO), format.maxISO)
                restored.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), iso: iso, completionHandler: nil)
            }
            if lockedWhiteBalance, restored.isWhiteBalanceModeSupported(.locked),
               let safe = WhiteBalanceSafety.validated(gains, maximum: restored.maxWhiteBalanceGain) {
                restored.setWhiteBalanceModeLocked(with: safe, completionHandler: nil)
            }
            if lockedFocus, restored.isLockingFocusWithCustomLensPositionSupported {
                restored.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            }
            restored.unlockForConfiguration()
        }
        configureOutputConnections(graph.originalInput.device)
        syncPreviewState()
        if wantsRunning { session.startRunning() }
        DispatchQueue.main.async { self.focusNavigatorActive = false; self.focusNavigatorImage = nil }
    }
    #if DEBUG
    func focusNavigatorStateForTesting(_ completion: @escaping ([String: String]) -> Void) {
        queue.async {
            let graph = self.focusNavigatorGraph
            let base = ["active": "\(graph != nil)", "session": "\(graph?.session.isRunning ?? self.session.isRunning)",
                        "hardwareCost": "\(graph?.session.hardwareCost ?? -1)", "pressureCost": "\(graph?.session.systemPressureCost ?? -1)",
                        "zoom": "\(graph?.main.videoZoomFactor ?? self.input?.device.videoZoomFactor ?? 0)",
                        "wanted": "\(self.focusNavigatorWanted)", "wantedZoom": "\(self.focusNavigatorZoom)",
                        "allowed": "\(self.focusNavigatorAllowed)", "wantsRunning": "\(self.wantsRunning)",
                        "video": "\(self.videoModeRequested)", "hdrSource": "\(self.hdrPreviewSource != nil)",
                        "hdrRequested": "\(self.heifHDRPreviewRequested)", "contexts": "\(self.captureContexts.count)",
                        "route": self.input?.device.deviceType.rawValue ?? "nil",
                        "failedSignature": self.focusNavigatorFailedSignature ?? "nil"]
            self.focusNavigatorQueue.async {
                var result = base; result["frames"] = "\(graph?.frames ?? 0)"; result["renderSeconds"] = "\(graph?.renderSeconds ?? 0)"
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    #endif

    private let session = AVCaptureSession()
    private let focusNavigatorQueue = DispatchQueue(label: "camera.focusNavigator", qos: .userInitiated)
    private var photoOutput = AVCapturePhotoOutput()
    private var replacePhotoOutputOnRecovery = false // session queue; 原生请求超时后废弃旧输出
    private var stalledPortraitDeviceIDs = Set<String>() // session queue; 当前进程内记住已超时的原生蒙版路线
    private let recordingOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Cinematic Video 官方要求会话包含并配置此元数据输出。
    private let cinematicMetadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let recordingQueue = DispatchQueue(label: "camera.recording", qos: .userInitiated)
    private var movieRecorder: MovieRecorder? // recordingQueue only, including audio and finish
    private var recordingFinishing = false // recordingQueue only
    private var lastRecordingPreviewEnqueueTime = -Double.infinity // recordingQueue only
    #if DEBUG
    private var receivedRecordingFramesForTesting = 0 // recordingQueue only
    func recordingFrameCountForTesting(_ completion: @escaping (Int) -> Void) {
        recordingQueue.async { completion(self.receivedRecordingFramesForTesting) }
    }
    #endif
    private var videoCaptureToken: UUID? // main queue only
    #if DEBUG
    private(set) var lastRecordingFrameCountsForTesting: (received: Int, written: Int, span: Double)?
    #endif
    private let videoModeRevision = PreviewRevision()
    private var videoAudioPermissionPending = false // main queue only
    #if DEBUG
    private var videoModeConfigurationsForTesting = 0 // session queue only
    private var runtimeErrorCountForTesting = 0 // session queue only
    private var recentSessionOperationsForTesting: [String] = [] // session queue only
    var onPhotoRequestDimensionsForTesting: ((CMVideoDimensions) -> Void)?
    var previewFrameTimeForTesting: Double { livePreviewState.snapshot().latestFrameHostTime }
    var nightPreviewHoldForTesting: Bool { livePreviewState.snapshot().nightCapturePreviewHold }
    struct CaptureHardwareState {
        let iso: Double
        let seconds: Double
        let customExposure: Bool
        let automaticFocus: Bool
        let focusMode: AVCaptureDevice.FocusMode
        let lensPosition: Float
        let adjustingFocus: Bool
        let focusPoint: CGPoint
        let whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains
    }
    func captureHardwareStateForTesting(_ completion: @escaping (CaptureHardwareState?) -> Void) {
        queue.async {
            let state = self.input.map { input in
                let device = input.device
                return CaptureHardwareState(iso:Double(device.iso),seconds:device.exposureDuration.seconds,
                    customExposure:device.exposureMode == .custom,
                    automaticFocus:device.focusMode == .autoFocus || device.focusMode == .continuousAutoFocus,
                    focusMode:device.focusMode,lensPosition:device.lensPosition,adjustingFocus:device.isAdjustingFocus,
                    focusPoint:device.focusPointOfInterest,whiteBalanceGains:device.deviceWhiteBalanceGains)
            }
            DispatchQueue.main.async { completion(state) }
        }
    }
    private var previewPublicationTimesForTesting: [Double] = [] // main queue only
    var previewPublicationTimesForTestingSnapshot: [Double] { previewPublicationTimesForTesting }
    func resetPreviewPublicationTimesForTesting() { previewPublicationTimesForTesting.removeAll(keepingCapacity: true) }
    func videoColorStateForTesting(_ completion: @escaping (AVCaptureColorSpace?, OSType?, Bool) -> Void) {
        queue.async {
            let color = self.input?.device.activeColorSpace
            let pixel = (self.recordingOutput.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            let photoActive = self.photoOutput.connection(with: .video)?.isActive ?? false
            DispatchQueue.main.async { completion(color, pixel, photoActive) }
        }
    }
    func photoOutputConfigurationForTesting(_ completion: @escaping ([String: String]) -> Void) {
        queue.async {
            let device = self.input?.device
            let dims = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) } ?? .init(width: 0, height: 0)
            let state: [String: String] = [
                "input": device?.uniqueID ?? "nil",
                "virtual": String(device?.isVirtualDevice ?? false),
                "active": "\(dims.width)x\(dims.height)",
                "supported": device?.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }.joined(separator: ",") ?? "",
                "outputMax": "\(self.photoOutput.maxPhotoDimensions.width)x\(self.photoOutput.maxPhotoDimensions.height)",
                "responsive": String(self.photoOutput.isResponsiveCaptureEnabled),
                "deferredPhotoDelivery": String(self.photoOutput.isAutoDeferredPhotoDeliveryEnabled),
                "proRAW": String(self.photoOutput.isAppleProRAWEnabled),
                "proRAWSupported": String(self.photoOutput.isAppleProRAWSupported),
                "rawTypes": "\(self.photoOutput.availableRawPhotoPixelFormatTypes.count)",
                "preset": self.session.sessionPreset.rawValue,
                "outputs": self.session.outputs.map { String(describing: type(of: $0)) }.joined(separator: ",")
            ]
            DispatchQueue.main.async { completion(state) }
        }
    }

    func maxBracketedPhotoCountForTesting(_ completion: @escaping (Int, [String]) -> Void) {
        queue.async {
            let dimensions = self.photoDimensions.map { "\($0.width)x\($0.height)" }
            DispatchQueue.main.async { completion(self.photoOutput.maxBracketedCapturePhotoCount, dimensions) }
        }
    }

    func videoRouteStateForTesting(_ completion: @escaping (Bool, Bool, Int) -> Void) {
        queue.async {
            let state = (self.videoModeRequested, self.session.outputs.contains(self.recordingOutput), self.videoModeConfigurationsForTesting)
            DispatchQueue.main.async { completion(state.0, state.1, state.2) }
        }
    }
    struct VideoStabilizationState {
        let device: String
        let format: String
        let minimumFrameSeconds: Double
        let maximumFrameSeconds: Double
        let recordingSupported: Bool
        let recordingPreferred: Int?
        let recordingActive: Int?
        let previewSupported: Bool
        let previewPreferred: Int?
        let previewActive: Int?
    }
    func videoStabilizationStateForTesting(_ completion: @escaping (VideoStabilizationState?) -> Void) {
        queue.async {
            guard let device = self.input?.device else { DispatchQueue.main.async { completion(nil) }; return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let recording = self.recordingOutput.connection(with: .video)
            let preview = self.videoOutput.connection(with: .video)
            let state = VideoStabilizationState(device: device.uniqueID, format: "\(dimensions.width)x\(dimensions.height)",
                minimumFrameSeconds: device.activeVideoMinFrameDuration.seconds, maximumFrameSeconds: device.activeVideoMaxFrameDuration.seconds,
                recordingSupported: recording?.isVideoStabilizationSupported ?? false,
                recordingPreferred: recording?.preferredVideoStabilizationMode.rawValue, recordingActive: recording?.activeVideoStabilizationMode.rawValue,
                previewSupported: preview?.isVideoStabilizationSupported ?? false,
                previewPreferred: preview?.preferredVideoStabilizationMode.rawValue, previewActive: preview?.activeVideoStabilizationMode.rawValue)
            DispatchQueue.main.async { completion(state) }
        }
    }
    func videoFormatStateForTesting(_ completion: @escaping (String, Double, Double, [String]) -> Void) {
        queue.async {
            guard let device = self.input?.device else {
                DispatchQueue.main.async { completion("unavailable", .nan, .nan, []) }
                return
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let name = "\(dimensions.width)x\(dimensions.height)-\(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))"
            let minimum = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            let maximum = CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
            let ranges = device.activeFormat.videoSupportedFrameRateRanges.map {
                String(format: "%.0f...%.0f", $0.minFrameRate, $0.maxFrameRate)
            }
            DispatchQueue.main.async { completion(name, minimum, maximum, ranges) }
        }
    }
    /// 只读核对真实前置倍率、系统人物居中与路由限制。
    /// 只读/可逆探测：双拍期间前置是否允许 CenterStage。测试结束后恢复关闭。
    func probeDualCaptureCenterStageForTesting(_ completion: @escaping ([String: String]) -> Void) {
        queue.async {
            guard let dual = self.dualCaptureSource else {
                DispatchQueue.main.async { completion(["dual": "false"]) }
                return
            }
            let front = dual.front
            let supported = front.activeFormat.isCenterStageSupported
            let centerFormats = front.formats.filter { $0.isCenterStageSupported }.count
            AVCaptureDevice.centerStageControlMode = .app
            let before = AVCaptureDevice.isCenterStageEnabled
            if supported { AVCaptureDevice.isCenterStageEnabled = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.queue.async {
                    let info = ["dual": "true", "supported": "\(supported)", "centerFormats": "\(centerFormats)",
                        "requested": "true", "global": "\(AVCaptureDevice.isCenterStageEnabled)",
                        "active": "\(front.isCenterStageActive)", "before": "\(before)",
                        "multicam": "\(dual.session.isRunning)", "device": front.deviceType.rawValue,
                        "zoom": "\(front.videoZoomFactor)"]
                    AVCaptureDevice.isCenterStageEnabled = false
                    DispatchQueue.main.async { completion(info) }
                }
            }
        }
    }

    func frontVideoCenteringStateForTesting(_ completion: @escaping ([String: String]) -> Void) {
        queue.async {
            guard let device = self.input?.device else { DispatchQueue.main.async { completion([:]) }; return }
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let value = ["requested": "\(self.frontVideoCenteringRequested)", "global": "\(AVCaptureDevice.isCenterStageEnabled)",
                "active": "\(device.isCenterStageActive)", "supports": "\(device.activeFormat.isCenterStageSupported)",
                "device": device.deviceType.rawValue, "size": "\(size.width)x\(size.height)",
                "zoom": "\(device.videoZoomFactor)", "depth": "\(self.photoOutput.isDepthDataDeliveryEnabled)",
                "distortion": "\(device.isGeometricDistortionCorrectionEnabled)",
                "roiWidth": "\(device.centerStageRectOfInterest.width)", "roiHeight": "\(device.centerStageRectOfInterest.height)",
                "outputWidth": "\(self.frontVideoOutputSize()?.width ?? 0)", "outputHeight": "\(self.frontVideoOutputSize()?.height ?? 0)",
                "centerFormats": "\(device.formats.filter { $0.isCenterStageSupported }.count)"]
            DispatchQueue.main.async { completion(value) }
        }
    }
    func frontFramingStateForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            guard let d = self.input?.device else { DispatchQueue.main.async { completion("no input") }; return }
            let state = "device=\(d.deviceType.rawValue) virtual=\(d.isVirtualDevice) zoom=\(d.videoZoomFactor) limits=\(d.minAvailableVideoZoomFactor)...\(d.maxAvailableVideoZoomFactor) formatMax=\(d.activeFormat.videoMaxZoomFactor) depth=\(self.photoOutput.isDepthDataDeliveryEnabled) matte=\(self.photoOutput.isPortraitEffectsMatteDeliveryEnabled) video=\(self.videoModeRequested) cinematic=\(self.requestedCinematicVideo) center=\(AVCaptureDevice.isCenterStageEnabled)/\(d.isCenterStageActive)"
            let dimensions = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
            let framing: String
            if #available(iOS 26.0, *) {
                framing = " smart=\(d.activeFormat.isSmartFramingSupported) framings=\(d.smartFramingMonitor?.supportedFramings.count ?? -1) cinemaInput=\(self.input?.isCinematicVideoCaptureEnabled ?? false)"
            } else { framing = "" }
            DispatchQueue.main.async { completion(state + " dimensions=\(dimensions.width)x\(dimensions.height)" + framing) }
        }
    }
    private var lastLensSwitchPhasesForTesting: [String: Double] = [:] // session queue
    func lensSwitchPhasesForTesting(_ completion: @escaping ([String: Double]) -> Void) {
        queue.async {
            let phases = self.lastLensSwitchPhasesForTesting
            DispatchQueue.main.async { completion(phases) }
        }
    }
    private var cinematicGraphRebuildCountForTesting = 0 // session queue
    func cinematicGraphRebuildCountForTestingSnapshot(_ completion: @escaping (Int) -> Void) {
        queue.async {
            let count = self.cinematicGraphRebuildCountForTesting
            DispatchQueue.main.async { completion(count) }
        }
    }
    func cinematicCaptureStateForTesting(_ completion: @escaping (Bool, Bool) -> Void) {
        queue.async {
            guard #available(iOS 26.0, *), let input = self.input else {
                DispatchQueue.main.async { completion(false, false) }
                return
            }
            let state = (input.isCinematicVideoCaptureSupported, input.isCinematicVideoCaptureEnabled)
            DispatchQueue.main.async { completion(state.0, state.1) }
        }
    }
    /// 仅用于真实景深效果对照；录制中不改光圈，遵守系统Cinematic限制。
    func cinematicApertureForTesting(_ requested: Float?, observer: AVCaptureMetadataOutputObjectsDelegate?,
                                     completion: @escaping ((minimum: Float, maximum: Float, current: Float)?) -> Void) {
        guard !videoBusy else { completion(nil); return }
        queue.async {
            guard #available(iOS 26.0, *), let input = self.input, input.isCinematicVideoCaptureEnabled,
                  input.device.activeFormat.minSimulatedAperture > 0 else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let format = input.device.activeFormat
            if let requested { input.simulatedAperture = min(max(requested,format.minSimulatedAperture),format.maxSimulatedAperture) }
            self.cinematicMetadataOutput.setMetadataObjectsDelegate(observer,queue:self.queue)
            let value = (format.minSimulatedAperture,format.maxSimulatedAperture,input.simulatedAperture)
            DispatchQueue.main.async { completion(value) }
        }
    }
    /// 输出实际输入、格式与请求值，区分 UI 选择和硬件路由真正应用的状态。
    func videoSubmodeStateForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            guard let device = self.input?.device else {
                DispatchQueue.main.async { completion("input=unavailable") }
                return
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let ranges = device.activeFormat.videoSupportedFrameRateRanges.map {
                String(format: "%.0f...%.0f", $0.minFrameRate, $0.maxFrameRate)
            }
            let cinematic: String
            if #available(iOS 26.0, *) {
                cinematic = "cinematic=\(self.input?.isCinematicVideoCaptureSupported ?? false)/\(self.input?.isCinematicVideoCaptureEnabled ?? false) scene=\(device.cinematicVideoCaptureSceneMonitoringStatuses)"
            } else { cinematic = "cinematic=iOSUnsupported" }
            let outputs = self.session.outputs.map { String(describing: type(of: $0)) }.joined(separator: ",")
            let state = "running=\(self.session.isRunning) runtimeErrors=\(self.runtimeErrorCountForTesting) outputs=\(outputs) input=\(device.deviceType.rawValue):\(device.uniqueID) active=\(dimensions.width)x\(dimensions.height) ranges=\(ranges) requested=\(self.requestedVideoSettings.resolution.title)/\(self.requestedVideoSettings.frameRate.rawValue)/capture\(self.requestedVideoSettings.captureFrameRate?.rawValue.description ?? "nil") cinematicRequested=\(self.requestedCinematicVideo) \(cinematic)"
            DispatchQueue.main.async { completion(state) }
        }
    }
    func resetRuntimeErrorCountForTesting(_ completion: @escaping () -> Void) {
        queue.async {
            self.runtimeErrorCountForTesting = 0
            DispatchQueue.main.async(execute: completion)
        }
    }
    func videoWhiteBalanceStateForTesting(_ completion: @escaping (AVCaptureDevice.WhiteBalanceMode, AVCaptureDevice.WhiteBalanceGains) -> Void) {
        queue.async {
            guard let device = self.input?.device else {
                DispatchQueue.main.async { completion(.locked, .init(redGain: .nan, greenGain: .nan, blueGain: .nan)) }
                return
            }
            let mode = device.whiteBalanceMode
            let gains = device.deviceWhiteBalanceGains
            DispatchQueue.main.async { completion(mode, gains) }
        }
    }
    #endif
    private let previewQueue: DispatchQueue
    private let livePreviewState = LivePreviewState()
    var latestPreviewFrameTime: TimeInterval { livePreviewState.snapshot().latestFrameHostTime }
    var latestRecordingPreviewFrameTime: TimeInterval { livePreviewState.snapshot().latestRecordingPreviewFrameHostTime }
    private let portraitPreviewProcessor = PortraitPreviewProcessor()
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    private struct DemoPreview {
        var look: CaptureLook
        let logLUTCube: LogLUTCube?
        let logLUTLog2ToLog1: Bool
        let videoColorSpace: VideoColorSpace?
        let revision: UInt64
        let zoom: CGFloat
        let quarterTurns: Int
        let histogram: Bool
        let focusPeaking: Bool
    }
    private lazy var demoPreviewThrottle = LatestValueThrottle<DemoPreview>(queue: previewQueue, interval: 0) { [weak self] in self?.renderDemoFrame($0) }
    private let processingQueue = DispatchQueue(label: "camera.photo", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let levelMonitor = DeviceLevelMonitor()
    /// 水平仪是可选辅助；未开启时不启动 10Hz CoreMotion，节省常驻功耗。
    private var levelMonitoringRequested = false
    private var input: AVCaptureDeviceInput?
    private var frontAutoCenteringRequested = false // session queue
    private var frontPhotoLandscapeRequested = false // session queue; remains a photo preference during video capture
    /// 只有系统动态构图回调成功后才更新，用来和快门时实际使用的构图保持一致。
    private var frontPhotoLandscapeApplied = false
    /// 宽高比按钮的临时往返状态，不覆盖用户原来的精确倍率；只在当前运行周期内保存。
    private var frontAspectReturnState: (deviceID:String, landscape:Bool, zoom:CGFloat, lensID:String)?
    private var frontAspectInFlight = false // session queue，避免连点时误把旧画幅当成已完成目标
    // 持续跟踪当前新前置相机的重力方向；快门时只读取角度，不重建会话或旋转取景控件。
    private var rearCaptureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var frontPhotoRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let frontAspectRequestRevision = PreviewRevision() // stale format/route completions are discarded
    private let frontAspectAvailabilityRevision = PreviewRevision()
    private var liveAudioInput: AVCaptureDeviceInput? // session queue only
    private var videoModeRequested = false // session queue only
    private var videoModeDesired = false // main queue only
    private var videoAudioRequested = false // session queue only
    private var videoAudioMeterRequested = false // session queue only
    private var recordingConnectionsEpoch = 0
    @Published private(set) var videoRecordingZoomRange: ClosedRange<CGFloat>?
    private var recordingZoomDeviceID: String? // session queue; recorder input stays fixed
    @Published private(set) var videoRecording = false
    @Published private(set) var audioLeftLevel: Float = 0
    @Published private(set) var audioRightLevel: Float = 0
    private var lastAudioMeterUpdate: Double = 0
    @Published private(set) var videoBusy = false
    @Published private(set) var videoConfiguring = false
    @Published private(set) var videoSettings = VideoCaptureSettings()
    @Published private(set) var rawVideoSettings: [VideoCaptureSettings] = []
    @Published private(set) var supportedVideoSettings: [VideoCaptureSettings] = []
    @Published private(set) var slowMotionVideoSettings: [VideoCaptureSettings] = []
    @Published private(set) var slowMotionCaptureFormats: [VideoCaptureSettings] = []
    @Published private(set) var cinematicVideoSettings: [VideoCaptureSettings] = []
    @Published private(set) var cinematicVideoCaptureActive = false
    @Published private(set) var openGateVideoSettings: [VideoCaptureSettings] = []
#if DEBUG
    /// 注入设备能力以验证子模式规格回退，不启动采集会话或触发硬件相机。
    func installVideoCapabilitiesForTesting(ordinary: [VideoCaptureSettings], cinematic: [VideoCaptureSettings],
                                           slowMotionCaptureRates: [VideoCaptureSettings] = []) {
        supportedVideoSettings = ordinary
        slowMotionVideoSettings = VideoSubmodeSettingsPolicy.slowMotionPlaybackSettings(
            from: ordinary, captureRates: slowMotionCaptureRates.isEmpty
                ? ordinary.filter { SlowMotionCapturePolicy.captureRates.contains($0.frameRate) }
                : slowMotionCaptureRates)
        self.slowMotionCaptureFormats = slowMotionCaptureRates.isEmpty
            ? ordinary.filter { SlowMotionCapturePolicy.captureRates.contains($0.frameRate) }
            : slowMotionCaptureRates
        cinematicVideoSettings = cinematic
    }
#endif
    private var requestedVideoSettings = VideoCaptureSettings() // session queue
    private var requestedVideoRatio: FrameRatio = .wide // session queue
    private var requestedVideoOpenGate = false
    private var preferredVideoStabilization = VideoStabilizationPreference.standard // session queue
    private var requestedCinematicVideo = false // session queue
    private var highResolutionPhotoRequested = false // session queue; 48MP pins a supported native physical lens
    private var dualSecondaryWhiteBalanceBeforeRecording: (AVCaptureDevice, AVCaptureDevice.WhiteBalanceMode)?
    private var videoWhiteBalanceBeforeRecording: (AVCaptureDevice, AVCaptureDevice.WhiteBalanceMode)?
    // 会话队列独占：等待请求有身份，取消后到达的旧回调不能改动下一次录制。
    private var videoWhiteBalanceLockToken: UUID?
    private var videoWhiteBalanceLockPending: Bool { videoWhiteBalanceLockToken != nil }
    private var videoWhiteBalancePendingAccess: ExternalVideoStorage.RecordingAccess?
    private struct PhotoDeviceConfiguration {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let colorSpace: AVCaptureColorSpace
        let minFrameDuration: CMTime
        let maxFrameDuration: CMTime
        let zoomFactor: CGFloat
    }
    private func restoreVideoWhiteBalance() {
        if let (device, mode) = dualSecondaryWhiteBalanceBeforeRecording {
            dualSecondaryWhiteBalanceBeforeRecording = nil
            if (try? device.lockForConfiguration()) != nil {
                if device.isWhiteBalanceModeSupported(mode) { device.whiteBalanceMode = mode }
                device.unlockForConfiguration()
            }
        }
        guard let (device, mode) = videoWhiteBalanceBeforeRecording else { return }
        videoWhiteBalanceBeforeRecording = nil
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isWhiteBalanceModeSupported(mode) { device.whiteBalanceMode = mode }
        } catch { report("恢复白平衡失败：\(error.localizedDescription)") }
    }

    /// 普通视频固定当前增益；RAW等待锁定回调后才读取专用元数据。
    private func lockVideoWhiteBalanceBeforeRecording(
        device: AVCaptureDevice,
        token: UUID,
        access: ExternalVideoStorage.RecordingAccess?,
        synchronizesRAWMetadata: Bool = false,
        startRecorder: @escaping () -> Void
    ) {
        guard device.isWhiteBalanceModeSupported(.locked) else {
            access?.stop()
            DispatchQueue.main.async {
                guard self.videoCaptureToken == token else { return }
                self.videoCaptureToken = nil
                self.videoBusy = false
                self.report("当前镜头不支持锁定白平衡，无法开始录像。")
            }
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            videoWhiteBalanceBeforeRecording = (device, device.whiteBalanceMode)
            if !synchronizesRAWMetadata {
                // 普通视频只冻结当前白平衡状态，不重新提交增益调整。
                // HDR路线实测可能不返回增益完成回调；使用官方locked模式避免因此阻塞写入器。
                // RAW专用推荐元数据仍走下方的完成回调，不放宽其前置条件。
                if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                   let gains = WhiteBalanceSafety.validated(device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain) {
                    // 显式固定已经有效的当前值；仅切换mode曾观测到后续增益变化，不能只凭状态判断稳定。
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                } else {
                    device.whiteBalanceMode = .locked
                }
                videoWhiteBalanceLockToken = token
                videoWhiteBalancePendingAccess = access
                waitForVideoWhiteBalanceToSettle(device: device, token: token, deadline: CACurrentMediaTime() + 0.6,
                    previous: nil, stableSamples: 0, startRecorder: startRecorder)
                return
            }
            videoWhiteBalanceLockToken = token
            videoWhiteBalancePendingAccess = access
            // Apple 的特殊增益值表示锁定设备当前白平衡，不改变当前色温与色调。
            device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains) { _ in
                DispatchQueue.main.async {
                    // 令牌只在主队列读写；先在主队列确认取消状态，再按序回到会话队列启动写入。
                    guard self.videoCaptureToken == token else {
                        access?.stop()
                        self.queue.async {
                            guard self.videoWhiteBalanceLockToken == token else { return }
                            self.videoWhiteBalanceLockToken = nil
                            self.videoWhiteBalancePendingAccess = nil
                            self.restoreVideoWhiteBalance()
                            // 取消中的忙碌状态保持到白平衡恢复结束，避免过早接受下一次录像请求。
                            DispatchQueue.main.async {
                                self.videoRecording = false
                                self.videoBusy = false
                                self.onVideoRecorded?(.failure(CancellationError()))
                            }
                        }
                        return
                    }
                    self.queue.async {
                        guard self.videoWhiteBalanceLockToken == token else { access?.stop(); return }
                        self.videoWhiteBalanceLockToken = nil
                        self.videoWhiteBalancePendingAccess = nil
                        startRecorder()
                    }
                }
            }
        } catch {
            videoWhiteBalanceLockToken = nil
            videoWhiteBalancePendingAccess = nil
            access?.stop()
            restoreVideoWhiteBalance()
            DispatchQueue.main.async {
                guard self.videoCaptureToken == token else { return }
                self.videoCaptureToken = nil
                self.videoBusy = false
                self.report("锁定白平衡失败：\(error.localizedDescription)")
            }
        }
    }

    /// Reading .locked immediately can still expose pre-quantization gains.
    /// Use bounded hardware-readback sampling, not the HDR gain callback which
    /// is not delivered on every tested route. Cancellation retires the token.
    private func waitForVideoWhiteBalanceToSettle(device: AVCaptureDevice, token: UUID, deadline: Double,
        previous: AVCaptureDevice.WhiteBalanceGains?, stableSamples: Int, startRecorder: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.videoWhiteBalanceLockToken == token else { return }
            let gains = device.deviceWhiteBalanceGains
            let unchanged = previous.map {
                abs($0.redGain-gains.redGain) < 0.0001 && abs($0.greenGain-gains.greenGain) < 0.0001
                    && abs($0.blueGain-gains.blueGain) < 0.0001
            } ?? false
            let stable = unchanged && device.whiteBalanceMode == .locked ? stableSamples + 1 : 0
            if stable >= 2 || CACurrentMediaTime() >= deadline {
                self.videoWhiteBalanceLockToken = nil
                self.videoWhiteBalancePendingAccess = nil
                startRecorder()
            } else {
                self.waitForVideoWhiteBalanceToSettle(device: device, token: token, deadline: deadline,
                    previous: gains, stableSamples: stable, startRecorder: startRecorder)
            }
        }
    }
    private let videoSettingsRevision = PreviewRevision()
    private var videoFormatCatalog: [String: [VideoCaptureSettings: AVCaptureDevice.Format]] = [:] // session queue
    private var openGateVideoFormatCatalog: [String: [VideoCaptureSettings: AVCaptureDevice.Format]] = [:] // session queue
    private var centerStageVideoFormatCatalog: [String: [VideoCaptureSettings: AVCaptureDevice.Format]] = [:] // session queue
    private var cinematicVideoFormatCatalog: [String: [VideoCaptureSettings: AVCaptureDevice.Format]] = [:] // session queue
    private var slowMotionCaptureFormatCatalog: [String: [VideoCaptureSettings]] = [:] // session queue
    private var videoLensCapabilityCache: [String: VideoLensCaptureCapabilities] = [:] // session queue
    private var videoSelectionDeviceCache: [String:VideoLensCaptureCapabilities] = [:] // session queue; static format snapshots
    private var videoWideColorBeforeVideo: Bool?
    private var photoColorBeforeVideo: [String: AVCaptureColorSpace] = [:]
    private var frontPhotoZoomAfterVideo: CGFloat? // session queue，退出视频后恢复前置照片取景
    private var photoDeviceConfigurationsBeforeVideo: [String: PhotoDeviceConfiguration] = [:] // session queue
    private var liveAudioRequested = false // session queue only
    private var liveAudioDesired = false // main queue only
    private var liveAudioPermissionPending = false // main queue only
    @Published private(set) var liveAudioConnected = false
    private var rearVirtualDevice: AVCaptureDevice?
    private var livePreviewRequested = false
    private var nativeLivePreviewSupported = false
    private var configuredPreviewRoute = ""
    private var configuredPreviewHDR = false
    private var nativeLiveCapabilityCache: [String:Bool] = [:]
    private let photoCapabilityRevision = PreviewRevision()
    private var deferredPhotoGraphConfiguration = false // session queue
    private var nativePhotoInFlight: Bool { captureContexts.values.contains { $0.waitingForNativeCompletion } }
    private var manualMode = false
    private var manualModeTransitionInFlight = false
    private var manualZoomAnchorID: String? // session queue only; never follows wheel crossings
    private var automaticWhiteBalanceRequested = true
    private var manualWhiteBalanceValues:(kelvin:Double,tint:Double)? // session queue
    private var customExposureRequested = false
    private var manualExposureValues: (iso: Float, seconds: Double)? // session queue only
    private var previewExposureAssistEnabled = false // session queue only
    private var slowShutterSequencePreviewAssistEnabled = false // session queue only
    private let previewExposureAssistMaximumDuration = 1.0 / 30.0
    private var slowShutterPreviewOptimizationRequested = false // session queue only
    private var slowShutterAutoPreviewOptimizationActive = false // session queue only; latched until the preset is cleared
    private var slowShutterAutomaticExposureMaximumSeconds: Double? // session queue only
    private struct PreviewHDRSettings { let automatic: Bool; let enabled: Bool }
    private var previewHDRSettings: [String: PreviewHDRSettings] = [:]
    private var heifHDRPreviewRequested = false
    private var heifHDRPipelineRequested = false
    private var captureLookOverride: CaptureLook?
    private var hdrStillCapturePreparing = false
    private struct HDRPreviewSource {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let color: AVCaptureColorSpace
        let preset: AVCaptureSession.Preset
        let automaticWideColor: Bool
        let videoHDR: PreviewHDRSettings
        let rawTypes: [OSType]
        let dimensions: [CMVideoDimensions]
        let live: Bool
        let zoom: CGFloat
    }
    private var hdrPreviewSource: HDRPreviewSource?
    private var lensCatalog: [CameraLens] = []
    private var configured = false
    private var wantsRunning = false
    private let previewRevision = PreviewRevision()
    private let lookUpdateRevision = PreviewRevision()
    private var lookRevision: UInt64 = 0
    private var look = CaptureLook()

    private var nightPreviewEV = 0.0 // frame queue only
    private var nightPreviewMeasurementTime = -Double.infinity
    private var previewQuarterTurns = 0
    private var demoZoom: CGFloat = 1
    /// Mutable only on the session queue, then handed exclusively to the processing queue.
    private final class CaptureContext {
        let sequence: UInt64
        let capturedAt = Date() // 快门请求时刻；耗时采集/处理不改变文件名时间。
        let token: UUID
        var look: CaptureLook
        var options: PhotoOptions
        let flashMode: CameraFlashMode
        let location: PhotoLocation?
        let weight: Int
        let completion: (CapturedPhoto?) -> Void
        var captureRotationAngle: CGFloat?
        var diagnostics: PhotoCaptureDiagnostics?
        var raw: Data?
        var processed: Data?
        var portraitMatte: AVPortraitEffectsMatte?
        var nightFrames: [(sequence: Int, data: Data)] = []
        // 整组夜景共用一个快门 token，单批始终不超过三张；这些字段只在相机会话队列修改。
        var nightBatchOffset = 0
        var nightSubmittedFrames = 3
        var nightTargetFrames = 3
        var nightExposureIndex: Double?
        var nightAutomaticExposure: NightAdaptiveCapturePolicy.Exposure?
        var nightMeteredExposure: NightAdaptiveCapturePolicy.Exposure?
        var nightPhysicalDeviceName: String?
        var nightRouteStartedAt: TimeInterval?
        var nightRouteSettledChecks = 0
        var nightStarted = CACurrentMediaTime()
        var nightBatchSubmittedAt: TimeInterval?
        var nightRouteGeneration: UInt64 = 0
        var nightPrimaryDeviceID: String?
        var nightStopReason = "环境无需追加"
        var nightHighResolutionCrop = false
        var nightCaptureZoom: CGFloat?
        var nightRestoreZoom: CGFloat?
        var nightCancelled = false
        var nightPreviewHeld = false
        var error: Error?
        var liveMovieURL: URL?
        var liveMovieReady = false
        var liveMovieWaitAttempts = 0
        var macroConstituentCapture = false
        var nativePortraitFrontSensor = false
        var nativePortraitDeviceID: String?
        var waitingForNativeCompletion = false // session queue; 夜景批次间的处理等待不算原生漏回调
        #if DEBUG
        var dropsFinalCallbackForTesting = false
        #endif
        var usesPreviewExposureAssist = false
        var manualWhiteBalanceForCapture:(kelvin:Double,tint:Double)?
        var usesManualExposureBracket = false
        var previewExposureAssistRestored = false
        var manualExposureForCapture: (iso: Float, seconds: Double)?
        var usesSlowShutterAutoPreviewAssist = false
        var slowShutterAEMaximumForCapture: Double?
        var slowShutterAutoPreviewAssistRestored = false
        init(sequence: UInt64, token: UUID, look: CaptureLook, options: PhotoOptions,
             flashMode: CameraFlashMode, location: PhotoLocation?, weight: Int, completion: @escaping (CapturedPhoto?) -> Void) {
            self.completion = completion
            self.sequence = sequence; self.token = token; self.look = look; self.options = options
            self.flashMode = flashMode; self.location = location; self.weight = weight
        }
    }
    private var captureContexts: [Int64: CaptureContext] = [:]
    private var independentNightCapture: IndependentNightCapture? // session queue
    private var independentNightContext: CaptureContext? // session queue
    private var independentNightModeActive = false // session queue
    #if DEBUG
    private var forceOrdinaryNightForTesting = false // session queue
    func setForceOrdinaryNightForTesting(_ force: Bool) {
        queue.async { self.forceOrdinaryNightForTesting = force }
    }
    #endif
    var locationProvider: (() -> PhotoLocation?)?
    private var photoDimensions: [CMVideoDimensions] = []
    private var metering = CameraMetering.system
    private var globalBias: Float = 0
    private var manualGlobalMeteringSuggestion: Double?
    private var liveGlobalMeteringTarget: Double?
    private var exposureBias: Float = 0
    private var globalMeteringPolicy = GlobalMeteringPolicy()
    private var globalMeteringRevision = UUID()
    private var lastFrameTime = 0.0
    private var lastReadingsTime = 0.0
    #if DEBUG
    private var lastNightPreviewTraceTime = -Double.infinity
    private var grainFrameCounter: UInt64 = 0
    #endif
    private var lastReadingsRefreshRevision: UInt64 = 0 // preview queue only
    private var readingsGeneration: UInt64 = 0
    private var histogramEnabled = false
    private var focusPeakingEnabled = false
    private var lastPublishedHistogramRevision: UInt64 = 0
    private struct HistogramFrame {
        let image: CIImage
        let revision: UInt64
        let generation: UInt64
    }
    private let histogramQueue = DispatchQueue(label: "camera.histogram", qos: .userInitiated)
    private let histogramContext = CIContext(options: [.cacheIntermediates: false])
    private lazy var histogramThrottle = LatestValueThrottle<HistogramFrame>(queue: histogramQueue, interval: 1.0 / 20) { [weak self] frame in
        guard let self else { return }
        let state = self.livePreviewState.snapshot()
        guard state.running, state.acceptsFrames, state.histogram, self.previewRevision.canRender(frame.revision),
              state.readingsGeneration == frame.generation else { return }
        let bins = Imaging.histogram(frame.image, context: self.histogramContext)
        DispatchQueue.main.async {
            let current = self.livePreviewState.snapshot()
            guard current.running, current.acceptsFrames, current.histogram,
                  self.previewRevision.canRender(frame.revision), frame.revision >= self.lastPublishedHistogramRevision, current.readingsGeneration == frame.generation else { return }
            self.lastPublishedHistogramRevision = frame.revision
            self.histogram = bins
        }
    }
    private var lastMeteringSampleTime = 0.0
    private var observers: [NSObjectProtocol] = []

    /// Called on the main queue after image processing completes.
    private var primaryLensObservation: NSKeyValueObservation?
    private var smartFramingObservation: NSKeyValueObservation?
    private var smartFramingFormatObservation: NSKeyValueObservation?
    private var smartFramingChoicesObservation: NSKeyValueObservation?
    private weak var smartFramingCapabilityDevice: AVCaptureDevice?
    private let smartFramingStateRevision = PreviewRevision()
    private weak var monitoredFrontDevice: AVCaptureDevice?
    private var smartFramingRecommendationToken = UUID() // session queue
    private weak var automaticConfiguredDevice: AVCaptureDevice?
    private var automaticUnrestrictedZoomRange: ClosedRange<CGFloat>?
    var onAutomaticLensChange: (() -> Void)?
    var onLivePhotoUnavailable: (() -> Void)?
    var onNightCaptureUnavailable: (() -> Void)?
    var onPortraitCaptureUnavailable: (() -> Void)?
    var onPhotoCaptured: ((UIImage?) -> Void)?
    /// 硬件曝光已完成、HDR编码尚未结束时先交付预览帧，用于缩略图/最近照片占位。
    var onCaptureThumbnailReady: ((UIImage?) -> Void)?
    var onCaptureCompleted: ((CapturedPhoto?) -> Void)?
    /// 成功交付一张照片后触发（取消的照片不触发），用于连拍张数等 UI 统计。
    var onCaptureDelivered: ((CapturedPhoto) -> Void)?
    var onSlowShutterSourceFrame: ((SlowShutterSourceFrame?) -> Void)?
    var onVideoRecorded: ((Result<URL, Error>) -> Void)?
    /// 视频会话启动失败时通知 UI 退出视频，避免 runtime error 恢复循环卡死。
    var onVideoRouteFailure: ((String) -> Void)?
    private var videoRouteFailureReported = false // main queue
    var canCapture: () -> Bool = { true }

    override convenience init() {
        self.init(previewQueue: DispatchQueue(label: "camera.preview", qos: .userInitiated))
    }
    init(previewQueue: DispatchQueue) {
        self.previewQueue = previewQueue
        super.init()
        _ = histogramThrottle // Initialise on the construction thread before either worker queue can use it.
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            if self?.videoBusy == true { self?.stopVideoRecording() }
            #if DEBUG
            self?.lastInterruptionForTesting = String(describing: note.userInfo ?? [:])
            #endif
            self?.requestSessionRecovery(waitForInterruptionEnd: true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.requestSessionRecovery(resumeInterruption: true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.configureRecordingHaptics() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.configureRecordingHaptics() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            self?.queue.async { [weak self] in self?.resumeFocusAfterSceneChange(deviceID: device.uniqueID) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            // 苹果要求从通知 userInfo 的 AVCaptureSessionErrorKey 读取具体运行错误。
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                // 保留 AVFoundation 提供的底层错误和恢复建议，便于定位具体是哪种会话重配置失败。
                NSLog("Camera capture session runtime error: %@ (%ld): %@ userInfo=%@",
                      error.domain, error.code, error.localizedDescription, String(reflecting: error.userInfo))
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    self.runtimeErrorCountForTesting += 1
                    for operation in self.recentSessionOperationsForTesting {
                        NSLog("Camera runtime history engine=%@ %@", String(describing: ObjectIdentifier(self)), operation)
                    }
                    #endif
                    let device = self.input?.device
                    let dimensions = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
                    let cinematic: String
                    if #available(iOS 26.0, *), let input = self.input {
                        cinematic = "supported=\(input.isCinematicVideoCaptureSupported) enabled=\(input.isCinematicVideoCaptureEnabled)"
                    } else {
                        cinematic = "unavailable"
                    }
                    NSLog("Camera session state at runtime error: running=%@ interrupted=%@ configured=%@ device=%@ type=%@ format=%@ cinematic={%@} outputs=%@",
                          String(self.session.isRunning), String(self.session.isInterrupted), String(self.configured),
                          device?.uniqueID ?? "none", device?.deviceType.rawValue ?? "none",
                          dimensions.map { "\($0.width)x\($0.height)" } ?? "none", cinematic,
                          self.session.outputs.map { String(describing: type(of: $0)) }.joined(separator: ","))
                }
            } else {
                NSLog("Camera capture session runtime error notification without AVCaptureSessionErrorKey: %@",
                      String(reflecting: note.userInfo ?? [:]))
            }
            if self?.videoBusy == true { self?.stopVideoRecording() }
            if let self, self.videoModeRequested {
                let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
                if code == -11819 || code == -11800 {
                    DispatchQueue.main.async {
                        guard !self.videoRouteFailureReported else { return }
                        self.videoRouteFailureReported = true
                        self.onVideoRouteFailure?("视频无法启动，已退出视频模式。")
                    }
                    return
                }
            }
            self?.requestSessionRecovery()
        })
    }

    deinit {
        let dual = dualCaptureSource, navigator = focusNavigatorGraph
        // 析构同样在会话串行队列释放独立图，避免遗留双摄及格式状态。
        queue.async { navigator?.restore(); dual?.release() }
        observers.forEach(NotificationCenter.default.removeObserver)
        levelMonitor.stop()
    }

    private let resumeDiagnostics = CameraResumeDiagnostics()
    private var resumeDiagnosticContext: [String: String] = [:] // main queue
    func noteLifecycleRequest(active: Bool, context: [String: String]) {
        resumeDiagnosticContext = context
        resumeDiagnostics.record(active ? "active-request" : "inactive-request", context: context)
    }

    func start() {
        resumeDiagnostics.start(context: resumeDiagnosticContext, probes: [
            "main": { [weak self] reply in DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reply(["ready": String(self.ready), "recovering": String(self.recoveringSession),
                       "zoomTarget": String(Double(self.currentZoom)),
                       "failed": String(self.recoveryFailed), "active": String(UIApplication.shared.applicationState == .active)])
            } },
            "session": { [weak self] reply in self?.queue.async { [weak self] in
                guard let self else { return }
                reply(["wantsRunning": String(self.wantsRunning), "configured": String(self.configured),
                       "captures": String(self.captureContexts.count)])
            } },
            "preview": { [weak self] reply in self?.previewQueue.async { [weak self] in
                guard let self else { return }
                let state = self.livePreviewState.snapshot(), age = CACurrentMediaTime() - state.latestFrameHostTime
                reply(["frameAge": age.isFinite ? String(age) : "unavailable", "running": String(state.running),
                       "acceptsFrames": String(state.acceptsFrames)])
            } }
        ])
        runRequested = true
        let lifecycle = recoveryRevision.advance()
        startPending = true
        let requestedZoom = currentZoom, requestedAnchor = selectedLens
        if recoveryFailed { message = nil }
        recoveryFailed = false; recoveringSession = false; ready = false
        if levelMonitoringRequested {
            levelMonitor.start { [weak self] in self?.roll = $0 }
        }
        #if targetEnvironment(simulator)
        demo = true
        queue.async {
            self.wantsRunning = true
            self.syncPreviewState()
            self.renderDemo()
            DispatchQueue.main.async {
                guard self.recoveryRevision.matches(lifecycle) else { return }
                self.startPending = false
                if self.runRequested { self.ready = true }
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            denied = false
            queue.async {
                guard self.recoveryRevision.matches(lifecycle) else { return }
                self.wantsRunning = true
                self.recordSessionOperation("start")
                DispatchQueue.main.async {
                    if self.recoveryRevision.matches(lifecycle) { self.startPending = false }
                }
                do {
                    if self.replacePhotoOutputOnRecovery {
                        self.rebuildSessionForUserRetry(token: lifecycle)
                        return
                    }
                    if let source = self.dualCaptureSource {
                        try source.start(); self.syncPreviewState()
                        self.livePreviewState.update { $0.acceptsFrames = true; $0.framesNotBefore = -Double.infinity }
                        self.verifyRecoveredFrames(token: lifecycle, attempt: 0, startedAt: CACurrentMediaTime())
                        return
                    }
                    if !self.configured { try self.configure() }
                    if let anchor = self.lensCatalog.first(where: { $0.id == requestedAnchor }),
                       self.input?.device.uniqueID != self.captureDevice(for:anchor).uniqueID {
                        let revision = self.zoomRevision.advance()
                        self.applyContinuousZoom(ZoomRequest(value:requestedZoom,position:anchor.device.position,revision:revision))
                    }
                    self.refreshHDRPreviewConfiguration()
                    if let device = self.input?.device { self.configureAutomaticLensPolicy(device) }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    if let device = self.input?.device {
                        self.applyFrontVideoWideFramingOnQueue(device)
                    }
                    self.refreshFrontSmartFraming()
                    if let device = self.input?.device { self.refreshFrontVideoCentering(device) }
                    let running = self.session.isRunning && !self.session.isInterrupted
                    self.syncPreviewState()
                    if running {
                        // Unlocking may leave a running session behind a closed frame gate.
                        // Readiness requires a new frame, not just isRunning.
                        let startedAt = CACurrentMediaTime()
                        self.livePreviewState.update { $0.acceptsFrames = true; $0.framesNotBefore = startedAt }
                        self.verifyRecoveredFrames(token: lifecycle, attempt: 0, startedAt: startedAt)
                    } else {
                        DispatchQueue.main.async {
                            guard self.runRequested, self.recoveryRevision.matches(lifecycle) else { return }
                            self.requestSessionRecovery(waitForInterruptionEnd: self.session.isInterrupted)
                        }
                    }
                } catch {
                    if self.dualCaptureSource != nil { self.releaseDualCaptureOnQueue() }
                    DispatchQueue.main.async { if self.recoveryRevision.matches(lifecycle) { self.requestSessionRecovery() } }
                }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    if UIApplication.shared.applicationState == .active { self?.start() }
                }
            }
        default:
            startPending = false
            denied = true
            ready = false
        }
        #endif
    }

    func stop() {
        resumeDiagnostics.stop()
        nightPreviewReveal = nil
        cancelledNightCaptureTokens.formUnion(nightCaptureTokens)
        if videoBusy { stopVideoRecording() }
        runRequested = false; startPending = false; _ = recoveryRevision.advance()
        recoveringSession = false; recoveryFailed = false
        previewRevision.setInteractive(false)
        unlockTargetExposure()
        levelMonitor.stop()
        zoomThrottle.cancel()
        ready = false
        macroActive = false
        livePreviewState.cancelMacroRouteChange()
        queue.async {
            self.wantsRunning = false
            self.stopFocusNavigatorOnQueue()
            // 不再追加夜景批次；正在执行的系统请求等待回调后释放，不向相册交付取消结果。
            for capture in self.captureContexts.values {
                if capture.options.nightMode { capture.nightCancelled = true }
                self.releaseNightPreviewHold(capture)
            }
            self.recordSessionOperation("stop")
            self.independentNightCapture?.cancel()
            self.independentNightCapture = nil
            self.independentNightContext = nil
            self.releaseAutomaticLensStability()
            self.syncPreviewState()
            self.demoPreviewThrottle.cancel()
            self.histogramThrottle.cancel()
            self.dualCaptureSource?.stop()
            if self.session.isRunning { self.session.stopRunning() }
            self.stopFrontSmartFraming()
            self.stopFrontVideoCentering(clearRequest: false)
            self.refreshHDRPreviewConfiguration()
        }
    }

    /// 用户点击“重试相机”时重建失效的采集图，再按原有生命周期重新启动。
    /// 普通恢复只会再次启动旧会话；若输入/输出连接已经失效，必须先从会话中移除并重新添加。
    func retrySessionRecovery() {
        guard runRequested else { start(); return }
        let token = recoveryRevision.advance()
        ready = false
        startPending = true
        recoveringSession = true
        recoveryFailed = false
        message = nil
        if videoBusy { stopVideoRecording() }
        recordingQueue.async { [weak self] in
            self?.waitForRecorderToFinishBeforeRetry(token: token)
        }
    }

    private func waitForRecorderToFinishBeforeRetry(token: UInt64) {
        guard recoveryRevision.matches(token) else { return }
        // 录制器只在自己的队列访问；等文件收尾后再拆除会话输出。
        guard movieRecorder == nil, !recordingFinishing else {
            recordingQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.waitForRecorderToFinishBeforeRetry(token: token)
            }
            return
        }
        queue.async { [weak self] in
            self?.rebuildSessionForUserRetry(token: token)
        }
    }

    private func rebuildSessionForUserRetry(token: UInt64) {
        guard recoveryRevision.matches(token) else { return }
        // 先让正在收尾的照片完成，避免 AVFoundation 回调仍持有输出时拆图。
        guard captureContexts.isEmpty else {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.rebuildSessionForUserRetry(token: token)
            }
            return
        }

        wantsRunning = false
        livePreviewState.update { $0.acceptsFrames = false; $0.running = false }
        releaseAutomaticLensStability()
        stopFrontSmartFraming()
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach {
            disableCinematicCapture(on: $0)
            session.removeInput($0)
        }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()

        if replacePhotoOutputOnRecovery {
            photoOutput = AVCapturePhotoOutput()
            replacePhotoOutputOnRecovery = false
        }

        input = nil
        liveAudioInput = nil
        reusableInputs.removeAll()
        configuredLiveCaptureRoute = nil
        configuredPreviewRoute = ""
        configured = false

        DispatchQueue.main.async { [weak self] in
            guard let self, self.recoveryRevision.matches(token), self.runRequested else { return }
            self.startPending = false
            // start() 会沿用已选择的焦段、倍率、模式和拍摄设置重新配置会话。
            self.start()
        }
    }

    /// Temporary ownership changes are expected lifecycle events, not user-facing errors.
    private func requestSessionRecovery(waitForInterruptionEnd: Bool = false, resumeInterruption: Bool = false) {
        guard runRequested, UIApplication.shared.applicationState == .active else { return }
        // start() already owns a fresh lifecycle but has not reached the session
        // queue yet. Advancing its token here would cancel that start while the
        // recovery task still sees wantsRunning=false from the previous stop.
        // The start itself checks interruption/running status and first frames.
        guard !startPending else { return }
        guard (!recoveringSession && !recoveryFailed) || resumeInterruption else { return }
        let token = recoveryRevision.advance()
        ready = false; recoveringSession = true; recoveryFailed = false
        queue.async {
            guard self.wantsRunning, self.recoveryRevision.matches(token) else { return }
            self.livePreviewState.update { $0.acceptsFrames = false }
            if !waitForInterruptionEnd { self.recoverSession(token: token, attempt: 0) }
        }
    }

    private func recoverSession(token: UInt64, attempt: Int) {
        guard wantsRunning, recoveryRevision.matches(token) else { return }
        #if targetEnvironment(simulator)
        syncPreviewState(); livePreviewState.update { $0.acceptsFrames = true }
        renderDemo()
        DispatchQueue.main.async {
            guard self.runRequested, self.recoveryRevision.matches(token) else { return }
            self.recoveringSession = false; self.recoveryFailed = false; self.ready = true
        }
        #else
        // Another owner has not released the hardware yet; the ended notification
        // or foreground lifecycle will resume us. Do not compete or spam alerts.
        guard !session.isInterrupted else { return }
        if !captureContexts.isEmpty {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.recoverSession(token: token, attempt: attempt) }
            return
        }
        do {
            if !configured {
                session.beginConfiguration()
                session.inputs.forEach {
                    self.disableCinematicCapture(on: $0)
                    session.removeInput($0)
                }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration(); input = nil; reusableInputs.removeAll(); configuredLiveCaptureRoute = nil
                try configure()
            }
            refreshHDRPreviewConfiguration()
            if !session.isRunning { session.startRunning() }
            if let device = input?.device { configureConnections(device: device) }
        } catch { NSLog("Camera automatic recovery attempt failed: %@", error.localizedDescription) }
        let running = session.isRunning && !session.isInterrupted
        if running {
            syncPreviewState(); livePreviewState.update { $0.acceptsFrames = true }
            verifyRecoveredFrames(token: token, attempt: attempt, startedAt: CACurrentMediaTime())
        } else if attempt < 2 {
            queue.asyncAfter(deadline: .now() + [0.25, 0.7][attempt]) { [weak self] in self?.recoverSession(token: token, attempt: attempt + 1) }
        } else {
            DispatchQueue.main.async {
                guard self.runRequested, self.recoveryRevision.matches(token) else { return }
                self.recoveringSession = false; self.recoveryFailed = true
                self.message = "相机暂时无法恢复，请点击重试重新连接。"
            }
        }
        #endif
    }

    private func verifyRecoveredFrames(token: UInt64, attempt: Int, startedAt: CFTimeInterval) {
        queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.wantsRunning, self.recoveryRevision.matches(token) else { return }
            if self.livePreviewState.snapshot().latestFrameHostTime >= startedAt {
                DispatchQueue.main.async {
                    guard self.runRequested, self.recoveryRevision.matches(token) else { return }
                    self.recoveringSession = false; self.recoveryFailed = false; self.ready = true
                }
            } else if CACurrentMediaTime() - startedAt < 3 {
                self.verifyRecoveredFrames(token: token, attempt: attempt, startedAt: startedAt)
            } else if self.dualCaptureSource != nil {
                self.releaseDualCaptureOnQueue()
                if self.wantsRunning { self.session.startRunning() }
                self.syncPreviewState()
                self.report("同步双拍未收到有效画面，已恢复普通视频。")
                self.verifyRecoveredFrames(token: token, attempt: 0, startedAt: CACurrentMediaTime())
            } else if attempt < 2 {
                if self.session.isRunning { self.session.stopRunning() }
                self.recoverSession(token: token, attempt: attempt + 1)
            } else {
                DispatchQueue.main.async {
                    guard self.runRequested, self.recoveryRevision.matches(token) else { return }
                    self.recoveringSession = false; self.recoveryFailed = true
                    self.message = "相机暂时无法恢复，请点击重试重新连接。"
                }
            }
        }
    }

    /// Only a user enabling Live can initiate an audio permission prompt.
    /// Permission callbacks always resolve against the latest intent, including rapid off/on changes.
    func setLiveAudioEnabled(_ enabled: Bool, requestPermission: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        liveAudioDesired = enabled
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if enabled, authorization == .notDetermined, requestPermission, !liveAudioPermissionPending {
            liveAudioPermissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.liveAudioPermissionPending = false
                    self.setLiveAudioEnabled(self.liveAudioDesired)
                    if !granted && self.liveAudioDesired { self.report("麦克风未授权，Live 将以无声方式拍摄。可在系统设置中开启麦克风权限。") }
                }
            }
        } else if enabled, requestPermission, authorization == .denied || authorization == .restricted {
            report("麦克风未授权，Live 将以无声方式拍摄。可在系统设置中开启麦克风权限。")
        }
        let connect = enabled && authorization == .authorized
        queue.async {
            self.liveAudioRequested = connect
            self.reconcileLiveAudio()
        }
    }

    private func allowCameraHaptics() {
        guard !AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording else { return }
        do { try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true) }
        catch {
            #if DEBUG
            print("Camera haptics unavailable: \(error.localizedDescription)")
            #endif
        }
    }

    private func configureRecordingHaptics() {
        guard liveAudioRequested || videoAudioRequested || dualCaptureSource?.includesAudio == true,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // Audio input suppresses haptics by default, including while the video
        // viewfinder is idle. Keep AVCaptureSession's automatic audio routing.
        allowCameraHaptics()
    }

    private func reconcileLiveAudio() {
        guard configured, captureContexts.isEmpty else { return }
        let shouldConnect = (liveAudioRequested || videoAudioRequested) && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if shouldConnect { configureRecordingHaptics() }
        guard shouldConnect != (liveAudioInput != nil) else { return }
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configureRecordingHaptics()
        }
        if shouldConnect {
            do {
                guard let microphone = AVCaptureDevice.default(for: .audio) else { return }
                let audio = try AVCaptureDeviceInput(device: microphone)
                guard session.canAddInput(audio) else { report("麦克风暂不可用，本次 Live 将以无声方式拍摄。"); return }
                session.addInput(audio)
                liveAudioInput = audio
            } catch { report("麦克风暂不可用，Live 将以无声方式拍摄：\(error.localizedDescription)") }
        } else if let audio = liveAudioInput {
            session.removeInput(audio); liveAudioInput = nil
        }
        let connected = liveAudioInput != nil
        DispatchQueue.main.async { self.liveAudioConnected = connected }
    }

    private var captureKindConfigurationTokens = Set<UUID>() // session queue
    private var captureKindConfigurationZooms: [UUID: CGFloat] = [:] // 事务前的显示倍率，不混用物理倍率。

    /// 照片/视频切换会同步发出 A/M、HDR、Live、规格等多条配置请求。
    /// 用最外层事务将它们一起提交，避免每个中间路线都启动一次输出图。
    func beginCaptureKindConfiguration() -> UUID? {
        guard ready, !recoveringSession, !capturing, !videoBusy else { return nil }
        let token = UUID()
        queue.async {
            guard self.configured, self.wantsRunning, self.session.isRunning,
                  !self.session.isInterrupted, self.captureContexts.isEmpty else { return }
            if let device = self.input?.device {
                let base = device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device)
                    : self.lensCatalog.first(where: { $0.device.uniqueID == device.uniqueID }).map { $0.displayZoom / $0.zoomFactor } ?? 1
                self.captureKindConfigurationZooms[token] = device.videoZoomFactor * base
            }
            self.session.beginConfiguration()
            self.captureKindConfigurationTokens.insert(token)
        }
        return token
    }

    func finishCaptureKindConfiguration(_ token: UUID?, transitionID: UUID) {
        queue.async {
            let displayedZoom = token.flatMap { self.captureKindConfigurationZooms.removeValue(forKey: $0) }
            if let token, self.captureKindConfigurationTokens.remove(token) != nil {
                self.session.commitConfiguration()
            }
            guard self.configured, self.wantsRunning, let device = self.input?.device else { return }
            // 外层提交后连接可能重建；随后只接收最终路线的新帧，不额外冻结等待。
            self.configureOutputConnections(device)
            // .photo preset 与输出图会在最外层提交时重置倍率。此时才按最终设备
            // 换算并恢复显示焦段，避免 8× 在内层事务中被暂时的范围钳回 1×。
            if let displayedZoom {
                let base = device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device)
                    : self.lensCatalog.first(where: { $0.device.uniqueID == device.uniqueID }).map { $0.displayZoom / $0.zoomFactor } ?? 1
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    // 外层提交会重置设备倍率；视频前置提交后的目标仍是固定超广角，
                    // 不能按进入前的照片显示倍率恢复，否则照片取景会被视频污染并产生呼吸。
                    let frontVideoWide = self.videoModeRequested && device.position == .front
                        ? self.lensCatalog.first { $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide }?.zoomFactor
                        : nil
                    let frontPhotoZoom = !self.videoModeRequested && device.position == .front
                        ? (self.frontPhotoZoomAfterVideo
                            ?? self.lensCatalog.first { $0.id == self.selectedLens }?.zoomFactor)
                        : nil
                    let target = frontVideoWide ?? frontPhotoZoom ?? displayedZoom / base
                    let factor = min(max(target, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                    if abs(device.videoZoomFactor - factor) > 0.001 { device.videoZoomFactor = factor }
                    if !self.videoModeRequested, device.position == .front { self.frontPhotoZoomAfterVideo = nil }
                } catch { self.report("恢复拍摄倍率失败：\(error.localizedDescription)") }
            }
            self.configureRecordingHaptics()
            self.configureAutomaticLensPolicy(device)
            self.refreshFrontSmartFraming()
            self.publishCapabilities(device, lensID: self.manualZoomAnchorID ?? self.selectedLens)
            self.syncPreviewState()
            self.markUserPreviewSwitch(transitionID)
        }
    }

    func setVideoStabilizationPreference(_ preference: VideoStabilizationPreference) {
        queue.async {
            guard self.preferredVideoStabilization != preference else { return }
            self.preferredVideoStabilization = preference
            // 会话/规格配置期间改 connection 会与事务竞争，容易触发 -11800。
            // 此时只保存偏好，等 configureConnections 完成后统一应用。
            guard self.videoModeRequested, !self.videoBusy, !self.videoConfiguring,
                  !self.recoveringSession, let device = self.input?.device else { return }
            for output in [self.videoOutput as AVCaptureOutput, self.recordingOutput as AVCaptureOutput] {
                guard let connection = output.connection(with: .video) else { continue }
                self.applyVideoStabilization(to: connection, device: device)
            }
        }
    }

    /// VideoDataOutput rejects explicit dimensions larger than the active format.
    /// Drop an over-sized width/height rather than letting AVFoundation throw.
    private func safeVideoOutputSettings(_ settings: [String: Any], device: AVCaptureDevice?) -> [String: Any] {
        guard let device else { return settings }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard let width = (settings[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue,
              let height = (settings[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue else { return settings }
        guard width > Int(dimensions.width) || height > Int(dimensions.height) else { return settings }
        var safe = settings
        safe.removeValue(forKey: kCVPixelBufferWidthKey as String)
        safe.removeValue(forKey: kCVPixelBufferHeightKey as String)
        return safe
    }

    /// 当前视频格式实际支持的防抖档位；设置页据此禁用不支持的选项。
    private func publishVideoStabilizationAvailability(device: AVCaptureDevice) {
        var values: Set<VideoStabilizationPreference> = [.off]
        if !requestedVideoSettings.isRAW, !requestedVideoOpenGate,
           let format = VideoCaptureSettings.format(for: requestedVideoSettings, device: device,
               requiringOpenGate: requestedVideoOpenGate,
               requiringCinematicVideo: requestedCinematicVideo) ?? Optional(device.activeFormat) {
            if format.isVideoStabilizationModeSupported(.standard) { values.insert(.standard) }
            if format.isVideoStabilizationModeSupported(.cinematic) { values.insert(.cinematic) }
        }
        DispatchQueue.main.async {
            if self.supportedVideoStabilizationPreferences != values {
                self.supportedVideoStabilizationPreferences = values
            }
        }
    }

    private func applyVideoStabilization(to connection: AVCaptureConnection, device: AVCaptureDevice) {
        guard connection.isVideoStabilizationSupported else { return }
        let mode: AVCaptureVideoStabilizationMode
        if videoModeRequested && !requestedVideoSettings.isRAW && !requestedVideoOpenGate {
            let candidates: [AVCaptureVideoStabilizationMode]
            switch preferredVideoStabilization {
            case .off:
                candidates = [.off]
            case .standard:
                candidates = [.standard, .off]
            case .cinematic:
                if #available(iOS 26.0, *) {
                    candidates = [.cinematic, .standard, .off]
                } else {
                    candidates = [.cinematic, .standard, .off]
                }
            }
            mode = candidates.first { device.activeFormat.isVideoStabilizationModeSupported($0) } ?? .off
        } else if connection === videoOutput.connection(with: .video),
                  videoOutput.deliversPreviewSizedOutputBuffers,
                  device.activeFormat.isVideoStabilizationModeSupported(.previewOptimized) {
            mode = .previewOptimized
        } else {
            mode = .off
        }
        if connection.preferredVideoStabilizationMode != mode {
            connection.preferredVideoStabilizationMode = mode
        }
    }

    func setVideoMode(_ enabled: Bool) {
        videoModeDesired = enabled
        if enabled { videoRouteFailureReported = false }
        if !enabled {
            // 返回照片后，排队中的旧电影规格不能重新启用电影输出。
            _ = videoSettingsRevision.advance()
            if videoConfiguring { videoConfiguring = false }
        }
        if enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined && !videoAudioPermissionPending {
            videoAudioPermissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.videoAudioPermissionPending = false
                    self.setVideoMode(self.videoModeDesired)
                }
            }
        }
        guard !videoBusy else { return }
        let revision = videoModeRevision.advance()
        queue.async {
            guard self.videoModeRevision.matches(revision) else { return }
            if enabled { self.allowCameraHaptics() }
            self.stopFocusNavigatorOnQueue()
            if self.dualCaptureSource != nil {
                if enabled { return }
                self.releaseDualCaptureOnQueue()
                if self.wantsRunning { self.session.startRunning() }
            }
            // 即使 A/M 没有变化，电影也可能使用与照片不同的物理输入。
            var wasCinematic = self.requestedCinematicVideo
            if #available(iOS 26.0, *), self.input?.isCinematicVideoCaptureEnabled == true {
                wasCinematic = true
            }
            // 离开视频路由前先关闭系统电影处理，避免其状态残留到照片采集会话。
            if !enabled { self.requestedCinematicVideo = false; self.stopFrontVideoCentering() }
            let audioWanted = enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            self.recordSessionOperation("setVideoMode=\(enabled)")
            let unchanged = self.videoModeRequested == enabled
                && self.session.outputs.contains(self.recordingOutput) == enabled
                && self.session.outputs.contains(self.audioOutput) == audioWanted
                && (enabled || !wasCinematic)
            self.videoModeRequested = enabled
            self.videoAudioRequested = enabled
            guard self.configured else { return }
            if enabled { self.publishVideoSelectionCapabilities() }
            guard !unchanged else { self.reconcileLiveAudio(); return }
            #if DEBUG
            self.videoModeConfigurationsForTesting += 1
            #endif
            // A session preset can immediately replace the format and reset zoom.
            // Capture the still-photo state before touching the session graph.
            if enabled, let device = self.input?.device {
                self.rememberPhotoDeviceConfiguration(device)
            }
            let zoomBeforeTransition = self.input?.device.videoZoomFactor
            var changedPhotoInput = false
            self.session.beginConfiguration()
            if #available(iOS 26.0, *), !enabled, let input = self.input,
               input.isCinematicVideoCaptureEnabled {
                input.isCinematicVideoCaptureEnabled = false
            }
            if enabled {
                // Video chooses activeFormat explicitly. A fixed 1080p preset
                // would replace the saved format and reset the selected zoom.
                if self.session.canSetSessionPreset(.inputPriority) { self.session.sessionPreset = .inputPriority }
                // InputPriority 会保留照片 activeFormat；若直接加录制输出，3264×2448
                // 等照片格式可能不支持视频输出，AVFoundation 以 -11800 失败并进入恢复循环。
                // 先应用一个安全的视频格式，随后 setVideoSettings 再覆盖为目标规格。
                self.applyInitialVideoFormatIfNeeded()
                self.addRecordingOutputs()
            } else {
                self.removeRecordingOutputs()
                if #available(iOS 26.0, *) {
                    _ = self.configureCinematicVideoOutputGraph(enabled: false, reuseRecordingOutputForPreview: false)
                }
                // Drop 10-bit/Log constraints before selecting a still-photo preset.
                self.videoOutput.videoSettings = [:]
                self.configuredPreviewRoute = ""
                if let original = self.videoWideColorBeforeVideo {
                    self.session.automaticallyConfiguresCaptureDeviceForWideColor = original
                    self.videoWideColorBeforeVideo = nil
                }
                if wasCinematic, let previous = self.input,
                   let lens = self.lensCatalog.first(where: { $0.id == (self.manualZoomAnchorID ?? self.selectedLens) }) {
                    let photoDevice = self.captureDevice(for: lens)
                    if photoDevice.uniqueID != previous.device.uniqueID {
                        do {
                            let restored = try self.reusableInput(for: photoDevice)
                            self.session.removeInput(previous)
                            if self.session.canAddInput(restored) {
                                self.session.addInput(restored)
                                self.input = restored
                                changedPhotoInput = true
                            } else {
                                self.session.addInput(previous)
                                throw CameraError.unavailable
                            }
                        } catch {
                            self.report("恢复照片镜头失败：\(error.localizedDescription)")
                        }
                    }
                }
            }
            if !enabled, self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
            if #available(iOS 26.0, *), !enabled, !self.manualMode, !self.highResolutionPhotoRequested,
               let current = self.input, current.device.deviceType == .builtInDualWideCamera,
               let rear = self.rearVirtualDevice, rear.uniqueID != current.device.uniqueID {
                // 电影使用 DualWide；返回照片的非手动/非高像素路线必须回到普通虚拟多摄。
                do {
                    let replacement = try self.reusableInput(for: rear)
                    self.session.removeInput(current)
                    if self.session.canAddInput(replacement) {
                        self.session.addInput(replacement)
                        self.input = replacement
                        changedPhotoInput = true
                    } else {
                        self.session.addInput(current)
                    }
                } catch {
                    self.report("恢复普通后置输入失败：\(error.localizedDescription)")
                }
            }
            // Nested configuration helpers participate in this transaction. Committing
            // each output/input/preview change separately restarts the graph repeatedly.
            self.reconcileLiveAudio()
            if let device = self.input?.device {
                if !enabled {
                    if device.position == .front {
                        self.frontPhotoZoomAfterVideo = self.photoDeviceConfigurationsBeforeVideo[device.uniqueID]?.zoomFactor
                    }
                    // 前置视频的 wide 是视频专用取景，不能当作照片倍率保留；恢复进入前照片配置。
                    let preserveZoom = device.position == .front ? nil
                        : (changedPhotoInput ? nil : zoomBeforeTransition)
                    self.restorePhotoDeviceConfigurationsAfterVideo(preservingActiveZoom: preserveZoom)
                }
                if enabled {
                    // setVideoMode 已持有最外层事务；configureConnections 默认还会
                    // 再开一层，视频入口反复切换时会间歇触发 -11819。
                    self.configureVideoFormat(device)
                    self.configureConnections(device: device, configuresVideoFormat: false)
                } else {
                    self.configureConnections(device: device)
                }
                if !enabled { self.configurePhotoOutput(device) }
                if !enabled {
                    // Video formats can leave a frame-rate exposure ceiling on the
                    // device. Clear it even when M mode itself did not change; the
                    // photo route must also release the fixed video frame cadence so
                    // the next manual still exposure can use its requested duration.
                    do {
                        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                        device.activeVideoMinFrameDuration = .invalid
                        device.activeVideoMaxFrameDuration = .invalid
                        self.restoreDefaultAutoExposureLimit(device)
                    } catch {
                        self.report("恢复照片曝光范围失败：\(error.localizedDescription)")
                    }
                }
                if enabled, let zoom = zoomBeforeTransition {
                    do {
                        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                        let frontWide = device.position == .front
                            ? self.lensCatalog.first { $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide }?.zoomFactor
                            : nil
                        let target = min(max(frontWide ?? zoom,
                            device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                        if abs(device.videoZoomFactor - target) > 0.001 { device.videoZoomFactor = target }
                    } catch { self.report("恢复视频倍率失败：\(error.localizedDescription)") }
                }
            }
            self.session.commitConfiguration()
            if enabled { self.applyVideoStandbyConnections() }
            if !enabled {
                DispatchQueue.main.async {
                    guard self.videoModeRevision.matches(revision) else { return }
                    self.cinematicVideoCaptureActive = false
                }
            }
            // 视频规格会把 UI 快门范围限制到帧周期；切回照片后在新路由提交完成后重发能力，
            // 让刻度和参数范围立即使用当前照片格式的真实设备范围。
            if let device = self.input?.device {
                self.publishCapabilities(device, lensID: self.manualZoomAnchorID ?? self.selectedLens)
            }
            // Automatic audio configuration may replace this permission when
            // committing a new graph. Apply it after the outermost commit too.
            self.configureRecordingHaptics()
        }
    }

    func setVideoSettings(_ settings: VideoCaptureSettings, openGate: Bool = false,
                          cinematicVideo: Bool = false, preferredLensID: String? = nil, dualRatio: FrameRatio? = nil) {
        guard !videoBusy else { return }
        let revision = videoSettingsRevision.advance()
        videoConfiguring = true
        queue.async {
            // 必须在 revision 守卫之前安装清理；旧请求被新请求取代时直接 return
            // 曾把 videoConfiguring 永久留在 true，导致无法切回照片/HDR。
            defer {
                DispatchQueue.main.async {
                    if self.videoSettingsRevision.matches(revision) { self.videoConfiguring = false }
                }
            }
            guard self.videoSettingsRevision.matches(revision) else { return }
            self.stopFocusNavigatorOnQueue()
            if self.dualCaptureSource != nil {
                let aspect = dualRatio ?? self.dualCaptureRatio
                DispatchQueue.main.async { self.applyDualCaptureSettings(settings, ratio: aspect, revision: revision) }
                return
            }
            self.requestedVideoRatio = dualRatio ?? .wide
            var request = settings
            if !request.hardwareEncoderAvailable { request.codec = .hevc; request.proRes = .hq }
            if request.isRAW && !ExternalVideoStorage.shared.isEligibleNow { request.codec = .hevc; request.proRes = .hq }
            self.requestedVideoSettings = request
            self.requestedCinematicVideo = cinematicVideo && !request.isRAW && !openGate
            self.requestedVideoOpenGate = openGate && !request.isRAW && !cinematicVideo
            guard self.videoModeRequested, self.configured, let device = self.input?.device else { return }
            // 子模式在切换规格时可指定最终焦段锚点；先设置 requestedCinematicVideo，
            // 再按目标镜头解析输入设备，避免先经过普通镜头、随后再次重建电影输入。
            let routeLens = preferredLensID.flatMap { id in self.lensCatalog.first(where: { $0.id == id }) }
                ?? self.lensCatalog.first(where: { $0.id == self.selectedLens })
            if let lens = routeLens,
               self.captureDevice(for: lens).uniqueID != device.uniqueID || self.selectedLens != lens.id {
                self.selectLensOnQueue(lens, previousID: lens.id, revision: self.zoomRevision.advance())
                return
            }
            // 规格提交必须只有一个事务：configureConnections 默认会再开一层，
            // 前置4:3/16:9切换时嵌套事务会让 activeFormat 回退并触发 -11819。
            self.session.beginConfiguration()
            self.configureVideoFormat(device)
            self.configureConnections(device: device, configuresVideoFormat: false)
            self.session.commitConfiguration()
            self.publishCapabilities(device, lensID: self.selectedLens)
        }
    }

    /// 在相机串行队列上寻找支持目标子模式的镜头；格式枚举只为每个物理设备做一次。
    func compatibleVideoSubmodeRoutes(for mode: VideoSubmode, position: AVCaptureDevice.Position,
                                      openGateEnabled: Bool,
                                      completion: @escaping ([VideoSubmodeCaptureRoute]) -> Void) {
        queue.async {
            var routes: [VideoSubmodeCaptureRoute] = []
            for lens in self.lensCatalog where lens.device.position == position {
                // 慢动作使用物理镜头高帧率格式；电影按系统公开能力选择后置双摄或前置电影设备。
                // 普通延时仍检查当前实际路由，避免把未接入的设备规格显示为可用。
                let routeDevice: AVCaptureDevice
                switch mode {
                case .slowMotion:
                    routeDevice = lens.device
                case .cinematic:
                    routeDevice = self.cinematicCaptureDevice(for: position) ?? lens.device
                case .timeLapse:
                    routeDevice = self.captureDevice(for: lens)
                }
                let deviceID = routeDevice.uniqueID
                let capabilities: VideoLensCaptureCapabilities
                if let cached = self.videoLensCapabilityCache[deviceID] {
                    capabilities = cached
                } else {
                    let ordinary = VideoCaptureSettings.supported(by: routeDevice)
                    let slowMotionCaptureRates = VideoCaptureSettings.slowMotionCaptureRates(by: routeDevice)
                    let openGate = VideoCaptureSettings.openGateSupported(by: routeDevice)
                    let cinematic: [VideoCaptureSettings]
                    // 格式属性是设备公开的静态能力；input 的支持状态要等它加入实际 session 后才有意义。
                    if #available(iOS 26.0, *) {
                        cinematic = VideoCaptureSettings.cinematicVideoSupported(by: routeDevice)
                    } else {
                        cinematic = []
                    }
                    capabilities = VideoLensCaptureCapabilities(ordinary: ordinary,
                                                                 slowMotionCaptureRates: slowMotionCaptureRates,
                                                                 openGate: openGate,
                                                                 cinematic: cinematic)
                    self.videoLensCapabilityCache[deviceID] = capabilities
                }
                var settings = capabilities.settings(for: mode, openGateEnabled: openGateEnabled)
                if #available(iOS 26.0, *), mode == .cinematic {
                    // 后置同样按电影专用倍率范围过滤，不能把共同设备规格映射到所有原生镜头。
                    settings = settings.filter { value in
                        guard let format = VideoCaptureSettings.format(for: value, device: routeDevice,
                            requiringCinematicVideo: true) else { return false }
                        let factor = routeDevice.isVirtualDevice ? lens.displayZoom/CameraLensCatalog.displayMultiplier(routeDevice) : lens.zoomFactor
                        return factor >= format.videoMinZoomFactorForCinematicVideo - 0.001
                            && factor <= format.videoMaxZoomFactorForCinematicVideo + 0.001
                    }
                }
                if !settings.isEmpty { routes.append(VideoSubmodeCaptureRoute(lensID: lens.id, settings: settings)) }
            }
            DispatchQueue.main.async { completion(routes) }
        }
    }

    /// 一次性扫描静态格式，之后界面只读取按逻辑焦段发布的兼容矩阵。
    private func publishVideoSelectionCapabilities() {
        guard !lensCatalog.isEmpty else { return }
        func capabilities(_ device:AVCaptureDevice)->VideoLensCaptureCapabilities {
            if let cached = videoSelectionDeviceCache[device.uniqueID] { return cached }
            let ordinary = VideoCaptureSettings.supported(by:device)
            let slow = VideoCaptureSettings.slowMotionCaptureRates(by:device)
            let open = VideoCaptureSettings.openGateSupported(by:device)
            let cine = VideoCaptureSettings.cinematicVideoSupported(by:device)
            let raw = VideoFrameRate.allCases.compactMap { rate -> VideoCaptureSettings? in
                let value = VideoCaptureSettings(resolution:.uhd4K,frameRate:rate,codec:.proRes,proRes:.raw)
                return VideoCaptureSettings.format(for:value,device:device) == nil ? nil : VideoCaptureSettings(resolution:.uhd4K,frameRate:rate)
            }
            let center = ordinary.filter { VideoCaptureSettings.format(for:$0,device:device,requiringCenterStage:true) != nil }
            let value = VideoLensCaptureCapabilities(ordinary:ordinary,slowMotionCaptureRates:slow,openGate:open,cinematic:cine,raw:raw,centerStage:center)
            videoSelectionDeviceCache[device.uniqueID] = value
            return value
        }
        var rows = [String:VideoLensCaptureCapabilities]()
        if let device = rearVirtualDevice { _ = capabilities(device) }
        for lens in lensCatalog {
            let base = capabilities(lens.device)
            var cine = [VideoCaptureSettings]()
            if #available(iOS 26.0, *), let device = cinematicCaptureDevice(for:lens.device.position) {
                let factor = device.isVirtualDevice ? lens.displayZoom/CameraLensCatalog.displayMultiplier(device) : lens.zoomFactor
                cine = capabilities(device).cinematic.filter { value in
                    guard let format = VideoCaptureSettings.format(for:value,device:device,requiringCinematicVideo:true) else { return false }
                    return factor >= format.videoMinZoomFactorForCinematicVideo-0.001 && factor <= format.videoMaxZoomFactorForCinematicVideo+0.001
                }
            }
            rows[lens.id] = .init(ordinary:base.ordinary,slowMotionCaptureRates:base.slowMotionCaptureRates,
                openGate:base.openGate,cinematic:cine,raw:base.raw,centerStage:base.centerStage)
        }
        DispatchQueue.main.async { if self.videoSelectionCapabilities != rows { self.videoSelectionCapabilities = rows } }
    }

    private func rememberPhotoDeviceConfiguration(_ device: AVCaptureDevice) {
        if photoDeviceConfigurationsBeforeVideo[device.uniqueID] == nil {
            var format = device.activeFormat
            // 先在视频中切到前置时，设备可能仍以1080p视频格式初始化。
            // 这不是可恢复的照片基线；按官方动态画幅能力保留真正的前置照片格式。
            if #available(iOS 26.0, *), device.position == .front,
               !(format.supportedDynamicAspectRatios.contains(.ratio3x4)
                    && format.supportedDynamicAspectRatios.contains(.ratio4x3)) {
                let candidates = device.formats.filter {
                    $0.supportedDynamicAspectRatios.contains(.ratio3x4)
                        && $0.supportedDynamicAspectRatios.contains(.ratio4x3)
                        && !$0.supportedMaxPhotoDimensions.isEmpty
                }.sorted {
                    if $0.isHighestPhotoQualitySupported != $1.isHighestPhotoQualitySupported { return $0.isHighestPhotoQualitySupported }
                    let lhs = $0.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                    let rhs = $1.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                    return lhs > rhs
                }
                if let photo = candidates.first { format = photo }
            }
            let changed = format != device.activeFormat
            photoDeviceConfigurationsBeforeVideo[device.uniqueID] = PhotoDeviceConfiguration(
                device: device, format: format,
                colorSpace: format.supportedColorSpaces.contains(device.activeColorSpace) ? device.activeColorSpace : .sRGB,
                minFrameDuration: changed ? .invalid : device.activeVideoMinFrameDuration,
                maxFrameDuration: changed ? .invalid : device.activeVideoMaxFrameDuration,
                zoomFactor: device.videoZoomFactor
            )
        }
    }

    /// 进入视频但目标 setVideoSettings 尚未到达时的安全格式，避免用照片格式挂录制输出。
    private func applyInitialVideoFormatIfNeeded() {
        guard let device = input?.device,
              let format = VideoCaptureSettings.format(
                for: VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30,
                                          colorSpace: .sdr, codec: .hevc),
                device: device) else { return }
        if device.activeFormat != format {
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } catch {
                report("初始化视频格式失败：\(error.localizedDescription)")
                return
            }
            configuredPreviewRoute = ""
        }
    }

    /// WWDC25 Cinematic 要求先使用 DualWide/TrueDepth 设备及其电影格式，再启用电影输入。
    /// 视频普通格式往往在 TripleCamera 上；这里在开启电影子模式前直接换到电影设备。
    func prepareCinematicInput(completion: @escaping (Bool) -> Void) {
        queue.async {
            guard #available(iOS 26.0, *), self.videoModeRequested,
                  let current = self.input,
                  let target = self.cinematicCaptureDevice(for: current.device.position) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            if current.device.uniqueID == target.uniqueID {
                DispatchQueue.main.async { completion(true) }; return
            }
            let supported = VideoCaptureSettings.cinematicVideoSupported(by: target)
            let preferred = supported.first {
                $0.resolution == .hd1080 && $0.frameRate == .fps30 && $0.colorSpace == .sdr
            } ?? supported.first
            guard let preferred,
                  let format = VideoCaptureSettings.format(for: preferred, device: target,
                                                           requiringCinematicVideo: true) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            self.session.beginConfiguration()
            do {
                let replacement = try self.reusableInput(for: target)
                self.session.removeInput(current)
                guard self.session.canAddInput(replacement) else {
                    self.session.addInput(current); self.session.commitConfiguration()
                    DispatchQueue.main.async { completion(false) }; return
                }
                self.session.addInput(replacement)
                self.input = replacement
                try self.prepareAutomaticRoute(target, factor: 1)
                try target.lockForConfiguration()
                target.activeFormat = format
                let duration = CMTime(value: 1, timescale: 30)
                target.activeVideoMinFrameDuration = duration
                target.activeVideoMaxFrameDuration = duration
                target.unlockForConfiguration()
                self.configureConnections(device: target)
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.session.addInput(current)
                self.session.commitConfiguration()
                self.report("切换电影设备失败：\(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Called on the session queue, inside the connection configuration transaction.
    /// 冷启动/回前台恢复视频前置时，格式可能没有重新配置；在 start 完成后补一次设备倍率。
    private func applyFrontVideoWideFramingOnQueue(_ device: AVCaptureDevice) {
        guard videoModeRequested, videoModeDesired, device.position == .front,
              let wide = lensCatalog.first(where: {
                  $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide
              }) else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            let target = min(max(wide.zoomFactor, device.minAvailableVideoZoomFactor),
                             device.maxAvailableVideoZoomFactor)
            if abs(device.videoZoomFactor - target) > 0.001 { device.videoZoomFactor = target }
        } catch { report("前置视频广角取景失败：\(error.localizedDescription)") }
    }

    private func configureVideoFormat(_ device: AVCaptureDevice) {
        let openGateRequested = requestedVideoOpenGate
        let cinematicRequested = requestedCinematicVideo && !openGateRequested
        let centerStageRequested = frontVideoCenteringRequested && device.position == .front && !openGateRequested && !cinematicRequested
        rememberPhotoDeviceConfiguration(device)
        if videoFormatCatalog[device.uniqueID] == nil {
            var catalog: [VideoCaptureSettings: AVCaptureDevice.Format] = [:]
            var openGateCatalog: [VideoCaptureSettings: AVCaptureDevice.Format] = [:]
            var cinematicCatalog: [VideoCaptureSettings: AVCaptureDevice.Format] = [:]
            var centerStageCatalog: [VideoCaptureSettings: AVCaptureDevice.Format] = [:]
            var slowMotionCaptureRates: [VideoCaptureSettings] = []
            for color in VideoColorSpace.allCases {
                for resolution in VideoResolution.allCases {
                    for rate in VideoFrameRate.allCases {
                        let settings = VideoCaptureSettings(resolution: resolution, frameRate: rate, colorSpace: color)
                        if let format = VideoCaptureSettings.format(for: settings, device: device) { catalog[settings] = format }
                        if device.position == .front,
                           let format = VideoCaptureSettings.format(for: settings, device: device, requiringCenterStage: true) { centerStageCatalog[settings] = format }
                        if let format = VideoCaptureSettings.format(for: settings, device: device, requiringOpenGate: true) {
                            openGateCatalog[settings] = format
                        }
                        if CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: true,
                               codec: settings.codec, isRAW: settings.isRAW, openGate: false,
                               timeLapse: false, slowMotion: false),
                           let format = VideoCaptureSettings.format(for: settings, device: device, requiringCinematicVideo: true) {
                            cinematicCatalog[settings] = format
                        }
                    }
                }
            }
            slowMotionCaptureRates = VideoCaptureSettings.slowMotionCaptureRates(by: device)
            videoFormatCatalog[device.uniqueID] = catalog
            openGateVideoFormatCatalog[device.uniqueID] = openGateCatalog
            cinematicVideoFormatCatalog[device.uniqueID] = cinematicCatalog
            centerStageVideoFormatCatalog[device.uniqueID] = centerStageCatalog
            slowMotionCaptureFormatCatalog[device.uniqueID] = slowMotionCaptureRates
        }
        let catalog = videoFormatCatalog[device.uniqueID] ?? [:]
        let openGateCatalog = openGateVideoFormatCatalog[device.uniqueID] ?? [:]
        let cinematicCatalog = cinematicVideoFormatCatalog[device.uniqueID] ?? [:]
        let centerStageCatalog = centerStageVideoFormatCatalog[device.uniqueID] ?? [:]
        let centerStageSupported = centerStageCatalog.keys.sorted {
            if $0.resolution != $1.resolution { return $0.resolution.dimensions.width < $1.resolution.dimensions.width }
            return $0.frameRate.rawValue < $1.frameRate.rawValue
        }
        DispatchQueue.main.async {
            self.frontVideoCenteringAvailable = device.position == .front && !centerStageSupported.isEmpty
            if self.frontVideoCenteringSettings != centerStageSupported { self.frontVideoCenteringSettings = centerStageSupported }
        }
        let rawDevice = device.isVirtualDevice ? (lensCatalog.first(where: { $0.id == selectedLens })?.device ?? device) : device
        let rawCapabilities = VideoFrameRate.allCases.compactMap { rate -> VideoCaptureSettings? in
            let raw = VideoCaptureSettings(resolution: .uhd4K, frameRate: rate, codec: .proRes, proRes: .raw)
            return VideoCaptureSettings.format(for: raw, device: rawDevice) == nil ? nil : VideoCaptureSettings(resolution: .uhd4K, frameRate: rate)
        }
        DispatchQueue.main.async { if self.rawVideoSettings != rawCapabilities { self.rawVideoSettings = rawCapabilities } }
        let supported = VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.map { VideoCaptureSettings(resolution: resolution, frameRate: $0, colorSpace: color) }.filter { catalog[$0] != nil }
            }
        }
        let slowMotionSupported = VideoSubmodeSettingsPolicy.slowMotionPlaybackSettings(
            from: supported, captureRates: slowMotionCaptureFormatCatalog[device.uniqueID] ?? [])
        let slowMotionCaptureSupported = slowMotionCaptureFormatCatalog[device.uniqueID] ?? []
        let openGateSupported = VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.map { VideoCaptureSettings(resolution: resolution, frameRate: $0, colorSpace: color) }
                    .filter { openGateCatalog[$0] != nil }
            }
        }
        let cinematicSupported = VideoColorSpace.allCases.flatMap { color in
            VideoResolution.allCases.flatMap { resolution in
                VideoFrameRate.allCases.map { VideoCaptureSettings(resolution: resolution, frameRate: $0, colorSpace: color) }
                    .filter { cinematicCatalog[$0] != nil }
            }
        }
        DispatchQueue.main.async {
            if self.slowMotionVideoSettings != slowMotionSupported { self.slowMotionVideoSettings = slowMotionSupported }
            if self.slowMotionCaptureFormats != slowMotionCaptureSupported { self.slowMotionCaptureFormats = slowMotionCaptureSupported }
            if self.openGateVideoSettings != openGateSupported { self.openGateVideoSettings = openGateSupported }
            if self.cinematicVideoSettings != cinematicSupported { self.cinematicVideoSettings = cinematicSupported }
        }
        var request = requestedVideoSettings
        if request.isRAW && !ExternalVideoStorage.shared.isEligibleNow { request.codec = .hevc; request.proRes = .hq }
        let requestedCaptureFrameRate = cinematicRequested ? nil : request.captureFrameRate
        request.captureFrameRate = nil
        let activeSupported = centerStageRequested ? centerStageSupported : openGateRequested ? openGateSupported : cinematicRequested ? cinematicSupported : supported
        let activeCatalog = centerStageRequested ? centerStageCatalog : openGateRequested ? openGateCatalog : cinematicRequested ? cinematicCatalog : catalog
        guard var settings = VideoCaptureSettings.resolved(request, supported: activeSupported) else { return }
        // 先按文件播放帧率解析输出规格，再独立核对高帧率采集格式。
        if let requestedCaptureFrameRate,
           requestedCaptureFrameRate.rawValue > settings.frameRate.rawValue {
            settings.captureFrameRate = requestedCaptureFrameRate
        }
        // High-rate 4:2:2 capture can exceed the two-output graph's bandwidth.
        // Keep the lighter device format at >60 fps and encode to ProRes once.
        var chosenFormat: AVCaptureDevice.Format?
        if settings.captureFrameRate != nil {
            chosenFormat = VideoCaptureSettings.format(for: settings, device: device,
                requiringOpenGate: openGateRequested, requiringCinematicVideo: cinematicRequested,
                requiringCenterStage: centerStageRequested,
                ratio: (!openGateRequested && !cinematicRequested && !centerStageRequested) ? requestedVideoRatio : nil)
            if chosenFormat == nil { settings.captureFrameRate = nil }
        }
        if chosenFormat == nil {
            chosenFormat = settings.isRAW || (settings.codec == .proRes && settings.frameRate.rawValue <= 60)
                ? VideoCaptureSettings.format(for: settings, device: device,
                    requiringOpenGate: openGateRequested, requiringCinematicVideo: cinematicRequested,
                    requiringCenterStage: centerStageRequested,
                    ratio: (!openGateRequested && !cinematicRequested && !centerStageRequested) ? requestedVideoRatio : nil)
                : VideoCaptureSettings.format(for: settings, device: device,
                    requiringOpenGate: openGateRequested, requiringCinematicVideo: cinematicRequested,
                    requiringCenterStage: centerStageRequested,
                    ratio: (!openGateRequested && !cinematicRequested && !centerStageRequested) ? requestedVideoRatio : nil)
                    ?? activeCatalog[settings.baseSettings]
        }
        if settings.isRAW && chosenFormat == nil {
            settings.codec = .hevc; settings.proRes = .hq
            chosenFormat = activeCatalog[settings.baseSettings]
        }
        guard let format = chosenFormat, let requestedColor = settings.colorSpace.captureColorSpace,
              let color = settings.isRAW ? format.supportedColorSpaces.first : requestedColor else {
            DispatchQueue.main.async { self.supportedVideoSettings = [] }
            return
        }
        let didFallback = requestedVideoSettings != settings
        do {
            if videoWideColorBeforeVideo == nil { videoWideColorBeforeVideo = session.automaticallyConfiguresCaptureDeviceForWideColor }
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            if photoColorBeforeVideo[device.uniqueID] == nil { photoColorBeforeVideo[device.uniqueID] = device.activeColorSpace }
            if device.activeFormat != format || device.activeColorSpace != color {
                videoOutput.videoSettings = [:]
                recordingOutput.videoSettings = [:]
                configuredPreviewRoute = ""
            }
            let zoom = device.videoZoomFactor
            let captureRate = settings.captureFrameRate ?? settings.frameRate
            let duration = CMTime(value: 1, timescale: Int32(captureRate.rawValue))
            let cinematicFormatChanges = device.activeFormat != format || device.activeColorSpace != color
                || device.activeVideoMinFrameDuration != duration || device.activeVideoMaxFrameDuration != duration
            if centerStageRequested {
                // 官方规定开启深度输出会停用Center Stage；视频不使用照片蒙版管线。
                if photoOutput.isDepthDataDeliveryEnabled { photoOutput.isDepthDataDeliveryEnabled = false }
                if photoOutput.isPortraitEffectsMatteDeliveryEnabled { photoOutput.isPortraitEffectsMatteDeliveryEnabled = false }
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if #available(iOS 26.0, *), let input, input.activeLockedVideoFrameDuration.isValid,
               CMTimeCompare(input.activeLockedVideoFrameDuration, duration) != 0 || cinematicFormatChanges || cinematicRequested {
                // 官方不允许锁帧期间直接改设备帧周期；换规格先释放旧锁，再设置新锁。
                input.activeLockedVideoFrameDuration = .invalid
            }
            // Apple 说明电影开关会重建耗时的渲染管线；只在退出或实际更换格式时关闭，
            // 同一输入、格式和帧率的重复同步保留已就绪的电影输出图。
            if #available(iOS 26.0, *), let input, input.isCinematicVideoCaptureEnabled,
               !cinematicRequested || cinematicFormatChanges {
                input.isCinematicVideoCaptureEnabled = false
            }
            if AVCaptureDevice.isCenterStageEnabled && (!centerStageRequested || device.activeFormat != format) {
                AVCaptureDevice.isCenterStageEnabled = false
            }
            if device.activeFormat != format { device.activeFormat = format }
            // 固定规格录制不能由自动降帧接管；先关闭它，再检查官方锁帧能力。
            if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
            if centerStageRequested && device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = true }
            if device.activeColorSpace != color { device.activeColorSpace = color }
            // 同一 activeFormat 内升帧率也要更新输入资源预算；仅改设备属性时，
            // 本机可能继续交付上一档节奏（25→30、50→60）。此官方属性在事务内生效。
            if let input, input.videoMinFrameDurationOverride != duration {
                input.videoMinFrameDurationOverride = duration
            }
            // 先解除上一档输入上限，再写设备帧周期；反过来会被旧 override 钳制一档。
            if device.activeVideoMinFrameDuration != duration { device.activeVideoMinFrameDuration = duration }
            if device.activeVideoMaxFrameDuration != duration { device.activeVideoMaxFrameDuration = duration }
            if #available(iOS 26.0, *), !cinematicRequested, let input, input.isLockedVideoFrameDurationSupported {
                let minimum = device.minSupportedLockedVideoFrameDuration
                if minimum.isValid, CMTimeCompare(duration, minimum) >= 0,
                   CMTimeCompare(input.activeLockedVideoFrameDuration, duration) != 0 {
                    input.activeLockedVideoFrameDuration = duration
                }
            }
            // 视频前置固定超广角在格式事务内应用，不修改 selectedLens；
            // 退出视频时再恢复进入前的照片倍率，避免视频入口后的二次呼吸和照片取景被改写。
            let frontVideoWideZoom = device.position == .front
                ? self.lensCatalog.first { $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide }?.zoomFactor
                : nil
            let restoredZoom = min(max(frontVideoWideZoom ?? zoom, device.minAvailableVideoZoomFactor),
                                   device.maxAvailableVideoZoomFactor)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let size: CGSize
            // Use the actual source format dimensions. For Open Gate this is the
            // largest native 4:3/1:1 readout; never ask the output to upscale it.
            size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            let preferredPixels: [OSType] = settings.isRAW ? [kCVPixelFormatType_96VersatileBayerPacked12] : settings.codec == .proRes ? [
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA
            ] : [settings.colorSpace.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            guard let pixel = preferredPixels.first(where: { recordingOutput.availableVideoPixelFormatTypes.contains($0) }) else {
                throw MovieRecorder.RecorderError.cannotStart("当前镜头不支持所选编码的采集格式。")
            }
            var outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixel,
                AVVideoAllowWideColorKey: NSNumber(value: settings.colorSpace != .sdr)
            ]
            // Dynamic front sensors reject explicit output-buffer dimensions.
            // Keep their native buffers and scale/crop once in the encoder.
            if !settings.isRAW && (device.position != .front || device.deviceType != .builtInUltraWideCamera) {
                outputSettings[kCVPixelBufferWidthKey as String] = Int(size.width)
                outputSettings[kCVPixelBufferHeightKey as String] = Int(size.height)
            }
            let safeOutputSettings = safeVideoOutputSettings(outputSettings, device: device)
            if !NSDictionary(dictionary: recordingOutput.videoSettings ?? [:]).isEqual(to: safeOutputSettings) {
                recordingOutput.videoSettings = safeOutputSettings
            }
            if #available(iOS 26.0, *) {
                // HDR 元数据需随采集缓冲保留给 AVAssetWriter；没有动态元数据时，成片仍是 HLG。
                let preservesDynamicHDRMetadata = settings.colorSpace == .hdr
                if recordingOutput.preservesDynamicHDRMetadata != preservesDynamicHDRMetadata {
                    recordingOutput.preservesDynamicHDRMetadata = preservesDynamicHDRMetadata
                }
            }
            if #available(iOS 26.0, *), let input {
                let formatSupportsCinematic = cinematicRequested
                    && input.isCinematicVideoCaptureSupported
                    && format.isCinematicVideoCaptureSupported
                let reuseRecordingOutputForPreview = formatSupportsCinematic || captureRate.rawValue > 60
                // Apple 的 Cinematic 示例先启用输入，再把输出加入会话。重排图时先
                // 设置最终采集像素格式，避免输出已连接后再次改写视频缓冲配置。
                let graphSupportsCinematic = configureCinematicVideoOutputGraph(
                    enabled: formatSupportsCinematic,
                    reuseRecordingOutputForPreview: reuseRecordingOutputForPreview)
                let enableCinematic = formatSupportsCinematic && graphSupportsCinematic
                if enableCinematic {
                    input.simulatedAperture = format.defaultSimulatedAperture
                } else if cinematicRequested {
                    report("当前相机输出组合无法启用电影模式。")
                }
                let active = input.isCinematicVideoCaptureEnabled
                DispatchQueue.main.async {
                    if self.cinematicVideoCaptureActive != active { self.cinematicVideoCaptureActive = active }
                }
            } else if captureRate.rawValue > 60 {
                _ = configurePreviewOutputGraph(useRecordingOutput: true)
            } else {
                _ = configurePreviewOutputGraph(useRecordingOutput: false)
            }
            if abs(device.videoZoomFactor - restoredZoom) > 0.001 { device.videoZoomFactor = restoredZoom }
            restoreManualExposureAfterZoom(device)
            refreshFrontVideoCentering(device, deviceLocked: true)
            requestedVideoSettings = settings
            DispatchQueue.main.async {
                if self.supportedVideoSettings != supported { self.supportedVideoSettings = supported }
                if self.videoSettings != settings || didFallback { self.videoSettings = settings }
                let portraitAspect = CGFloat(min(dimensions.width, dimensions.height)) / CGFloat(max(dimensions.width, dimensions.height))
                if openGateRequested { self.openGatePortraitRatio = portraitAspect }
            }
        } catch { report("视频规格配置失败：\(error.localizedDescription)") }
    }

    /// 按 Apple Cinematic Video 要求设置元数据类型，并以录制帧复用预览，控制会话负载。
    /// 调用方位于相机串行队列和 AVCaptureSession 配置事务中。
    @available(iOS 26.0, *)
    private func configureCinematicVideoOutputGraph(enabled: Bool,
                                                     reuseRecordingOutputForPreview: Bool) -> Bool {
        guard let input else {
            return configurePreviewOutputGraph(useRecordingOutput: reuseRecordingOutputForPreview)
        }
        if enabled {
            guard input.isCinematicVideoCaptureSupported,
                  input.device.activeFormat.isCinematicVideoCaptureSupported else {
                #if DEBUG
                print("CINEMATIC-GRAPH unavailable input=\(input.isCinematicVideoCaptureSupported) format=\(input.device.activeFormat.isCinematicVideoCaptureSupported)")
                #endif
                return false
            }
            let graphIsReady = input.isCinematicVideoCaptureEnabled
                && session.outputs.contains(cinematicMetadataOutput)
                && session.outputs.contains(photoOutput)
                && session.outputs.contains(recordingOutput)
                && !session.outputs.contains(videoOutput)
            if !graphIsReady {
                #if DEBUG
                cinematicGraphRebuildCountForTesting += 1
                #endif
                // Apple Cinematic 示例先启用输入、再将输出挂入会话。
                // 普通视频图先在同一事务中拆除，避免在已连接输出上切换 Cinematic。
                for output in [videoOutput as AVCaptureOutput, recordingOutput as AVCaptureOutput,
                               audioOutput as AVCaptureOutput, photoOutput as AVCaptureOutput,
                               cinematicMetadataOutput as AVCaptureOutput]
                where session.outputs.contains(output) {
                    session.removeOutput(output)
                }
                cinematicMetadataOutput.metadataObjectTypes = []
                input.isCinematicVideoCaptureEnabled = true
                input.simulatedAperture = input.device.activeFormat.defaultSimulatedAperture

                guard session.canAddOutput(cinematicMetadataOutput) else {
                    restoreStandardVideoOutputGraph(reuseRecordingOutputForPreview: false)
                    return false
                }
                session.addOutput(cinematicMetadataOutput)
                // 官方 Cinematic 会话需要 metadata delegate；缺失时电影图可能不开始送帧。
                cinematicMetadataOutput.setMetadataObjectsDelegate(self, queue: queue)
                let requiredTypes = cinematicMetadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture
                guard !requiredTypes.isEmpty,
                      requiredTypes.allSatisfy(cinematicMetadataOutput.availableMetadataObjectTypes.contains) else {
                    restoreStandardVideoOutputGraph(reuseRecordingOutputForPreview: false)
                    return false
                }
                cinematicMetadataOutput.metadataObjectTypes = requiredTypes
                guard session.canAddOutput(photoOutput), session.canAddOutput(recordingOutput) else {
                    restoreStandardVideoOutputGraph(reuseRecordingOutputForPreview: false)
                    return false
                }
                session.addOutput(photoOutput)
                addRecordingOutputs()
                // 电影管线首帧后编码可能变慢；默认丢迟到帧会让录制输出只剩一帧。
                recordingOutput.alwaysDiscardsLateVideoFrames = false
                guard session.outputs.contains(recordingOutput),
                      configurePreviewOutputGraph(useRecordingOutput: true) else {
                    restoreStandardVideoOutputGraph(reuseRecordingOutputForPreview: false)
                    return false
                }
            } else {
                let requiredTypes = cinematicMetadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture
                guard !requiredTypes.isEmpty,
                      requiredTypes.allSatisfy(cinematicMetadataOutput.availableMetadataObjectTypes.contains) else {
                    return false
                }
                cinematicMetadataOutput.metadataObjectTypes = requiredTypes
                livePreviewState.update { $0.previewFromRecordingOutput = reuseRecordingOutputForPreview }
            }
            return true
        }

        if input.isCinematicVideoCaptureEnabled { input.isCinematicVideoCaptureEnabled = false }
        if session.outputs.contains(cinematicMetadataOutput) {
            cinematicMetadataOutput.metadataObjectTypes = []
            session.removeOutput(cinematicMetadataOutput)
        }
        if videoModeRequested {
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            addRecordingOutputs()
        }
        return configurePreviewOutputGraph(useRecordingOutput: reuseRecordingOutputForPreview)
    }

    /// 电影图重建失败时恢复普通输出，避免相机会话停留在半配置状态。
    private func restoreStandardVideoOutputGraph(reuseRecordingOutputForPreview: Bool) {
        if #available(iOS 26.0, *), let input, input.isCinematicVideoCaptureEnabled {
            input.isCinematicVideoCaptureEnabled = false
        }
        cinematicMetadataOutput.metadataObjectTypes = []
        if session.outputs.contains(cinematicMetadataOutput) { session.removeOutput(cinematicMetadataOutput) }
        if videoModeRequested {
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            addRecordingOutputs()
        }
        _ = configurePreviewOutputGraph(useRecordingOutput: reuseRecordingOutputForPreview)
    }

    /// 电影和高帧率慢动作共用录制帧预览，避免双路帧输出争用硬件带宽。
    private func configurePreviewOutputGraph(useRecordingOutput: Bool) -> Bool {
        if useRecordingOutput {
            guard session.outputs.contains(recordingOutput) else { return false }
            recordingOutput.connection(with: .video)?.isEnabled = true
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
        } else if !session.outputs.contains(videoOutput) {
            guard session.canAddOutput(videoOutput) else { return false }
            videoOutput.setSampleBufferDelegate(self, queue: previewQueue)
            session.addOutput(videoOutput)
        }
        livePreviewState.update { $0.previewFromRecordingOutput = useRecordingOutput }
        return true
    }

    /// Video formats can restrict a virtual camera's available constituents.
    /// Restore every device configured for video inside the photo-mode transaction,
    /// including physical routes used by ProRes RAW and lenses switched mid-session.
    private func restorePhotoDeviceConfigurationsAfterVideo(preservingActiveZoom: CGFloat?) {
        guard !photoDeviceConfigurationsBeforeVideo.isEmpty else { return }
        var restoredIdentifiers = Set<String>()
        let activeID = input?.device.uniqueID
        // A virtual device shares sensors with its constituents. Restore the input
        // currently in use last so inactive-route settings cannot overwrite it.
        let configurations = photoDeviceConfigurationsBeforeVideo.sorted {
            if ($0.key == activeID) != ($1.key == activeID) { return $0.key != activeID }
            return $0.key < $1.key
        }
        for (identifier, state) in configurations {
            let device = state.device
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // Restore the retained format belonging to this device.
                if device.activeFormat != state.format {
                    device.activeFormat = state.format
                }
                if state.format.supportedColorSpaces.contains(state.colorSpace), device.activeColorSpace != state.colorSpace {
                    device.activeColorSpace = state.colorSpace
                }
                if CMTimeCompare(device.activeVideoMinFrameDuration, state.minFrameDuration) != 0 {
                    device.activeVideoMinFrameDuration = state.minFrameDuration
                }
                if CMTimeCompare(device.activeVideoMaxFrameDuration, state.maxFrameDuration) != 0 {
                    device.activeVideoMaxFrameDuration = state.maxFrameDuration
                }
                let requestedZoom = identifier == activeID ? preservingActiveZoom ?? state.zoomFactor : state.zoomFactor
                let zoom = min(max(requestedZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                if zoom.isFinite, abs(device.videoZoomFactor - zoom) > 0.001 { device.videoZoomFactor = zoom }
                restoredIdentifiers.insert(identifier)
            } catch {
                report("恢复照片镜头配置失败：\(error.localizedDescription)")
            }
        }
        for identifier in restoredIdentifiers {
            photoDeviceConfigurationsBeforeVideo.removeValue(forKey: identifier)
            photoColorBeforeVideo.removeValue(forKey: identifier)
        }
    }

    /// Video standby keeps the outputs in the graph (format negotiation depends on
    /// them) but stops their connections from delivering frames/audio. Starting a
    /// recording enables both immediately; a failed start falls back after a delay.
    private func applyVideoStandbyConnections() {
        guard videoModeRequested, configured else { return }
        let keepForPreview = livePreviewState.snapshot().previewFromRecordingOutput
        recordingOutput.connection(with: .video)?.isEnabled = recordingBusyOnQueue || keepForPreview
        audioOutput.connection(with: .audio)?.isEnabled = recordingBusyOnQueue || videoAudioMeterRequested
    }

    private func enableRecordingConnectionsForStart() {
        recordingConnectionsEpoch &+= 1
        let epoch = recordingConnectionsEpoch
        recordingOutput.connection(with: .video)?.isEnabled = true
        audioOutput.connection(with: .audio)?.isEnabled = true
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.recordingConnectionsEpoch == epoch,
                  !self.recordingBusyOnQueue, !self.livePreviewState.snapshot().previewFromRecordingOutput else { return }
            self.applyVideoStandbyConnections()
        }
    }

    func setVideoAudioMeterEnabled(_ enabled: Bool) {
        queue.async {
            self.videoAudioMeterRequested = enabled
            self.applyVideoStandbyConnections()
        }
    }

    /// Must be called inside an open session configuration transaction.
    private func addRecordingOutputs() {
        if !session.outputs.contains(recordingOutput), session.canAddOutput(recordingOutput) {
            // 规格切换会先写入目标像素格式和缓冲尺寸；重建输出图时保留该设置。
            if recordingOutput.videoSettings == nil || recordingOutput.videoSettings?.isEmpty == true {
                recordingOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            }
            recordingOutput.alwaysDiscardsLateVideoFrames = true
            recordingOutput.automaticallyConfiguresOutputBufferDimensions = false
            recordingOutput.deliversPreviewSizedOutputBuffers = false
            recordingOutput.setSampleBufferDelegate(self, queue: recordingQueue)
            session.addOutput(recordingOutput)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: recordingQueue)
            session.addOutput(audioOutput)
        }
    }

    private func removeRecordingOutputs() {
        if session.outputs.contains(recordingOutput) { session.removeOutput(recordingOutput) }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        DispatchQueue.main.async {
            self.audioLeftLevel = 0
            self.audioRightLevel = 0
        }
    }

    /// 在写入专用队列创建并安装 AVAssetWriter，避免把编码器初始化和结束流程放到界面线程。
    private func installMovieRecorder(token: UUID, device: AVCaptureDevice, settings: VideoCaptureSettings,
                                      aspect: FrameRatio, sourceSize: CGSize, outputBaseSize: CGSize,
                                      mirrored: Bool, includeAudio: Bool, pixelFormat: OSType,
                                      recordingURL: URL,
                                      recordingAccess: ExternalVideoStorage.RecordingAccess?,
                                      rawSettings: [String: Any]?, recordingMetadata: [AVMetadataItem],
                                      look: CaptureLook, logLUTCube: LogLUTCube?,
                                      logLUTLog2ToLog1: Bool = false,
                                      timeLapseInterval: TimeInterval?, timeLapseFrameLimit: Int? = nil,
                                      nativeCaptureRotationAngle: CGFloat? = nil,
                                      rearCaptureRotationAngle: CGFloat? = nil) {
        recordingQueue.async { [self] in
            guard self.movieRecorder == nil, !self.recordingFinishing else {
                return
            }
            do {
                let recorder = try MovieRecorder(url: recordingURL, sourceSize: sourceSize, ratio: aspect,
                                                 mirrored: mirrored, includeAudio: includeAudio,
                                                 settings: settings, pixelFormat: pixelFormat,
                                                 metadata: recordingMetadata, outputBaseSize: outputBaseSize,
                                                 rawSettings: rawSettings,
                                                 externalRecordingAccess: recordingAccess, look: look,
                                                 logLUTCube: logLUTCube,
                                                 logLUTLog2ToLog1: logLUTLog2ToLog1,
                                                 timeLapseInterval: timeLapseInterval,
                                                 timeLapseFrameLimit: timeLapseFrameLimit,
                                                 nativeCaptureRotationAngle: nativeCaptureRotationAngle,
                                                 rearCaptureRotationAngle: rearCaptureRotationAngle)
                recorder.onStarted = {
                    DispatchQueue.main.async {
                        if self.videoCaptureToken == token { self.videoRecording = true }
                    }
                }
                recorder.onFailure = {
                    DispatchQueue.main.async {
                        if self.videoCaptureToken == token { self.stopVideoRecording() }
                    }
                }
                recorder.onTimeLapseLimitReached = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.videoCaptureToken == token else { return }
                        self.stopVideoRecording()
                    }
                }
                recorder.onTimeLapseFrameAccepted = { [weak self] count in
                    DispatchQueue.main.async { self?.timeLapseCapturedFrames = count }
                }
                self.movieRecorder = recorder
            } catch {
                recordingAccess?.stop()
                self.queue.async { self.restoreVideoWhiteBalance() }
                DispatchQueue.main.async {
                    self.videoBusy = false
                    self.report("视频暂时无法开始录制：\(error.localizedDescription)")
                }
            }
        }
    }

    func startVideoRecording(aspect: FrameRatio, copyright: String? = nil, look: CaptureLook = CaptureLook(),
                              logLUTCube: LogLUTCube? = nil, logLUTLog2ToLog1: Bool = false,
                              burnLogLUT: Bool = false,
                              logLUTName: String? = nil, lockWhiteBalance: Bool = false,
                              timeLapsePreset: TimeLapsePreset? = nil,
                              timeLapseEnabled: Bool = false,
                              timeLapseInterval: TimeInterval? = nil, timeLapseFrameLimit: Int? = nil,
                              cinematicVideo: Bool = false) {
        guard ready, !videoBusy, !videoConfiguring, !capturing, pendingPhotoCount == 0 else {
            return
        }
        timeLapseCapturedFrames = 0
        guard !timeLapseEnabled || !requestedVideoSettings.isRAW else {
            report("ProRes RAW 保留原始帧时间戳，暂不支持延时摄影。")
            return
        }
        guard !(timeLapseEnabled && requestedVideoSettings.captureFrameRate != nil) else {
            report("延时摄影与慢动作不能同时使用。")
            return
        }
        guard requestedVideoSettings.captureFrameRate == nil || !requestedVideoSettings.isRAW else {
            report("ProRes RAW 保留原始帧时间戳，暂不支持慢动作。")
            return
        }
        guard !cinematicVideo || (requestedCinematicVideo && !requestedVideoSettings.isRAW
                                  && !requestedVideoOpenGate && !timeLapseEnabled
                                  && requestedVideoSettings.captureFrameRate == nil) else {
            report("电影模式规格尚未准备好，请稍后重试。")
            return
        }
        guard !burnLogLUT || (requestedVideoSettings.colorSpace.isLog && logLUTCube != nil) else {
            report("Log 滤镜尚未准备好，请稍后重试。")
            return
        }
        let location = locationProvider?()
        let deviceModel = UIDevice.current.model
        let displayedZoom = Double(currentZoom)
        let token = UUID()
        videoCaptureToken = token
        #if DEBUG
        lastRecordingFrameCountsForTesting = nil
        #endif
        videoBusy = true
        videoRecordingZoomRange = nil
        queue.async {
            guard !self.videoWhiteBalanceLockPending else {
                DispatchQueue.main.async {
                    if self.videoCaptureToken == token {
                        self.videoCaptureToken = nil
                        self.videoBusy = false
                    }
                }
                return
            }
            let dual = self.dualCaptureSource
            guard self.videoModeRequested, dual?.session.isRunning == true || (self.session.isRunning && self.session.outputs.contains(self.recordingOutput)) else {
                DispatchQueue.main.async { self.videoBusy = false; self.report("视频暂时无法开始录制，请重试。") }
                return
            }
            guard let device = self.dualControlDevice else {
                DispatchQueue.main.async { self.videoBusy = false; self.report("视频暂时无法开始录制，请重试。") }
                return
            }
            self.enableRecordingConnectionsForStart()
            self.recordingZoomDeviceID = dual == nil ? device.uniqueID : nil
            let recordingRange = dual == nil ? self.recordingZoomRange(for: device) : nil
            DispatchQueue.main.async { self.videoRecordingZoomRange = recordingRange }
            if dual != nil { self.recordingQueue.sync { self.dualInsetThrottle.flush() } }
            let settings = self.requestedVideoSettings
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let nativeSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            let openGate = self.requestedVideoOpenGate
            // 片门全开按实际采集格式输出完整像素；正方形由编码器从该画面中心裁切。
            let openGateSize = openGate ? nativeSize : nil
            let dynamicFront = device.position == .front && device.deviceType == .builtInUltraWideCamera
            let actualFrontOutputSize: CGSize? = device.isCenterStageActive ? self.frontVideoOutputSize() : nil
            let sourceSize = dual?.outputSize ?? actualFrontOutputSize
                ?? (settings.isRAW || dynamicFront ? nativeSize : (openGateSize ?? settings.resolution.dimensions))
            let outputBaseSize = openGateSize ?? settings.resolution.dimensions
            let includeAudio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                && (dual?.includesAudio ?? self.session.outputs.contains(self.audioOutput))
                && !timeLapseEnabled
                && settings.captureFrameRate == nil
            let mirrored = dual == nil && device.position == .front
            // Center Stage的新前置传感器不走旧的横缓冲=旋转90度假设。
            // 保持输入像素与预览一致，仅在视频轨道写入开拍时的官方重力方向。
            var centerStageCaptureAngle: CGFloat?
            if #available(iOS 26.0, *), dual == nil, device.isCenterStageActive,
               device.position == .front, self.frontPhotoRotationCoordinator != nil {
                centerStageCaptureAngle = self.frontPhotoRotationCoordinator?.videoRotationAngleForHorizonLevelCapture
            }
            #if DEBUG
            if device.isCenterStageActive { print("CENTER-ORIENTATION native=\(nativeSize) angle=\(String(describing:centerStageCaptureAngle))") }
            #endif
            let rearCaptureAngle: CGFloat? = dual == nil && device.position == .back && !settings.isRAW
                ? self.rearCaptureRotationCoordinator.map { CaptureOrientation.cardinalAngle($0.videoRotationAngleForHorizonLevelCapture) } : nil
            #if DEBUG
            if let rearCaptureAngle { print("REAR-VIDEO-ORIENTATION angle=\(rearCaptureAngle) source=\(sourceSize)") }
            #endif
            let bakedLogFilterName = burnLogLUT && settings.colorSpace.isLog ? logLUTName : nil
            let metadata = VideoFileMetadata.items(device: device, model: deviceModel, location: location,
                mode: self.manualMode ? "M" : "A", bias: Double(self.exposureBias), zoom: dual == nil ? displayedZoom : Double(device.videoZoomFactor),
                ratio: aspect.rawValue, copyright: copyright, colorSpace: settings.colorSpace,
                bakedLogFilterName: bakedLogFilterName, timeLapsePreset: timeLapsePreset,
                slowMotionCaptureFrameRate: settings.captureFrameRate, playbackFrameRate: settings.frameRate,
                cinematicVideo: cinematicVideo, dualCapture: dual != nil, virtualAperture: look.virtualAperture, centerStage: device.isCenterStageActive)
            let pixelFormat: OSType = dual != nil ? kCVPixelFormatType_32BGRA : (self.recordingOutput.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? settings.colorSpace.pixelFormat
            let installRecorder: (URL, ExternalVideoStorage.RecordingAccess?, [String: Any]?, [AVMetadataItem]) -> Void = {
                recordingURL, recordingAccess, rawSettings, recordingMetadata in
                self.installMovieRecorder(token: token, device: device, settings: settings,
                    aspect: aspect, sourceSize: sourceSize, outputBaseSize: outputBaseSize,
                    mirrored: mirrored, includeAudio: includeAudio, pixelFormat: pixelFormat,
                    recordingURL: recordingURL, recordingAccess: recordingAccess,
                    rawSettings: rawSettings, recordingMetadata: recordingMetadata,
                    look: look, logLUTCube: burnLogLUT ? logLUTCube : nil,
                    logLUTLog2ToLog1: burnLogLUT && logLUTLog2ToLog1,
                    timeLapseInterval: timeLapseInterval ?? timeLapsePreset?.intervalSeconds,
                    timeLapseFrameLimit: timeLapseFrameLimit,
                    nativeCaptureRotationAngle: centerStageCaptureAngle,
                    rearCaptureRotationAngle: rearCaptureAngle)
            }
            let requiresWhiteBalanceLock = VideoWhiteBalancePolicy.requiresLocking(
                isRAW: settings.isRAW, userPreference: lockWhiteBalance)
            if settings.isRAW {
                do {
                    guard #available(iOS 26, *), self.recordingOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov).contains(settings.avCodec) else {
                        throw MovieRecorder.RecorderError.cannotStart("当前镜头不支持 RAW 视频。")
                    }
                    let destination = try ExternalVideoStorage.shared.openDestination()
                    self.lockVideoWhiteBalanceBeforeRecording(device: device, token: token, access: destination.access,
                                                             synchronizesRAWMetadata: true) {
                        do {
                            // 锁定回调前不能查询 recommendedMovieMetadata；否则系统直接抛出
                            // NSInvalidArgumentException。回调后重新核对当前会话和编码能力。
                            guard self.session.isRunning, self.input?.device === device,
                                  self.recordingOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov).contains(settings.avCodec) else {
                                throw MovieRecorder.RecorderError.cannotStart("RAW 录像配置已变化，请重试。")
                            }
                            let configuration = try RAWVideoWriterConfiguration.read(
                                whiteBalanceMode: device.whiteBalanceMode,
                                videoSettings: {
                                    self.recordingOutput.recommendedVideoSettings(forVideoCodecType: settings.avCodec,
                                        assetWriterOutputFileType: .mov, outputFileURL: destination.url)
                                }, metadata: {
                                    self.recordingOutput.recommendedMovieMetadata(forVideoCodecType: settings.avCodec,
                                        assetWriterOutputFileType: .mov)
                                })
                            installRecorder(destination.url, destination.access, configuration.videoSettings,
                                            metadata + configuration.metadata)
                        } catch {
                            destination.access.stop()
                            self.restoreVideoWhiteBalance()
                            DispatchQueue.main.async {
                                guard self.videoCaptureToken == token else { return }
                                self.videoCaptureToken = nil
                                self.videoBusy = false
                                self.report(error.localizedDescription)
                            }
                        }
                    }
                } catch {
                    self.restoreVideoWhiteBalance()
                    DispatchQueue.main.async { self.videoBusy = false; self.report(error.localizedDescription) }
                    return
                }
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumaVideo-\(UUID().uuidString).mov")
            if requiresWhiteBalanceLock {
                if let dual {
                    let secondary = device === dual.front ? dual.rear : dual.front
                    do {
                        try secondary.lockForConfiguration()
                        self.dualSecondaryWhiteBalanceBeforeRecording = (secondary, secondary.whiteBalanceMode)
                        if secondary.isWhiteBalanceModeSupported(.locked) { secondary.whiteBalanceMode = .locked }
                        secondary.unlockForConfiguration()
                    } catch {
                        self.report("同步双拍白平衡锁定失败：\(error.localizedDescription)")
                        DispatchQueue.main.async { self.videoBusy = false }
                        return
                    }
                }
                self.lockVideoWhiteBalanceBeforeRecording(device: device, token: token, access: nil) {
                    installRecorder(url, nil, nil, metadata)
                }
            } else {
                installRecorder(url, nil, nil, metadata)
            }
        }
    }

    func stopVideoRecording() {
        videoCaptureToken = nil
        videoRecording = false
        videoRecordingZoomRange = nil
        queue.async {
            self.recordingZoomDeviceID = nil
            // 尚未创建写入器时也要主动完成取消，不依赖相机是否继续送达白平衡回调。
            // 清除令牌后，迟到回调既不能创建旧写入器，也不能清掉新一轮的状态。
            if self.videoWhiteBalanceLockPending {
                self.videoWhiteBalanceLockToken = nil
                self.videoWhiteBalancePendingAccess?.stop()
                self.videoWhiteBalancePendingAccess = nil
                self.restoreVideoWhiteBalance()
                DispatchQueue.main.async {
                    self.videoRecording = false
                    self.videoBusy = false
                    self.onVideoRecorded?(.failure(CancellationError()))
                }
                return
            }
            self.recordingQueue.async {
            guard !self.recordingFinishing else { return }
            guard let recorder = self.movieRecorder else {
                DispatchQueue.main.async {
                    // 重复停止留下的空操作不能清掉随后新建请求的忙碌状态。
                    guard self.videoCaptureToken == nil else { return }
                    self.videoRecording = false; self.videoBusy = false
                }
                return
            }
            self.movieRecorder = nil
            self.recordingFinishing = true
            recorder.finish { result in
                #if DEBUG
                let counts = recorder.frameCountsForTesting
                #endif
                self.queue.async { self.restoreVideoWhiteBalance() }
                self.recordingQueue.async {
                    self.recordingFinishing = false
                    self.queue.async { self.applyVideoStandbyConnections() }
                }
                DispatchQueue.main.async {
                    #if DEBUG
                    self.lastRecordingFrameCountsForTesting = counts
                    #endif
                    self.videoRecording = false
                    self.videoBusy = false
                    switch result {
                    case .success(let url): self.onVideoRecorded?(.success(url))
                    case .failure(let error): self.onVideoRecorded?(.failure(error))
                    }
                }
            }
            }
        }
    }

    private func appendFrontLenses(to lenses: inout [CameraLens]) {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .front).devices
        if #available(iOS 26.0, *),
           let centerStage = devices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
           centerStage.formats.contains(where: { !$0.supportedDynamicAspectRatios.isEmpty }) {
            // One official Center Stage route: narrow and wide are sensor framing
            // choices, not separate physical lenses. Prefer Apple's narrow zoom.
            let supported = centerStage.smartFramingMonitor?.supportedFramings
                .map { CGFloat($0.zoomFactor) }.filter { $0.isFinite && $0 > 1.3 && $0 < 1.8 } ?? []
            let narrow = supported.min(by: { abs($0-1.6) < abs($1-1.6) }) ?? 1.6
            lenses.append(CameraLens(device: centerStage, title: "前置", zoomFactor: narrow, displayZoom: 1,
                                     isNative: false, frontFraming: .standard))
            lenses.append(CameraLens(device: centerStage, title: "广角", displayZoom: 1/narrow,
                                     frontFraming: .wide))
        } else if let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            // Older front cameras keep the existing route and rotation behavior.
            lenses.append(CameraLens(device: wide, title: "前置"))
        }
    }

    private func configure() throws {
        // 前置宽窄按钮与照片画幅按钮由应用控制。
        // 系统视频人物居中可能从上次状态恢复并限制变焦范围；明确接管并关闭，
        // 避免系统自动裁切与应用取景控制冲突。
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        let back = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        var found = CameraLensCatalog.rearLenses(back)
        appendFrontLenses(to: &found)
        guard let initialLens = found.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.001 }) ?? found.first else {
            throw CameraError.unavailable
        }
        rearVirtualDevice = CameraLensCatalog.preferredVirtualRearCamera()
        let device = captureDevice(for: initialLens)
        let newInput = try reusableInput(for: device)
        session.beginConfiguration()
        // Establish the photo baseline before an initial video route takes explicit
        // ownership of activeFormat in configureVideoFormat.
        session.sessionPreset = .photo
        guard session.canAddInput(newInput), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraError.unavailable
        }
        session.addInput(newInput)
        session.addOutput(photoOutput)
        // Apple documents that the output must prepare its highest requested quality before
        // the session starts. Ordinary captures still request balanced/speed per shot; A-mode
        // night brackets request quality so the processed source frames may use the platform's
        // available low-light noise/detail processing. This is not the Camera app's private Night mode.
        photoOutput.maxPhotoQualityPrioritization = .quality
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        // Preview proxies can stop reflecting high digital zoom on this device/OS.
        // Use full zoom semantics with explicit bounded dimensions set after format selection.
        videoOutput.deliversPreviewSizedOutputBuffers = true
        videoOutput.setSampleBufferDelegate(self, queue: previewQueue)
        session.addOutput(videoOutput)
        if videoModeRequested { addRecordingOutputs() }
        input = newInput
        session.commitConfiguration()
        if videoModeRequested { applyVideoStandbyConnections() }
        try applyZoom(initialLens)
        configureConnections(device: device)
        configurePhotoOutput(device,publish:false)
        configured = true
        reconcileLiveAudio()
        // The photo preset may select a different format with different native crop factors.
        found = CameraLensCatalog.rearLenses(back)
        appendFrontLenses(to: &found)
        lensCatalog = found
        publishPhotoCapabilities(device)
        if videoModeRequested { publishVideoSelectionCapabilities() }
        if manualMode && manualZoomAnchorID == nil { manualZoomAnchorID = initialLens.id }
        DispatchQueue.main.async { self.lenses = found }
        publishCapabilities(device, lensID: initialLens.id)
    }

    private func configurePhotoOutput(_ device: AVCaptureDevice, publish: Bool = true) {
        guard !videoModeRequested else { return }
        guard !nativePhotoInFlight else { deferredPhotoGraphConfiguration = true; return }
        // Batch output changes so max dimensions, ProRAW and responsiveness do not
        // each restart the photo graph independently after an input replacement.
        let liveRoute = device.uniqueID + String(describing: device.activeFormat)
        let enableLive = livePreviewRequested && photoOutput.isLivePhotoCaptureSupported
        // The Live recorder must be bound after dimensions/ProRAW have settled.
        // Reusing its old graph can otherwise yield a metadata-only .mov without video.
        if photoOutput.isLivePhotoCaptureEnabled && (!enableLive || configuredLiveCaptureRoute != liveRoute) {
            photoOutput.isLivePhotoCaptureEnabled = false
        }
        session.beginConfiguration()
        if photoOutput.isVirtualDeviceConstituentPhotoDeliverySupported,
           !photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled {
            photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled = true
        }
        // Configure the maximum once per input, never when merely changing the crop.
        photoDimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        if let largest = photoDimensions.last,
           photoOutput.maxPhotoDimensions.width != largest.width || photoOutput.maxPhotoDimensions.height != largest.height {
            photoOutput.maxPhotoDimensions = largest
        }
        // Keep native Live's extra buffering only while the feature is actually on.
        if photoOutput.isAppleProRAWSupported && !photoOutput.isAppleProRAWEnabled { photoOutput.isAppleProRAWEnabled = true }
        if photoOutput.isResponsiveCaptureSupported {
            // Responsive capture can return a faster lower-resolution still on the
            // first frame after a 48MP route change. Disable it for the explicit
            // high-resolution request so the first file is already 48MP.
            let enableResponsive = !highResolutionPhotoRequested
            if photoOutput.isResponsiveCaptureEnabled != enableResponsive {
                photoOutput.isResponsiveCaptureEnabled = enableResponsive
            }
        }
        let portraitSupported = photoOutput.isDepthDataDeliverySupported && photoOutput.isPortraitEffectsMatteDeliverySupported
        // 苹果要求：若会使用景深数据，应在 AVCaptureSession.startRunning() 前启用输出管线。
        // 管线能力常驻开启，单张照片是否请求景深/人像蒙版仍由 PhotoSettings 决定，避免用户
        // 每次开关人像时在运行中的会话内重配管线、冻结预览或中止未完成的拍摄。
        // 该设备原生蒙版实际超时后，重建时改用已有 Vision 后备路径；不让用户每张都再次等待超时。
        let enablePortrait = portraitSupported && !stalledPortraitDeviceIDs.contains(device.uniqueID)
        if photoOutput.isDepthDataDeliveryEnabled != enablePortrait {
            photoOutput.isDepthDataDeliveryEnabled = enablePortrait
        }
        if photoOutput.isPortraitEffectsMatteDeliveryEnabled != enablePortrait {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = enablePortrait
        }
        session.commitConfiguration()
        if photoOutput.isLivePhotoCaptureEnabled != enableLive { photoOutput.isLivePhotoCaptureEnabled = enableLive }
        configuredLiveCaptureRoute = enableLive ? liveRoute : nil
        if publish { publishPhotoCapabilities(device) }
    }

    private func publishPhotoCapabilities(_ device: AVCaptureDevice) {
        let revision = photoCapabilityRevision.advance()
        // The caller may still own an outer session transaction. Read the final
        // graph on the next session-queue turn, never an intermediate video graph.
        queue.async { [weak self] in
            guard let self, self.photoCapabilityRevision.matches(revision), !self.videoModeRequested,
                  self.input?.device.uniqueID == device.uniqueID else { return }
            self.publishSettledPhotoCapabilities(device, revision: revision)
        }
    }

    private func publishSettledPhotoCapabilities(_ device: AVCaptureDevice, revision: UInt64) {
        let key = device.uniqueID + String(describing:device.activeFormat) + "-\(device.activeColorSpace.rawValue)"
        let nativeFront = device.position == .front && videoOutput.automaticallyConfiguresOutputBufferDimensions
        if videoOutput.deliversPreviewSizedOutputBuffers || nativeFront {
            nativeLivePreviewSupported = photoOutput.isLivePhotoCaptureSupported
            nativeLiveCapabilityCache[key] = nativeLivePreviewSupported
        } else {
            nativeLivePreviewSupported = nativeLiveCapabilityCache[key] ?? true
        }
        let supportsLive = nativeLivePreviewSupported || hdrPreviewSource?.live == true
        var formats: [PhotoFileFormat] = [.jpeg, .tiff]
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) { formats.insert(.heif, at: 0) }
        let rawTypes = hdrPreviewSource?.rawTypes ?? photoOutput.availableRawPhotoPixelFormatTypes
        let hasProRAW = rawTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        if hasProRAW || (!rawTypes.isEmpty && abs(device.videoZoomFactor - 1) < 0.001) { formats += [.raw, .rawJPEG, .heifPro] }
        let high = (hdrPreviewSource?.dimensions ?? photoDimensions).contains { Int64($0.width) * Int64($0.height) >= 40_000_000 }
        let mainWide = lensCatalog.first(where: {
            $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
                && abs($0.displayZoom - 1) < 0.05
        })?.device ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let mainHigh = device.position == .back && (mainWide?.formats.contains {
            $0.supportedMaxPhotoDimensions.contains {
                Int64($0.width) * Int64($0.height) >= 40_000_000
            }
        } ?? false)
        let highLensIDs = Set(lensCatalog.filter { lens in
            lens.device.position == .back && abs(lens.zoomFactor-1)<0.001
                && [CGFloat(0.5),1,4].contains { abs($0-lens.displayZoom)<0.05 }
                && lens.device.formats.contains { $0.supportedMaxPhotoDimensions.contains { Int64($0.width)*Int64($0.height)>=40_000_000 } }
        }.map(\.id))
        // Portrait RAW eligibility must follow the active route's advertised
        // formats, not merely the output's global ProRAW-enabled switch. Some
        // routes can still expose Bayer RAW without an Apple ProRAW pixel type.
        let pro = hasProRAW
        // HEIF HDR 走系统 HLG/增益图，不要求当前 output 同时公开 RAW 类型；
        // 视频/Live 返回瞬间 rawTypes 可能暂时为空，不能因此把 HDR 误报为不可用。
        let heifHDRSupported = hlgPreviewFormat(device) != nil
        let highHDRSupported = !reducedHDRResolutionDevices.contains(device.uniqueID)
            && !device.constituentDevices.contains { $0.deviceType == .builtInWideAngleCamera && reducedHDRResolutionDevices.contains($0.uniqueID) }
        let nightSupported = photoOutput.maxBracketedCapturePhotoCount >= NightCapturePolicy.frameCount
            && device.isExposureModeSupported(.continuousAutoExposure)
        let nativePortraitSupported = photoOutput.isDepthDataDeliverySupported && photoOutput.isPortraitEffectsMatteDeliverySupported
        // 此属性表示应用人像可用性，不代表系统保证交付原生深度/人像蒙版。
        // M 挡物理镜头仍可对真实静态照片运行现有 Vision 后备分割。
        let portraitSupported = nativePortraitSupported || PortraitCapturePolicy.supportsSoftwarePortrait(
            formats: Set(formats), resolutions: high ? [.standard, .high] : [.standard])
        // 子模块只依赖每个镜头的静态照片能力；在会话队列读取并一次发布，避免界面反复探测设备格式。
        let routeCapabilities = Dictionary(uniqueKeysWithValues: lensCatalog.map { lens in
            let dimensions = lens.device.activeFormat.supportedMaxPhotoDimensions
            var resolutions = Set<PhotoResolution>()
            if dimensions.contains(where: { Int64($0.width) * Int64($0.height) >= 12_000_000 }) {
                resolutions.insert(.standard)
            }
            if dimensions.contains(where: { Int64($0.width) * Int64($0.height) >= 40_000_000 }) {
                resolutions.insert(.high)
            }
            var routeFormats: Set<PhotoFileFormat> = [.jpeg, .tiff]
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) { routeFormats.insert(.heif) }
            let hasStandardResolution = resolutions.contains(.standard)
            let routeNight = hasStandardResolution
                && photoOutput.maxBracketedCapturePhotoCount >= NightCapturePolicy.frameCount
                && lens.device.isExposureModeSupported(.continuousAutoExposure)
            let routePortrait = hasStandardResolution && (
                (lens.device.uniqueID == device.uniqueID && nativePortraitSupported)
                || PortraitCapturePolicy.supportsSoftwarePortrait(formats: routeFormats, resolutions: resolutions))
            return (lens.id, PhotoLensCaptureCapabilities(formats: routeFormats,
                resolutions: resolutions, supportsNightCapture: routeNight,
                supportsPortraitCapture: routePortrait))
        })
        DispatchQueue.main.async {
            guard self.photoCapabilityRevision.matches(revision), !self.videoModeDesired else { return }
            self.supportsLivePhoto = supportsLive
            self.availablePhotoFormats = formats
            self.availableResolutions = (high || mainHigh) ? [.standard, .high] : [.standard]
            self.highResolutionLensIDs = highLensIDs
            self.supportsProRAW = pro
            self.supportsHEIFHDR = heifHDRSupported
            self.supportsHighResolutionHEIFHDR = highHDRSupported
            self.supportsNightCapture = nightSupported
            self.supportsPortraitCapture = portraitSupported
            self.photoLensCapabilities = routeCapabilities
        }
    }

    func setPortraitCaptureEnabled(_ enabled: Bool, transitionID: UUID? = nil) {
        queue.async {
            guard let device = self.input?.device, !self.videoModeRequested else {
                if let transitionID { self.markUserPreviewSwitch(transitionID) }
                return
            }
            // 景深输出管线在会话启动时已按当前设备能力配置；开关只影响逐张照片的请求参数。
            // 重新确认 A 挡虚拟多摄由系统自动选镜头，且不为人像开关重启照片输出管线。
            if !self.manualMode { self.configureAutomaticLensPolicy(device) }
            if let transitionID { self.markUserPreviewSwitch(transitionID) }
        }
    }

    func setPortraitPreview(enabled: Bool, blurStrength: Double) {
        var generation: UInt64 = 0
        var segmentationStateChanged = false
        livePreviewState.update {
            if $0.portraitPreviewEnabled != enabled {
                $0.portraitPreviewGeneration &+= 1
                segmentationStateChanged = true
            }
            $0.portraitPreviewEnabled = enabled
            $0.portraitBlurStrength = min(1, max(0, blurStrength.isFinite ? blurStrength : 0.5))
            generation = $0.portraitPreviewGeneration
        }
        // 滑块每次变化只更新当前渲染强度；不要重复进入分割处理器的配置锁。
        if segmentationStateChanged {
            portraitPreviewProcessor.configure(enabled: enabled, generation: generation)
        }
        #if targetEnvironment(simulator)
        queue.async { self.renderDemo() }
        #endif
    }

    #if DEBUG
    func portraitPreviewMetricsForTesting() -> PortraitPreviewProcessor.Metrics {
        portraitPreviewProcessor.metrics()
    }
    #endif

    /// Automatic mode delegates scene-dependent primary and fallback selection to
    /// the complete virtual camera. Do not force the ultra-wide as the sole fallback.
    /// 有界记录配置顺序，错误时才输出；避免仅凭延迟通知中的设备快照猜测原因。
    private func recordSessionOperation(_ operation: String) {
        #if DEBUG
        let device = input?.device
        let dimensions = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        recentSessionOperationsForTesting.append("\(CACurrentMediaTime()) \(operation) video=\(videoModeRequested) M=\(manualMode) running=\(session.isRunning) wants=\(wantsRunning) input=\(device?.deviceType.rawValue ?? "none") size=\(dimensions.map { "\($0.width)x\($0.height)" } ?? "none")")
        if recentSessionOperationsForTesting.count > 32 { recentSessionOperationsForTesting.removeFirst() }
        #endif
    }

    private func configureAutomaticLensPolicy(_ device: AVCaptureDevice) {
        #if DEBUG
        if device.isVirtualDevice { print("LENS-AUTO-RESET macro=\(macroActive) primary=\(device.activePrimaryConstituent?.deviceType.rawValue ?? "nil")") }
        #endif
        guard !manualMode, device.isVirtualDevice,
              device.primaryConstituentDeviceSwitchingBehavior != .unsupported else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            automaticConfiguredDevice = device
            // 系统格式切换期间的当前 fallback 可能是临时子集；不能把它缓存为默认。
            // 恢复官方声明支持的完整集合，由系统继续按场景挑选物理镜头。
            let fallbacks = device.supportedFallbackPrimaryConstituentDevices
            if device.fallbackPrimaryConstituentDevices.map(\.uniqueID) != fallbacks.map(\.uniqueID) {
                device.fallbackPrimaryConstituentDevices = fallbacks
            }
            let behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior = .auto
            if device.primaryConstituentDeviceSwitchingBehavior != behavior || !device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions.isEmpty {
                device.setPrimaryConstituentDeviceSwitchingBehavior(behavior, restrictedSwitchingBehaviorConditions: [])
            }
            if behavior == .auto {
                // The available minimum updates asynchronously after leaving .locked.
                // Do not overwrite the known full range with that transient minimum.
                let minimum = min(automaticUnrestrictedZoomRange?.lowerBound ?? device.minAvailableVideoZoomFactor, device.minAvailableVideoZoomFactor)
                automaticUnrestrictedZoomRange = minimum...max(minimum, automaticUnrestrictedZoomRange?.upperBound ?? 0, device.maxAvailableVideoZoomFactor)
            }
        } catch { report("自动镜头策略配置失败：\(error.localizedDescription)") }
    }
    /// User zoom can release an externally locked route. The normal A-mode path
    /// leaves system automatic selection running continuously, without lock/unlock timers.
    private func resumeAutomaticLensSelectionForUserZoom(_ device: AVCaptureDevice) {
        guard !manualMode, device.isVirtualDevice else { return }
        guard device.primaryConstituentDeviceSwitchingBehavior != .auto ||
              !device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions.isEmpty else { return }
        configureAutomaticLensPolicy(device)
    }

    private func releaseAutomaticLensStability() {
        automaticUnrestrictedZoomRange = nil
        guard let device = automaticConfiguredDevice else { return }
        automaticConfiguredDevice = nil
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.fallbackPrimaryConstituentDevices = device.supportedFallbackPrimaryConstituentDevices
            if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            }
        } catch { report("恢复自动镜头选择失败：\(error.localizedDescription)") }
    }

    func setLivePhotoPreviewRequested(_ enabled: Bool) {
        queue.async {
            if self.livePreviewRequested != enabled { self.stopFocusNavigatorOnQueue() }
            // A Live toggle can arrive while the last focal-button tap is still
            // waiting in the coalesced zoom queue. Apply that target before the
            // session graph is changed so Live setup cannot snapshot a stale 1×.
            self.zoomThrottle.flush()
            guard self.livePreviewRequested != enabled else { return }
            self.livePreviewRequested = enabled
            guard self.configured, let device = self.input?.device else { return }
            guard !self.nativePhotoInFlight else { self.deferredPhotoGraphConfiguration = true; return }
            let zoomBeforeReconfiguration = device.videoZoomFactor
            self.configurePreviewOutput(device)
            self.configurePhotoOutput(device)
            self.restoreZoomAfterLiveReconfiguration(zoomBeforeReconfiguration, on: device)
        }
    }

    /// Changing the preview buffer path for Live can make AVFoundation reset the
    /// active device's crop. Preserve the user's selected framing across that graph
    /// transaction, including the 35 mm crop represented by the 1× focal control.
    private func restoreZoomAfterLiveReconfiguration(_ zoom: CGFloat, on device: AVCaptureDevice) {
        guard input?.device.uniqueID == device.uniqueID,
              zoom.isFinite, zoom > 0 else { return }
        let target = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        guard abs(device.videoZoomFactor - target) > 0.001 else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        } catch {
            report("恢复 Live 取景倍率失败：\(error.localizedDescription)")
            return
        }
        publishCapabilities(device, lensID: selectedLens)
    }

    private func configurePreviewOutput(_ device: AVCaptureDevice) {
        guard !nativePhotoInFlight else { deferredPhotoGraphConfiguration = true; return }
        // 电影由录制输出送帧，不能再配置已拆下的普通预览输出。
        guard !requestedCinematicVideo || session.outputs.contains(videoOutput) else { return }
        let previewDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        // A/M 在虚拟/物理后置之间切换时，只要视频输出格式尺寸和色彩空间一致，
        // 就不必为了设备 ID 变化重建预览输出；输入替换本身会继续送帧。
        let key = "\(previewDimensions.width)x\(previewDimensions.height)-\(device.activeColorSpace.rawValue)"
        let rawVideo = videoModeRequested && requestedVideoSettings.isRAW
        let nativeFrontPhoto: Bool
        if #available(iOS 26.0, *), device.position == .front, !videoModeRequested {
            nativeFrontPhoto = !device.activeFormat.supportedDynamicAspectRatios.isEmpty
        } else { nativeFrontPhoto = false }
        // 新前置动态传感器由系统负责预览尺寸。手动全分辨率输出沿用旧方向的
        // 宽高约束会缩放人物，而且与独立照片输出的视野不一致。
        if nativeFrontPhoto {
            if configuredPreviewRoute == key && configuredPreviewHDR == (hdrPreviewSource != nil) && videoOutput.automaticallyConfiguresOutputBufferDimensions { return }
            livePreviewState.update { $0.acceptsFrames = false }
            session.beginConfiguration()
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            let tenBit = hdrPreviewSource != nil
            let desired: OSType = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            if videoOutput.availableVideoPixelFormatTypes.contains(desired) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: desired]
            } else { videoOutput.videoSettings = [:] }
            videoOutput.automaticallyConfiguresOutputBufferDimensions = true
            session.commitConfiguration()
            nativeLivePreviewSupported = photoOutput.isLivePhotoCaptureSupported
            configuredPreviewRoute = key; configuredPreviewHDR = tenBit
            let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            livePreviewState.update { $0.framesNotBefore = cutoff; $0.warmupFrames = 2; $0.acceptsFrames = true }
            return
        }
        // 离开新前置照片路线后，后置/视频继续按既有受限尺寸及倍率语义配置。
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        let proxyWanted = rawVideo || (livePreviewRequested && hdrPreviewSource == nil)
        if configuredPreviewRoute == key && videoOutput.deliversPreviewSizedOutputBuffers == proxyWanted { return }
        let previousProxy = videoOutput.deliversPreviewSizedOutputBuffers
        let hdrSourceMatchesDevice = hdrPreviewSource?.device.uniqueID == device.uniqueID
        let isHDR = (hdrSourceMatchesDevice && device.activeFormat.isVideoHDRSupported)
            || (videoModeRequested && requestedVideoSettings.colorSpace == .hdr)
        let colorChanged = configuredPreviewHDR != isHDR
        livePreviewState.update { $0.acceptsFrames = false }
        if rawVideo {
            videoOutput.videoSettings = [:]
            videoOutput.deliversPreviewSizedOutputBuffers = true
            let pixels: [OSType] = [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
            if let pixel = pixels.first(where: { videoOutput.availableVideoPixelFormatTypes.contains($0) }) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel]
            }
            configuredPreviewRoute = key; configuredPreviewHDR = false
            livePreviewState.update { $0.warmupFrames = 2; $0.acceptsFrames = true }
            return
        }
        let tenBit = (hdrSourceMatchesDevice && device.activeFormat.isVideoHDRSupported)
            || (videoModeRequested && requestedVideoSettings.colorSpace.usesTenBit)
        // Drop dimensions from the previous active format before writing pixel/color.
        videoOutput.videoSettings = [:]
        var previewSettings: [String: Any] = [:]
        let previewPixels: [OSType] = [rawVideo ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        if let pixel = previewPixels.first(where: { videoOutput.availableVideoPixelFormatTypes.contains($0) }) {
            previewSettings[kCVPixelBufferPixelFormatTypeKey as String] = pixel
        }
        previewSettings[AVVideoAllowWideColorKey] = NSNumber(value: tenBit || (videoModeRequested && requestedVideoSettings.colorSpace == .p3))
        // videoSettings may carry dimensions from the previous activeFormat. A
        // 4:3 format is smaller than the prior 16:9 format; writing those stale
        // dimensions raises an AVFoundation exception. Always clear them here and
        // let configurePreviewBufferDimensions apply the new format's bounds.
        previewSettings.removeValue(forKey: kCVPixelBufferWidthKey as String)
        previewSettings.removeValue(forKey: kCVPixelBufferHeightKey as String)
        if !NSDictionary(dictionary: videoOutput.videoSettings ?? [:]).isEqual(to: previewSettings) { videoOutput.videoSettings = previewSettings }
        // Probe native Live only when enabling it. Ordinary A/M and focal changes
        // must not flip full → proxy → full merely to rediscover a capability.
        if proxyWanted {
            session.beginConfiguration()
            var settings = videoOutput.videoSettings ?? [:]
            settings.removeValue(forKey:kCVPixelBufferWidthKey as String)
            settings.removeValue(forKey:kCVPixelBufferHeightKey as String)
            videoOutput.videoSettings = settings
            videoOutput.deliversPreviewSizedOutputBuffers = true
            session.commitConfiguration()
            nativeLivePreviewSupported = photoOutput.isLivePhotoCaptureSupported
        } else {
            // A full-output graph cannot answer native Live support. An unknown
            // route may attempt Live; enabling it performs the definitive check,
            // automatically disabling it if the system rejects that combination.
            // Only the settled photo-graph publisher updates this cache.
            // The previous proxy can belong to another format or a video graph.
            nativeLivePreviewSupported = nativeLiveCapabilityCache[key] ?? true
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let target = PreviewBufferConfiguration.dimensions(width:Int(dimensions.width),height:Int(dimensions.height))
            let settings = videoOutput.videoSettings ?? [:]
            let matches = target.map { (settings[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue == $0.width &&
                (settings[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue == $0.height } ?? false
            if previousProxy || !matches {
                session.beginConfiguration()
                var resized = settings
                resized.removeValue(forKey:kCVPixelBufferWidthKey as String)
                resized.removeValue(forKey:kCVPixelBufferHeightKey as String)
                videoOutput.videoSettings = safeVideoOutputSettings(resized, device: device)
                videoOutput.deliversPreviewSizedOutputBuffers = false
                configurePreviewBufferDimensions(device)
                session.commitConfiguration()
            }
        }
        configuredPreviewRoute = key
        configuredPreviewHDR = isHDR
        let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        livePreviewState.update { $0.framesNotBefore = cutoff; $0.warmupFrames = previousProxy != proxyWanted || colorChanged ? 2 : 1; $0.acceptsFrames = true }
    }

    private func configurePreviewBufferDimensions(_ device: AVCaptureDevice) {
        // The front ultra-wide uses a dynamic aspect ratio; any fixed buffer size
        // raises an AVFoundation exception when switching to it. Let the output
        // choose dimensions for this route.
        if device.position == .front, device.deviceType == .builtInUltraWideCamera { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard let size = PreviewBufferConfiguration.dimensions(width: Int(dimensions.width), height: Int(dimensions.height)) else { return }
        var settings = videoOutput.videoSettings ?? [:]
        settings[kCVPixelBufferWidthKey as String] = size.width
        settings[kCVPixelBufferHeightKey as String] = size.height
        videoOutput.videoSettings = settings
    }

    private func configureConnections(device: AVCaptureDevice, configuresVideoFormat: Bool = true) {
        recordSessionOperation("configureConnections target=\(device.deviceType.rawValue)")
        if #available(iOS 26.0, *), !videoModeRequested, let input, input.activeLockedVideoFrameDuration.isValid {
            // 返回照片后归还帧周期，避免手动照片继承录像快门上限。
            input.activeLockedVideoFrameDuration = .invalid
        }
        if !videoModeRequested, let input, input.videoMinFrameDurationOverride.isValid {
            input.videoMinFrameDurationOverride = .invalid
        }
        if videoModeRequested, configuresVideoFormat {
            session.beginConfiguration()
            configureVideoFormat(device)
            session.commitConfiguration()
        } else if !videoModeRequested, let original = photoColorBeforeVideo.removeValue(forKey: device.uniqueID) {
            do {
                try device.lockForConfiguration()
                let restored = device.activeFormat.supportedColorSpaces.contains(original) ? original : .sRGB
                if device.activeColorSpace != restored { device.activeColorSpace = restored }
                device.unlockForConfiguration()
            } catch { report("恢复照片色彩配置失败：\(error.localizedDescription)") }
        }
        if heifHDRPipelineRequested, hdrPreviewSource == nil, photoOutput.isAppleProRAWSupported, !photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = true
        }
        _ = reconcileHDRPreviewFormat(device)
        configurePreviewOutput(device)
        primaryLensObservation = nil
        if monitoredFrontDevice?.uniqueID != device.uniqueID { stopFrontSmartFraming() }
        if automaticConfiguredDevice?.uniqueID != device.uniqueID { releaseAutomaticLensStability() }
        configureAutomaticLensPolicy(device)
        if device.isVirtualDevice {
            primaryLensObservation = device.observe(\.activePrimaryConstituent, options: [.old, .new]) { [weak self] observed, change in
                guard let self, let old = change.oldValue ?? nil, let new = change.newValue ?? nil, old.uniqueID != new.uniqueID else { return }
                self.queue.async { [weak self] in
                    guard let self, self.wantsRunning, !self.manualMode, self.input?.device.uniqueID == observed.uniqueID else { return }
                    // Discard old in-flight renders rather than publishing an old lens frame
                    // after the first new lens frame. No capture-session rebuild is required.
                    self.readingsGeneration &+= 1
                    self.syncPreviewState()
                    let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                    self.livePreviewState.update { $0.framesNotBefore = cutoff }
                    let generation = self.readingsGeneration
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.livePreviewState.snapshot().readingsGeneration == generation else { return }
                        self.onAutomaticLensChange?()
                    }
                }
            }
        }

        do {
            try device.lockForConfiguration()
            updatePreviewHDR(device, customExposure: customExposureRequested)
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch { report("预览配置失败：\(error.localizedDescription)") }
        readingsGeneration &+= 1
        DispatchQueue.main.async { self.readings = nil }
        defer {
            syncPreviewState()
            let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            livePreviewState.update { $0.framesNotBefore = cutoff; $0.acceptsFrames = true }
        }
        configureOutputConnections(device)
        observeFrontSmartFramingCapabilities(device: device)
        prepareFrontSmartFraming(device: device)
        queue.async { [weak self] in self?.refreshFrontSmartFraming() }
        publishFrontAutoCenteringState(device)
        synchronizeFrontPhotoAspectRatio(device)
    }

    /// Front Center Stage can change between portrait and landscape aspect ratios
    /// without rebuilding the capture graph. Video remains on the portrait sensor
    /// framing; the remembered landscape choice is restored on the photo route.
    private func synchronizeFrontPhotoAspectRatio(_ device: AVCaptureDevice) {
        guard input?.device.uniqueID == device.uniqueID else { return }
        let available: Bool
        if #available(iOS 26.0, *), device.position == .front, !videoModeRequested {
            let supported = device.activeFormat.supportedDynamicAspectRatios
            available = supported.contains(.ratio3x4) && supported.contains(.ratio4x3)
        } else {
            available = false
        }
        let availabilityRevision = frontAspectAvailabilityRevision.advance()
        DispatchQueue.main.async {
            guard self.frontAspectAvailabilityRevision.matches(availabilityRevision) else { return }
            if self.frontPhotoAspectRatioSwitchAvailable != available {
                self.frontPhotoAspectRatioSwitchAvailable = available
            }
        }
        guard #available(iOS 26.0, *), device.position == .front else { return }
        let useLandscape = !videoModeRequested && frontPhotoLandscapeRequested && available
        // 按当前连接的实际输出方向选择系统动态画幅，视频保持原路线。
        let target: AVCaptureDevice.AspectRatio = videoModeRequested ? .ratio3x4 : (useLandscape ? .ratio3x4 : .ratio4x3)
        guard device.activeFormat.supportedDynamicAspectRatios.contains(target) else {
            frontPhotoLandscapeApplied = false
            return
        }
        if device.dynamicAspectRatio == target {
            frontPhotoLandscapeApplied = useLandscape
            return
        }
        applyFrontDynamicAspectRatio(target, to: device, publishPhotoPreference: false, landscape: useLandscape)
    }

    func setFrontPhotoLandscapeEnabled(_ enabled: Bool) {
        queue.async {
            guard self.wantsRunning, self.configured, self.session.isRunning,
                  !self.videoModeRequested, !self.videoRecording, !self.videoBusy,
                  !self.capturing, let device = self.input?.device, device.position == .front,
                  self.frontPhotoAspectRatioSwitchAvailable else { return }
            if self.frontAutoCenteringRequested {
                self.frontAutoCenteringRequested = false
                self.stopFrontSmartFraming()
                self.publishFrontAutoCenteringState(device)
            }
            self.frontAspectReturnState = nil
            self.frontPhotoLandscapeRequested = enabled
            guard #available(iOS 26.0, *) else { return }
            let target: AVCaptureDevice.AspectRatio = enabled ? .ratio3x4 : .ratio4x3
            self.applyFrontDynamicAspectRatio(target, to: device, publishPhotoPreference: true, landscape: enabled)
        }
    }

    /// 宽高比按钮：横幅配合最广前置取景；第二次按原快照恢复，不能只恢复到固定1倍。
    func toggleFrontPhotoWideAspect(selectedLensID:String, displayZoom:CGFloat) {
        _ = zoomRevision.advance()
        zoomThrottle.cancel()
        queue.async { [self] in
            guard #available(iOS 26.0, *), self.wantsRunning, self.configured, self.session.isRunning,
                  !self.videoModeRequested, !self.videoBusy, !self.capturing, !self.frontAspectInFlight,
                  let device = self.input?.device, device.position == .front,
                  self.frontPhotoAspectRatioSwitchAvailable,
                  let wide = self.lensCatalog.first(where: { $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide }) else { return }
            if self.frontAutoCenteringRequested {
                self.frontAutoCenteringRequested = false; self.stopFrontSmartFraming()
                self.publishFrontAutoCenteringState(device)
            }
            let oldState = self.frontAspectReturnState, oldLandscape = self.frontPhotoLandscapeRequested
            let landscape:Bool, zoom:CGFloat, lensID:String
            if let saved = oldState, saved.deviceID == device.uniqueID {
                landscape = saved.landscape; zoom = saved.zoom; lensID = saved.lensID
                self.frontAspectReturnState = nil
            } else if oldLandscape {
                // 冷启动恢复的旧横幅没有往返快照，保留原有倍率退出横幅。
                landscape = false; zoom = device.videoZoomFactor; lensID = selectedLensID
                self.frontAspectReturnState = nil
            } else {
                let selected = self.lensCatalog.first { $0.id == selectedLensID && $0.device.uniqueID == device.uniqueID } ?? wide
                let previousZoom = displayZoom.isFinite && displayZoom>0
                    ? displayZoom * selected.zoomFactor / selected.displayZoom : device.videoZoomFactor
                self.frontAspectReturnState = (device.uniqueID,oldLandscape,previousZoom,selected.id)
                landscape = true; zoom = wide.zoomFactor; lensID = wide.id
            }
            self.frontPhotoLandscapeRequested = landscape
            self.continuousZoomActive = false
            self.applyFrontDynamicAspectRatio(landscape ? .ratio3x4 : .ratio4x3, to:device,
                publishPhotoPreference:true,landscape:landscape,zoomOverride:zoom,logicalLensID:lensID) { [weak self] success in
                guard let self else { return }
                if !success {
                    self.frontAspectReturnState = oldState
                    self.frontPhotoLandscapeRequested = oldLandscape
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private func applyFrontDynamicAspectRatio(_ aspect: AVCaptureDevice.AspectRatio, to device: AVCaptureDevice,
                                             publishPhotoPreference: Bool, landscape: Bool,
                                             zoomOverride:CGFloat? = nil, logicalLensID:String? = nil,
                                             completion:((Bool)->Void)? = nil) {
        guard input?.device.uniqueID == device.uniqueID,
              device.activeFormat.supportedDynamicAspectRatios.contains(aspect) else { completion?(false); return }
        let requestRevision = frontAspectRequestRevision.advance()
        let framingZoom = zoomOverride ?? device.videoZoomFactor
        let applyFraming: ()->Void = { [weak self, weak device] in
            guard let self, let device else { return }
            // 进入视频即取消尚未完成的照片按钮请求，不能让迟到回调改变视频倍率或look。
            guard !publishPhotoPreference || !self.videoModeRequested else { completion?(false); return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(max(framingZoom,device.minAvailableVideoZoomFactor),device.maxAvailableVideoZoomFactor)
                device.unlockForConfiguration()
            } catch {
                self.report("恢复前置构图倍率失败：\(error.localizedDescription)"); completion?(false); return
            }
            self.frontPhotoLandscapeApplied = landscape
            if zoomOverride != nil {
                // 画幅回调之后的倍率仍有缓冲过渡；沿用现有暖帧门控，只发布联合设置后的新帧。
                self.livePreviewState.update { $0.warmupFrames = max($0.warmupFrames,2) }
            }
            if publishPhotoPreference { self.applyLandscapeToCurrentPhotoLook(landscape) }
            if let logicalLensID {
                if self.manualMode { self.manualZoomAnchorID = logicalLensID }
                self.publishCapabilities(device,lensID:logicalLensID)
            }
            completion?(true)
        }
        if device.dynamicAspectRatio == aspect, !frontAspectInFlight {
            applyFraming()
            return
        }
        frontAspectInFlight = true
        do {
            try device.lockForConfiguration()
            device.setDynamicAspectRatio(aspect) { [weak self, weak device] syncTime, error in
                guard let self else { return }
                self.queue.async {
                    guard let device, self.frontAspectRequestRevision.matches(requestRevision),
                          self.input?.device.uniqueID == device.uniqueID else { return }
                    self.frontAspectInFlight = false
                    if let error {
                        self.report("前置照片宽高比切换失败：\(error.localizedDescription)")
                        completion?(false)
                        return
                    }
                    // Apple 的回调时刻在输入时钟上，先转换到会话时钟，再排除旧画幅样本。
                    if let inputClock = self.input?.ports.first(where: { $0.mediaType == .video })?.clock,
                       let sessionClock = self.session.synchronizationClock {
                        let appliedTime = CMTimeGetSeconds(CMSyncConvertTime(syncTime, from: inputClock, to: sessionClock))
                        if appliedTime.isFinite {
                            self.livePreviewState.update { $0.framesNotBefore = max($0.framesNotBefore, appliedTime) }
                        }
                    }
                    // 本机先设倍率再改画幅曾使恢复后的实际焦距偏大，保留先画幅后倍率的顺序。
                    // 即使倍率数字未变也需重新应用，避免预览仍按旧裁切窗口缩放。
                    applyFraming()
                }
            }
            device.unlockForConfiguration()
        } catch {
            frontAspectInFlight = false
            self.report("前置照片宽高比切换失败：\(error.localizedDescription)")
            completion?(false)
        }
    }

    /// Keep the processing look on the capture queue in step with the completed
    /// sensor framing change, so a shutter request cannot race the UI publisher.
    private func applyLandscapeToCurrentPhotoLook(_ landscape: Bool) {
        // 让尚未执行的旧 UI look 更新失效；宽高比回调已在相机队列确认，
        // 不能再被切换前排队的参数覆盖。
        _ = lookUpdateRevision.advance()
        guard look.landscape != landscape else {
            syncPreviewState()
            return
        }
        look.landscape = landscape
        lookRevision = previewRevision.advance(resetInteractiveFloor: true)
        syncPreviewState()
    }

    /// 系统格式与构图候选都可能在会话提交后才更新。持续观察真实能力，
    /// 避免只在切镜当刻读取一次，把暂时不可用的状态永久留在按钮上。
    private func observeFrontSmartFramingCapabilities(device: AVCaptureDevice) {
        guard #available(iOS 26.0, *), device.position == .front,
              let monitor = device.smartFramingMonitor else {
            smartFramingFormatObservation = nil; smartFramingChoicesObservation = nil
            smartFramingCapabilityDevice = nil
            return
        }
        guard smartFramingCapabilityDevice !== device else { return }
        smartFramingFormatObservation = nil; smartFramingChoicesObservation = nil
        smartFramingCapabilityDevice = device
        let refresh: () -> Void = { [weak self, weak device] in
            self?.queue.async { [weak self, weak device] in
                guard let self, let device, self.wantsRunning,
                      self.input?.device === device else { return }
                self.prepareFrontSmartFraming(device: device)
                self.refreshFrontSmartFraming()
            }
        }
        smartFramingFormatObservation = device.observe(\.activeFormat, options: [.new]) { _, _ in refresh() }
        smartFramingChoicesObservation = monitor.observe(\.supportedFramings, options: [.new]) { _, _ in refresh() }
    }

    private func prepareFrontSmartFraming(device: AVCaptureDevice) {
        guard #available(iOS 26.0, *), device.position == .front,
              device.activeFormat.isSmartFramingSupported,
              let monitor = device.smartFramingMonitor else { return }
        // Apple requires enabled framings to be configured before the capture
        // session starts. Keep the app's portrait sensor framing and crop policy.
        let choices = monitor.supportedFramings.filter { $0.aspectRatio == .ratio3x4 }
        if monitor.enabledFramings != choices { monitor.enabledFramings = choices }
    }

    /// 普通前置视频用普通会话 input，双拍时 CenterStage 必须落到双拍自己的前置设备。
    private var frontCenterStageDevice: AVCaptureDevice? {
        if let dualCaptureSource { return dualCaptureSource.front }
        return input?.device
    }

    /// 官方Center Stage负责对人物自动平移/缩放，使用相机原生输出，不叠加软件裁切。
    func setFrontVideoCentering(_ enabled: Bool, transitionID: UUID? = nil) {
        guard !videoBusy, !frontVideoCenteringPreparing else { return }
        frontVideoCenteringPreparing = true
        let revision = frontVideoCenteringRevision.advance()
        queue.async {
            defer { DispatchQueue.main.async { if self.frontVideoCenteringRevision.matches(revision) { self.frontVideoCenteringPreparing = false } } }
            guard self.videoModeRequested, let device = self.frontCenterStageDevice,
                  device.position == .front else { return }
            guard self.wantsRunning || self.dualCaptureSource != nil else { return }
            if enabled && !device.formats.contains(where: { $0.isCenterStageSupported }) {
                self.report("当前前置镜头不支持人物居中。"); return
            }
            self.frontAutoCenteringRequested = false; self.stopFrontSmartFraming()
            if !enabled { self.stopFrontVideoCentering() }
            else { self.frontVideoCenteringRequested = true }
            if self.dualCaptureSource == nil {
                self.session.beginConfiguration()
                self.configureConnections(device: device)
                self.session.commitConfiguration()
            }
            self.refreshFrontVideoCentering(device)
            if self.dualCaptureSource == nil { self.publishCapabilities(device, lensID: self.selectedLens) }
            self.syncPreviewState(); if let transitionID { self.markUserPreviewSwitch(transitionID) }
        }
    }
    private func stopFrontVideoCentering(clearRequest: Bool = true) {
        if clearRequest { frontVideoCenteringRequested = false }
        AVCaptureDevice.centerStageControlMode = .app
        // 裁切ROI仅属于本功能，退出前恢复整幅，避免带到下一种取景/格式。
        if AVCaptureDevice.isCenterStageEnabled, let device = frontCenterStageDevice,
           device.formats.contains(where: { $0.isCenterStageSupported }),
           device.centerStageRectOfInterest != CGRect(x:0,y:0,width:1,height:1) {
            do {
                try device.lockForConfiguration()
                device.centerStageRectOfInterest = CGRect(x:0,y:0,width:1,height:1)
                device.unlockForConfiguration()
            } catch { report("人物居中取景恢复失败：\(error.localizedDescription)") }
        }
        if AVCaptureDevice.isCenterStageEnabled { AVCaptureDevice.isCenterStageEnabled = false }
        frontVideoCenteringObservation = nil
        if let device = frontCenterStageDevice { publishFrontVideoCenteringState(device) }
    }
    private func refreshFrontVideoCentering(_ device: AVCaptureDevice, deviceLocked: Bool = false) {
        let enabled = frontVideoCenteringRequested && videoModeRequested && device.position == .front
            && device.activeFormat.isCenterStageSupported && (wantsRunning || dualCaptureSource != nil)
        AVCaptureDevice.centerStageControlMode = .app
        if AVCaptureDevice.isCenterStageEnabled != enabled { AVCaptureDevice.isCenterStageEnabled = enabled }
        if enabled { updateFrontVideoCenteringRegion(device, deviceLocked: deviceLocked) }
        frontVideoCenteringObservation = enabled ? device.observe(\.isCenterStageActive, options: [.new]) { [weak self, weak device] _, _ in
            self?.queue.async { [weak self, weak device] in
                guard let self, let device, self.frontCenterStageDevice === device else { return }
                self.publishFrontVideoCenteringState(device)
            }
        } : nil
        publishFrontVideoCenteringState(device)
    }
    /// 官方ROI告诉系统最终保留的裁切区域；否则系统按整张宽缓冲构图，
    /// 人物可能仍落在竖幅成片之外。区域位于未旋转/未镜像的输入坐标内。
    private func updateFrontVideoCenteringRegion(_ device: AVCaptureDevice, deviceLocked: Bool = false) {
        guard frontVideoCenteringRequested, AVCaptureDevice.isCenterStageEnabled,
              device.position == .front, device.activeFormat.isCenterStageSupported else { return }
        guard dualCaptureSource == nil else {
            if device.centerStageRectOfInterest != CGRect(x:0,y:0,width:1,height:1) {
                device.centerStageRectOfInterest = CGRect(x:0,y:0,width:1,height:1)
            }
            return
        }
        guard let size = frontVideoOutputSize() else { return }
        let width = size.width, height = size.height
        guard width > 0, height > 0 else { return }
        let target = look.ratio.portraitRatio
        let rect: CGRect
        if width / height > target {
            let fraction = height * target / width
            rect = CGRect(x:(1-fraction)/2,y:0,width:fraction,height:1)
        } else {
            let fraction = width / target / height
            rect = CGRect(x:0,y:(1-fraction)/2,width:1,height:fraction)
        }
        guard device.centerStageRectOfInterest != rect else { return }
        do {
            if !deviceLocked { try device.lockForConfiguration() }
            defer { if !deviceLocked { device.unlockForConfiguration() } }
            device.centerStageRectOfInterest = rect
        } catch { report("人物居中画幅配置失败：\(error.localizedDescription)") }
    }
    /// 自动配置的输出尺寸与activeFormat标称宽高可能对调，应读取输出实际配置。
    /// 同时用于构图ROI和滤镜缓冲池，避免黑边、方向错误及渲染进错误尺寸的缓冲。
    private func frontVideoOutputSize() -> CGSize? {
        guard let settings = recordingOutput.videoSettings,
              let width = (settings[kCVPixelBufferWidthKey as String] as? NSNumber)?.doubleValue,
              let height = (settings[kCVPixelBufferHeightKey as String] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width:width,height:height)
    }
    private func publishFrontVideoCenteringState(_ device: AVCaptureDevice) {
        let enabled = frontVideoCenteringRequested && videoModeRequested && device.position == .front
        let active = enabled && device.isCenterStageActive
        DispatchQueue.main.async {
            self.frontVideoCenteringEnabled = enabled
            self.frontVideoCenteringActive = active
        }
    }

    private func publishFrontAutoCenteringState(_ device: AVCaptureDevice) {
        guard input?.device === device else { return }
        let revision = smartFramingStateRevision.advance()
        let available: Bool
        let enabled: Bool
        if #available(iOS 26.0, *) {
            available = device.position == .front && device.activeFormat.isSmartFramingSupported
                && device.smartFramingMonitor?.supportedFramings.contains(where: { $0.aspectRatio == .ratio3x4 }) == true
            enabled = available && (device.smartFramingMonitor?.isMonitoring == true)
        } else { available = false; enabled = false }
        DispatchQueue.main.async {
            // 新路线的能力已产生后，旧路线排队的不可用回报不得再次把按钮置灰。
            guard self.smartFramingStateRevision.matches(revision) else { return }
            if self.frontAutoCenteringAvailable != available { self.frontAutoCenteringAvailable = available }
            if self.frontAutoCenteringEnabled != enabled { self.frontAutoCenteringEnabled = enabled }
        }
    }

    func setFrontAutoCentering(_ enabled: Bool, transitionID: UUID? = nil) {
        queue.async {
            guard self.wantsRunning, let device = self.input?.device,
                  device.position == .front else { return }
            if #available(iOS 26.0, *), device.activeFormat.isSmartFramingSupported {
                self.frontAutoCenteringRequested = enabled
                self.refreshFrontSmartFraming()
                if let transitionID { self.markUserPreviewSwitch(transitionID) }
            }
        }
    }

    private func stopFrontSmartFraming() {
        smartFramingRecommendationToken = UUID()
        smartFramingObservation?.invalidate()
        smartFramingObservation = nil
        if #available(iOS 26.0, *) { monitoredFrontDevice?.smartFramingMonitor?.stopMonitoring() }
        monitoredFrontDevice = nil
    }

    private func refreshFrontSmartFraming() {
        guard #available(iOS 26.0, *), let device = input?.device,
              device.position == .front, device.activeFormat.isSmartFramingSupported,
              let monitor = device.smartFramingMonitor else {
            if input?.device.position == .front { frontAutoCenteringRequested = false }
            stopFrontSmartFraming()
            if let device = input?.device { publishFrontAutoCenteringState(device) }
            return
        }
        guard frontAutoCenteringRequested, wantsRunning, session.isRunning else {
            stopFrontSmartFraming()
            publishFrontAutoCenteringState(device)
            return
        }
        // Framing choices were configured before the session started (or whenever
        // the active format changed) by prepareFrontSmartFraming.
        guard !monitor.enabledFramings.isEmpty else { publishFrontAutoCenteringState(device); return }
        guard !monitor.isMonitoring else { publishFrontAutoCenteringState(device); return }
        monitoredFrontDevice = device
        smartFramingObservation = monitor.observe(\.recommendedFraming, options: [.new]) { [weak self] monitor, _ in
            let framing = monitor.recommendedFraming
            self?.queue.async { [weak self] in
                guard let self else { return }
                let token = UUID()
                self.smartFramingRecommendationToken = token
                guard let framing else { return }
                // Briefly settle scene recommendations so an entering/leaving face
                // does not send the front crop back and forth each frame.
                self.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.smartFramingRecommendationToken == token else { return }
                    self.applyFrontSmartFraming(framing, device: device)
                }
            }
        }
        do { try monitor.startMonitoring() }
        catch { stopFrontSmartFraming(); report("前置自动居中暂不可用：\(error.localizedDescription)") }
        publishFrontAutoCenteringState(device)
    }

    @available(iOS 26.0, *)
    private func applyFrontSmartFraming(_ framing: AVCaptureFraming, device: AVCaptureDevice) {
        guard wantsRunning, frontAutoCenteringRequested, input?.device.uniqueID == device.uniqueID,
              device.smartFramingMonitor?.isMonitoring == true else { return }
        let target = CGFloat(framing.zoomFactor)
        guard target.isFinite, target >= device.minAvailableVideoZoomFactor,
              target <= device.maxAvailableVideoZoomFactor,
              abs(device.videoZoomFactor - target) > 0.03 else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: target, withRate: 4)
            device.unlockForConfiguration()
            let base = lensCatalog.first(where: { $0.device.uniqueID == device.uniqueID && $0.frontFraming == .wide })?.displayZoom ?? 1
            let logical = lensCatalog.filter { $0.device.uniqueID == device.uniqueID }
                .min { abs($0.zoomFactor - target) < abs($1.zoomFactor - target) }
            DispatchQueue.main.async {
                self.currentZoom = base * target
                if let logical { self.selectedLens = logical.id }
            }
        } catch { report("前置自动居中调整失败：\(error.localizedDescription)") }
    }

    /// A transaction can replace the output connections at commit. Apply these
    /// to the committed graph as well, without restarting session configuration.
    private func configureOutputConnections(_ device: AVCaptureDevice) {
        var portraitFrontSensor = false
        if #available(iOS 26.0, *), device.position == .front {
            portraitFrontSensor = photoOutput.isCameraSensorOrientationCompensationSupported || !device.activeFormat.supportedDynamicAspectRatios.isEmpty
            // Center Stage的视频格式不一定公开照片方向补偿能力；按设备的动态画幅能力
            // 识别新传感器，避免切到居中视频格式时丢掉官方方向协调器。
            if frontVideoCenteringRequested && device.formats.contains(where: { !$0.supportedDynamicAspectRatios.isEmpty }) {
                portraitFrontSensor = true
            }
            if photoOutput.isCameraSensorOrientationCompensationSupported {
                // Handle the new native portrait sensor consistently with preview,
                // instead of combining the legacy compensation with a 90° turn.
                photoOutput.isCameraSensorOrientationCompensationEnabled = false
            }
        }
        if portraitFrontSensor {
            if frontPhotoRotationCoordinator?.device?.uniqueID != device.uniqueID {
                frontPhotoRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
        } else {
            frontPhotoRotationCoordinator = nil
        }
        if device.position == .back {
            if rearCaptureRotationCoordinator?.device?.uniqueID != device.uniqueID {
                rearCaptureRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
        } else { rearCaptureRotationCoordinator = nil }
        for output in [videoOutput as AVCaptureOutput, recordingOutput as AVCaptureOutput, photoOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // Preview mirroring is applied in Core Image, atomically with portrait orientation.
                connection.isVideoMirrored = output === photoOutput && device.position == .front
            }
            let angle: CGFloat = output === videoOutput || output === recordingOutput || (portraitFrontSensor && output === photoOutput) ? 0 : 90
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if output !== photoOutput, connection.isVideoStabilizationSupported {
                applyVideoStabilization(to: connection, device: device)
            }
            // 配置前置照片路线时，按能力开启官方内参交付；其他路线不额外请求。
            if output === videoOutput {
                let wantsIntrinsics = portraitFrontSensor && !videoModeRequested
                if wantsIntrinsics && connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                } else if connection.isCameraIntrinsicMatrixDeliveryEnabled {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = false
                }
            }

        }
        publishVideoStabilizationAvailability(device: device)
    }

    private func publishCapabilities(_ device: AVCaptureDevice, lensID: String, zoomRequest: UInt64? = nil) {
        publishFrontVideoCenteringState(device)
        let revision = capabilityRevision.advance()
        let format = device.activeFormat
        let minimum = CMTimeGetSeconds(format.minExposureDuration)
        let maximum = CMTimeGetSeconds(format.maxExposureDuration)
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum,
              format.minISO.isFinite, format.maxISO.isFinite, format.minISO > 0, format.maxISO >= format.minISO else {
            report("镜头参数暂时不可用，请稍后重试。")
            return
        }
        let minDuration = max(minimum, 1.0 / 16000)
        let activeVideoRate = requestedVideoSettings.captureFrameRate ?? requestedVideoSettings.frameRate
        let maxDuration = max(minDuration, min(maximum, videoModeRequested ? 1 / Double(activeVideoRate.rawValue) : 1))
        let isoRange = Double(format.minISO)...Double(max(format.maxISO, format.minISO + 1))
        let shutterRange = log2(minDuration)...max(log2(maxDuration), log2(minDuration) + 0.001)
        let exposure = device.isExposureModeSupported(.custom)
        let focus = device.isLockingFocusWithCustomLensPositionSupported
        let targetFocus = device.isFocusModeSupported(.locked)
        let whiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        let flash = device.hasFlash
        let base = device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device) : (lensCatalog.first(where: { $0.device.uniqueID == device.uniqueID }).map { $0.displayZoom / $0.zoomFactor } ?? 1)
        let zoom = base * device.videoZoomFactor
        let zoomRange: ClosedRange<CGFloat>
        if #available(iOS 26.0, *),videoModeRequested,requestedCinematicVideo,format.isCinematicVideoCaptureSupported {
            let lower = max(device.position == .back ? 1:0,base*max(device.minAvailableVideoZoomFactor,format.videoMinZoomFactorForCinematicVideo))
            let upper = min(device.position == .back ? 3:40,base*min(device.maxAvailableVideoZoomFactor,format.videoMaxZoomFactorForCinematicVideo))
            zoomRange = lower...max(lower,upper)
        } else if device.isVirtualDevice {
            let available = automaticUnrestrictedZoomRange ?? (device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor)
            let low = base * available.lowerBound
            let high = min(40, base * available.upperBound)
            guard low.isFinite, high.isFinite, low > 0 else { return }
            zoomRange = low...max(low, high)
        } else if manualMode, let anchor = lensCatalog.first(where: { $0.id == lensID }) {
            zoomRange = ManualZoomPolicy.range(anchor: anchor.displayZoom, physicalBase: anchor.displayZoom / anchor.zoomFactor,
                                               minimum: device.minAvailableVideoZoomFactor, maximum: device.maxAvailableVideoZoomFactor)
        } else { zoomRange = ContinuousZoomPolicy.range(zoomCapabilities(position: device.position)) }
        // All AVFoundation reads happen on the session queue; the main queue only publishes values.
        DispatchQueue.main.async {
            guard self.capabilityRevision.matches(revision) else { return }
            if let request = zoomRequest, !self.zoomRevision.matches(request) { return }
            self.isoRange = isoRange; self.shutterRange = shutterRange
            self.supportsExposure = exposure; self.supportsFocus = focus; self.supportsTargetFocusLock = targetFocus
            self.supportsWB = whiteBalance; self.supportsFlash = flash
            self.selectedLens = lensID
            if self.activeCaptureDeviceID != device.uniqueID { self.activeCaptureDeviceID = device.uniqueID }
            if !self.continuousZoomActive, zoom.isFinite, zoom > 0 { self.currentZoom = zoom }
            self.continuousZoomRange = zoomRange
        }
    }

    private func captureDevice(for lens: CameraLens, forcePhysical: Bool = false) -> AVCaptureDevice {
        if videoModeRequested {
            if videoNeedsPhysicalInput { return lens.device }
            if requestedCinematicVideo, let device = cinematicCaptureDevice(for: lens.device.position) { return device }
        }
        if forcePhysical, lens.device.position == .back { return lens.device }
        // 48MP固定原生物理镜头，不能在A挡切回仅交付低像素的虚拟路由。
        if highResolutionPhotoRequested, lens.device.position == .back {
            return lens.device
        }
        if lens.device.position == .back, !manualMode, let virtual = rearVirtualDevice { return virtual }
        return lens.device
    }

    /// 部分物理规格并未由虚拟多摄公开；保留用户规格，仅在需要时使用兼容物理输入。
    private var videoNeedsPhysicalInput: Bool {
        guard videoModeRequested, !requestedCinematicVideo else { return false }
        if requestedVideoSettings.isRAW || requestedVideoSettings.captureFrameRate != nil { return true }
        guard let device = rearVirtualDevice, let row = videoSelectionDeviceCache[device.uniqueID] else { return false }
        let values = requestedVideoOpenGate ? row.openGate : row.ordinary
        return !values.contains { $0.resolution == requestedVideoSettings.resolution
            && $0.frameRate == requestedVideoSettings.frameRate && $0.colorSpace == requestedVideoSettings.colorSpace }
    }

    /// 选用公开支持 Cinematic 的设备；其他自动模式继续使用原有虚拟多摄。
    private lazy var frontCinematicDevice: AVCaptureDevice? = {
        guard #available(iOS 26.0, *) else { return nil }
        // 新一代前置电影能力由超广角提供，TrueDepth 不一定公布电影格式。
        // 按公开格式能力选设备并缓存，避免使用机型名称推测或每次点按重复扫描。
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera,
            .builtInTrueDepthCamera, .builtInWideAngleCamera], mediaType: .video, position: .front).devices
        return devices.first { $0.deviceType == .builtInUltraWideCamera && $0.formats.contains(where: \.isCinematicVideoCaptureSupported) }
            ?? devices.first { $0.formats.contains(where: \.isCinematicVideoCaptureSupported) }
    }()

    private func cinematicCaptureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard #available(iOS 26.0, *) else { return nil }
        switch position {
        case .back:
            return AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
        case .front:
            return frontCinematicDevice
        default:
            return nil
        }
    }
    private func applyZoom(_ lens: CameraLens) throws {
        let device = captureDevice(for: lens)
        resumeAutomaticLensSelectionForUserZoom(device)
        // 前置普通/广角是同一传感器的宽窄取景；电影使用 TrueDepth 虚拟设备时
        // 也保留实际取景倍率，不能套用后置的显示倍率换算把两者都钳制到 1×。
        let factor = device.position == .front ? lens.zoomFactor
            : device.isVirtualDevice ? lens.displayZoom / CameraLensCatalog.displayMultiplier(device) : lens.zoomFactor
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    /// Initialize the destination virtual route before it starts producing frames.
    /// Keep automatic lens selection; no forced constituent or timed lock.
    private func prepareAutomaticRoute(_ device: AVCaptureDevice, factor: CGFloat) throws {
        guard !manualMode, device.isVirtualDevice else { return }
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        restoreDefaultAutoExposureLimit(device)
        device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if #available(iOS 26.0, *), requestedCinematicVideo || input?.isCinematicVideoCaptureEnabled == true {
            // Cinematic 自己选择并跟踪主体；再写普通 AF 中心点会把焦点从主体抢到背景。
        } else {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x:0.5,y:0.5) }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x:0.5,y:0.5) }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }

    func setManualMode(_ enabled: Bool, customExposure: Bool = false) {
        let target = currentZoom
        let selectedAnchorID = selectedLens
        let position = lenses.first(where: { $0.id == selectedLens })?.device.position ?? .back
        let revision = zoomRevision.advance()
        // Changing the capture route preserves the logical focal length and parameter preferences.
        continuousZoomActive = true
        // Old wheel events must not rebuild an intermediate route during a mode change.
        zoomThrottle.cancel()
        queue.async {
            guard self.manualMode != enabled else { return }
            self.stopFocusNavigatorOnQueue()
            defer { self.syncPreviewState(); self.refreshHDRPreviewConfiguration() }
            self.manualMode = enabled
            if self.dualCaptureSource != nil {
                self.customExposureRequested = enabled && customExposure
                return // 双拍保持自己的输入图，不能重建已停止的普通会话。
            }
            // A-mode's latched slow-preview decision belongs to its current AE run.
            // Re-evaluate it after the mode switch instead of carrying a stale cap.
            self.slowShutterAutoPreviewOptimizationActive = false
            self.manualZoomAnchorID = enabled ? selectedAnchorID : nil
            if let device = self.input?.device {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    self.restoreDefaultAutoExposureLimit(device)
                } catch { self.report("恢复相机曝光范围失败：\(error.localizedDescription)") }
            }
            // Connections must be configured for the destination exposure policy, not the
            // previous mode. Otherwise an input swap toggles streaming HDR off then on again.
            self.customExposureRequested = enabled && customExposure
            #if !targetEnvironment(simulator)
            guard self.configured, self.wantsRunning else { return }
            if position != .back {
                if let device = self.input?.device { self.publishCapabilities(device, lensID: selectedAnchorID) }
                return
            }
            if self.highResolutionPhotoRequested, !self.videoModeRequested {
                self.continuousZoomActive = false
                if let device = self.input?.device { self.configureConnections(device:device) }
            } else {
                self.manualModeTransitionInFlight = true
                self.applyContinuousZoom(ZoomRequest(value: target, position: position, revision: revision))
                self.manualModeTransitionInFlight = false
            }
            if let device = self.input?.device {
                self.publishCapabilities(device, lensID: self.manualZoomAnchorID ?? selectedAnchorID)
            }
            // Signal that the next accepted frame belongs to the new capture route.
            // No resizing or crop animation is needed when opening a popup during this transition.
            let running = self.session.isRunning
            DispatchQueue.main.async {
                guard self.zoomRevision.matches(revision) else { return }
                // 用户切换路线时保留上一帧；最终路由帧标识负责结束既有局部过渡。
                // 清空会使慢快门/前置重配期间误显示首次启动的“正在准备相机”。
                self.ready = running
            }
            #endif
        }
    }

    /// Limit automatic exposure's longest frame for slow-shutter presets. If live AE
    /// selects a frame slower than the viewfinder cadence, preview is temporarily capped
    /// and the preset ceiling is restored for the still capture.
    func setAutomaticExposureDurationLimit(_ maximumSeconds: Double?) {
        queue.async {
            let requested = maximumSeconds.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            let previous = self.slowShutterAutomaticExposureMaximumSeconds
            let presetChanged: Bool
            if let previous, let requested {
                presetChanged = abs(previous - requested) > 0.000_001
            } else {
                presetChanged = previous != nil || requested != nil
            }
            self.slowShutterAutomaticExposureMaximumSeconds = requested
            if presetChanged { self.slowShutterAutoPreviewOptimizationActive = false }
            guard !self.videoModeRequested, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                guard !self.manualMode, let requested else {
                    self.slowShutterAutoPreviewOptimizationActive = false
                    if self.manualMode {
                        self.applyManualPreviewExposurePolicy(device)
                    } else {
                        self.restoreDefaultAutoExposureLimit(device)
                    }
                    return
                }
                if !self.slowShutterPreviewOptimizationRequested {
                    self.slowShutterAutoPreviewOptimizationActive = false
                } else if SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
                    currentExposureSeconds: CMTimeGetSeconds(device.exposureDuration),
                    presetMaximumSeconds: requested) {
                    self.slowShutterAutoPreviewOptimizationActive = true
                }
                self.applyAutomaticSlowShutterExposureLimit(requested, to: device)
            } catch {
                self.report("慢门预设应用失败：\(error.localizedDescription)")
            }
        }
    }

    /// 仅选中慢门预设时自动优化预览：A 挡等待实际 AE 达到 1/15 秒，M 挡按请求快门判断。
    /// 触发门限与 1/30 秒预览上限分开；静态拍摄仍恢复用户请求的快门和 ISO。
    func setSlowShutterPreviewOptimization(_ enabled: Bool) {
        queue.async {
            self.slowShutterPreviewOptimizationRequested = enabled
            if !enabled { self.slowShutterAutoPreviewOptimizationActive = false }
            guard !self.videoModeRequested, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                if self.manualMode {
                    self.applyManualPreviewExposurePolicy(device)
                } else if let maximum = self.slowShutterAutomaticExposureMaximumSeconds {
                    if enabled && SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
                        currentExposureSeconds: CMTimeGetSeconds(device.exposureDuration),
                        presetMaximumSeconds: maximum) {
                        self.slowShutterAutoPreviewOptimizationActive = true
                    }
                    self.applyAutomaticSlowShutterExposureLimit(maximum, to: device)
                }
            } catch { self.report("慢门预览优化失败：\(error.localizedDescription)") }
        }
    }

    private func applyAutomaticSlowShutterExposureLimit(_ requested: Double, to device: AVCaptureDevice) {
        let desired = slowShutterAutoPreviewOptimizationActive
            ? min(requested, previewExposureAssistMaximumDuration)
            : requested
        applyExposureDurationLimit(desired, to: device)
    }

    private func applyExposureDurationLimit(_ requested: Double, to device: AVCaptureDevice) {
        let formatMaximum = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let minimum = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        guard requested.isFinite, formatMaximum.isFinite, minimum.isFinite,
              requested > 0, formatMaximum > 0, minimum > 0 else { return }
        device.activeMaxExposureDuration = CMTime(seconds: min(max(requested, minimum), formatMaximum),
                                                  preferredTimescale: 1_000_000_000)
    }

    private func activateAutomaticSlowShutterPreviewOptimizationIfNeeded(deviceID: String, exposureSeconds: Double) {
        guard slowShutterPreviewOptimizationRequested, !slowShutterAutoPreviewOptimizationActive,
              !manualMode, !videoModeRequested, captureContexts.isEmpty,
              let maximum = slowShutterAutomaticExposureMaximumSeconds,
              let device = input?.device, device.uniqueID == deviceID,
              SlowShutterPreviewPolicy.shouldAutomaticallyAssist(
                currentExposureSeconds: exposureSeconds,
                presetMaximumSeconds: maximum) else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            slowShutterAutoPreviewOptimizationActive = true
            applyAutomaticSlowShutterExposureLimit(maximum, to: device)
        } catch { report("慢门预览优化失败：\(error.localizedDescription)") }
    }

    private func reusableInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        if let cached = reusableInputs[device.uniqueID] { return cached }
        let created = try AVCaptureDeviceInput(device: device)
        reusableInputs[device.uniqueID] = created
        return created
    }

    /// 移除并缓存输入前先关闭 Cinematic，避免复用输入时带入旧会话的电影状态。
    private func disableCinematicCapture(on captureInput: AVCaptureInput?) {
        guard #available(iOS 26.0, *),
              let deviceInput = captureInput as? AVCaptureDeviceInput,
              deviceInput.isCinematicVideoCaptureEnabled else { return }
        deviceInput.isCinematicVideoCaptureEnabled = false
    }

    /// Called after explicit user configuration, never from automatic constituent changes.
    func completeUserPreviewSwitch(_ id: UUID) {
        queue.async { self.markUserPreviewSwitch(id) }
    }
    private func markUserPreviewSwitch(_ id: UUID) {
        let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        livePreviewState.update { $0.userSwitchID = id; $0.framesNotBefore = cutoff }
    }

    /// A/M 48MP均保留当前支持的原生镜头；从裁切倍率进入时回到同传感器原生焦段。
    func setHighResolutionPhotoRequested(_ enabled: Bool) {
        if highResolutionPhotoZoomLocked != enabled { highResolutionPhotoZoomLocked = enabled }
        queue.async { [self] in
            guard self.highResolutionPhotoRequested != enabled else { return }
            self.highResolutionPhotoRequested = enabled
            if !enabled { self.photoOutput.setPreparedPhotoSettingsArray([],completionHandler:nil) }
            let configGeneration = UUID()
            DispatchQueue.main.async {
                self.highResolutionPhotoConfigGeneration = configGeneration
                self.highResolutionPhotoConfiguring = enabled
                if enabled { self.ready = false }
            }
            let eligible = self.lensCatalog.filter { lens in
                lens.device.position == .back && abs(lens.zoomFactor-1)<0.001
                    && [CGFloat(0.5),1,4].contains { abs($0-lens.displayZoom)<0.05 }
                    && lens.device.formats.contains { $0.supportedMaxPhotoDimensions.contains { Int64($0.width)*Int64($0.height)>=40_000_000 } }
            }
            let current = self.lensCatalog.first { $0.id == self.selectedLens }
            let target = enabled
                ? (eligible.first { $0.device.uniqueID == current?.device.uniqueID }
                   ?? eligible.first { abs($0.displayZoom-1)<0.05 } ?? eligible.first)
                : current
            guard !self.videoModeRequested, self.configured,
                  let main = target ?? self.lensCatalog.first(where: {
                      $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
                          && abs($0.displayZoom - 1) < 0.05
                  }) else {
                DispatchQueue.main.async { self.highResolutionPhotoConfiguring = false }
                return
            }
            let revision = self.zoomRevision.advance()
            self.zoomThrottle.cancel()
            self.continuousZoomActive = false
            self.selectLensOnQueue(main, previousID: self.selectedLens, revision: revision,
                                   forcePhysical: enabled)
            if enabled, let current = self.input?.device, current.uniqueID == main.device.uniqueID {
                self.configurePhotoOutput(current)
            }
            if enabled {
                self.prepareHighResolutionPhotoRoute(generation:configGeneration)
            } else {
                DispatchQueue.main.async {
                    guard self.highResolutionPhotoConfigGeneration == configGeneration else { return }
                    self.highResolutionPhotoConfiguring = false
                }
            }
        }
    }

    /// 使用官方资源准备回调，不额外拍摄并丢弃照片。
    private func prepareHighResolutionPhotoRoute(generation:UUID = UUID()) {
        guard let largest = photoDimensions.last else {
            DispatchQueue.main.async { self.highResolutionPhotoConfiguring = false }
            return
        }
        DispatchQueue.main.async {
            self.highResolutionPhotoConfigGeneration = generation
            self.highResolutionPhotoConfiguring = true; self.ready = false
        }
        let settings = photoOutput.availablePhotoCodecTypes.filter { $0 == .jpeg || $0 == .hevc }.map { codec in
            let value = AVCapturePhotoSettings(format:[AVVideoCodecKey:codec])
            value.maxPhotoDimensions = largest; value.photoQualityPrioritization = .balanced; value.flashMode = .off
            return value
        }
        photoOutput.setPreparedPhotoSettingsArray(settings) { [weak self] prepared,error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.highResolutionPhotoConfigGeneration == generation else { return }
                self.highResolutionPhotoConfiguring = false; self.ready = self.session.isRunning
                if let error { self.report("高像素准备失败：\(error.localizedDescription)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+8) {
            guard self.highResolutionPhotoConfigGeneration == generation, self.highResolutionPhotoConfiguring else { return }
            self.highResolutionPhotoConfiguring = false; self.ready = self.session.isRunning
        }
    }

    func selectLens(_ lens: CameraLens, transitionID: UUID? = nil, preservingFrontAutoCentering: Bool = false) {
        guard !highResolutionPhotoZoomLocked || highResolutionLensIDs.contains(lens.id) else { return }
        guard !highResolutionPhotoConfiguring else { return }
        guard !dualCaptureEnabled, !dualCapturePreparing, ready, !capturing, !videoBusy, selectedLens != lens.id || abs(currentZoom - lens.displayZoom) > 0.001 else { return }
        // Don't carry the previous route's macro badge across a deliberate focal
        // selection. The new route will publish its own system-selected state.
        macroActive = false
        let macroRouteGeneration = livePreviewState.beginMacroRouteChange()
        let revision = zoomRevision.advance()
        continuousZoomActive = false
        zoomThrottle.cancel()
        ready = false
        readings = nil
        let previousID = selectedLens
        queue.async { self.selectLensOnQueue(lens, previousID: previousID, revision: revision, transitionID: transitionID,
                                             preservingFrontAutoCentering: preservingFrontAutoCentering,
                                             macroRouteGeneration: macroRouteGeneration) }
    }

    private func selectLensOnQueue(_ lens: CameraLens, previousID: String, revision: UInt64, retry: Int = 0,
                                   transitionID: UUID? = nil, preservingFrontAutoCentering: Bool = false,
                                   macroRouteGeneration: UInt64? = nil, forcePhysical: Bool = false) {
        stopFocusNavigatorOnQueue()
        #if DEBUG
        // 分别记录会话阶段耗时，与首帧/过渡耗时区分；不将此值当作屏幕 FPS。
        let isFacingSwitch = input?.device.position != lens.device.position
        let switchStartedAt = CACurrentMediaTime()
        var phaseStartedAt = switchStartedAt
        var phases: [String: Double] = [:]
        func markPhase(_ key: String) {
            let now = CACurrentMediaTime()
            phases[key] = now - phaseStartedAt; phaseStartedAt = now
        }
        defer {
            phases["total"] = CACurrentMediaTime() - switchStartedAt
            if isFacingSwitch { lastLensSwitchPhasesForTesting = phases }
        }
        #endif
        guard wantsRunning, zoomRevision.matches(revision) else {
            if let macroRouteGeneration { livePreviewState.finishMacroRouteChange(generation: macroRouteGeneration) }
            return
        }
        if frontAutoCenteringRequested && !preservingFrontAutoCentering {
            frontAutoCenteringRequested = false
            stopFrontSmartFraming()
        }
        if frontVideoCenteringRequested && !preservingFrontAutoCentering { stopFrontVideoCentering() }
        let candidate = captureDevice(for: lens, forcePhysical: forcePhysical)
        if !manualMode, candidate.isVirtualDevice {
            resumeAutomaticLensSelectionForUserZoom(candidate)
            let factor = lens.displayZoom / CameraLensCatalog.displayMultiplier(candidate)
            if factor < candidate.minAvailableVideoZoomFactor - 0.0001, retry < 20 {
                queue.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                    self?.selectLensOnQueue(lens, previousID: previousID, revision: revision, retry: retry + 1,
                                            transitionID: transitionID, preservingFrontAutoCentering: preservingFrontAutoCentering,
                                            macroRouteGeneration: macroRouteGeneration)
                }
                return
            }
        }
        let previousAnchor = self.manualZoomAnchorID
        if self.manualMode { self.manualZoomAnchorID = lens.id }
        // A single SDR, non-Live graph transaction avoids starting intermediate
        // input-only and preview-only graphs. HDR and Live keep their required
        // format/recorder ordering.
        // 视频换镜统一先装好目标输入、最终格式及输出图，再一次提交。
        // 避免慢动作换镜时先启动普通帧率的中间输入，随后再停下来切到 120/240 帧。
        let specializedVideoRoute = videoModeRequested
            && (requestedCinematicVideo || requestedVideoSettings.captureFrameRate != nil)
        let batchReplacement = (input?.device.position != lens.device.position || videoModeRequested || highResolutionPhotoRequested) &&
            !livePreviewRequested && !photoOutput.isLivePhotoCaptureEnabled &&
            !heifHDRPipelineRequested && hdrPreviewSource == nil
        var replacementTransactionOpen = false
        defer { if replacementTransactionOpen { session.commitConfiguration() } }
        do {
            let device = self.captureDevice(for: lens)
            let changedDevice = self.input?.device.uniqueID != device.uniqueID
            let wasUnit = abs(device.videoZoomFactor - 1) < 0.001
            if changedDevice {
                self.prepareHDRForInputReplacement()
                self.livePreviewState.update {
                    $0.acceptsFrames = false
                    $0.macroNotBefore = CACurrentMediaTime() + 0.6
                }
                let newInput = try self.reusableInput(for: device)
                self.session.beginConfiguration()
                replacementTransactionOpen = true
                if let old = self.input {
                    self.disableCinematicCapture(on: old)
                    self.session.removeInput(old)
                }
                guard self.session.canAddInput(newInput) else {
                    if let old = self.input { self.session.addInput(old) }
                    self.session.commitConfiguration()
                    replacementTransactionOpen = false
                    throw CameraError.unavailable
                }
                self.session.addInput(newInput)
                self.input = newInput
                if self.heifHDRPipelineRequested, self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                // The batched path already writes target zoom before its only
                // commit. Avoid restarting a healthy A-mode AF/AE controller.
                if !batchReplacement || specializedVideoRoute {
                    let routeFactor = device.isVirtualDevice ? lens.displayZoom / CameraLensCatalog.displayMultiplier(device) : lens.zoomFactor
                    try self.prepareAutomaticRoute(device, factor:routeFactor)
                }
                if !batchReplacement { self.session.commitConfiguration(); replacementTransactionOpen = false }
            }
            #if DEBUG
            markPhase("input")
            #endif
            try self.applyZoom(lens)
            // Configure the replacement connections before publishing route readiness.
            if changedDevice { self.configureConnections(device: device) }
            #if DEBUG
            markPhase("connections")
            #endif
            if changedDevice || wasUnit != (abs(device.videoZoomFactor - 1) < 0.001) {
                let newDimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }
                let dimensionsMatch = newDimensions.map { "\($0.width)x\($0.height)" } == photoDimensions.map { "\($0.width)x\($0.height)" }
                if highResolutionPhotoRequested && dimensionsMatch {
                    // 换输入可能关闭 ProRAW；不能绕过会话事务直接改 output。
                    if self.photoOutput.isAppleProRAWSupported && !self.photoOutput.isAppleProRAWEnabled {
                        self.configurePhotoOutput(device, publish: false)
                    }
                    if let largest = newDimensions.last,
                       self.photoOutput.maxPhotoDimensions.width != largest.width
                        || self.photoOutput.maxPhotoDimensions.height != largest.height {
                        self.photoOutput.maxPhotoDimensions = largest
                    }
                } else {
                    self.configurePhotoOutput(device, publish: !batchReplacement)
                }
            }
            #if DEBUG
            markPhase("photoOutput")
            #endif
            if replacementTransactionOpen {
                self.session.commitConfiguration()
                replacementTransactionOpen = false
                #if DEBUG
                markPhase("commitAPI")
                #endif
                // Connections can be recreated when the complete graph commits.
                self.configureOutputConnections(device)
                self.refreshFrontSmartFraming()
                #if DEBUG
                markPhase("outputConnections")
                #endif
                // 视频换镜不发布尚未恢复照片格式的中间照片能力，避免界面触发额外参数协调。
                if !self.videoModeRequested { self.publishPhotoCapabilities(device) }
                self.syncPreviewState()
            }
            #if DEBUG
            markPhase("commit")
            #endif
            // 会话提交可能重置 fallback 子集；只在完成用户路由切换时恢复公开候选，
            // 不按距离或定时干预系统的实际选镜。
            self.configureAutomaticLensPolicy(device)
            self.syncPreviewState()
            if self.session.isRunning && !self.session.isInterrupted {
                let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                self.livePreviewState.update { $0.framesNotBefore = cutoff; $0.acceptsFrames = true }
            }
            if let macroRouteGeneration { self.livePreviewState.finishMacroRouteChange(generation: macroRouteGeneration) }
            self.configureRecordingHaptics()
            self.publishCapabilities(device, lensID: lens.id)
            // 主摄/长焦的高像素 prepared settings 可复用；超广角切换后必须重新准备，
            // 否则 0.5× 会退回 12MP。
            if self.highResolutionPhotoRequested, !forcePhysical, changedDevice,
               lens.device.deviceType == .builtInUltraWideCamera {
                self.prepareHighResolutionPhotoRoute()
            }
            if let transitionID { self.markUserPreviewSwitch(transitionID) }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                // 保留最近取景直到新路由出帧，不能在提交后再次清空已发布的新画面。
                // 不改变帧接收门限、真实错误恢复或用户切镜的旧帧淡出逻辑。
                self.ready = running
            }
        } catch {
            if replacementTransactionOpen {
                self.session.commitConfiguration()
                replacementTransactionOpen = false
            }
            self.manualZoomAnchorID = previousAnchor
            if let device = self.input?.device {
                self.configureConnections(device: device)
                let actual = self.lensCatalog.filter { $0.device.uniqueID == device.uniqueID }
                    .min { abs($0.zoomFactor - device.videoZoomFactor) < abs($1.zoomFactor - device.videoZoomFactor) }
                self.publishCapabilities(device, lensID: actual?.id ?? previousID)
            }
            self.syncPreviewState()
            if let macroRouteGeneration { self.livePreviewState.finishMacroRouteChange(generation: macroRouteGeneration) }
            self.report("切换镜头失败：\(error.localizedDescription)")
            DispatchQueue.main.async { self.ready = self.session.isRunning }
        }

    }

    private func zoomCapabilities(position: AVCaptureDevice.Position) -> [LensZoomCapabilities] {
        var seen = Set<String>()
        return lensCatalog.filter { $0.device.position == position }.compactMap { lens in
            guard seen.insert(lens.device.uniqueID).inserted else { return nil }
            // 连续变焦也保留视频规格；慢动作 A 挡切物理输入时不得绕过焦段按钮的能力筛选。
            if videoModeRequested, let row = videoSelectionDeviceCache[lens.device.uniqueID] {
                let values = requestedVideoSettings.isRAW ? row.raw : requestedCinematicVideo ? row.cinematic
                    : requestedVideoOpenGate ? row.openGate : requestedVideoSettings.captureFrameRate != nil ? row.slowMotionCaptureRates : row.ordinary
                let rate = requestedVideoSettings.captureFrameRate ?? requestedVideoSettings.frameRate
                guard values.contains(where: { $0.resolution == requestedVideoSettings.resolution && $0.frameRate == rate
                    && $0.colorSpace == requestedVideoSettings.colorSpace }) else { return nil }
            }
            return LensZoomCapabilities(id: lens.device.uniqueID, baseZoom: lens.displayZoom / lens.zoomFactor,
                                        minimum: lens.device.minAvailableVideoZoomFactor, maximum: lens.device.maxAvailableVideoZoomFactor,
                                        nativeFactors: lens.device.activeFormat.secondaryNativeResolutionZoomFactors)
        }
    }

    func setContinuousZoom(_ value: CGFloat, transitionID: UUID? = nil, smooth:Bool = false) {
        guard !highResolutionPhotoZoomLocked || videoRecording else { return }
        guard !dualCaptureEnabled, !dualCapturePreparing, ready, !capturing,
              (!videoBusy || videoRecording), !videoConfiguring, value.isFinite else { return }
        let revision = zoomRevision.advance()
        continuousZoomActive = true
        let range: ClosedRange<CGFloat> = videoRecording ? (videoRecordingZoomRange ?? continuousZoomRange) : (demo ? 1...5 : continuousZoomRange)
        let target = min(max(value, range.lowerBound), range.upperBound)
        currentZoom = target
        if demo { continuousZoomRange = 1...5 }
        let position = lenses.first(where: { $0.id == selectedLens })?.device.position ?? .back
        zoomThrottle.submit(ZoomRequest(value: target, position: position, revision: revision, transitionID: transitionID,smooth:smooth))
    }

    func flushRestoredZoom(completion: @escaping () -> Void) {
        queue.async {
            self.zoomThrottle.flush()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func zoomDisplayBase(_ device: AVCaptureDevice) -> CGFloat {
        device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device)
            : (lensCatalog.first { $0.device.uniqueID == device.uniqueID }.map { $0.displayZoom / $0.zoomFactor } ?? 1)
    }
    private func recordingZoomRange(for device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let base = zoomDisplayBase(device)
        var minimum = device.minAvailableVideoZoomFactor, maximum = device.maxAvailableVideoZoomFactor
        if #available(iOS 26.0, *), requestedCinematicVideo {
            minimum = max(minimum, device.activeFormat.videoMinZoomFactorForCinematicVideo)
            maximum = min(maximum, device.activeFormat.videoMaxZoomFactorForCinematicVideo)
        }
        let lower = base * minimum, upper = min(40, base * maximum)
        return lower...max(lower, upper)
    }
    private func applyRecordingZoom(_ request: ZoomRequest, device: AVCaptureDevice) {
        guard device.position == request.position else { return }
        let range = recordingZoomRange(for: device), base = zoomDisplayBase(device)
        let target = min(max(request.value, range.lowerBound), range.upperBound)
        let factor = min(max(target / base, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            if request.smooth { device.ramp(toVideoZoomFactor: factor, withRate: 4) }
            else { if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }; device.videoZoomFactor = factor }
            device.unlockForConfiguration()
            let anchors = lensCatalog.filter {
                $0.device.position == request.position && range.contains($0.displayZoom)
                    && (device.isVirtualDevice || $0.device.uniqueID == device.uniqueID)
            }
            let anchor = anchors.filter { $0.displayZoom <= target + 0.001 }.max { $0.displayZoom < $1.displayZoom } ?? anchors.first
            DispatchQueue.main.async {
                guard self.zoomRevision.matches(request.revision) else { return }
                if abs(self.currentZoom - target) > 0.0001 { self.currentZoom = target }
                if self.videoRecordingZoomRange != range { self.videoRecordingZoomRange = range }
                if let anchor { self.selectedLens = anchor.id }
            }
        } catch { report("变焦失败：\(error.localizedDescription)") }
    }

    private func applyContinuousZoom(_ request: ZoomRequest, retry: Int = 0) {
        guard !highResolutionPhotoRequested || videoModeRequested else { return }
        guard zoomRevision.matches(request.revision) else { return }
        if request.position == .front, frontAutoCenteringRequested {
            frontAutoCenteringRequested = false
            stopFrontSmartFraming()
            if let device = input?.device { publishFrontAutoCenteringState(device) }
        }
        #if targetEnvironment(simulator)
        demoZoom = request.value
        renderDemo()
        #else
        guard wantsRunning else { return }
        if videoModeRequested && videoBusy {
            guard let device = input?.device, device.uniqueID == recordingZoomDeviceID else { return }
            applyRecordingZoom(request, device: device)
            return
        }
        if let graph = focusNavigatorGraph {
            if request.position == .back, request.value >= 8 {
                do {
                    try graph.main.lockForConfiguration()
                    graph.main.videoZoomFactor = min(max(request.value / graph.mainBase, graph.main.minAvailableVideoZoomFactor), graph.main.maxAvailableVideoZoomFactor)
                    graph.main.unlockForConfiguration()
                    focusNavigatorZoom = request.value; syncPreviewState(); if let id = request.transitionID { markUserPreviewSwitch(id) }
                } catch { report(error.localizedDescription) }
                return
            }
            stopFocusNavigatorOnQueue()
        }
        // 不由虚拟多摄支持的视频规格在 A 挡也保留兼容物理输入，变焦和 M→A 不能悄悄降规格。
        let physicalVideoRoute = videoNeedsPhysicalInput
        if !manualMode, !physicalVideoRoute, !requestedCinematicVideo, request.position == .back, let virtual = rearVirtualDevice {
            resumeAutomaticLensSelectionForUserZoom(virtual)
        }
        // The active virtual device owns its zoom limits. Inactive physical
        // constituents can expose different format limits and must not clamp it.
        var target = request.value
        let device: AVCaptureDevice
        let factor: CGFloat
        let anchor: CameraLens
        if #available(iOS 26.0, *),videoModeRequested,requestedCinematicVideo,
           let cinematic = cinematicCaptureDevice(for:request.position) {
            device = cinematic
            let multiplier = cinematic.isVirtualDevice ? CameraLensCatalog.displayMultiplier(cinematic)
                : (lensCatalog.first { $0.device.uniqueID == cinematic.uniqueID }.map { $0.displayZoom/$0.zoomFactor } ?? 1)
            let format = cinematic.activeFormat
            let lower = max(request.position == .back ? 1:0,multiplier*max(cinematic.minAvailableVideoZoomFactor,format.videoMinZoomFactorForCinematicVideo))
            let upper = min(request.position == .back ? 3:40,multiplier*min(cinematic.maxAvailableVideoZoomFactor,format.videoMaxZoomFactorForCinematicVideo))
            target = min(max(target,lower),max(lower,upper)); factor = target/multiplier
            let anchors = lensCatalog.filter { $0.device.position == request.position && (request.position != .back || abs($0.displayZoom-1)<0.001 || abs($0.displayZoom-2)<0.001) }
            guard let selected = anchors.filter({ $0.displayZoom<=target+0.001 }).max(by:{ $0.displayZoom<$1.displayZoom }) ?? anchors.first else { return }
            anchor = selected
        } else if request.position == .back, !manualMode, !physicalVideoRoute, !livePreviewRequested,
                  let virtual = rearVirtualDevice {
            let multiplier = CameraLensCatalog.displayMultiplier(virtual)
            let minimum = automaticUnrestrictedZoomRange?.lowerBound ?? virtual.minAvailableVideoZoomFactor
            let maximum = automaticUnrestrictedZoomRange?.upperBound ?? virtual.maxAvailableVideoZoomFactor
            let displayMinimum = multiplier * virtual.minAvailableVideoZoomFactor
            // 虚拟多摄的最小 zoomFactor 可能仍是1；此时0.5×必须落到物理超广角，
            // 否则会不断重试并被夹回1×。
            if target < displayMinimum - 0.0001,
               let ultra = lensCatalog.first(where: { $0.device.position == .back
                   && $0.device.deviceType == .builtInUltraWideCamera
                   && !$0.device.isVirtualDevice && $0.displayZoom <= 0.55 }) {
                // 用户主动缩到超广角也要释放系统锁定，否则后续长焦/自动切镜会卡在旧虚拟设备。
                resumeAutomaticLensSelectionForUserZoom(virtual)
                device = ultra.device
                let base = ultra.displayZoom / ultra.zoomFactor
                target = min(max(target, 0.5), 1)
                factor = target / base
                anchor = ultra
            } else {
                device = virtual
                target = min(max(target, multiplier * minimum), min(40, multiplier * maximum))
                factor = target / multiplier
                if factor < virtual.minAvailableVideoZoomFactor - 0.0001 || factor > virtual.maxAvailableVideoZoomFactor + 0.0001 {
                    guard retry < 20 else { report("镜头倍率尚未恢复，请重试。"); return }
                    queue.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                        self?.applyContinuousZoom(request, retry: retry + 1)
                    }
                    return
                }
                let anchors = lensCatalog.filter { $0.device.position == .back }
                guard let selected = anchors.filter({ $0.displayZoom <= target + 0.001 }).max(by: { $0.displayZoom < $1.displayZoom }) ?? anchors.first else { return }
                anchor = selected
            }
        } else if manualMode,
                  let fixed = lensCatalog.first(where: { $0.id == manualZoomAnchorID }) ?? lensCatalog.first(where: { $0.device.uniqueID == input?.device.uniqueID }) {
            // Do not re-select either a physical lens or its logical preset while dragging.
            device = fixed.device
            anchor = fixed
            let base = fixed.displayZoom / fixed.zoomFactor
            let pinnedRange = ManualZoomPolicy.range(anchor: fixed.displayZoom, physicalBase: base,
                                                     minimum: device.minAvailableVideoZoomFactor, maximum: device.maxAvailableVideoZoomFactor)
            target = min(max(request.value, pinnedRange.lowerBound), pinnedRange.upperBound)
            factor = target / base
            manualZoomAnchorID = fixed.id
        } else {
            let capabilities = zoomCapabilities(position: request.position)
            let range = ContinuousZoomPolicy.range(capabilities)
            target = min(max(target, range.lowerBound), range.upperBound)
            guard let choice = CameraZoomPolicy.selectContinuous(target, from: capabilities, currentID: input?.device.uniqueID),
                  let lens = lensCatalog.first(where: { $0.device.uniqueID == choice.id }) else { return }
            device = lens.device
            factor = choice.factor
            let anchors = lensCatalog.filter { $0.device.uniqueID == device.uniqueID }
            anchor = anchors.filter { $0.displayZoom <= target + 0.001 }.max { $0.displayZoom < $1.displayZoom } ?? lens
        }
        var replacementTransactionOpen = false
        defer { if replacementTransactionOpen { session.commitConfiguration() } }
        do {
            let changedDevice = input?.device.uniqueID != device.uniqueID
            if changedDevice {
                prepareHDRForInputReplacement()
                livePreviewState.update { $0.acceptsFrames = false }
                let newInput = try reusableInput(for: device)
                session.beginConfiguration()
                replacementTransactionOpen = true
                let old = input
                if let old {
                    disableCinematicCapture(on: old)
                    session.removeInput(old)
                }
                guard session.canAddInput(newInput) else {
                    if let old { session.addInput(old) }
                    session.commitConfiguration()
                    replacementTransactionOpen = false
                    throw CameraError.unavailable
                }
                session.addInput(newInput); input = newInput
                if heifHDRPipelineRequested, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                try prepareAutomaticRoute(device, factor:factor)
                // 普通视频同样必须等目标格式和输出准备好再提交；否则 A/M
                // 换输入会先启动旧输出设置的中间图，引发底层会话错误。
                if !videoModeRequested {
                    session.commitConfiguration()
                    replacementTransactionOpen = false
                }
                configureConnections(device: device)
            }
            let wasUnit = abs(device.videoZoomFactor - 1) < 0.001
            try device.lockForConfiguration()
            if changedDevice, manualMode, !videoModeRequested {
                // 切回 M 挡时可能换到视频流使用过的物理镜头；恢复照片帧节奏，避免继承录像帧率的快门上限。
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
                restoreDefaultAutoExposureLimit(device)
            }
            let boundedFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if request.smooth { device.ramp(toVideoZoomFactor:boundedFactor,withRate:4) }
            else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = boundedFactor
            }
            let isUnit = abs(device.videoZoomFactor - 1) < 0.001
            // Keep sensor crop updates light; restore custom exposure after the wheel settles.
            device.unlockForConfiguration()
            if manualMode && customExposureRequested {
                let deviceID = device.uniqueID
                queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.zoomRevision.matches(request.revision), self.wantsRunning,
                          let current = self.input?.device, current.uniqueID == deviceID else { return }
                    do {
                        try current.lockForConfiguration(); defer { current.unlockForConfiguration() }
                        self.restoreManualExposureAfterZoom(current)
                    } catch { self.report("恢复手动曝光失败：\(error.localizedDescription)") }
                }
            }
            // Photo-output configuration is not a per-frame zoom operation.
            // A/M 过渡只换输入，标准照片沿用既有输出上限；48MP 路由会单独重建。
            if (changedDevice || wasUnit != isUnit)
                && !(manualModeTransitionInFlight && !highResolutionPhotoRequested) {
                configurePhotoOutput(device)
                // Live 输出重配可能重置传感器裁切；保留本次用户变焦目标。
                if livePreviewRequested {
                    // Rebuild the Live preview proxy once for this crop change; the
                    // proxy can otherwise keep the previous 24/35 mm framing.
                    // Restore the requested factor, not the pre-request device value.
                    configuredPreviewRoute = ""
                    configurePreviewOutput(device)
                    restoreZoomAfterLiveReconfiguration(boundedFactor, on: device)
                }
            } else if manualModeTransitionInFlight {
                // 跳过高像素/标准照片的整次输出重建时，系统仍可能在换输入后关闭
                // ProRAW；Capacity 仍显示支持但 rawTypes 为空，HDR/HEIF Pro 会误报。
                if photoOutput.isAppleProRAWSupported && !photoOutput.isAppleProRAWEnabled {
                    configurePhotoOutput(device, publish: false)
                }
            }
            if replacementTransactionOpen {
                session.commitConfiguration()
                replacementTransactionOpen = false
                configureOutputConnections(device)
                syncPreviewState()
            }
            // 同一路由拖动只改倍率；自动策略在上方按需恢复，换输入才重新配置。
            if changedDevice { configureAutomaticLensPolicy(device) }
            if let id = request.transitionID { markUserPreviewSwitch(id) }
            let appliedTarget = target
            DispatchQueue.main.async {
                if self.zoomRevision.matches(request.revision), abs(self.currentZoom - appliedTarget) > 0.001 { self.currentZoom = appliedTarget }
            }
            if changedDevice {
                publishCapabilities(device, lensID: anchor.id)
            } else {
                DispatchQueue.main.async {
                    guard self.zoomRevision.matches(request.revision) else { return }
                    if self.selectedLens != anchor.id { self.selectedLens = anchor.id }
                }
            }
        } catch {
            if replacementTransactionOpen {
                session.commitConfiguration()
                replacementTransactionOpen = false
            }
            if !livePreviewState.snapshot().acceptsFrames, let device = input?.device { configureConnections(device: device) }
            report("变焦失败：\(error.localizedDescription)")
        }
        #endif
    }

    /// Sensor crop changes can alter reported custom ISO. Reapply the user's values,
    /// only when they differ, after the final coalesced wheel event.
    /// Called on the session queue while the device configuration lock is held.
    private func restoreManualExposureAfterZoom(_ device: AVCaptureDevice) {
        guard captureContexts.isEmpty, manualMode, !videoModeRequested, customExposureRequested, let requested = manualExposureValues,
              device.isExposureModeSupported(.custom) else { return }
        if usesSmoothManualPreviewExposure {
            applySmoothPreviewExposure(device)
            return
        }
        applyRequestedManualExposure(requested, to: device)
    }

    private var usesSmoothManualPreviewExposure: Bool {
        // 预览辅助只服务静态照片。偏好可以跨模式保留，但不能把视频 M 挡的真实曝光改成自动。
        guard !videoModeRequested else { return false }
        return previewExposureAssistEnabled || slowShutterSequencePreviewAssistEnabled ||
            (slowShutterPreviewOptimizationRequested && manualMode && !videoModeRequested
                && customExposureRequested
                && SlowShutterPreviewPolicy.manualExposureNeedsAssist(
                    slowShutterEnabled: true,
                    requestedExposureSeconds: manualExposureValues?.seconds ?? 0))
    }

    private func applyRequestedManualExposure(_ requested: (iso: Float, seconds: Double), to device: AVCaptureDevice) {
        let iso = min(max(requested.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let activeVideoRate = requestedVideoSettings.captureFrameRate ?? requestedVideoSettings.frameRate
        let maximum = min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration), videoModeRequested ? 1 / Double(activeVideoRate.rawValue) : 1)
        let seconds = min(max(requested.seconds, CMTimeGetSeconds(device.activeFormat.minExposureDuration)), maximum)
        if manualMode && !videoModeRequested && !usesSmoothManualPreviewExposure {
            updateManualPhotoPreviewFrameDuration(seconds, on: device)
        }
        if device.exposureMode != .custom || abs(device.iso - iso) > max(1, iso * 0.005) || abs(CMTimeGetSeconds(device.exposureDuration) - seconds) > 0.00001 {
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), iso: iso, completionHandler: nil)
        }
    }

    /// M 挡照片快门慢于预览帧周期时放宽视频数据输出的最低帧率限制；较快快门恢复格式默认值。
    private func updateManualPhotoPreviewFrameDuration(_ exposureSeconds: Double, on device: AVCaptureDevice) {
        guard exposureSeconds.isFinite, exposureSeconds > 0 else { return }
        guard exposureSeconds > 1 / 30 else {
            device.activeVideoMaxFrameDuration = .invalid
            return
        }
        let targetFrameRate = 1 / exposureSeconds
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
            targetFrameRate >= $0.minFrameRate && targetFrameRate <= $0.maxFrameRate
        }) else { return }
        let maximumSupportedDuration = CMTimeGetSeconds(range.maxFrameDuration)
        guard maximumSupportedDuration.isFinite, maximumSupportedDuration > 0 else { return }
        device.activeVideoMaxFrameDuration = CMTime(seconds: min(exposureSeconds, maximumSupportedDuration),
                                                    preferredTimescale: 1_000_000_000)
    }

    /// Use automatic ISO and a bounded streaming exposure for a steady viewfinder.
    /// The still capture temporarily reapplies the separately stored manual values.
    private func applySmoothPreviewExposure(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose) else { return }
        let minimum = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maximum = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return }
        let limitedDuration = min(max(previewExposureAssistMaximumDuration, minimum), maximum)
        device.activeVideoMaxFrameDuration = .invalid
        device.activeMaxExposureDuration = CMTime(seconds: limitedDuration, preferredTimescale: 1_000_000_000)
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        else { device.exposureMode = .autoExpose }
        let bias = min(max(exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        if abs(device.exposureTargetBias - bias) > 0.01 {
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
    }

    private func restoreDefaultAutoExposureLimit(_ device: AVCaptureDevice) {
        device.activeMaxExposureDuration = .invalid
    }

    /// 手动长曝光可能改变视频帧时长；照片恢复AE时归还格式默认值，录像帧率完全不动。
    private func restoreAutomaticPhotoFrameDurations(_ device: AVCaptureDevice) {
        guard !videoModeRequested else { return }
        device.activeVideoMinFrameDuration = .invalid
        device.activeVideoMaxFrameDuration = .invalid
    }

    /// 从硬件模式变更后请求一次新采样并短暂加快回传，丢弃此前排队的旧读数，不伪造自动数值。
    private func refreshAutomaticParameterReadings() {
        guard !videoModeRequested else { return }
        livePreviewState.update {
            $0.readingsRefreshRevision &+= 1
            $0.readingsFastUntil = CACurrentMediaTime()+1.5
        }
    }


    private func applyManualPreviewExposurePolicy(_ device: AVCaptureDevice) {
        guard customExposureRequested, let requested = manualExposureValues,
              device.isExposureModeSupported(.custom) else {
            restoreDefaultAutoExposureLimit(device)
            updatePreviewHDR(device, customExposure: false)
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            return
        }
        if usesSmoothManualPreviewExposure {
            updatePreviewHDR(device, customExposure: false)
            applySmoothPreviewExposure(device)
        } else {
            restoreDefaultAutoExposureLimit(device)
            updatePreviewHDR(device, customExposure: true)
            applyRequestedManualExposure(requested, to: device)
        }
    }

    func setPreviewExposureAssist(_ enabled: Bool) {
        queue.async {
            guard self.previewExposureAssistEnabled != enabled else { return }
            self.previewExposureAssistEnabled = enabled
            guard self.manualMode, !self.videoModeRequested, self.customExposureRequested, self.captureContexts.isEmpty,
                  let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                self.applyManualPreviewExposurePolicy(device)
            } catch { self.report("更新流畅预览失败：\(error.localizedDescription)") }
        }
    }

    /// Speed-first slow-shutter sequence: keep the requested long exposure
    /// applied for the whole sequence so each frame does not pay the expensive
    /// auto-preview to custom-exposure transition. The preview intentionally
    /// updates at the long-exposure cadence while the sequence is running.
    func setSlowShutterSequenceCaptureExposure(_ enabled: Bool, iso: Double?, seconds: Double?) {
        queue.async {
            self.slowShutterSequencePreviewAssistEnabled = false
            guard enabled, let iso, let seconds, iso.isFinite, seconds.isFinite,
                  let device = self.input?.device else { return }
            self.manualExposureValues = (Float(iso), seconds)
            self.customExposureRequested = true
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                self.updateManualPhotoPreviewFrameDuration(seconds, on: device)
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
                    (1 / seconds) >= $0.minFrameRate && (1 / seconds) <= $0.maxFrameRate
                }) {
                    let duration = CMTime(seconds: min(seconds, CMTimeGetSeconds(range.maxFrameDuration)),
                                          preferredTimescale: 1_000_000_000)
                    device.activeVideoMaxFrameDuration = duration
                    if duration <= range.maxFrameDuration { device.activeVideoMinFrameDuration = duration }
                }
                let isoValue = min(max(iso, Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO))
                device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                             iso: Float(isoValue), completionHandler: nil)
            } catch { self.report("应用慢门序列曝光失败：\(error.localizedDescription)") }
        }
    }

    /// 序列取景使用短自动曝光，静态请求独立保存手动值。
    /// 支持时用手动包围曝光；不支持时回退到临时切换曝光后恢复预览。
    func setSlowShutterSequencePreviewAssist(_ enabled: Bool, iso: Double?, seconds: Double?) {
        queue.async {
            self.slowShutterSequencePreviewAssistEnabled = enabled
            guard enabled, let iso, let seconds, iso.isFinite, seconds.isFinite else { return }
            self.manualExposureValues = (Float(iso), seconds)
            self.customExposureRequested = true
            guard let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                self.applySmoothPreviewExposure(device)
            } catch { self.report("更新慢门序列预览失败：\(error.localizedDescription)") }
        }
    }

    func clearSlowShutterSequenceCaptureExposure() {
        queue.async {
            self.slowShutterSequencePreviewAssistEnabled = false
            guard let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            } catch { self.report("恢复慢门序列帧时长失败：\(error.localizedDescription)") }
        }
    }

    /// HEIF 照片模式内保持一条 HDR 能力预览管线；HDR 开关只切显示，不再切格式。
    func setHEIFHDRPipeline(_ enabled: Bool) {
        queue.async {
            guard self.heifHDRPipelineRequested != enabled else { return }
            self.heifHDRPipelineRequested = enabled
            DispatchQueue.main.async { self.hdrPreviewConfiguring = true }
            let started = CACurrentMediaTime()
            if let device = self.input?.device {
                if self.reconcileHDRPreviewFormat(device) {
                    self.configurePreviewOutput(device)
                    self.configureAutomaticLensPolicy(device)
                }
            } else {
                self.refreshHDRPreviewConfiguration()
            }
            self.updateHDRPreviewActive()
            #if DEBUG
            print("HDR-PIPELINE enabled=\(enabled) seconds=\(CACurrentMediaTime()-started)")
            #endif
            DispatchQueue.main.async {
                if self.heifHDRPipelineRequested == enabled { self.hdrPreviewConfiguring = false }
            }
        }
    }

    func setHEIFHDRPreview(_ enabled: Bool) {
        queue.async {
            guard self.heifHDRPreviewRequested != enabled else { return }
            self.heifHDRPreviewRequested = enabled
            // 首次直接开启 HDR 时补建管线；正常照片模式进入时管线已准备好。
            if enabled, !self.heifHDRPipelineRequested {
                self.heifHDRPipelineRequested = true
                if let device = self.input?.device, self.reconcileHDRPreviewFormat(device) {
                    self.configurePreviewOutput(device)
                    self.configureAutomaticLensPolicy(device)
                }
            }
            self.updateHDRPreviewActive()
            self.syncPreviewState()
        }
    }

    private func updateHDRPreviewActive() {
        let active = heifHDRPreviewRequested && hdrPreviewSource != nil
        DispatchQueue.main.async { if self.hdrPreviewActive != active { self.hdrPreviewActive = active } }
    }

    private func hlgPreviewFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.filter { format in
            guard format.supportedColorSpaces.contains(.HLG_BT2020) else { return false }
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return abs(Double(d.width)/Double(d.height) - 4.0/3) < 0.01 &&
                format.supportedMaxPhotoDimensions.contains { Int64($0.width)*Int64($0.height) >= 12_000_000 }
        }.min { a,b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int64(da.width)*Int64(da.height) < Int64(db.width)*Int64(db.height)
        }
    }

    private func prepareHDRForInputReplacement() {
        guard hdrPreviewSource != nil, let device = input?.device else { return }
        let preparing = hdrStillCapturePreparing
        hdrStillCapturePreparing = true
        _ = reconcileHDRPreviewFormat(device)
        hdrStillCapturePreparing = preparing
    }

    private func resumeFramesAfterHDRConfigurationFailure() {
        let cutoff = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        syncPreviewState()
        livePreviewState.update { $0.framesNotBefore = cutoff; $0.acceptsFrames = true }
    }

    private func refreshHDRPreviewConfiguration() {
        guard dualCaptureSource == nil, focusNavigatorGraph == nil, let device = input?.device, captureContexts.isEmpty else { return }
        if reconcileHDRPreviewFormat(device) {
            configureConnections(device: device)
            configurePhotoOutput(device)
            publishCapabilities(device, lensID: manualZoomAnchorID ?? selectedLens)
        }
    }

    private func hdrZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let display = max(0.5, currentZoom)
        let base: CGFloat
        if device.isVirtualDevice {
            base = CameraLensCatalog.displayMultiplier(device)
        } else {
            base = lensCatalog.first { $0.device.uniqueID == device.uniqueID }
                .map { $0.displayZoom / $0.zoomFactor } ?? 1
        }
        guard base.isFinite, base > 0 else { return device.videoZoomFactor }
        return display / base
    }

    @discardableResult private func reconcileHDRPreviewFormat(_ device: AVCaptureDevice) -> Bool {
        guard captureContexts.isEmpty else { return false }
        // 物理输入（微距临时路线）没有完整虚拟多摄HDR能力；只允许虚拟设备启用HLG预览。
        let wanted = heifHDRPipelineRequested && wantsRunning && !hdrStillCapturePreparing && device.isVirtualDevice
        var changed = false
        if let original = hdrPreviewSource,
           !wanted || original.device.uniqueID != device.uniqueID {
            livePreviewState.update { $0.acceptsFrames = false }
            session.beginConfiguration()
            do {
                // Clear the 10-bit-only output constraint before selecting the photo preset.
                videoOutput.videoSettings = [:]
                try original.device.lockForConfiguration()
                original.device.activeFormat = original.format
                original.device.activeColorSpace = original.color
                if original.device.automaticallyAdjustsVideoHDREnabled { original.device.automaticallyAdjustsVideoHDREnabled = false }
                if original.device.activeFormat.isVideoHDRSupported { original.device.isVideoHDREnabled = original.videoHDR.enabled }
                original.device.automaticallyAdjustsVideoHDREnabled = original.videoHDR.automatic
                original.device.unlockForConfiguration()
                if session.canSetSessionPreset(original.preset) { session.sessionPreset = original.preset }
                session.automaticallyConfiguresCaptureDeviceForWideColor = original.automaticWideColor
                videoOutput.videoSettings = videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA)
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : [:]
                hdrPreviewSource = nil
                session.commitConfiguration()
                // sessionPreset/格式恢复会重置 zoomFactor，必须在 commit 后重新应用。
                let restoreZoom = hdrZoomFactor(for: original.device)
                do {
                    try original.device.lockForConfiguration()
                    original.device.videoZoomFactor = min(max(restoreZoom,
                        original.device.minAvailableVideoZoomFactor), original.device.maxAvailableVideoZoomFactor)
                    original.device.unlockForConfiguration()
                } catch { report("恢复 HDR 关闭后的倍率失败：\(error.localizedDescription)") }
                #if DEBUG
                print("HDR-PREVIEW-DISABLE zoom=\(original.device.videoZoomFactor) primary=\(original.device.activePrimaryConstituent?.deviceType.rawValue ?? "nil")")
                #endif
                changed = true
            } catch {
                session.commitConfiguration(); resumeFramesAfterHDRConfigurationFailure()
                report("恢复照片预览失败：\(error.localizedDescription)"); return false
            }
        }
        if wanted && hdrPreviewSource == nil {
            guard let format = hlgPreviewFormat(device) else {
                DispatchQueue.main.async { self.hdrPreviewActive = false }
                return changed
            }
            let source = HDRPreviewSource(device:device,format:device.activeFormat,color:device.activeColorSpace,
                preset:session.sessionPreset,automaticWideColor:session.automaticallyConfiguresCaptureDeviceForWideColor,
                videoHDR:PreviewHDRSettings(automatic:device.automaticallyAdjustsVideoHDREnabled,enabled:device.isVideoHDREnabled),
                rawTypes:photoOutput.availableRawPhotoPixelFormatTypes,dimensions:device.activeFormat.supportedMaxPhotoDimensions,
                live:nativeLivePreviewSupported, zoom: device.videoZoomFactor)
            livePreviewState.update { $0.acceptsFrames = false }
            session.beginConfiguration()
            do {
                videoOutput.videoSettings = [:]
                session.automaticallyConfiguresCaptureDeviceForWideColor = false
                try device.lockForConfiguration()
                device.activeFormat = format; device.activeColorSpace = .HLG_BT2020
                let zoom = hdrZoomFactor(for: device)
                device.videoZoomFactor = min(max(zoom,device.minAvailableVideoZoomFactor),device.maxAvailableVideoZoomFactor)
                restoreManualExposureAfterZoom(device)
                device.unlockForConfiguration()
                if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
                    if let dimensions = format.supportedMaxPhotoDimensions.last { photoOutput.maxPhotoDimensions = dimensions }
                    hdrPreviewSource = source
                } else {
                    // 当前格式不提供10-bit预览，放弃本次HLG启用而不是写不支持格式。
                    videoOutput.videoSettings = [:]
                    hdrPreviewSource = nil
                }
                session.commitConfiguration()
                #if DEBUG
                print("HDR-PREVIEW-ENABLE zoom=\(device.videoZoomFactor) primary=\(device.activePrimaryConstituent?.deviceType.rawValue ?? "nil")")
                #endif
                changed = true
            } catch {
                session.automaticallyConfiguresCaptureDeviceForWideColor = source.automaticWideColor
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                session.commitConfiguration(); resumeFramesAfterHDRConfigurationFailure()
                report("HDR 预览配置失败：\(error.localizedDescription)"); return false
            }
        }
        let active = hdrPreviewSource != nil
        syncPreviewState()
        DispatchQueue.main.async { if self.hdrPreviewActive != active { self.hdrPreviewActive = active } }
        return changed
    }

    func setFilterParameterEditing(_ active: Bool) { previewRevision.setInteractive(active) }

    func setLevelMonitoringEnabled(_ enabled: Bool) {
        levelMonitoringRequested = enabled
        if enabled, runRequested, ready {
            levelMonitor.start { [weak self] in self?.roll = $0 }
        } else {
            levelMonitor.stop()
        }
    }

    func updateVideoLogLUT(_ cube: LogLUTCube?, convertLog2ToLog1: Bool = false) {
        let revision = previewRevision.advance(resetInteractiveFloor: true)
        let update = lookUpdateRevision.advance()
        queue.async {
            guard self.lookUpdateRevision.matches(update) else { return }
            self.livePreviewState.update {
                $0.logLUTCube = cube
                $0.logLUTLog2ToLog1 = convertLog2ToLog1
                $0.revision = revision
            }
            self.lookRevision = revision
            #if targetEnvironment(simulator)
            if self.previewRevision.canRender(revision) { self.renderDemo() }
            #endif
        }
    }

    /// 成片 look 与预览 look 分离：HDR 预览可屏蔽滤镜，但快门仍使用完整滤镜配方。
    func setCaptureLook(_ value: CaptureLook) {
        queue.async { self.captureLookOverride = value }
    }

    func updateLook(_ value: CaptureLook, photoFormat: PhotoFileFormat = .jpeg) {
        let current = livePreviewState.snapshot().look
        let revision = previewRevision.advance(resetInteractiveFloor: current.ratio != value.ratio || current.style != value.style)
        let update = lookUpdateRevision.advance()
        queue.async {
            guard self.lookUpdateRevision.matches(update) else { return }
            var appliedLook = value
            // 前置动态宽高比由相机队列掌握；UI 偶尔排队提交旧 look 时，以设备已确认状态修正预览。
            if self.input?.device.position == .front, !self.videoModeRequested,
               photoFormat != .raw, appliedLook.ratio != .square {
                appliedLook.landscape = self.frontPhotoLandscapeApplied
            }
            let ratioChanged = self.look.ratio != appliedLook.ratio
            self.look = appliedLook
            let recordingLook = appliedLook
            self.recordingQueue.async { self.movieRecorder?.updateLook(recordingLook) }
            if ratioChanged, let device = self.input?.device { self.updateFrontVideoCenteringRegion(device) }
            self.lookRevision = revision
            self.syncPreviewState()
            #if targetEnvironment(simulator)
            if self.previewRevision.canRender(revision) { self.renderDemo() }
            #endif
        }
    }

    func rotatePreview(quarterTurns: Int) {
        previewRevision.setInteractive(false)
        let revision = previewRevision.advance()
        queue.async {
            self.lookRevision = revision
            self.previewQuarterTurns = quarterTurns % 4
            self.syncPreviewState()
            #if targetEnvironment(simulator)
            self.renderDemo()
            #endif
        }
    }

    func enableHistogram(_ enabled: Bool) {
        queue.async {
            self.histogramEnabled = enabled
            self.syncPreviewState()
            #if targetEnvironment(simulator)
            if enabled { self.renderDemo() }
            #endif
            if !enabled {
                self.histogramThrottle.cancel()
                DispatchQueue.main.async { self.histogram = [] }
            }
        }
    }

    func enableFocusPeaking(_ enabled: Bool) {
        let revision = previewRevision.advance(resetInteractiveFloor: true)
        queue.async {
            self.focusPeakingEnabled = enabled; self.lookRevision = revision
            self.syncPreviewState()
            #if targetEnvironment(simulator)
            self.renderDemo()
            #endif
        }
    }

    private func syncPreviewState() {
        scheduleFocusNavigatorRefresh()
        let nativeFrontPhotoSensor: Bool
        if #available(iOS 26.0, *), !videoModeRequested, let device = input?.device, device.position == .front {
            nativeFrontPhotoSensor = !device.activeFormat.supportedDynamicAspectRatios.isEmpty
        } else { nativeFrontPhotoSensor = false }
        livePreviewState.update {
            $0.running = wantsRunning; $0.manualMode = manualMode
            $0.temporaryMacroPhysicalInput = input?.device.deviceType == .builtInUltraWideCamera
                && (macroPhysicalHoldRoute != nil || macroPreviewRoute != nil || !macroAutomaticRoutes.isEmpty)
            $0.hdr = (heifHDRPreviewRequested && hdrPreviewSource != nil)
                || (videoModeRequested && requestedVideoSettings.colorSpace == .hdr)
            $0.videoColorSpace = videoModeRequested ? requestedVideoSettings.colorSpace : nil
            $0.videoFrameRate = videoModeRequested ? requestedVideoSettings.frameRate.rawValue : nil
            $0.videoCaptureFrameRate = videoModeRequested ? requestedVideoSettings.captureFrameRate?.rawValue : nil
            $0.nativeFrontPhotoSensor = nativeFrontPhotoSensor
            if #available(iOS 26.0, *) {
                $0.nativeFrontCenterStageSensor = videoModeRequested && frontVideoCenteringRequested
                    && input?.device.position == .front && frontPhotoRotationCoordinator != nil
            } else { $0.nativeFrontCenterStageSensor = false }
            $0.nativeFrontSensorLandscape = nativeFrontPhotoSensor && frontPhotoLandscapeApplied
            $0.look = look; $0.revision = lookRevision
            $0.readingsGeneration = readingsGeneration
            $0.quarterTurns = previewQuarterTurns; $0.histogram = histogramEnabled; $0.focusPeaking = focusPeakingEnabled
            $0.metering = metering; $0.mirrorFrontPreview = dualCaptureSource == nil; $0.device = dualControlDevice
        }
    }

    private func renderDemo() {
        guard previewRevision.canRender(lookRevision), wantsRunning else { return }
        let state = livePreviewState.snapshot()
        demoPreviewThrottle.submit(DemoPreview(look: look, logLUTCube: state.logLUTCube,
            logLUTLog2ToLog1: state.logLUTLog2ToLog1, videoColorSpace: state.videoColorSpace,
            revision: lookRevision, zoom: demoZoom, quarterTurns: previewQuarterTurns, histogram: histogramEnabled, focusPeaking: focusPeakingEnabled))
    }
    private func renderDemoFrame(_ frame: DemoPreview) {
        guard previewRevision.canRender(frame.revision), livePreviewState.snapshot().running,
              let source = CIImage(image: DemoImageFactory.make()) else { return }
        let sourceFrame = ContinuousZoomPolicy.demoFrame(source, zoom: frame.zoom)
        var lookImage = Imaging.filtered(sourceFrame, look: frame.look)
        if frame.videoColorSpace?.isLog == true, let cube = frame.logLUTCube {
            if frame.logLUTLog2ToLog1 { lookImage = AppleLogLUTInput.log2ToLog1(lookImage) }
            lookImage = cube.apply(to: lookImage)
        }
        let filtered = PreviewRotation.image(lookImage, quarterTurns: frame.quarterTurns)
        let display = frame.focusPeaking ? FocusPeakingRenderer.apply(to: filtered, analysis: PreviewRotation.image(sourceFrame, quarterTurns: frame.quarterTurns)) : filtered
        guard let cg = previewContext.createCGImage(display, from: display.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false) else { return }
        if frame.histogram {
            let histogramSource = frame.focusPeaking ? filtered : CIImage(cgImage: cg)
            histogramThrottle.submit(HistogramFrame(image: frame.look.ratio.crop(histogramSource, landscape: frame.look.landscape), revision: frame.revision,
                                                   generation: livePreviewState.snapshot().readingsGeneration))
        }
        let image = UIImage(cgImage: cg)
        publishPreview(image, revision: frame.revision)
    }

    func setExposure(iso: Double?, seconds: Double?, bias: Double) {
        guard bias.isFinite, iso?.isFinite != false, seconds?.isFinite != false else { return }
        let targetToken = targetExposureLockActive ? targetExposureRevision.advance() : nil
        if targetToken != nil && iso == nil && seconds == nil { targetExposureLocked = demo }
        configureDevice(restartLongPhotoExposure: iso == nil && seconds == nil) { device in
            if let targetToken, !self.targetExposureRevision.matches(targetToken) { return }
            let assistedStillInFlight = self.captureContexts.values.contains {
                ($0.usesPreviewExposureAssist && !$0.previewExposureAssistRestored)
                    || ($0.usesSlowShutterAutoPreviewAssist && !$0.slowShutterAutoPreviewAssistRestored)
            }
            if assistedStillInFlight {
                self.exposureBias = Float(bias)
                if iso == nil && seconds == nil {
                    self.customExposureRequested = false
                    self.manualExposureValues = nil
                } else if device.isExposureModeSupported(.custom) {
                    let format = device.activeFormat
                    let minimum = CMTimeGetSeconds(format.minExposureDuration)
                    let maximum = min(CMTimeGetSeconds(format.maxExposureDuration), 1)
                    guard let iso, let seconds, iso.isFinite, seconds.isFinite,
                          minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum,
                          format.minISO.isFinite, format.maxISO.isFinite, format.minISO > 0, format.maxISO >= format.minISO else { return }
                    self.manualExposureValues = (Float(min(max(iso, Double(format.minISO)), Double(format.maxISO))),
                                                 min(max(seconds, minimum), maximum))
                    self.customExposureRequested = true
                }
                return
            }
            if iso == nil && seconds == nil {
                self.customExposureRequested = false
                self.manualExposureValues = nil
                // 先退出长曝光custom，再恢复HDR流；反过来会让HDR重配置等待多个旧长曝光帧。
                self.tracePhotoPhase("auto-return before-mode")
                if !self.videoModeRequested, !self.targetLockRequested,
                   device.isExposureModeSupported(.continuousAutoExposure), device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                self.tracePhotoPhase("auto-return after-mode")
                self.restoreAutomaticPhotoFrameDurations(device)
                self.tracePhotoPhase("auto-return after-frame-durations")
                if self.previewExposureAssistEnabled && !self.videoModeRequested { self.restoreDefaultAutoExposureLimit(device) }
                self.updatePreviewHDR(device, customExposure: false)
                self.tracePhotoPhase("auto-return after-hdr")
            }
            if self.targetLockRequested && iso == nil && seconds == nil {
                // Re-meter the same selected target after EV changes, then lock again.
                self.exposureBias = Float(bias)
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = self.targetSensorPoint }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.setExposureTargetBias(min(max(Float(bias), device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
                if let targetToken { self.scheduleTargetExposureLock(device: device, revision: targetToken) }
                return
            }
            if iso == nil && seconds == nil {
                if device.isExposureModeSupported(.continuousAutoExposure), device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                self.refreshAutomaticParameterReadings()
            } else if device.isExposureModeSupported(.custom) {
                let format = device.activeFormat
                let requestedISO = iso ?? Double(device.iso)
                let requestedSeconds = seconds ?? CMTimeGetSeconds(device.exposureDuration)
                let minimum = CMTimeGetSeconds(format.minExposureDuration)
                let activeVideoRate = self.requestedVideoSettings.captureFrameRate ?? self.requestedVideoSettings.frameRate
                let maximum = min(CMTimeGetSeconds(format.maxExposureDuration), self.videoModeRequested ? 1 / Double(activeVideoRate.rawValue) : .infinity)
                guard requestedISO.isFinite, requestedISO > 0, requestedSeconds.isFinite, requestedSeconds > 0,
                      format.minISO.isFinite, format.maxISO.isFinite, format.minISO > 0, format.maxISO >= format.minISO,
                      minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return }
                let actualISO = Float(min(max(requestedISO, Double(format.minISO)), Double(format.maxISO)))
                let duration = min(max(requestedSeconds, minimum), maximum)
                self.customExposureRequested = true
                self.manualExposureValues = (actualISO, duration)
                if self.usesSmoothManualPreviewExposure {
                    self.updatePreviewHDR(device, customExposure: false)
                    self.applySmoothPreviewExposure(device)
                } else {
                    if self.manualMode && !self.videoModeRequested {
                        self.updateManualPhotoPreviewFrameDuration(duration, on: device)
                    }
                    self.updatePreviewHDR(device, customExposure: true)
                    device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: actualISO, completionHandler: nil)
                }
            }
            let rebaseMetering = self.exposureBias != Float(bias) || iso != nil
            if rebaseMetering {
                self.globalMeteringRevision = UUID()
                self.globalMeteringPolicy.complete(at: CACurrentMediaTime())
            }
            if iso != nil { self.globalBias = 0; self.globalMeteringPolicy.reset(); self.manualGlobalMeteringSuggestion = nil }
            self.exposureBias = Float(bias)
            let meteringRevision = self.globalMeteringRevision
            device.setExposureTargetBias(min(max(Float(bias) + (self.metering == .global && iso == nil ? self.globalBias : 0), device.minExposureTargetBias), device.maxExposureTargetBias)) { [weak engine = self] _ in
                guard let engine else { return }
                engine.queue.async {
                    guard engine.globalMeteringRevision == meteringRevision,
                          engine.input?.device.uniqueID == device.uniqueID else { return }
                    if rebaseMetering, iso == nil, engine.metering == .global {
                        engine.globalMeteringPolicy.complete(at: CACurrentMediaTime())
                    }
                    engine.publishGlobalMetering(device)
                }
            }
            self.publishGlobalMetering(device)
            if let targetToken, self.targetLockRequested || self.targetFocusLockRequested {
                self.scheduleTargetExposureLock(device: device, revision: targetToken)
            }
        }
    }

    /// Called on the session queue with the device lock held. Automatic video HDR can
    /// preserve highlights despite large manual ISO increases. Use SDR for custom exposure;
    /// restore the device's original streaming policy when automatic exposure is requested.
    /// This does not change photo format/HDR encoding, white balance or local tone mapping.
    private func updatePreviewHDR(_ device: AVCaptureDevice, customExposure: Bool) {
        guard device.activeColorSpace != .HLG_BT2020 else { return }
        if customExposure || videoModeRequested {
            if previewHDRSettings[device.uniqueID] == nil {
                previewHDRSettings[device.uniqueID] = PreviewHDRSettings(automatic: device.automaticallyAdjustsVideoHDREnabled,
                                                                       enabled: device.isVideoHDREnabled)
            }
            if device.automaticallyAdjustsVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false }
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
        } else if let original = previewHDRSettings.removeValue(forKey: device.uniqueID) {
            if device.automaticallyAdjustsVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false }
            let enabled = original.enabled && device.activeFormat.isVideoHDRSupported
            if device.isVideoHDREnabled != enabled { device.isVideoHDREnabled = enabled }
            device.automaticallyAdjustsVideoHDREnabled = original.automatic
        }
    }

    func setWhiteBalance(kelvin: Double?, tint: Double = 0) {
        configureDevice { device in
            if let kelvin, (!kelvin.isFinite || kelvin <= 0 || !tint.isFinite) { return }
            if self.metering == .global {
                self.globalMeteringPolicy.reset(); self.globalMeteringRevision = UUID()
                self.manualGlobalMeteringSuggestion = nil
            }
            self.automaticWhiteBalanceRequested = kelvin == nil
            guard let kelvin else {
                self.manualWhiteBalanceValues = nil
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                self.refreshAutomaticParameterReadings()
                return
            }
            // Virtual cameras can support .locked without accepting explicit RGB gains.
            // Old queued parameter events may reach that route during A/M changes.
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                self.manualWhiteBalanceValues = nil
                self.automaticWhiteBalanceRequested = true
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                return
            }
            guard kelvin.isFinite, kelvin > 0, tint.isFinite else { return }
            let gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(min(max(kelvin, 2500), 9000)), tint: Float(min(max(tint, -150), 150))))
            guard let safeGains = WhiteBalanceSafety.clamped(gains, maximum: device.maxWhiteBalanceGain) else { return }
            self.manualWhiteBalanceValues = (kelvin:min(max(kelvin,2500),9000),tint:min(max(tint,-150),150))
            device.setWhiteBalanceModeLocked(with: safeGains, completionHandler: nil)
        }
    }

    func setFocus(position: Double?) {
        if position != nil, targetFocusLockActive {
            targetFocusLockActive = false; targetFocusLocked = false
            queue.async { self.targetFocusLockRequested = false }
        }
        configureDevice { device in
            if self.metering == .global {
                self.globalMeteringPolicy.reset(); self.globalMeteringRevision = UUID()
                self.manualGlobalMeteringSuggestion = nil
            }
            if #available(iOS 26.0, *), self.input?.isCinematicVideoCaptureEnabled == true {
                // Cinematic 模式由系统的主体跟踪/固定点 API 控制焦点，不接受镜头位置刻度值。
                device.setCinematicVideoTrackingFocus(at: self.targetSensorPoint, focusMode: .weak)
                return
            }
            if let position, device.isLockingFocusWithCustomLensPositionSupported {
                guard position.isFinite else { return }
                device.setFocusModeLocked(lensPosition: Float(min(max(position, 0), 1)), completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                self.refreshAutomaticParameterReadings()
            }
        }
    }

    func focus(at point: CGPoint, lockExposure: Bool = false, lockFocus: Bool = false) {
        guard ready, !capturing, point.x.isFinite, point.y.isFinite else { return }
        let revision = targetExposureRevision.advance()
        targetExposureLockActive = lockExposure
        targetExposureLocked = demo && lockExposure
        targetFocusLockActive = lockFocus; targetFocusLocked = demo && lockFocus
        if demo { return }
        configureDevice(onFailure: {
            guard self.targetExposureRevision.matches(revision) else { return }
            self.targetLockRequested = false; self.targetFocusLockRequested = false
            self.publishTargetFocusLock(false, active: false, revision: revision)
            self.publishTargetExposureLock(false, active: false, revision: revision)
        }) { [self] device in
            guard self.targetExposureRevision.matches(revision) else { return }
            self.targetLockRequested = lockExposure
            self.targetFocusLockRequested = lockFocus
            if !lockExposure, device.exposureMode == .locked, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let sourceExtent = self.livePreviewState.snapshot().extent
            guard sourceExtent.width.isFinite, sourceExtent.height.isFinite, sourceExtent.width > 0, sourceExtent.height > 0 else {
                self.targetLockRequested = false; self.targetFocusLockRequested = false
                self.publishTargetFocusLock(false, active: false, revision: revision)
                self.publishTargetExposureLock(false, active: false, revision: revision)
                return
            }
            // Video output is physically rotated to portrait, while device metering uses sensor coordinates.
            let displayExtent = PreviewRotation.image(CIImage(color: .black).cropped(to: sourceExtent), quarterTurns: self.previewQuarterTurns).extent
            let crop = self.look.ratio.crop(CIImage(color: .black).cropped(to: displayExtent), landscape: self.look.landscape).extent
            let displayPoint = CGPoint(x: (crop.minX - displayExtent.minX + point.x * crop.width) / displayExtent.width,
                                       y: (crop.minY - displayExtent.minY + point.y * crop.height) / displayExtent.height)
            let original = PreviewRotation.sourcePoint(displayPoint, quarterTurns: self.previewQuarterTurns)
            let x = original.x
            let y = original.y
            let sensorPoint = CGPoint(x: min(max(y, 0), 1), y: min(max(device.position == .front ? x : 1 - x, 0), 1))
            self.targetSensorPoint = sensorPoint
            if #available(iOS 26.0, *), self.input?.isCinematicVideoCaptureEnabled == true {
                // 电影采集期间由系统 Cinematic 控制对焦；普通 focusMode 与其不能同时改写。
                if lockFocus {
                    device.setCinematicVideoFixedFocus(at: sensorPoint, focusMode: .strong)
                } else {
                    device.setCinematicVideoTrackingFocus(at: sensorPoint, focusMode: .weak)
                }
                self.targetFocusLockRequested = false
                self.publishTargetFocusLock(lockFocus, active: lockFocus, revision: revision)
            } else {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = sensorPoint
                    if !lockFocus, device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if lockFocus && !device.isFocusModeSupported(.locked) {
                    self.targetFocusLockRequested = false
                    self.publishTargetFocusLock(false, active: false, revision: revision)
                }
            }
            if (lockExposure || self.metering == .spot), device.isExposurePointOfInterestSupported, device.exposureMode != .custom {
                device.exposurePointOfInterest = sensorPoint
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            if lockExposure {
                if device.exposureMode == .custom {
                    self.publishTargetExposureLock(true, active: true, revision: revision)
                } else if device.isExposureModeSupported(.locked) {
                    self.globalBias = 0
                    self.globalMeteringRevision = UUID(); self.globalMeteringPolicy.reset()
                    self.publishGlobalMetering(device)
                    device.setExposureTargetBias(min(max(self.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
                } else {
                    self.targetLockRequested = false
                    self.publishTargetExposureLock(false, active: false, revision: revision)
                    self.report("当前镜头不支持锁定曝光。")
                }
            }
            if self.targetLockRequested || self.targetFocusLockRequested {
                self.scheduleTargetExposureLock(device: device, revision: revision)
            }
        }
    }

    /// Let the virtual camera reconsider a close-up after the scene changes. Never
    /// cancel an intentional target lock or a manual-mode focus setting.
    private func resumeFocusAfterSceneChange(deviceID: String) {
        guard wantsRunning, !manualMode, !targetLockRequested, !targetFocusLockRequested,
              let device = input?.device,
              device.uniqueID == deviceID || device.constituentDevices.contains(where: { $0.uniqueID == deviceID }) else { return }
        if #available(iOS 26.0, *), input?.isCinematicVideoCaptureEnabled == true { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        let pointChanged = device.isFocusPointOfInterestSupported &&
            (abs(device.focusPointOfInterest.x - center.x) > 0.0001 || abs(device.focusPointOfInterest.y - center.y) > 0.0001)
        let modeChanged = device.isFocusModeSupported(.continuousAutoFocus) && device.focusMode != .continuousAutoFocus
        // Re-setting continuous AF can restart a focus scan. Let an already
        // centered continuous controller handle near/far changes on its own.
        guard pointChanged || modeChanged else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if pointChanged { device.focusPointOfInterest = center }
            if modeChanged { device.focusMode = .continuousAutoFocus }
            #if DEBUG
            sceneFocusReconfigurationsForTesting += 1
            #endif
        } catch { /* A later scene-change notification can retry while configuration is busy. */ }
    }

    private func publishTargetFocusLock(_ locked: Bool, active: Bool, revision: UInt64) {
        DispatchQueue.main.async {
            guard self.targetExposureRevision.matches(revision) else { return }
            self.targetFocusLocked = locked; self.targetFocusLockActive = active
        }
    }

    private func publishTargetExposureLock(_ locked: Bool, active: Bool, revision: UInt64) {
        DispatchQueue.main.async {
            guard self.targetExposureRevision.matches(revision) else { return }
            self.targetExposureLocked = locked
            self.targetExposureLockActive = active
        }
    }

    private func scheduleTargetExposureLock(device: AVCaptureDevice, revision: UInt64) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        queue.asyncAfter(deadline: .now() + 0.15) {
            self.finishTargetExposureLock(device: device, revision: revision, deadline: deadline)
        }
    }

    private func finishTargetExposureLock(device: AVCaptureDevice, revision: UInt64, deadline: UInt64) {
        guard targetExposureRevision.matches(revision), targetLockRequested || targetFocusLockRequested,
              wantsRunning, input?.device.uniqueID == device.uniqueID else { return }
        let adjusting = (targetLockRequested && device.exposureMode != .custom && device.isAdjustingExposure) ||
            (targetFocusLockRequested && device.isAdjustingFocus)
        if (adjusting || !captureContexts.isEmpty) && DispatchTime.now().uptimeNanoseconds < deadline {
            queue.asyncAfter(deadline: .now() + 0.05) {
                self.finishTargetExposureLock(device: device, revision: revision, deadline: deadline)
            }
            return
        }
        guard captureContexts.isEmpty else {
            targetLockRequested = false; targetFocusLockRequested = false
            publishTargetExposureLock(false, active: false, revision: revision)
            publishTargetFocusLock(false, active: false, revision: revision)
            return
        }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if targetFocusLockRequested, device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
                publishTargetFocusLock(true, active: true, revision: revision)
            }
            if targetLockRequested {
                if device.exposureMode != .custom, device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                publishTargetExposureLock(device.exposureMode == .locked || device.exposureMode == .custom, active: true, revision: revision)
            }
        } catch {
            targetLockRequested = false; targetFocusLockRequested = false
            publishTargetExposureLock(false, active: false, revision: revision)
            publishTargetFocusLock(false, active: false, revision: revision)
            report("目标锁定失败：\(error.localizedDescription)")
        }
    }

    /// Compatibility entry point: cancelling a target releases both target locks.
    func unlockTargetExposure() {
        guard targetLockActive else { return }
        let releaseFocus = targetFocusLockActive
        _ = targetExposureRevision.advance()
        targetExposureLockActive = false; targetExposureLocked = false
        targetFocusLockActive = false; targetFocusLocked = false
        configureDevice { device in
            self.targetLockRequested = false; self.targetFocusLockRequested = false
            if releaseFocus, device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if !self.customExposureRequested, device.exposureMode != .custom, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    func setMetering(_ mode: CameraMetering) {
        unlockTargetExposure()
        configureDevice { device in
            self.metering = mode; self.globalBias = 0
            self.globalMeteringPolicy.reset(); self.globalMeteringRevision = UUID()
            self.manualGlobalMeteringSuggestion = nil; self.liveGlobalMeteringTarget = nil
            self.syncPreviewState()
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if !self.customExposureRequested, device.exposureMode != .custom, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                let revision = self.globalMeteringRevision
                device.setExposureTargetBias(min(max(self.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)) { [weak engine = self] _ in
                    guard let engine else { return }
                    engine.queue.async {
                        guard engine.globalMeteringRevision == revision, engine.input?.device.uniqueID == device.uniqueID else { return }
                        engine.publishGlobalMetering(device)
                    }
                }
            }
            self.publishGlobalMetering(device)
        }
    }

    /// 只在会话队列改变状态；补偿完成回调按版本隔离，切格式后旧回调不能复活全局测光。
    private func publishGlobalMetering(_ device: AVCaptureDevice) {
        let value = GlobalMeteringReadout(user: Double(exposureBias), correction: Double(globalBias),
            actual: Double(device.exposureTargetBias),
            automatic: metering == .global && !customExposureRequested && !targetLockRequested && device.exposureMode != .custom,
            suggestion: metering == .global && customExposureRequested ? manualGlobalMeteringSuggestion : nil,
            target: metering == .global && !customExposureRequested ? liveGlobalMeteringTarget : nil)
        DispatchQueue.main.async {
            if self.globalMeteringReadout != value { self.globalMeteringReadout = value }
        }
    }

    private func updateGlobalMetering(_ sample: GlobalMeteringPolicy.Sample, deviceID: String?, generation: UInt64, adjustingForTesting: Bool? = nil) {
        guard metering == .global, generation == readingsGeneration,
              let device = input?.device, device.uniqueID == deviceID else { return }
        #if DEBUG
        if let observer = onGlobalMeteringObservationForTesting {
            let line = "mean=\(sample.mean) level=\(sample.sceneLevel) AE=\(device.isAdjustingExposure) WB=\(device.isAdjustingWhiteBalance) AF=\(device.isAdjustingFocus) target=\(liveGlobalMeteringTarget.map(String.init(describing:)) ?? "nil") global=\(globalBias) device=\(device.exposureTargetBias) computes=\(globalMeteringPolicy.computations)"
            DispatchQueue.main.async { observer(line) }
        }
        #endif
        // bias属性读回可能略晚于完成回调；低频刷新实际值，但不重新计算/下发曝光。
        liveGlobalMeteringTarget = GlobalMeteringPolicy.target(for: sample)
        publishGlobalMetering(device)
        guard !targetLockRequested, captureContexts.isEmpty else { globalMeteringPolicy.suspend(); return }
        let adjusting = adjustingForTesting ?? (device.isAdjustingExposure || device.isAdjustingWhiteBalance || device.isAdjustingFocus)
        if customExposureRequested {
            guard let values = manualExposureValues else { globalMeteringPolicy.suspend(); return }
            let aperture = max(Double(device.lensAperture), 0.1)
            let planned = Double(values.0) * values.1 / (aperture * aperture)
            let manual = GlobalMeteringPolicy.manualSample(sample, plannedExposureProduct: planned)
            // 手动建议跟随每次预览取样，不等场景稳定，也不下发任何曝光指令。
            manualGlobalMeteringSuggestion = GlobalMeteringPolicy.target(for: manual)
            globalMeteringPolicy.suspend()
            publishGlobalMetering(device)
            return
        }
        guard device.exposureMode != .custom else { globalMeteringPolicy.suspend(); return }
        guard let target = globalMeteringPolicy.consider(sample, adjusting: adjusting) else { return }
        let revision = globalMeteringRevision
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            let current = Double(device.exposureTargetBias - exposureBias)
            let correction = GlobalMeteringPolicy.appliedCorrection(target: target, current: current)
            let total = min(max(exposureBias + Float(correction), device.minExposureTargetBias), device.maxExposureTargetBias)
            globalBias = total - exposureBias
            device.setExposureTargetBias(total) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.globalMeteringRevision == revision, self.metering == .global,
                          self.input?.device.uniqueID == deviceID else { return }
                    self.globalMeteringPolicy.complete(at: CACurrentMediaTime())
                    self.publishGlobalMetering(device)
                }
            }
            publishGlobalMetering(device)
        } catch {
            globalMeteringPolicy.complete(at: sample.time)
        }
    }

    private func configureDevice(onFailure: (() -> Void)? = nil, restartLongPhotoExposure: Bool = false,
                                 _ action: @escaping (AVCaptureDevice) -> Void) {
        let lifecycle = recoveryRevision.current
        queue.async {
            guard let device = self.dualControlDevice else { onFailure?(); return }
            let state = self.livePreviewState.snapshot()
            // 原生对照观察到一秒曝光退出仍交付3–4张长帧；停止同一会话后归还AE，避免等待该队列。
            // 仅空闲普通照片M挡长曝光使用，不动镜头、格式、用户曝光或录像/人像/HDR原生预览。
            var restart = restartLongPhotoExposure && self.manualMode && !self.videoModeRequested
                && self.customExposureRequested && !self.usesSmoothManualPreviewExposure
                && !self.targetLockRequested && self.captureContexts.isEmpty
                && self.hdrPreviewSource == nil && !state.portraitPreviewEnabled
                && device.exposureMode == .custom && device.exposureDuration.seconds>=0.5
                && self.wantsRunning && self.session.isRunning && state.latestFrameHostTime.isFinite
                && self.recoveryRevision.matches(lifecycle)
            #if DEBUG
            if self.automaticExposureLegacyForTesting { restart = false }
            #endif
            if restart {
                #if DEBUG
                self.automaticExposureRestartsForTesting += 1
                #endif
                self.tracePhotoPhase("auto-return stream-stop")
                self.readingsGeneration &+= 1
                self.syncPreviewState()
                self.livePreviewState.update { $0.acceptsFrames = false }
                self.session.stopRunning()
            }
            defer {
                if restart, self.wantsRunning, self.recoveryRevision.matches(lifecycle) {
                    // 设备锁已由下面的do块释放；不得持锁调用startRunning。
                    self.session.startRunning()
                    let cutoff = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    self.livePreviewState.update { $0.framesNotBefore = cutoff; $0.warmupFrames = 1; $0.acceptsFrames = true }
                    self.tracePhotoPhase("auto-return stream-resumed")
                }
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                action(device)
            } catch { onFailure?(); self.report("参数调整失败：\(error.localizedDescription)") }
        }
    }

    func hasCaptureCapacity(for options: PhotoOptions) -> Bool {
        pendingCaptureWeight + captureWeight(options) <= 4
    }

    private func captureWeight(_ options: PhotoOptions) -> Int {
        if options.nightMode { return NightCapturePolicy.frameCount }
        return options.capturesLive || options.usesRAWCapture || options.resolution == .high || options.saveUnfilteredOriginal ? 2 : 1
    }

    func capture(flash: Bool) { capture(flashMode: flash ? .on : .off, options: PhotoOptions()) }

    private func lockPrearmedMacroFocus(_ device: AVCaptureDevice) {
        guard macroPreviewRoute != nil, !macroPreviewFocusLocked,
              device.deviceType == .builtInUltraWideCamera, device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setFocusModeLocked(lensPosition: min(max(device.lensPosition, 0), 1), completionHandler: nil)
            macroPreviewFocusLocked = true
        } catch { return }
    }

    /// 系统一判定微距就切到最终物理超广角，用户在这之后的预览上构图；
    /// 快门阶段不再切换输入，避免拍后构图轻微变化。
    private func updateMacroPhysicalPreview(active: Bool) {
        queue.async {
            if active { self.armMacroPhysicalPreview() }
            else { self.disarmMacroPhysicalPreview() }
        }
    }

    private func armMacroPhysicalPreview() {
        guard macroPreviewRoute == nil, captureContexts.isEmpty, !manualMode,
              let original = input, original.device.isVirtualDevice else { return }
        let virtual = original.device
        let displayZoom = virtual.videoZoomFactor * CameraLensCatalog.displayMultiplier(virtual)
        let primary = virtual.activePrimaryConstituent
        let fallback = lensCatalog.first(where: { $0.device.position == .back && $0.device.deviceType == .builtInUltraWideCamera })?.device
        guard macroActive, virtual.position == .back, displayZoom >= 0.99,
              let physical = primary?.deviceType == .builtInUltraWideCamera ? primary : fallback,
              let lens = lensCatalog.first(where: { $0.device.uniqueID == physical.uniqueID }),
              let replacement = try? reusableInput(for: physical) else { return }
        let base = lens.displayZoom / lens.zoomFactor
        session.beginConfiguration()
        session.removeInput(original)
        guard session.canAddInput(replacement) else {
            session.addInput(original); session.commitConfiguration(); return
        }
        session.addInput(replacement); input = replacement
        session.commitConfiguration()
        macroPreviewRoute = (original, physical.uniqueID)
        try? physical.lockForConfiguration()
        physical.videoZoomFactor = min(max(displayZoom / base, physical.minAvailableVideoZoomFactor), physical.maxAvailableVideoZoomFactor)
        if physical.isFocusPointOfInterestSupported { physical.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if physical.isFocusModeSupported(.continuousAutoFocus) { physical.focusMode = .continuousAutoFocus }
        physical.unlockForConfiguration()
        configureConnections(device: physical)
        configurePhotoOutput(physical, publish: false)
        syncPreviewState()
        #if DEBUG
        print("MACRO-PREVIEW-PHYSICAL input=\(physical.deviceType.rawValue)")
        #endif
    }

    private func disarmMacroPhysicalPreview() {
        guard let saved = macroPreviewRoute, captureContexts.isEmpty,
              input?.device.uniqueID == saved.physicalID, let current = input else { return }
        macroPreviewRoute = nil
        if macroPreviewFocusLocked {
            macroPreviewFocusLocked = false
            if let device = input?.device, device.isFocusModeSupported(.continuousAutoFocus) {
                try? device.lockForConfiguration(); device.focusMode = .continuousAutoFocus; device.unlockForConfiguration()
            }
        }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(saved.original) {
            session.addInput(saved.original); input = saved.original
        } else { session.addInput(current) }
        session.commitConfiguration()
        if let device = input?.device, device.isVirtualDevice {
            configureConnections(device: device)
            configurePhotoOutput(device, publish: false)
            syncPreviewState()
            configureAutomaticLensPolicy(device)
        }
    }

    /// 第一张微距后系统会把虚拟多摄切回主摄；锁住当前超广角一小段时间，
    /// 保证紧接着的第二张仍然走微距。
    private func holdMacroPrimaryConstituent(_ device: AVCaptureDevice) {
        guard device.isVirtualDevice, device.position == .back,
              device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
              device.primaryConstituentDeviceSwitchingBehavior != .unsupported else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
        } catch { return }
        // 延长锁定失败时保留上一次已排定的释放任务。
        macroLensHoldGeneration &+= 1
        let generation = macroLensHoldGeneration
        macroLensHoldUntil = CACurrentMediaTime() + 2.2
        #if DEBUG
        print("MACRO-HOLD locked generation=\(generation)")
        #endif
        queue.asyncAfter(deadline: .now() + 2.2) {
            guard generation == self.macroLensHoldGeneration else { return }
            self.macroLensHoldUntil = 0
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                }
            } catch { return }
        }
    }

    /// 微距超广角通常比主摄暗约0.5EV；仅在自动曝光下临时补偿，拍完恢复。
    private func applyMacroExposureBias(_ device: AVCaptureDevice) {
        guard macroExposureBiasRestore == nil, device.exposureMode == .continuousAutoExposure,
              macroActive || CACurrentMediaTime() - lastMacroCaptureAt < 5 || CameraMacroPolicy.isActive(manual: manualMode, virtual: device.isVirtualDevice,
                  rear: device.position == .back,
                  ultraWide: device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
                  displayZoom: device.videoZoomFactor * CameraLensCatalog.displayMultiplier(device)) else { return }
        let old = device.exposureTargetBias
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(min(old + 0.5, device.maxExposureTargetBias), completionHandler: nil)
            macroExposureBiasRestore = (device, old)
        } catch { return }
    }

    private func restoreMacroExposureBias() {
        guard let saved = macroExposureBiasRestore else { return }
        macroExposureBiasRestore = nil
        do {
            try saved.device.lockForConfiguration()
            saved.device.setExposureTargetBias(saved.bias, completionHandler: nil)
            saved.device.unlockForConfiguration()
        } catch {}
    }

    func capture(flashMode: CameraFlashMode, options: PhotoOptions) {
        guard ready, !shutterBusy, hasCaptureCapacity(for: options), canCapture() else { return }
        // 快门反馈先出当前预览占位；HDR编码稍后用最终成片替换。
        if let currentPreview = preview { onCaptureThumbnailReady?(currentPreview) }
        if let device = input?.device,
           macroActive || CameraMacroPolicy.isActive(manual: manualMode, virtual: device.isVirtualDevice,
               rear: device.position == .back,
               ultraWide: device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
               displayZoom: device.videoZoomFactor * CameraLensCatalog.displayMultiplier(device)) {
            lastMacroCaptureAt = CACurrentMediaTime()
        }
        let captureLocation = locationProvider?()
        let token = UUID()
        let sequence = nextCaptureSequence
        let callback = onCaptureCompleted, legacyCallback = onPhotoCaptured
        let completion: (CapturedPhoto?) -> Void = { photo in
            if let callback { callback(photo) }
            else if let photo { legacyCallback?(photo.preview) }
        }
        nextCaptureSequence &+= 1
        let weight = captureWeight(options)
        pendingPhotoCount += 1; pendingCaptureWeight += weight
        pendingCaptureTokens.insert(token)
        if options.nightMode { nightCaptureTokens.insert(token) }
        hardwareTokens.insert(token); shutterToken = token
        if options.capturesLive { liveCaptureToken = token }
        capturing = true; shutterBusy = true
        queue.async {
            self.stopFocusNavigatorOnQueue()
            var options = options
            #if !targetEnvironment(simulator)
            // Capability can change after the UI snapshot, particularly during a route switch.
            // Preserve the still photograph instead of asking the user to turn Live off.
            if options.capturesLive, let device = self.input?.device,
               !self.livePreviewRequested || !self.videoOutput.deliversPreviewSizedOutputBuffers || !self.photoOutput.isLivePhotoCaptureEnabled {
                self.livePreviewRequested = true
                self.configurePreviewOutput(device); self.configurePhotoOutput(device)
            }
            if options.capturesLive && (!self.photoOutput.isLivePhotoCaptureSupported ||
                !self.photoOutput.isLivePhotoCaptureEnabled || self.photoOutput.isLivePhotoCaptureSuspended) {
                options.live = false
                DispatchQueue.main.async { self.onLivePhotoUnavailable?() }
            }
            if options.nightMode {
                let canBracket = self.photoOutput.maxBracketedCapturePhotoCount >= NightCapturePolicy.frameCount
                    && self.input?.device.isExposureModeSupported(self.manualMode && self.customExposureRequested ? .custom : .continuousAutoExposure) == true
                if !canBracket {
                    options.nightMode = false
                    DispatchQueue.main.async { self.onNightCaptureUnavailable?() }
                }
            }
            if options.portraitMode && (!self.photoOutput.isDepthDataDeliveryEnabled ||
                !self.photoOutput.isPortraitEffectsMatteDeliveryEnabled ||
                !self.photoOutput.isDepthDataDeliverySupported || !self.photoOutput.isPortraitEffectsMatteDeliverySupported) {
                let hasProRAW = self.photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                let softwareCompatible = PortraitCapturePolicy.supports(format: options.format,
                    resolution: options.resolution, live: options.live, hdr: options.hdr, proRAWAvailable: hasProRAW)
                // 无原生蒙版时保留请求，让 finishCapture 使用实际照片的 Vision 后备蒙版。
                // 后面的 PhotoSettings 仍按真实管线能力关闭 depth/matte，避免不支持的系统请求。
                if !softwareCompatible {
                    options.portraitMode = false
                    DispatchQueue.main.async { self.onPortraitCaptureUnavailable?() }
                }
            }
            #endif
            var captureLook = (self.captureLookOverride ?? self.look).forOutput(options.format)
            var frontCaptureAngle: CGFloat?
            // 预览保持既有固定布局，照片独立按官方协调器写入方向元数据。
            // 仅在快门前更新 photoOutput，避免影响视频流或引入切镜重配。
            if let coordinator = self.frontPhotoRotationCoordinator,
               coordinator.device?.uniqueID == self.input?.device.uniqueID,
               let connection = self.photoOutput.connection(with: .video) {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                frontCaptureAngle = connection.videoRotationAngle
            }
            if let coordinator = self.rearCaptureRotationCoordinator,
               coordinator.device?.uniqueID == self.input?.device.uniqueID,
               let connection = self.photoOutput.connection(with: .video) {
                let angle = CaptureOrientation.cardinalAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                if options.format != .raw { captureLook.landscape = CaptureOrientation.rearLandscape(angle: connection.videoRotationAngle) }
                #if DEBUG
                print("REAR-PHOTO-ORIENTATION angle=\(connection.videoRotationAngle) landscape=\(captureLook.landscape)")
                #endif
            }
            // 以相机队列确认已应用的构图作为成片依据，避免界面状态异步时快门仍取旧方向。
            if self.input?.device.position == .front, options.format != .raw, captureLook.ratio != .square {
                captureLook.landscape = frontCaptureAngle.map {
                    CaptureOrientation.frontPhotoLandscape(sensorLandscape: self.frontPhotoLandscapeApplied, captureAngle: $0)
                } ?? self.frontPhotoLandscapeApplied
            }
            let physical = self.input?.device.isVirtualDevice == true ? self.input?.device.activePrimaryConstituent : self.input?.device
            if physical?.position != .back || ![AVCaptureDevice.DeviceType.builtInWideAngleCamera, .builtInTelephotoCamera].contains(physical?.deviceType ?? .builtInUltraWideCamera) {
                captureLook.virtualAperture = nil
                if options.shootingType == "虚拟光圈" { options.shootingType = "普通" }
            }
            captureLook.grainPhase = self.livePreviewState.snapshot().grainPhase
            let context = CaptureContext(sequence: sequence, token: token, look: captureLook, options: options,
                                         flashMode: flashMode, location: captureLocation, weight: weight, completion: completion)
            if self.input?.device.position == .back { context.captureRotationAngle = self.photoOutput.connection(with: .video)?.videoRotationAngle }
            context.manualWhiteBalanceForCapture = self.automaticWhiteBalanceRequested ? nil : self.manualWhiteBalanceValues
            #if DEBUG
            context.dropsFinalCallbackForTesting = self.dropFinalPhotoCallbackForTesting
            #endif
            context.usesPreviewExposureAssist = self.usesSmoothManualPreviewExposure
                && (self.manualMode || self.slowShutterSequencePreviewAssistEnabled)
                && self.customExposureRequested && self.manualExposureValues != nil
            // 普通 M 挡也保存快门瞬间的手动曝光，不能仅凭预览读数判定重配后的参数已生效。
            // 提交照片前等待官方曝光完成回调；预览辅助是否需要恢复仍由独立标志控制。
            context.manualExposureForCapture = !self.videoModeRequested && self.customExposureRequested
                && (self.manualMode || self.slowShutterSequencePreviewAssistEnabled) ? self.manualExposureValues : nil
            context.usesSlowShutterAutoPreviewAssist = self.slowShutterAutoPreviewOptimizationActive
                && self.slowShutterPreviewOptimizationRequested && !self.manualMode
                && self.slowShutterAutomaticExposureMaximumSeconds != nil
            context.slowShutterAEMaximumForCapture = context.usesSlowShutterAutoPreviewAssist
                ? self.slowShutterAutomaticExposureMaximumSeconds : nil
            if #available(iOS 26.0, *), let device = self.input?.device, device.position == .front {
                context.nativePortraitFrontSensor = !device.activeFormat.supportedDynamicAspectRatios.isEmpty
            }
            #if DEBUG
            let independentNightAllowed = !self.forceOrdinaryNightForTesting
            #else
            let independentNightAllowed = true
            #endif
            if options.nightMode, self.independentNightModeActive, independentNightAllowed, !self.videoModeRequested,
               self.currentZoom >= 0.5, self.currentZoom <= 8.0,
               let route = self.independentNightRoute(for: self.currentZoom) {
                self.captureIndependentNight(context: context, physical: route.device,
                                             baseDisplayZoom: route.baseDisplayZoom)
                return
            }
            self.zoomThrottle.flush()
            #if targetEnvironment(simulator)
            let source = ContinuousZoomPolicy.demoFrame(CIImage(image: DemoImageFactory.make())!, zoom: self.demoZoom)
            self.hardwareFinished(token: token)
            self.processingQueue.async { autoreleasepool { self.finishCapture(source: source, context: context) } }
            #else
            guard self.wantsRunning && self.session.isRunning else {
                self.hardwareFinished(token: token)
                self.completeCapture(context, photo: nil, message: "相机已停止，未完成拍摄。")
                return
            }
            let directSystemHDR = options.hdr && options.format == .heif && !options.adaptiveHighDynamic
                && context.look.ratio == .standard && context.look.style == .original && context.look.adjustments.isNeutral
                && context.look.virtualAperture == nil && !context.look.border && !options.portraitMode && !options.capturesLive
                && !options.saveUnfilteredOriginal
            if options.usesHDRHEIF && !directSystemHDR {
                // Preserve full photo/RAW quality: HLG streams do not expose RAW capture.
                // Keep the last live frame while temporarily restoring the still-photo route.
                context.nightPreviewHeld = true
                self.livePreviewState.update { $0.nightCapturePreviewHold = true }
                self.hdrStillCapturePreparing = true
                self.refreshHDRPreviewConfiguration()
            }
            defer {
                if self.captureContexts.isEmpty {
                    self.hdrStillCapturePreparing = false
                    self.refreshHDRPreviewConfiguration()
                    self.releaseNightPreviewHold(context)
                }
            }
            // 虚拟多摄不公开custom曝光时，只为本次用户按下的夜景快门借用系统已选中的物理镜头。
            // 普通取景与自动微距仍由原虚拟多摄选择；不强制主摄，不依据距离主动切镜。
            if options.nightMode, context.manualExposureForCapture == nil {
                do { try self.prepareNightAutomaticRoute(context) }
                catch {
                    self.hardwareFinished(token: token)
                    self.completeCapture(context, photo: nil, message: "准备夜景曝光失败：\(error.localizedDescription)")
                    return
                }
            } else if self.manualMode {
                // A 挡始终保留系统虚拟多摄输入，快门不再造成第二次预览切镜。
                do { try self.prepareMacroAutomaticRoute(context) }
                catch {
                    self.hardwareFinished(token: token)
                    self.completeCapture(context, photo: nil, message: "准备微距拍摄失败：\(error.localizedDescription)")
                    return
                }
            }
            let settings: AVCapturePhotoSettings
            var bayerRAW = false
            var canCaptureNight = options.nightMode
            let captureDevice = self.input?.device
            if let captureDevice { self.lockPrearmedMacroFocus(captureDevice) }
            if let captureDevice {
                if captureDevice.deviceType == .builtInUltraWideCamera, self.macroPhysicalHoldRoute != nil || CACurrentMediaTime() < self.macroPhysicalHoldUntil {
                    self.macroPhysicalHoldUntil = CACurrentMediaTime() + 5.0
                    // 连续拍摄延长保持时间后，需要重新安排恢复；旧任务到期会因期限尚未到达而退出。
                    if self.macroPhysicalHoldRoute != nil { self.scheduleMacroPhysicalRestore() }
                }
                self.applyMacroExposureBias(captureDevice)

            }
            if canCaptureNight && (captureDevice?.isExposureModeSupported(context.manualExposureForCapture != nil ? .custom : .continuousAutoExposure) != true
                || self.photoOutput.maxBracketedCapturePhotoCount < NightCapturePolicy.frameCount) {
                canCaptureNight = false
                options.nightMode = false
                context.options.nightMode = false
                DispatchQueue.main.async { self.onNightCaptureUnavailable?() }
            }
            // 苹果手动包围曝光将真实曝光参数绑定到静态请求；这里只请求一张，
            // 保留现有逐帧进度、提前结束和取消语义，不等待取景器先切成长曝光。
            let bracketExposure = context.manualExposureForCapture
            var manualBracketAllowed = options.prefersManualExposureBracket
                && !(context.usesPreviewExposureAssist && options.purpose == .standard)
                && options.resolution == .standard
                && !options.usesRAWCapture && !options.capturesLive && !options.nightMode && !options.portraitMode
                && self.photoOutput.maxBracketedCapturePhotoCount >= 1
            #if DEBUG
            manualBracketAllowed = manualBracketAllowed && !self.slowShutterManualBracketDisabledForTesting
            #endif
            if manualBracketAllowed, let device = captureDevice, let exposure = bracketExposure,
               self.supportsManualBracket(device, seconds: exposure.seconds, iso: exposure.iso),
               exposure.seconds >= device.activeFormat.minExposureDuration.seconds,
               exposure.seconds <= device.activeFormat.maxExposureDuration.seconds,
               exposure.iso >= device.activeFormat.minISO, exposure.iso <= device.activeFormat.maxISO {
                let codec: AVVideoCodecType = options.format == .heif && self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                let frame = AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(seconds: exposure.seconds, preferredTimescale: 1_000_000_000), iso: exposure.iso)
                settings = AVCapturePhotoBracketSettings(rawPixelFormatType: 0,
                    processedFormat: [AVVideoCodecKey: codec], bracketedSettings: [frame])
                context.usesManualExposureBracket = true
            } else if canCaptureNight, let device = captureDevice {
                let meteringBias = NightManualExposurePolicy.meteringBias(userBias:Double(self.exposureBias+self.globalBias),
                    customExposure:device.exposureMode == .custom,offsetEV:Double(device.exposureTargetOffset))
                var index = meteringBias.flatMap { NightAdaptiveCapturePolicy.exposureIndex(
                    iso: context.nightMeteredExposure?.iso ?? Double(device.iso),
                    seconds: context.nightMeteredExposure?.seconds ?? device.exposureDuration.seconds, bias: $0) }
                #if DEBUG
                if let override = self.nightExposureIndexForTesting { index = override }
                #endif
                context.nightExposureIndex = index
                context.nightTargetFrames = NightAdaptiveCapturePolicy.targetFrameCount(
                    exposureIndex: index, constrained: self.nightCaptureIsResourceConstrained)
                context.nightRouteGeneration = self.readingsGeneration
                context.nightPrimaryDeviceID = (device.activePrimaryConstituent ?? device).uniqueID
                context.nightStopReason = context.nightTargetFrames > 3 ? "等待场景稳定性评估" : "环境或资源条件采用三帧"
                settings = self.makeNightCaptureSettings(context: context, device: device,
                                                        biases: NightCapturePolicy.exposureTargetBiases)
            } else if options.usesRAWCapture {
                guard let pixelFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                        ?? self.photoOutput.availableRawPhotoPixelFormatTypes.first else {
                    self.report("当前镜头不支持 RAW，请选择其他格式。")
                    self.hardwareFinished(token: token)
                    self.completeCapture(context, photo: nil, message: nil); return
                }
                bayerRAW = AVCapturePhotoOutput.isBayerRAWPixelFormat(pixelFormat)
                if bayerRAW && abs((self.input?.device.videoZoomFactor ?? 1) - 1) > 0.001 {
                    self.report("此镜头的 RAW 仅支持原生倍率，请切换倍率或使用 JPG。")
                    self.hardwareFinished(token: token)
                    self.completeCapture(context, photo: nil, message: nil); return
                }
                settings = AVCapturePhotoSettings(rawPixelFormatType: pixelFormat, processedFormat: options.format == .rawJPEG ? [AVVideoCodecKey: AVVideoCodecType.jpeg] : nil)
            } else {
                let codec: AVVideoCodecType = options.format == .heif && self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            }
            // 输入提交后系统可能才换到最终照片格式。逐张核对原生尺寸，避免
            // UI 已公布 48MP，而缓存仍是切换前的 12MP，导致第一张降分辨率。
            if let device = self.input?.device, !options.nightMode {
                let current = device.activeFormat.supportedMaxPhotoDimensions.sorted {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }
                if current.map({ "\($0.width)x\($0.height)" }) != self.photoDimensions.map({ "\($0.width)x\($0.height)" }) {
                    self.configurePhotoOutput(device)
                }
            }
            let macroNow: Bool = {
                guard let device = self.input?.device else { return false }
                let recentMacro = CACurrentMediaTime() - self.lastMacroCaptureAt < 5
                return self.macroActive || recentMacro || CameraMacroPolicy.isActive(manual: self.manualMode, virtual: device.isVirtualDevice,
                    rear: device.position == .back,
                    ultraWide: device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
                    displayZoom: device.videoZoomFactor * CameraLensCatalog.displayMultiplier(device))
            }()
            // 标准档恢复即时12MP，显式高像素仍按原路由能力请求48MP；不启用24MP延迟代理。
            let requested = options.resolution == .high ? self.photoDimensions.last
                : self.photoDimensions.last(where: { Int64($0.width) * Int64($0.height) <= 16_000_000 }) ?? self.photoDimensions.first
            // Bracketed capture supports only the documented shared photo settings;
            // its default dimensions are the active format's standard resolution.
            if let requested, !options.nightMode {
                let outputMax = self.photoOutput.maxPhotoDimensions
                settings.maxPhotoDimensions = CMVideoDimensions(
                    width: min(requested.width, outputMax.width),
                    height: min(requested.height, outputMax.height))
            }
            #if DEBUG
            if let callback = self.onPhotoRequestDimensionsForTesting {
                let dimensions = settings.maxPhotoDimensions
                DispatchQueue.main.async { callback(dimensions) }
            }
            #endif
            if macroNow, self.photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled,
               let device = self.input?.device, device.isVirtualDevice,
               let ultraWide = device.constituentDevices.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
                // 官方允许指定 constituent 子集；仅交付超广角，避免同时请求主摄。
                settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = [ultraWide]
                if self.photoOutput.isVirtualDeviceFusionSupported { settings.isAutoVirtualDeviceFusionEnabled = false }
                context.macroConstituentCapture = true
            }
            settings.metadata = PhotoMetadata.capture(location: captureLocation, copyright: options.copyright)
            if !(settings is AVCapturePhotoBracketSettings), self.photoOutput.supportedFlashModes.contains(flashMode.avMode) { settings.flashMode = flashMode.avMode }
            if !options.nightMode {
                if options.shootingType == "连拍", !bayerRAW {
                    // 连拍优先降低每张照片的管线延迟，画质处理让位于拍摄节奏。
                    settings.photoQualityPrioritization = .speed
                } else {
                    // 明确的高像素请求不能沿用M挡为速度优先的普通12MP策略。
                    settings.photoQualityPrioritization = options.resolution == .high && context.manualExposureForCapture == nil
                        ? .balanced : NightCapturePolicy.qualityPriority(
                        nightMode: false, usesRAW: bayerRAW,
                        usesManualExposure: context.usesPreviewExposureAssist || self.input?.device.exposureMode == .custom,
                        maximum: self.photoOutput.maxPhotoQualityPrioritization)
                }
            }
            // 普通HEIF HDR在通用策略之后设定画质优先，避免被balanced覆盖。
            // 用户手动曝光仍沿用speed策略，不能让计算摄影改写指定快门/ISO。
            if directSystemHDR, !self.customExposureRequested, context.manualExposureForCapture == nil,
               self.photoOutput.maxPhotoQualityPrioritization == .quality {
                settings.photoQualityPrioritization = .quality
            }
            #if DEBUG
            if directSystemHDR, let callback = self.onHEIFHDRQualityForTesting {
                let value = settings.photoQualityPrioritization.rawValue
                DispatchQueue.main.async { callback(value) }
            }
            #endif

            // Apple ProRAW doesn't use AVFoundation depth/matte delivery. Its portrait
            // matte is scene-dependent auxiliary data embedded in the ProRAW DNG and
            // is decoded below through Core Image. Request the AVFoundation matte only
            // for processed JPEG/HEIF captures.
            // 微距优先于人像：用提交时的实际主镜头判断，不依赖延迟发布给界面的
            // macroActive（它会受采样间隔和切镜提示抑制影响）。只暂停本张人像效果，
            // 不关闭用户的人像开关，也不干预系统虚拟多摄的镜头选择。
            if let device = self.input?.device,
               CameraMacroPolicy.isActive(manual: self.manualMode, virtual: device.isVirtualDevice,
                    rear: device.position == .back,
                    ultraWide: device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
                    displayZoom: device.videoZoomFactor * CameraLensCatalog.displayMultiplier(device)) {
                options.portraitMode = false
                context.options.portraitMode = false
                if context.options.shootingType == "人像" { context.options.shootingType = "普通" }
                self.tracePhotoPhase("portrait-suspended-for-system-macro")
            }
            let portraitDeliveryEnabled = options.portraitMode && !options.usesRAWCapture &&
                self.photoOutput.isDepthDataDeliverySupported && self.photoOutput.isPortraitEffectsMatteDeliverySupported &&
                self.photoOutput.isDepthDataDeliveryEnabled && self.photoOutput.isPortraitEffectsMatteDeliveryEnabled
            settings.isDepthDataDeliveryEnabled = portraitDeliveryEnabled
            settings.isPortraitEffectsMatteDeliveryEnabled = portraitDeliveryEnabled
            settings.embedsDepthDataInPhoto = portraitDeliveryEnabled
            settings.embedsPortraitEffectsMatteInPhoto = portraitDeliveryEnabled
            if portraitDeliveryEnabled { context.nativePortraitDeviceID = self.input?.device.uniqueID }

            if options.capturesLive {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Live-" + UUID().uuidString + ".mov")
                context.liveMovieURL = url
                settings.livePhotoMovieFileURL = url
            }
            self.captureContexts[settings.uniqueID] = context
            self.submitPhotoCapture(settings, context: context)
            #endif
        }
    }

    private var nightCaptureIsResourceConstrained: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return false
        case .serious, .critical: return true
        @unknown default: return true
        }
    }

    // 仅会话队列访问；各组以token归还原输入，失败、取消与超时共用hardwareFinished清理。
    private var nightAutomaticRoutes: [UUID: (original: AVCaptureDeviceInput, physicalID: String)] = [:]
    private var macroAutomaticRoutes: [UUID: (original: AVCaptureDeviceInput, physicalID: String)] = [:]
    private var macroExposureBiasRestore: (device: AVCaptureDevice, bias: Float)?
    private var macroLensHoldGeneration = 0
    private var macroLensHoldUntil: TimeInterval = 0
    private var lastMacroCaptureAt: TimeInterval = 0
    private var macroPhysicalHoldRoute: (original: AVCaptureDeviceInput, physicalID: String)?
    private var macroPhysicalHoldUntil: TimeInterval = 0
    private var macroPhysicalHoldGeneration = 0
    private var macroPreviewRoute: (original: AVCaptureDeviceInput, physicalID: String)?
    private var macroPreviewFocusLocked = false
    private func scheduleMacroPhysicalRestore() {
        macroPhysicalHoldGeneration &+= 1
        let generation = macroPhysicalHoldGeneration
        queue.asyncAfter(deadline: .now() + 5.0) {
            guard generation == self.macroPhysicalHoldGeneration,
                  CACurrentMediaTime() >= self.macroPhysicalHoldUntil,
                  let saved = self.macroPhysicalHoldRoute else { return }
            // 仍在微距时继续保持超广角，避免定时到期造成预览放大。
            if self.macroActive {
                self.macroPhysicalHoldUntil = CACurrentMediaTime() + 5.0
                self.scheduleMacroPhysicalRestore()
                return
            }
            self.macroPhysicalHoldRoute = nil
            self.restorePhysicalInput(saved)
        }
    }

    private func restorePhysicalInput(_ saved: (original: AVCaptureDeviceInput, physicalID: String)) {
        guard input?.device.uniqueID == saved.physicalID, let current = input else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(saved.original) { session.addInput(saved.original); input = saved.original }
        else { session.addInput(current) }
        session.commitConfiguration()
        if let device = input?.device, device.isVirtualDevice {
            configureConnections(device: device)
            configurePhotoOutput(device, publish: false)
            syncPreviewState()
            // 重接虚拟多摄后 fallback 可能被系统重置成仅主摄；恢复完整支持集合。
            configureAutomaticLensPolicy(device)
        }
    }

    /// 自动微距预览可能使用虚拟多摄的超广角 constituent，但照片请求会重新选主摄。
    /// 快门时临时切到当前超广角物理输入，拍完恢复虚拟输入。
    private func prepareMacroAutomaticRoute(_ capture: CaptureContext) throws {
        guard let original = input, original.device.isVirtualDevice else { return }
        let virtual = original.device
        let displayZoom = virtual.videoZoomFactor * CameraLensCatalog.displayMultiplier(virtual)
        let policyMacro = CameraMacroPolicy.isActive(manual: manualMode, virtual: true, rear: true,
            ultraWide: virtual.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera,
            displayZoom: displayZoom)
        // 快门瞬间系统可能已经切回主摄；预览宏标仍为真时也按微距处理。
        let detectedMacro = policyMacro || (macroActive && displayZoom >= 0.99)
            || CACurrentMediaTime() - lastMacroCaptureAt < 5
        let physical = virtual.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera
            ? virtual.activePrimaryConstituent
            : lensCatalog.first { $0.device.position == .back && $0.device.deviceType == .builtInUltraWideCamera }?.device
        guard virtual.position == .back, detectedMacro,
              let physical, physical.deviceType == .builtInUltraWideCamera,
              let lens = lensCatalog.first(where: { $0.device.uniqueID == physical.uniqueID }) else { return }
        #if DEBUG
        print("MACRO-ROUTE active=\(macroActive) policy=\(policyMacro) primary=\(virtual.activePrimaryConstituent?.deviceType.rawValue ?? "nil") zoom=\(displayZoom)")
        #endif
        let base = lens.displayZoom / lens.zoomFactor
        let replacement = try reusableInput(for: physical)
        session.beginConfiguration()
        session.removeInput(original)
        guard session.canAddInput(replacement) else {
            session.addInput(original); session.commitConfiguration(); throw CameraError.unavailable
        }
        session.addInput(replacement); input = replacement
        session.commitConfiguration()
        macroAutomaticRoutes[capture.token] = (original, physical.uniqueID)
        macroPhysicalHoldUntil = CACurrentMediaTime() + 5.0
        macroPhysicalHoldRoute = nil
        try physical.lockForConfiguration()
        physical.videoZoomFactor = min(max(displayZoom / base, physical.minAvailableVideoZoomFactor), physical.maxAvailableVideoZoomFactor)
        if physical.isFocusPointOfInterestSupported { physical.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        // 切到可能尚未合焦的超广角物理镜头，先主动AF并等待稳定，
        // 再锁住镜片位置；只锁当前位置可能在无穷远。
        if physical.isFocusModeSupported(.autoFocus) {
            physical.focusMode = .autoFocus
            let deadline = CACurrentMediaTime() + 0.25
            while CACurrentMediaTime() < deadline && physical.isAdjustingFocus {
                Thread.sleep(forTimeInterval: 0.02)
            }
            // AF 可能刚结束，再给一个很短的收敛窗口。
            Thread.sleep(forTimeInterval: 0.06)
        }
        if physical.isFocusModeSupported(.locked) {
            physical.setFocusModeLocked(lensPosition: min(max(physical.lensPosition, 0), 1), completionHandler: nil)
        } else if physical.isFocusModeSupported(.continuousAutoFocus) {
            physical.focusMode = .continuousAutoFocus
        }
        if virtual.whiteBalanceMode == .locked, physical.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            var gains = virtual.deviceWhiteBalanceGains
            gains.redGain = min(max(1, gains.redGain), physical.maxWhiteBalanceGain)
            gains.greenGain = min(max(1, gains.greenGain), physical.maxWhiteBalanceGain)
            gains.blueGain = min(max(1, gains.blueGain), physical.maxWhiteBalanceGain)
            physical.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if physical.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            physical.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        physical.unlockForConfiguration()
        configureConnections(device: physical)
        configurePhotoOutput(physical, publish: false)
        syncPreviewState()
    }

    private func restoreMacroAutomaticRoute(token: UUID) {
        guard let saved = macroAutomaticRoutes.removeValue(forKey: token) else { return }
        if CACurrentMediaTime() < macroPhysicalHoldUntil {
            // 保持物理超广角，预览和下一张都不切回主摄。
            macroPhysicalHoldRoute = saved
            scheduleMacroPhysicalRestore()
            return
        }
        guard input?.device.uniqueID == saved.physicalID, let current = input else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(saved.original) {
            session.addInput(saved.original); input = saved.original
        } else {
            session.addInput(current)
        }
        session.commitConfiguration()
        if let device = input?.device, device.isVirtualDevice {
            configureConnections(device: device)
            configurePhotoOutput(device, publish: false)
            syncPreviewState()
            configureAutomaticLensPolicy(device)
        }
    }

    private func prepareNightAutomaticRoute(_ capture: CaptureContext, forcePhysical: Bool = false) throws {
        guard let original = input, original.device.isVirtualDevice else { return }
        // 即使后续不需要主动借用物理输入，也要记住原虚拟输入。
        // 2 秒长曝光期间系统的自动镜头可能切到物理主摄，结束时必须归还。
        if nightAutomaticRoutes[capture.token] == nil,
           let physical = original.device.activePrimaryConstituent {
            nightAutomaticRoutes[capture.token] = (original, physical.uniqueID)
        }
        guard !original.device.isExposureModeSupported(.custom),
              let physical = original.device.activePrimaryConstituent,
              physical.isExposureModeSupported(.custom),
              let lens = lensCatalog.first(where: { $0.device.uniqueID == physical.uniqueID }) else { return }
        let virtual = original.device
        capture.nightMeteredExposure = .init(seconds: virtual.exposureDuration.seconds, iso: Double(virtual.iso))
        let displayZoom = virtual.videoZoomFactor * CameraLensCatalog.displayMultiplier(virtual)
        let base = lens.displayZoom / lens.zoomFactor
        let replacement = try reusableInput(for: physical)
        session.beginConfiguration()
        session.removeInput(original)
        guard session.canAddInput(replacement) else {
            session.addInput(original); session.commitConfiguration(); throw CameraError.unavailable
        }
        session.addInput(replacement); input = replacement
        session.commitConfiguration()
        nightAutomaticRoutes[capture.token] = (original, physical.uniqueID)
        try physical.lockForConfiguration()
        physical.videoZoomFactor = min(max(displayZoom / base, physical.minAvailableVideoZoomFactor), physical.maxAvailableVideoZoomFactor)
        // 保留虚拟路线实际对焦点；不重新给出一次居中对焦指令。
        if physical.isFocusPointOfInterestSupported { physical.focusPointOfInterest = virtual.focusPointOfInterest }
        if physical.isFocusModeSupported(virtual.focusMode) { physical.focusMode = virtual.focusMode }
        if virtual.whiteBalanceMode == .locked, physical.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            var gains = virtual.deviceWhiteBalanceGains
            gains.redGain = min(max(1, gains.redGain), physical.maxWhiteBalanceGain)
            gains.greenGain = min(max(1, gains.greenGain), physical.maxWhiteBalanceGain)
            gains.blueGain = min(max(1, gains.blueGain), physical.maxWhiteBalanceGain)
            physical.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if physical.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            physical.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        physical.unlockForConfiguration()
        configureConnections(device: physical)
        configurePhotoOutput(physical, publish: false)
        syncPreviewState()
        capture.nightPhysicalDeviceName = physical.localizedName
        capture.nightRouteStartedAt = CACurrentMediaTime()
    }

    private func restoreNightAutomaticRoute(token: UUID) {
        guard let saved = nightAutomaticRoutes.removeValue(forKey: token), input?.device.uniqueID == saved.physicalID,
              let current = input else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(saved.original) {
            session.addInput(saved.original); input = saved.original
        } else {
            session.addInput(current)
            report("夜景拍摄已结束，但自动镜头路线恢复失败，请重新连接相机。")
        }
        session.commitConfiguration()
        if let device = input?.device {
            if device.isVirtualDevice {
                // 长曝光期间系统的自动镜头选择可能停在物理主摄；归还输入后
                // 重新交给虚拟多摄自动选择，避免预览停留在 5 号物理 constituent。
                resumeAutomaticLensSelectionForUserZoom(device)
                do {
                    try device.lockForConfiguration()
                    device.fallbackPrimaryConstituentDevices = device.supportedFallbackPrimaryConstituentDevices
                    if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                        device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                    }
                    let factor = min(max(device.videoZoomFactor, 1), device.maxAvailableVideoZoomFactor)
                    device.videoZoomFactor = factor
                    device.unlockForConfiguration()
                } catch {}
                try? prepareAutomaticRoute(device, factor: 1)
            }
            configureConnections(device: device)
            configurePhotoOutput(device, publish: false)
            syncPreviewState()
        }
    }

    private func supportsManualBracket(_ device: AVCaptureDevice, seconds: Double, iso: Float) -> Bool {
        guard device.isExposureModeSupported(.custom) else { return false }
        if #available(iOS 27.0, *) {
            return device.activeFormat.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), iso: iso)
        }
        return seconds >= device.activeFormat.minExposureDuration.seconds
            && seconds <= device.activeFormat.maxExposureDuration.seconds
            && iso >= device.activeFormat.minISO && iso <= device.activeFormat.maxISO
    }

    private func makeNightCaptureSettings(context: CaptureContext, device: AVCaptureDevice,
                                          biases: [Float]) -> AVCapturePhotoBracketSettings {
        let codec: AVVideoCodecType = context.options.format == .heif && photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let frames: [AVCaptureBracketedStillImageSettings]
        if let manual = context.manualExposureForCapture {
            // M挡手动曝光：所有批次都重复快门瞬间的同一参数，不用±EV擅改用户快门或ISO。
            frames = biases.map { _ in AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration:CMTime(seconds:manual.seconds,preferredTimescale:1_000_000_000),iso:manual.iso) }
            context.usesManualExposureBracket = true
        } else if device.isExposureModeSupported(.custom),
                  device.activeFormat.minExposureDuration.seconds > 0,
                  device.activeFormat.maxExposureDuration.seconds.isFinite {
            let durations = device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds
            let sensitivities = Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO)
            if context.nightAutomaticExposure == nil {
                context.nightAutomaticExposure = NightAdaptiveCapturePolicy.automaticExposure(
                    iso: context.nightMeteredExposure?.iso ?? Double(device.iso),
                    seconds: context.nightMeteredExposure?.seconds ?? device.exposureDuration.seconds,
                    durationRange: durations.lowerBound...min(durations.upperBound,
                        max(durations.lowerBound, NightAdaptiveCapturePolicy.handheldMaximumExposureSeconds)),
                    isoRange: sensitivities)
                #if DEBUG
                if let planned = nightAutomaticExposureForTesting { context.nightAutomaticExposure = planned }
                #endif
            }
            if let base = context.nightAutomaticExposure {
                var usesControlledFrameTarget = false
                #if DEBUG
                usesControlledFrameTarget = nightExposureIndexForTesting != nil
                #endif
                if !usesControlledFrameTarget {
                    context.nightTargetFrames = NightAdaptiveCapturePolicy.targetFrameCount(
                        exposureIndex:context.nightExposureIndex, constrained:nightCaptureIsResourceConstrained,
                        automaticExposure:base)
                }
                frames = biases.map { bias in
                    // 基准本身已按暗度增加曝光；两张相同基准优先保证可融合样本，短帧保护亮部。
                    // 不再对已提亮基准额外加亮，减少首次三帧都因亮度/运动差异而无法配准。
                    let exposure = NightAdaptiveCapturePolicy.bracket(base, bias: Double(min(bias, 0)),
                        durationRange: durations.lowerBound...min(durations.upperBound,
                            max(durations.lowerBound, NightAdaptiveCapturePolicy.handheldMaximumExposureSeconds)),
                        isoRange: sensitivities)
                    return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                        exposureDuration: CMTime(seconds: exposure.seconds, preferredTimescale: 1_000_000_000), iso: Float(exposure.iso))
                }
            } else {
                frames = biases.map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                    exposureTargetBias: min(max($0, device.minExposureTargetBias), device.maxExposureTargetBias)) }
            }
        } else {
            frames = biases.map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                exposureTargetBias:min(max($0,device.minExposureTargetBias),device.maxExposureTargetBias)) }
        }
        let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: 0,
            processedFormat: [AVVideoCodecKey: codec], bracketedSettings: frames)
        if photoOutput.isLensStabilizationDuringBracketedCaptureSupported { settings.isLensStabilizationEnabled = true }
        settings.photoQualityPrioritization = NightCapturePolicy.qualityPriority(
            nightMode: context.manualExposureForCapture == nil, usesRAW: false,
            usesManualExposure: context.manualExposureForCapture != nil,
            maximum: photoOutput.maxPhotoQualityPrioritization)
        settings.metadata = PhotoMetadata.capture(location: context.location, copyright: context.options.copyright)
        return settings
    }

    /// 批次间仅分析小图；字典继续持有组上下文，分析期间仍保持快门忙碌，不允许穿插镜头/模式切换。
    private func continueAdaptiveNightCaptureIfNeeded(_ capture: CaptureContext, uniqueID: Int64, error: Error?) -> Bool {
        guard !capture.nightCancelled, error == nil, wantsRunning, session.isRunning,
              capture.nightSubmittedFrames < capture.nightTargetFrames,
              capture.nightFrames.count == capture.nightSubmittedFrames else {
            if error != nil || capture.nightFrames.count != capture.nightSubmittedFrames { capture.nightStopReason = "曝光帧不完整，停止追加" }
            return false
        }
        let frames = capture.nightFrames
        let latest = Array(frames.suffix(3).map(\.data))
        guard let reference = frames.first(where: { $0.sequence == 2 })?.data else { return false }
        // 上一批实测包含曝光与系统回调。首批有一张短帧，追加三张正常曝光还需检查曝光下限。
        let lastBatchSeconds = capture.nightBatchSubmittedAt.map { CACurrentMediaTime() - $0 } ?? 0
        let baseSeconds = capture.manualExposureForCapture?.seconds ?? capture.nightAutomaticExposure?.seconds ?? 0
        let nextBatchSeconds = max(lastBatchSeconds, 3 * baseSeconds)
        processingQueue.async {
            self.tracePhotoPhase("night-motion-start")
            let assessment = autoreleasepool { () -> NightSceneAssessment in
                let images = latest.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
                guard images.count == 3, let base = CIImage(data: reference, options: [.applyOrientationProperty: true]) else {
                    return NightSceneAssessment(motion: .unknown)
                }
                return NightPhotoMerger.assessMotion(images, reference: base, context: self.context)
            }
            self.tracePhotoPhase("night-motion-end")
            self.queue.async {
                guard self.captureContexts[uniqueID] === capture else { return }
                var motion = assessment.motion
                #if DEBUG
                if let override = self.nightMotionForTesting { motion = override }
                #endif
                var diagnostics = capture.diagnostics ?? PhotoCaptureDiagnostics()
                diagnostics.add("夜景运动评估", String(format: "%@，最大位移 %.2f%%，变化区域 %.1f%%", motion.rawValue,
                    assessment.maximumShift * 100, assessment.changedFraction * 100) + (assessment.reason.isEmpty ? "" : "（\(assessment.reason)）"))
                capture.diagnostics = diagnostics
                let constrained = self.nightCaptureIsResourceConstrained
                let sameRoute = self.readingsGeneration == capture.nightRouteGeneration
                    && self.input.map { ($0.device.activePrimaryConstituent ?? $0.device).uniqueID } == capture.nightPrimaryDeviceID
                let shouldContinue = NightAdaptiveCapturePolicy.shouldContinue(target: capture.nightTargetFrames,
                    submitted: capture.nightSubmittedFrames, received: capture.nightFrames.count, motion: motion,
                    elapsed: CACurrentMediaTime() - capture.nightStarted,
                    nextBatchSeconds: nextBatchSeconds,
                    compressedBytes: capture.nightFrames.reduce(0) { $0 + $1.data.count }, constrained: constrained)
                guard !capture.nightCancelled, self.wantsRunning, self.session.isRunning, sameRoute,
                      shouldContinue, self.photoOutput.maxBracketedCapturePhotoCount >= 3, let device = self.input?.device else {
                    capture.nightStopReason = capture.nightCancelled ? "退出相机，取消序列"
                        : (!sameRoute ? "镜头路线变化，停止追加" : (constrained ? "资源限制，停止追加"
                            : (motion == .stable ? "时间或数据预算限制，停止追加" : "\(motion.rawValue)，停止追加")))
                    self.finishPhotoCapture(uniqueID: uniqueID, error: error)
                    return
                }
                self.captureContexts.removeValue(forKey: uniqueID)
                capture.nightBatchOffset = capture.nightSubmittedFrames
                capture.nightSubmittedFrames += 3
                capture.nightStopReason = motion == .unknown ? "暗景评估未知，补足降噪帧并逐区域保护" : "画面可配准，追加降噪帧"
                // 首批保留高光/暗部包围，追加批次使用相同 AE 目标以增加有效降噪样本。
                let settings = self.makeNightCaptureSettings(context: capture, device: device, biases: [0, 0, 0])
                self.captureContexts[settings.uniqueID] = capture
                self.submitPhotoCapture(settings, context: capture)
            }
        }
        return true
    }

    #if DEBUG
    /// 仅测试注入环境/运动条件，以核对 6/9 帧真实硬件批次，不改变正式版本的自动判定。
    func nightBracketLimitForTesting(_ completion: @escaping (Int) -> Void) {
        queue.async {
            let count = self.photoOutput.maxBracketedCapturePhotoCount
            DispatchQueue.main.async { completion(count) }
        }
    }
    func nightRouteIdentityForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            let device = self.input?.device
            let value = "\(self.readingsGeneration):\(device?.uniqueID ?? "none"):\((device?.activePrimaryConstituent ?? device)?.uniqueID ?? "none")"
            DispatchQueue.main.async { completion(value) }
        }
    }
    var nightExposureIndexForTesting: Double?
    var nightAutomaticExposureForTesting: NightAdaptiveCapturePolicy.Exposure?
    var nightMotionForTesting: NightSceneMotion?
    var onNightBatchSubmittedForTesting: ((Int) -> Void)?
    var onNightSourceForTesting: ((Data,Int) -> Void)?
    /// 仅诊断普通HEIF HDR的系统原始资源，不写相册、不参与正式处理。
    var onProcessedHEIFHDRForTesting: ((Data) -> Void)?
    var onHEIFHDRQualityForTesting: ((Int) -> Void)?
    /// 验证测光归属及残留补偿；只读硬件状态，返回值不用于正式曝光控制。
    func meteringStateForTesting(_ completion: @escaping (CameraMetering, Float, Float, Float) -> Void) {
        queue.async {
            let mode = self.metering, user = self.exposureBias, extra = self.globalBias
            let actual = self.input?.device.exposureTargetBias ?? .nan
            DispatchQueue.main.async { completion(mode, user, extra, actual) }
        }
    }
    /// 用已知亮度触发一次既有全局测光算法，避免测试依赖现场亮度是否恰好产生负补偿。
    func submitGlobalMeteringSampleForTesting(mean: Double) {
        queue.async {
            guard let device = self.input?.device else { return }
            self.globalMeteringPolicy.reset()
            let now = CACurrentMediaTime()
            for offset in [-0.8, -0.4, 0.0] {
                let sample = GlobalMeteringPolicy.Sample(mean: mean, shape: [0], exposureProduct: 1,
                    deviceBias: Double(device.exposureTargetBias), userBias: Double(self.exposureBias),
                    time: now + offset, route: device.uniqueID)
                self.updateGlobalMetering(sample, deviceID: device.uniqueID, generation: self.readingsGeneration, adjustingForTesting: false)
            }
        }
    }
    var onGlobalMeteringObservationForTesting: ((String) -> Void)?
    /// 全局测光建议不得改写全手动曝光；读取真实设备而非界面数值。
    func globalMeteringManualExposureForTesting(_ completion: @escaping (Double, Double) -> Void) {
        queue.async {
            let iso = Double(self.input?.device.iso ?? 0)
            let seconds = self.input?.device.exposureDuration.seconds ?? 0
            DispatchQueue.main.async { completion(iso, seconds) }
        }
    }
    func heifExposureSnapshotForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            let value = "requested=\(self.exposureBias) global=\(self.globalBias) hardware=\(self.input?.device.exposureTargetBias ?? .nan) metering=\(self.metering.rawValue)"
            DispatchQueue.main.async { completion(value) }
        }
    }
    private func notifyNightBatchSubmitted(_ capture: CaptureContext) {
        let submitted = capture.nightSubmittedFrames
        if let callback = onNightBatchSubmittedForTesting { DispatchQueue.main.async { callback(submitted) } }
    }
    #endif

    private func tracePhotoPhase(_ phase: String) {
        #if DEBUG
        guard photoPhaseTracingForTesting else { return }
        print("PHOTO-PHASE host=\(CACurrentMediaTime()) stage=\(phase)")
        #endif
    }

    private func captureNativePhoto(_ settings: AVCapturePhotoSettings, context: CaptureContext) {
        if let angle = context.captureRotationAngle, let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if context.options.nightMode { context.nightBatchSubmittedAt = CACurrentMediaTime() }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func submitPhotoCapture(_ settings: AVCapturePhotoSettings, context: CaptureContext) {
        // 取消/切换后格式可能已改变；提交时再次验证，而不是让不可捕获的NSException终止进程。
        if let bracket = settings as? AVCapturePhotoBracketSettings {
            let frames = bracket.bracketedSettings.compactMap { $0 as? AVCaptureManualExposureBracketedStillImageSettings }
            let supported = input.map { current in frames.allSatisfy {
                supportsManualBracket(current.device, seconds: $0.exposureDuration.seconds, iso: $0.iso)
            } } ?? false
            if !frames.isEmpty, !supported {
                failPhotoCaptureBeforeSubmission(context, message: "当前镜头格式不支持所选手动包围曝光，请重新选择拍摄参数。")
                return
            }
        }
        // 借用物理输入后等真实新帧且AF/AWB连续两次稳定，再提交首批；不发送额外对焦指令。
        // 最多等0.8秒，低照度长期调焦时仍有界返回；后台取消不再提交。
        if let started = context.nightRouteStartedAt, context.nightBatchOffset == 0 {
            guard wantsRunning, captureContexts[settings.uniqueID] === context else {
                failPhotoCaptureBeforeSubmission(context, message: "夜景拍摄已取消。"); return
            }
            let fresh = livePreviewState.snapshot().latestFrameHostTime >= started
            let settled = fresh && input?.device.isAdjustingFocus == false && input?.device.isAdjustingWhiteBalance == false
            context.nightRouteSettledChecks = settled ? context.nightRouteSettledChecks + 1 : 0
            if context.nightRouteSettledChecks < 2 && CACurrentMediaTime() - started < 0.8 {
                queue.asyncAfter(deadline: .now() + 0.04) { [weak self, weak context] in
                    guard let self, let context else { return }
                    self.submitPhotoCapture(settings, context: context)
                }
                return
            }
            context.nightRouteStartedAt = nil
        }
        // 普通照片、手动包围与夜景追加批次统一使用快门按下时的静音快照。
        // 每个原生请求重新查询官方能力；不支持时保持 false，避免系统抛出无效参数异常。
        let soundSuppressionSupported = photoOutput.isShutterSoundSuppressionSupported
        settings.isShutterSoundSuppressionEnabled = context.options.silentShutter && soundSuppressionSupported
        let slowShutterNeedsPreviewHold: Bool
        if case .slowShutterSequence = context.options.purpose {
            slowShutterNeedsPreviewHold = !context.usesManualExposureBracket && context.usesPreviewExposureAssist
        } else { slowShutterNeedsPreviewHold = false }
        if (context.options.nightMode || slowShutterNeedsPreviewHold), !context.nightPreviewHeld {
            context.nightPreviewHeld = true
            // 夜景跨批次保留取景；慢门只在不支持独立静态包围曝光、必须临时切曝光时保留。
            // 在测试通知和硬件提交前启用，同时挡住已排队的预览发布。
            livePreviewState.update { $0.nightCapturePreviewHold = true }
            if context.options.nightMode {
                DispatchQueue.main.async {
                    guard self.runRequested,self.pendingCaptureTokens.contains(context.token),let image = self.preview else { return }
                    self.nightPreviewReveal = NightPreviewReveal(id:context.token,image:image)
                }
            }
        }
        #if DEBUG
        lastShutterSoundRequest = (context.options.silentShutter, soundSuppressionSupported, settings.isShutterSoundSuppressionEnabled)
        // 必须等首次路线门控完成，才能把“已提交”和该批静音快照一起通知测试。
        if context.options.nightMode { notifyNightBatchSubmitted(context) }
        #endif
        tracePhotoPhase("submit id=\(settings.uniqueID) readiness=\(photoOutput.captureReadiness.rawValue)")
        #if DEBUG
        if photoPhaseTracingForTesting, let device = input?.device {
            tracePhotoPhase("exposure-submit mode=\(device.exposureMode.rawValue) seconds=\(device.exposureDuration.seconds) iso=\(device.iso) requested=\(String(describing: manualExposureValues)) priority=\(settings.photoQualityPrioritization.rawValue)")
            if let bracket = settings as? AVCapturePhotoBracketSettings {
                tracePhotoPhase("manual-bracket \(bracket.bracketedSettings.compactMap { $0 as? AVCaptureManualExposureBracketedStillImageSettings }.map { "\($0.exposureDuration.seconds)/\($0.iso)" })")
            }
        }
        #endif
        // 正常生命周期按最终 delegate 回调收尾；这是应用级漏回调保护，不是平台承诺的拍摄时限。
        // RAW/Live/高像素保留更长预算，夜景按原生三帧批次计时，不限制整组或长曝序列总时长。
        var timeout: TimeInterval = context.options.usesRAWCapture || context.options.capturesLive ? 60
            : context.options.resolution == .high || context.options.hdr ? 45 : 25
        if context.options.portraitMode && context.options.resolution == .standard && !context.options.usesRAWCapture {
            timeout = 12
        }
        #if DEBUG
        if let override = self.nativeCaptureTimeoutForTesting { timeout = override }
        #endif
        let uniqueID = settings.uniqueID
        context.waitingForNativeCompletion = true
        queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak context] in
            guard let self, let context, context.waitingForNativeCompletion,
                  self.captureContexts[uniqueID] === context else { return }
            self.expireUnfinishedPhotoCaptures(requestID: uniqueID)
        }
        if context.usesManualExposureBracket {
            if context.options.nightMode, let device = input?.device {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    // 与普通M挡正式曝光一致；平滑预览的HDR流不能影响本次手动夜景成片。
                    updatePreviewHDR(device,customExposure:true)
                } catch { failPhotoCaptureBeforeSubmission(context,message:"应用夜景拍摄参数失败：\(error.localizedDescription)"); return }
            }
            captureNativePhoto(settings, context: context)
            return
        }
        if context.usesSlowShutterAutoPreviewAssist,
           let device = input?.device,
           let requested = context.slowShutterAEMaximumForCapture {
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                applyExposureDurationLimit(requested, to: device)
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                failPhotoCaptureBeforeSubmission(context, message: "应用慢门曝光失败：\(error.localizedDescription)")
                return
            }
            // Restoring the preset ceiling does not instantly re-meter the scene.
            // Wait briefly for AE to select a longer frame before asking the photo
            // output to capture, then restore the smooth preview cap after exposure.
            waitForAutomaticSlowShutterExposure(settings, context: context, device: device,
                                                deadline: CACurrentMediaTime() + 0.75)
            return
        }
        guard let device = input?.device,
              let requested = context.manualExposureForCapture,
              device.isExposureModeSupported(.custom) else {
            captureHighResolutionWithWhiteBalance(settings,context:context)
            return
        }
        let iso = min(max(requested.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let minimum = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maximum = min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration), 1)
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else {
            failPhotoCaptureBeforeSubmission(context, message: "当前镜头无法应用手动曝光。")
            return
        }
        let seconds = min(max(requested.seconds, minimum), maximum)
        do {
            try device.lockForConfiguration()
            // 流畅预览使用AE及自动HDR流；正式手动照片须与关闭辅助时使用相同的传感器策略。
            // 不能只等待custom回调却沿用预览HDR策略；成片像素也需验证，不能只看EXIF。
            restoreDefaultAutoExposureLimit(device)
            updatePreviewHDR(device, customExposure: true)
            updateManualPhotoPreviewFrameDuration(seconds, on: device)
        } catch {
            failPhotoCaptureBeforeSubmission(context, message: "应用拍摄参数失败：\(error.localizedDescription)")
            return
        }
        device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), iso: iso) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.captureContexts[settings.uniqueID] === context else { return }
                    guard self.session.isRunning else {
                        self.failPhotoCaptureBeforeSubmission(context, message: "相机已停止，未完成拍摄。")
                        return
                    }
                    self.captureNativePhoto(settings, context: context)
                }
        }
        device.unlockForConfiguration()
    }

    private func captureHighResolutionWithWhiteBalance(_ settings:AVCapturePhotoSettings,context:CaptureContext) {
        guard context.options.resolution == .high, let requested = context.manualWhiteBalanceForCapture,
              let device = input?.device, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            captureNativePhoto(settings, context: context); return
        }
        let gains = device.deviceWhiteBalanceGains(for:.init(temperature:Float(requested.kelvin),tint:Float(requested.tint)))
        guard let safe = WhiteBalanceSafety.clamped(gains,maximum:device.maxWhiteBalanceGain) else {
            failPhotoCaptureBeforeSubmission(context,message:"当前白平衡参数不可用。"); return
        }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.setWhiteBalanceModeLocked(with:safe) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.captureContexts[settings.uniqueID] === context else { return }
                    guard self.session.isRunning else {
                        self.failPhotoCaptureBeforeSubmission(context,message:"相机已停止，未完成拍摄。"); return
                    }
                    self.captureNativePhoto(settings, context: context)
                }
            }
        } catch { failPhotoCaptureBeforeSubmission(context,message:"应用白平衡失败：\(error.localizedDescription)") }
    }

    private func waitForAutomaticSlowShutterExposure(_ settings: AVCapturePhotoSettings,
                                                     context: CaptureContext,
                                                     device: AVCaptureDevice,
                                                     deadline: CFTimeInterval) {
        guard captureContexts[settings.uniqueID] === context else { return }
        guard session.isRunning else {
            failPhotoCaptureBeforeSubmission(context, message: "相机已停止，未完成拍摄。")
            return
        }

        let exposureSeconds = CMTimeGetSeconds(device.exposureDuration)
        let reachedSlowExposure = exposureSeconds.isFinite
            && exposureSeconds > SlowShutterPreviewPolicy.previewMaximumDuration + 0.001
        if (reachedSlowExposure && !device.isAdjustingExposure) || CACurrentMediaTime() >= deadline {
            captureNativePhoto(settings, context: context)
            return
        }

        queue.asyncAfter(deadline: .now() + 0.03) { [weak self, weak device] in
            guard let self, let device else { return }
            self.waitForAutomaticSlowShutterExposure(settings, context: context, device: device,
                                                     deadline: deadline)
        }
    }

    private func failPhotoCaptureBeforeSubmission(_ context: CaptureContext, message: String) {
        if let id = captureContexts.first(where: { $0.value === context })?.key {
            captureContexts.removeValue(forKey: id)
        }
        finishPreviewExposureAssistCapture(context)
        if let url = context.liveMovieURL { try? FileManager.default.removeItem(at: url) }
        hardwareFinished(token: context.token)
        releaseNightPreviewHold(context)
        completeCapture(context, photo: nil, message: message)
    }

    /// 系统请求已不再按时回调：结束全部旧输出请求，再重建照片输出。
    /// 不把残缺照片写入相册；uniqueID 移除后，旧输出迟到回调只能被忽略。
    /// 切换照片/视频模式前主动结束尚未回调的静态照片请求；否则原生回调丢失后
    /// 会在新模式下触发“拍照超时”，用户看到的是与当前模式无关的错误。
    func cancelPendingPhotoCapturesForModeSwitch() {
        queue.async {
            let pending = self.captureContexts
            guard !pending.isEmpty else { return }
            for (requestID, capture) in pending {
                self.captureContexts.removeValue(forKey: requestID)
                self.finishPreviewExposureAssistCapture(capture)
                if let url = capture.liveMovieURL { try? FileManager.default.removeItem(at: url) }
                self.hardwareFinished(token: capture.token)
                self.releaseNightPreviewHold(capture)
                self.completeCapture(capture, photo: nil, message: nil, notifyFailure: false)
                if case .slowShutterSequence = capture.options.purpose {
                    DispatchQueue.main.async { self.onSlowShutterSourceFrame?(nil) }
                }
            }
            self.syncPreviewState()
        }
    }

    private func expireUnfinishedPhotoCaptures(requestID: Int64) {
        guard captureContexts[requestID] != nil else { return }
        let captures = Dictionary(grouping: captureContexts.values, by: \.token).compactMap { $0.value.first }
            .sorted { $0.sequence < $1.sequence }
        NSLog("Photo capture timed out: request=%lld unfinished=%ld; retire old photo output", requestID, captures.count)
        wantsRunning = false
        replacePhotoOutputOnRecovery = true
        livePreviewState.update { $0.acceptsFrames = false }
        captureContexts.removeAll()
        for capture in captures {
            if let deviceID = capture.nativePortraitDeviceID { stalledPortraitDeviceIDs.insert(deviceID) }
        }
        hdrStillCapturePreparing = false
        DispatchQueue.main.async { self.ready = false }
        for capture in captures {
            finishPreviewExposureAssistCapture(capture)
            if let url = capture.liveMovieURL { try? FileManager.default.removeItem(at: url) }
            hardwareFinished(token: capture.token)
            releaseNightPreviewHold(capture)
            completeCapture(capture, photo: nil, message: nil, notifyFailure: true)
            if case .slowShutterSequence = capture.options.purpose {
                DispatchQueue.main.async { self.onSlowShutterSourceFrame?(nil) }
            }
        }
        DispatchQueue.main.async {
            // 退出相机期间只清理；下次 start 再替换输出，不被迟到超时任务拉回前台。
            guard self.runRequested else { return }
            self.retrySessionRecovery()
            self.message = "拍照超时，本次照片未能完成，请重新拍摄。"
        }
    }

    private func finishPreviewExposureAssistCapture(_ context: CaptureContext) {
        // 静态请求自行管理曝光，没有临时更改预览曝光，也无需每帧恢复 AE。
        if context.usesManualExposureBracket && !context.options.nightMode { context.previewExposureAssistRestored = true; return }
        if context.usesSlowShutterAutoPreviewAssist, !context.slowShutterAutoPreviewAssistRestored {
            context.slowShutterAutoPreviewAssistRestored = true
            let anotherAutomaticCaptureNeedsPresetLimit = captureContexts.values.contains {
                $0 !== context && $0.usesSlowShutterAutoPreviewAssist && !$0.slowShutterAutoPreviewAssistRestored
            }
            if !anotherAutomaticCaptureNeedsPresetLimit, let device = input?.device {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    if manualMode {
                        applyManualPreviewExposurePolicy(device)
                    } else if slowShutterPreviewOptimizationRequested,
                              let maximum = slowShutterAutomaticExposureMaximumSeconds {
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        applyAutomaticSlowShutterExposureLimit(maximum, to: device)
                    } else {
                        slowShutterAutoPreviewOptimizationActive = false
                        restoreDefaultAutoExposureLimit(device)
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                    }
                } catch { report("恢复慢门预览失败：\(error.localizedDescription)") }
            }
        }
        guard context.usesPreviewExposureAssist, !context.previewExposureAssistRestored else { return }
        context.previewExposureAssistRestored = true
        let anotherCaptureNeedsManualExposure = captureContexts.values.contains {
            $0 !== context && $0.usesPreviewExposureAssist && !$0.previewExposureAssistRestored
        }
        guard !anotherCaptureNeedsManualExposure, let device = input?.device else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if usesSmoothManualPreviewExposure && (manualMode || slowShutterSequencePreviewAssistEnabled) && customExposureRequested {
                updatePreviewHDR(device, customExposure: false)
                applySmoothPreviewExposure(device)
            } else if manualMode, customExposureRequested, let requested = manualExposureValues {
                restoreDefaultAutoExposureLimit(device)
                updatePreviewHDR(device, customExposure: true)
                applyRequestedManualExposure(requested, to: device)
            } else {
                restoreAutomaticPhotoFrameDurations(device)
                restoreDefaultAutoExposureLimit(device)
                updatePreviewHDR(device, customExposure: false)
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                refreshAutomaticParameterReadings()
            }
        } catch { report("恢复流畅预览失败：\(error.localizedDescription)") }
    }

    private func releaseNightPreviewHold(_ context: CaptureContext) {
        guard context.nightPreviewHeld else { return }
        context.nightPreviewHeld = false
        let cutoff = CACurrentMediaTime()
        _ = previewRevision.advance(resetInteractiveFloor: true)
        livePreviewState.update {
            $0.nightCapturePreviewHold = false
            $0.framesNotBefore = max($0.framesNotBefore, cutoff)
            $0.warmupFrames = max($0.warmupFrames, 2)
        }
    }

    private func shutterFinished(token: UUID) {
        DispatchQueue.main.async {
            guard self.shutterToken == token, self.liveCaptureToken != token else { return }
            self.shutterToken = nil
            self.shutterBusy = false
        }
    }

    private func hardwareFinished(token: UUID) {
        restoreNightAutomaticRoute(token: token)
        restoreMacroAutomaticRoute(token: token)
        if hardwareTokens.count <= 1 { restoreMacroExposureBias() }
        DispatchQueue.main.async {
            self.hardwareTokens.remove(token)
            self.capturing = !self.hardwareTokens.isEmpty
            if self.shutterToken == token, self.liveCaptureToken != token { self.shutterToken = nil; self.shutterBusy = false }
        }
    }

    private func finishCapture(source: CIImage, context capture: CaptureContext, portraitMask: CIImage? = nil) {
        tracePhotoPhase("postprocess-start")
        // Live 电影文件回调可能晚于照片最终回调到达；先把上下文保留在字典里等待，
        // 否则回调找不到 capture，会删除 movie，最终误报“无法编码所选照片格式”。
        if capture.options.live, capture.liveMovieURL != nil,
           !capture.liveMovieReady, capture.error == nil {
            guard capture.liveMovieWaitAttempts < 100 else {
                self.captureContexts = self.captureContexts.filter { $0.value !== capture }
                completeCapture(capture, photo: nil, message: "Live 处理失败：电影文件未在预期时间内完成。")
                return
            }
            capture.liveMovieWaitAttempts += 1
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.finishCapture(source: source, context: capture, portraitMask: portraitMask)
            }
            return
        }
        if capture.options.live { self.captureContexts = self.captureContexts.filter { $0.value !== capture } }
        do {
            let image = capture.nativePortraitFrontSensor
                ? CaptureOrientation.nativeFrontPhotoFrame(source) : source
            // 慢门序列不需要逐帧编码；把全分辨率源图直接交给合成器，
            // 最终只在合成完成后编码一次。
            if case .slowShutterSequence(let sequenceID) = capture.options.purpose {
                let frame = SlowShutterSourceFrame(sequenceID: sequenceID, image: image, look: capture.look, diagnostics: capture.diagnostics, location: capture.location)
                completeCapture(capture, photo: nil, message: nil)
                DispatchQueue.main.async { self.onSlowShutterSourceFrame?(frame) }
                return
            }
            // 设备有时不会为当前场景交付原生 Portrait Effects Matte。对已解码的静态图像补做一次 Vision 人物分割，
            // 避免人像模式无蒙版时静默输出完全清晰的普通照片；无人物/分割失败时仍安全保留原图。
            let usesVisionPortraitFallback = capture.options.portraitMode
                && capture.options.format != .raw
                && portraitMask == nil && capture.portraitMatte == nil
            let orientedPortraitMask = portraitMask
            let orientedPortraitMatte = capture.portraitMatte
            tracePhotoPhase("segmentation-start fallback=\(usesVisionPortraitFallback)")
            // 即使原生蒙版已交付，也在同一张原片上补充准确头部轮廓；仅静态出片运行一次。
            let semanticPortraitMask = capture.options.portraitMode && capture.options.format != .raw
                && capture.options.portraitBlurStrength > 0 ? PortraitPreviewProcessor.segmentStillImage(image) : nil
            let effectivePortraitMask = orientedPortraitMask ?? (usesVisionPortraitFallback
                ? semanticPortraitMask : nil)
            tracePhotoPhase("encode-start")
            var photo = try PhotoEncoder.encode(source: image, raw: capture.raw, look: capture.look,
                                               options: capture.options, context: context, location: capture.location,
                                               portraitMatte: orientedPortraitMatte, portraitMask: effectivePortraitMask,
                                               portraitHeadMask: semanticPortraitMask,
                                               systemHEIF: capture.nativePortraitFrontSensor ? nil : capture.processed,
                                               captureDate: capture.capturedAt)
            tracePhotoPhase("encode-end")
            if capture.options.portraitMode {
                var diagnostics = capture.diagnostics ?? PhotoCaptureDiagnostics()
                diagnostics.add("景深虚化强度", "\(Int((capture.options.portraitBlurStrength * 100).rounded()))%")
                let portraitEffectDescription: String
                if usesVisionPortraitFallback, effectivePortraitMask != nil {
                    portraitEffectDescription = "Vision 人物分割后备虚化"
                } else if capture.portraitMatte != nil || portraitMask != nil {
                    portraitEffectDescription = "系统人像遮罩背景虚化"
                } else {
                    portraitEffectDescription = "未生成可用人物遮罩，保留清晰原片"
                }
                diagnostics.add("人像背景效果", portraitEffectDescription)
                capture.diagnostics = diagnostics
            }
            photo.diagnostics = capture.diagnostics
            if let movie = capture.liveMovieURL {
                guard capture.liveMovieReady, let original = capture.processed else { throw PhotoEncodingError.encoding }
                let still = photo
                Task {
                    defer { try? FileManager.default.removeItem(at: movie) }
                    do {
                        let paired = try await LivePhotoProcessor.process(still, original: original, movie: movie, look: capture.look)
                        self.completeCapture(capture, photo: paired, message: nil)
                    } catch {
                        self.completeCapture(capture, photo: nil, message: "Live 处理失败：\(error.localizedDescription)")
                    }
                }
            } else { completeCapture(capture, photo: photo, message: nil) }
        } catch {
            if let url = capture.liveMovieURL { try? FileManager.default.removeItem(at: url) }
            if case .slowShutterSequence = capture.options.purpose {
                completeCapture(capture, photo: nil, message: nil)
                DispatchQueue.main.async { self.onSlowShutterSourceFrame?(nil) }
                return
            }
            completeCapture(capture, photo: nil, message: "照片处理失败：\(error.localizedDescription)")
        }
    }

    /// Apple can finish different photo formats out of order. Publish in shutter order so
    /// an older RAW result never replaces a newer photograph or its album thumbnail.
    /// 用户开启夜景模式后，24/28/48mm 主摄焦段走独立 48MP 会话。
    func setIndependentNightModeActive(_ active: Bool) {
        queue.async { self.independentNightModeActive = active }
    }
    #if DEBUG
    func independentNightModeActiveForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async { completion(self.independentNightModeActive) }
    }
    #endif

    private func independentNightRoute(for displayZoom: CGFloat) -> (device: AVCaptureDevice, baseDisplayZoom: CGFloat)? {
        func supports48(_ device: AVCaptureDevice) -> Bool {
            device.formats.contains { $0.supportedMaxPhotoDimensions.contains { Int64($0.width) * Int64($0.height) >= 40_000_000 } }
        }
        if displayZoom >= 3.8 {
            if let lens = lensCatalog.first(where: {
                $0.device.position == .back && $0.device.deviceType == .builtInTelephotoCamera
                    && !$0.device.isVirtualDevice && abs($0.displayZoom - 4) < 0.1 && supports48($0.device)
            }) { return (lens.device, 4) }
            return nil
        }
        if displayZoom < 1 {
            if let lens = lensCatalog.first(where: {
                $0.device.position == .back && $0.device.deviceType == .builtInUltraWideCamera
                    && !$0.device.isVirtualDevice && abs($0.displayZoom - 0.5) < 0.1 && supports48($0.device)
            }) { return (lens.device, 0.5) }
            return nil
        }
        if let lens = lensCatalog.first(where: {
            $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
                && !$0.device.isVirtualDevice && abs($0.zoomFactor - 1) < 0.01 && supports48($0.device)
        }) { return (lens.device, 1) }
        if let lens = lensCatalog.first(where: {
            $0.device.position == .back && !$0.device.isVirtualDevice && abs($0.displayZoom - 1) < 0.01 && supports48($0.device)
        }) { return (lens.device, 1) }
        return nil
    }

    private struct DetachedMainSession {
        let input: AVCaptureDeviceInput?
        let outputs: [AVCaptureOutput]
        let hardwareZoom: CGFloat?
    }

    private func detachMainSessionForIndependentNight() -> DetachedMainSession {
        let detached = DetachedMainSession(input: input, outputs: session.outputs, hardwareZoom: input?.device.videoZoomFactor)
        session.stopRunning()
        session.beginConfiguration()
        for output in detached.outputs where session.outputs.contains(output) {
            session.removeOutput(output)
        }
        if let input = detached.input, session.inputs.contains(input) {
            session.removeInput(input)
        }
        session.commitConfiguration()
        return detached
    }

    private func reattachMainSessionAfterIndependentNight(_ detached: DetachedMainSession) {
        session.beginConfiguration()
        if let input = detached.input, !session.inputs.contains(input), session.canAddInput(input) {
            session.addInput(input)
        }
        for output in detached.outputs where !session.outputs.contains(output) {
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        // 界面倍率与虚拟多摄的硬件倍率单位不同；恢复原值，避免夜景拍完后换视野或供图镜头。
        if let input = detached.input, session.inputs.contains(input), let zoom = detached.hardwareZoom {
            let device = input.device
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            } catch {
                tracePhotoPhase("night-main-zoom-restore-failed")
            }
        }
        if wantsRunning, !session.isRunning { session.startRunning() }
    }

    private func captureIndependentNight(context: CaptureContext, physical: AVCaptureDevice,
                                          baseDisplayZoom: CGFloat) {
        #if DEBUG
        if let injected = nightAutomaticExposureForTesting {
            startIndependentNightCapture(context: context, physical: physical, baseDisplayZoom: baseDisplayZoom, metered: injected)
            return
        }
        #endif
        guard let device = input?.device, wantsRunning, session.isRunning else {
            hardwareFinished(token: context.token)
            completeCapture(context, photo: nil, message: "相机尚未就绪，请重试夜景拍摄。")
            return
        }
        let startedAt = CACurrentMediaTime()
        livePreviewState.update {
            $0.independentNightMeteringRequest = (startedAt, device.uniqueID)
            $0.independentNightMeteringSample = nil
        }
        tracePhotoPhase("night-meter-start seconds=\(device.exposureDuration.seconds) iso=\(device.iso) adjusting=\(device.isAdjustingExposure)")
        waitForIndependentNightMetering(context: context, physical: physical, baseDisplayZoom: baseDisplayZoom,
            deviceID: device.uniqueID, lifecycle: recoveryRevision.current, metering: IndependentNightMetering(startedAt: startedAt))
    }

    private func waitForIndependentNightMetering(context: CaptureContext, physical: AVCaptureDevice,
                                                 baseDisplayZoom: CGFloat, deviceID: String, lifecycle: UInt64,
                                                 metering: IndependentNightMetering) {
        var metering = metering
        let elapsed = CACurrentMediaTime() - metering.startedAt
        let routeValid = recoveryRevision.matches(lifecycle) && wantsRunning && session.isRunning
            && !videoModeRequested && !manualMode && input?.device.uniqueID == deviceID
        let sample = livePreviewState.snapshot().independentNightMeteringSample
        let stable = routeValid && elapsed < IndependentNightMetering.timeout ? sample.flatMap { metering.observe($0) } : nil
        if routeValid, elapsed < IndependentNightMetering.timeout, stable == nil {
            let pending = metering
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                waitForIndependentNightMetering(context: context, physical: physical, baseDisplayZoom: baseDisplayZoom,
                    deviceID: deviceID, lifecycle: lifecycle, metering: pending)
            }
            return
        }
        livePreviewState.update {
            guard $0.independentNightMeteringRequest?.startedAt == metering.startedAt else { return }
            $0.independentNightMeteringRequest = nil
            $0.independentNightMeteringSample = nil
        }
        guard let stable else {
            tracePhotoPhase("night-meter-ended elapsed=\(elapsed) routeValid=\(routeValid)")
            hardwareFinished(token: context.token)
            completeCapture(context, photo: nil, message: routeValid ? "夜景测光尚未稳定，请保持取景片刻后重试。" : nil)
            return
        }
        tracePhotoPhase("night-meter-selected seconds=\(stable.seconds) iso=\(stable.iso) wait=\(elapsed)")
        startIndependentNightCapture(context: context, physical: physical, baseDisplayZoom: baseDisplayZoom, metered: stable)
    }

    /// 暂停普通会话，以稳定的预览曝光为基准完成独立夜景采集。
    private func startIndependentNightCapture(context: CaptureContext, physical: AVCaptureDevice,
                                              baseDisplayZoom: CGFloat, metered: NightAdaptiveCapturePolicy.Exposure) {
        let meteredSeconds = metered.seconds
        let meteredISO = metered.iso
        let lower = physical.activeFormat.minExposureDuration.seconds
        let upper = min(physical.activeFormat.maxExposureDuration.seconds,
                        max(lower, NightAdaptiveCapturePolicy.handheldMaximumExposureSeconds))
        let isoRange = Double(physical.activeFormat.minISO)...Double(physical.activeFormat.maxISO)
        var plan = NightAdaptiveCapturePolicy.automaticExposure(iso: meteredISO, seconds: meteredSeconds,
            durationRange: lower...upper, isoRange: isoRange)
        #if DEBUG
        if let injected = nightAutomaticExposureForTesting { plan = injected }
        #endif
        // 极暗场景的预览曝光乘积可能低于规划器阈值；用当前测光值兜底，
        // 不能直接把一次夜景判为“无法计算曝光”。
        let usedFallback = plan == nil
        if usedFallback {
            let fallbackSeconds = min(max(meteredSeconds, lower), upper)
            let fallbackISO = min(max(meteredISO, isoRange.lowerBound), isoRange.upperBound)
            if fallbackSeconds.isFinite, fallbackSeconds > 0, fallbackISO.isFinite, fallbackISO > 0 {
                plan = .init(seconds: fallbackSeconds, iso: fallbackISO)
            }
        }
        guard let plan else {
            hardwareFinished(token: context.token)
            completeCapture(context, photo: nil, message: "夜景独立采集无法计算曝光。")
            return
        }
        tracePhotoPhase("night-exposure-plan seconds=\(plan.seconds) iso=\(plan.iso) demand=\(meteredSeconds * meteredISO) fallback=\(usedFallback)")
        context.nightHighResolutionCrop = true
        context.nightCaptureZoom = max(1, currentZoom / max(0.5, baseDisplayZoom))
        context.nightRestoreZoom = max(0.5, currentZoom)
        let capture = IndependentNightCapture()
        capture.onPreviewFrame = { [weak self] sampleBuffer in
            self?.renderIndependentNightPreview(sampleBuffer, device: physical)
        }
        independentNightCapture = capture
        independentNightContext = context
        let detached = detachMainSessionForIndependentNight()
        capture.capture(device: physical, exposureSeconds: plan.seconds, iso: Float(plan.iso),
                        rotationAngle: nil, profile: context.options.nightProfile) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.independentNightCapture = nil
                self.independentNightContext = nil
                self.reattachMainSessionAfterIndependentNight(detached)
                DispatchQueue.main.async { self.ready = self.session.isRunning }
                if let device = self.input?.device {
                    self.configureOutputConnections(device)
                    self.configurePhotoOutput(device, publish: false)
                    self.syncPreviewState()
                }
                self.hardwareFinished(token: context.token)
                switch result {
                case .failure(let error):
                    self.completeCapture(context, photo: nil, message: "夜景独立采集失败：\(error.localizedDescription)")
                case .success(let captured):
                    self.processingQueue.async {
                        autoreleasepool {
                            let images = captured.frames.compactMap { frame -> CIImage? in
                                guard let source = CGImageSourceCreateWithData(frame as CFData, nil),
                                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                                // CIImage(data:) 对 48MP HEIC 会取预览表示；必须解主图。
                                var image = CIImage(cgImage: cgImage)
                                // ImageIO属性不能丢：独立夜景最终EXIF/TIFF/镜头信息从这里继承。
                                var frameProperties = properties
                                frameProperties[kCGImagePropertyOrientation as String] = 1
                                if let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
                                   let orientation = CGImagePropertyOrientation(rawValue: raw) {
                                    image = image.oriented(forExifOrientation: Int32(orientation.rawValue))
                                }
                                if let angle = context.captureRotationAngle {
                                    let normalized = angle.truncatingRemainder(dividingBy: 360)
                                    let landscapeCapture = abs(normalized) < 45 || abs(normalized - 180) < 45
                                    if landscapeCapture, image.extent.height > image.extent.width {
                                        image = image.oriented(.right)
                                    }
                                }
                                let zoom = max(1, context.nightCaptureZoom ?? 1)
                                if zoom > 1 {
                                    let extent = image.extent
                                    let width = extent.width / zoom
                                    let height = extent.height / zoom
                                    image = image.cropped(to: CGRect(x: extent.midX - width / 2,
                                                                     y: extent.midY - height / 2,
                                                                     width: width, height: height))
                                }
                                return image.settingProperties(frameProperties)
                            }
                            guard images.count >= 2 else {
                                self.completeCapture(context, photo: nil, message: "夜景独立采集帧不足。")
                                return
                            }
                            do {
                                let merged = try NightPhotoMerger.merge(images, context: self.context,
                                    referenceIndex: min(1, images.count - 1), adaptiveTone: true)
                                var diagnostics = context.diagnostics ?? PhotoCaptureDiagnostics()
                                if context.options.nightHDRPhoto, context.options.format == .heif {
                                    context.options.hdr = true
                                    diagnostics.add("夜景HDR成片", "10-bit HEIF PQ")
                                }
                                diagnostics.add("夜景独立采集", "\(captured.dimensions.width)×\(captured.dimensions.height) · \(images.count) 帧 · 中心裁切")
                                diagnostics.add("夜景源尺寸", "\(Int(images[0].extent.width))x\(Int(images[0].extent.height))")
                                diagnostics.add("夜景融合尺寸", "\(Int(merged.image.extent.width))x\(Int(merged.image.extent.height))")
                                diagnostics.add("夜景边缘裁切", String(format: "%.1f%%", merged.croppedFraction * 100))
                                diagnostics.add("夜景自动曝光", String(format: "%.4f秒 · ISO %.0f", plan.seconds, plan.iso))
                                context.diagnostics = diagnostics
                                // 独立会话帧的方向由 EXIF 决定；按融合结果的实际宽高
                                // 修正裁切方向，避免把竖幅 3:4 当成横向 4:3 裁掉高度。
                                let extent = merged.image.extent
                                context.look.landscape = extent.width > extent.height
                                self.finishCapture(source: merged.image, context: context)
                            } catch {
                                self.completeCapture(context, photo: nil, message: "夜景独立融合失败：\(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func completeCapture(_ capture: CaptureContext, photo: CapturedPhoto?, message: String?, notifyFailure: Bool = false) {
        tracePhotoPhase("complete success=\(photo != nil) error=\(message ?? "none")")
        DispatchQueue.main.async {
            guard self.pendingCaptureTokens.remove(capture.token) != nil else { return }
            if self.nightPreviewReveal?.id == capture.token,
               !self.cancelledNightCaptureTokens.contains(capture.token) {
                if let photo {
                    self.nightPreviewReveal?.progress = 1
                    self.nightPreviewReveal?.finalImage = photo.preview
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.65) {
                        if self.nightPreviewReveal?.id == capture.token { self.nightPreviewReveal = nil }
                    }
                } else { self.nightPreviewReveal = nil }
            }
            // Live includes post-shutter movie capture and pairing. Unlock on success or failure,
            // rather than the earlier still-photo shutter callback. Regular photos retain burst capture.
            if self.liveCaptureToken == capture.token {
                self.liveCaptureToken = nil
                if self.shutterToken == capture.token { self.shutterToken = nil; self.shutterBusy = false }
            }
            self.completedCaptures[capture.sequence] = CompletedCapture(token: capture.token, weight: capture.weight, photo: photo, message: message,
                notifiesFailure: notifyFailure || message != nil, completion: capture.completion)
            while let completed = self.completedCaptures.removeValue(forKey: self.nextDeliverySequence) {
                self.nextDeliverySequence &+= 1
                self.pendingPhotoCount -= 1
                self.pendingCaptureWeight -= completed.weight
                self.nightCaptureTokens.remove(completed.token)
                let cancelled = self.cancelledNightCaptureTokens.remove(completed.token) != nil
                // 退出后即使后台合成成功或较早请求刚释放有序队列，也不再交付旧夜景。
                guard !cancelled else { continue }
                if let message = completed.message { self.message = message }
                if let photo = completed.photo {
                    self.deliveredPhotoRevision &+= 1
                    self.onCaptureDelivered?(photo)
                }
                if completed.photo != nil || completed.notifiesFailure {
                    completed.completion(completed.photo)
                }
            }
        }
    }

    private func publishPreview(_ image: UIImage, revision: UInt64, generation: UInt64? = nil, userSwitchID: UUID? = nil, frontLandscape: Bool? = nil) {
        DispatchQueue.main.async {
            let state = self.livePreviewState.snapshot()
            guard state.running, state.acceptsFrames, !state.nightCapturePreviewHold,
                  generation == nil || generation == state.readingsGeneration,
                  userSwitchID == nil || userSwitchID == state.userSwitchID,
                  self.previewRevision.acceptsPublication(revision) else { return }
            // 与同一张新帧在一次主线程更新内提交；按钮和画幅不抢在帧前面切换。
            self.preview = image
            if let frontLandscape, state.nativeFrontPhotoSensor, state.nativeFrontSensorLandscape == frontLandscape,
               self.frontPhotoLandscapeEnabled != frontLandscape {
                self.frontPhotoLandscapeEnabled = frontLandscape
            }
#if DEBUG
            self.previewPublicationTimesForTesting.append(CACurrentMediaTime())
            if self.previewPublicationTimesForTesting.count > 512 {
                self.previewPublicationTimesForTesting.removeFirst(self.previewPublicationTimesForTesting.count - 512)
            }
#endif
            if let userSwitchID, self.userSwitchFrameID != userSwitchID { self.userSwitchFrameID = userSwitchID }
        }
    }

    #if DEBUG
    private var lastShutterSoundRequest: (requested: Bool, supported: Bool, enabled: Bool)?
    func shutterSoundStateForTesting(_ completion: @escaping (((requested: Bool, supported: Bool, enabled: Bool)?) -> Void)) {
        queue.async {
            let state = self.lastShutterSoundRequest
            DispatchQueue.main.async { completion(state) }
        }
    }
    func zoomStateForTesting(_ completion: @escaping (CGFloat, ClosedRange<CGFloat>, ClosedRange<CGFloat>) -> Void) {
        queue.async {
            guard let device = self.input?.device else { return }
            let base = device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device) : (self.lensCatalog.first { $0.device.uniqueID == device.uniqueID }.map { $0.displayZoom / $0.zoomFactor } ?? 1)
            let actual = base * device.videoZoomFactor
            let range = (base * device.minAvailableVideoZoomFactor)...(base * device.maxAvailableVideoZoomFactor)
            let legacy = ContinuousZoomPolicy.range(self.zoomCapabilities(position: device.position))
            DispatchQueue.main.async { completion(actual,range,legacy) }
        }
    }
    private var sceneFocusReconfigurationsForTesting = 0
    func repeatSceneFocusChangesForTesting(_ count: Int, completion: @escaping (Int, CGPoint, Bool) -> Void) {
        queue.async {
            guard let device = self.input?.device else { return }
            let before = self.sceneFocusReconfigurationsForTesting
            for _ in 0..<count { self.resumeFocusAfterSceneChange(deviceID: device.uniqueID) }
            let changes = self.sceneFocusReconfigurationsForTesting - before
            let point = device.focusPointOfInterest, continuous = device.focusMode == .continuousAutoFocus
            DispatchQueue.main.async { completion(changes, point, continuous) }
        }
    }
    func automaticRouteSnapshotForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            guard let d = self.input?.device else { DispatchQueue.main.async { completion("none") }; return }
            let primary = d.isVirtualDevice ? d.activePrimaryConstituent : d
            let zoom = d.isVirtualDevice ? d.videoZoomFactor * CameraLensCatalog.displayMultiplier(d) : d.videoZoomFactor
            let dimensions = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
            let frameRates = d.activeFormat.videoSupportedFrameRateRanges
                .map { String(format: "%.2f-%.2f", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: "_")
            let format = "\(dimensions.width)x\(dimensions.height)-\(CMFormatDescriptionGetMediaSubType(d.activeFormat.formatDescription))-\(frameRates)"
            let switching = d.primaryConstituentDeviceSwitchingBehavior == .auto ? "auto" :
                d.primaryConstituentDeviceSwitchingBehavior == .locked ? "locked" :
                d.primaryConstituentDeviceSwitchingBehavior == .restricted ? "restricted" : "unsupported"
            let fallback = d.fallbackPrimaryConstituentDevices.map(\.deviceType.rawValue).joined(separator: ",")
            let value = "video=\(self.videoModeRequested) input=\(d.deviceType.rawValue) virtual=\(d.isVirtualDevice) primary=\(primary?.deviceType.rawValue ?? "none") switching=\(switching) conditions=\(d.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions.rawValue) fallback=\(fallback) format=\(format) color=\(d.activeColorSpace.rawValue) autoWideColor=\(self.session.automaticallyConfiguresCaptureDeviceForWideColor) zoom=\(zoom) focus=\(d.lensPosition) primaryFocus=\(primary?.lensPosition ?? -1) AF=\(d.focusMode.rawValue) AE=\(d.exposureMode.rawValue) adjusting=\(d.isAdjustingFocus) point=\(d.focusPointOfInterest)"
            let optics = " fov=\(d.activeFormat.videoFieldOfView) primaryFOV=\(primary?.activeFormat.videoFieldOfView ?? 0) deviceZoom=\(d.videoZoomFactor) primaryZoom=\(primary?.videoZoomFactor ?? 0) distortion=\(d.isGeometricDistortionCorrectionEnabled) primaryDistortion=\(primary?.isGeometricDistortionCorrectionEnabled ?? false)"
            DispatchQueue.main.async { completion(value + optics) }
        }
    }
    func checkAutomaticLensStabilityForTesting(completion: @escaping (Bool, Int, UInt, String?) -> Void) {
        queue.async {
            let device = self.input?.device
            let virtual = device?.isVirtualDevice ?? false
            let behavior = device?.primaryConstituentDeviceSwitchingBehavior.rawValue ?? 0
            let primary = device?.activePrimaryConstituent?.uniqueID
            let conditions = device?.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions.rawValue ?? 0
            DispatchQueue.main.async { completion(virtual, behavior, conditions, primary) }
        }
    }
    func simulateInterruptionForTesting(ended: Bool) {
        NotificationCenter.default.post(name: ended ? AVCaptureSession.interruptionEndedNotification : AVCaptureSession.wasInterruptedNotification, object: session)
    }
    func simulateRuntimeStopForTesting(error: NSError? = nil) {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async {
                let info: [AnyHashable: Any]? = error.map { [AVCaptureSessionErrorKey: $0] }
                NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification, object: self.session, userInfo: info)
            }
        }
    }
    func pauseSessionQueueForTesting(_ gate: DispatchSemaphore) {
        queue.async { _ = gate.wait(timeout: .now() + 10) }
    }
    func actualSessionRunningForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async { let running = self.session.isRunning; DispatchQueue.main.async { completion(running) } }
    }
    func holdCurrentSceneLensForTesting(_ completion: @escaping () -> Void) {
        queue.async {
            if let device = self.input?.device, device.isVirtualDevice,
               device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                } catch { NSLog("Test route locking failed: %@",error.localizedDescription) }
            }
            DispatchQueue.main.async { completion() }
        }
    }
    func automaticConstituentTypesForTesting(_ completion: @escaping ([AVCaptureDevice.DeviceType], [AVCaptureDevice.DeviceType]) -> Void) {
        queue.async {
            let device = self.input?.device
            let constituents = device?.constituentDevices.map(\.deviceType) ?? []
            let supported = device?.supportedFallbackPrimaryConstituentDevices.map(\.deviceType) ?? []
            DispatchQueue.main.async { completion(constituents, supported) }
        }
    }
    func automaticFallbackTypesForTesting(_ completion: @escaping ([AVCaptureDevice.DeviceType]) -> Void) {
        queue.async {
            let types = self.input?.device.fallbackPrimaryConstituentDevices.map(\.deviceType) ?? []
            DispatchQueue.main.async { completion(types) }
        }
    }
    func previewHDRCapabilitiesForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            let device = self.input?.device
            let values: [String: Any] = ["hdrSupported":device?.activeFormat.isVideoHDRSupported ?? false,
                "colors":device?.activeFormat.supportedColorSpaces.map(\.rawValue) ?? [],
                "pixels":self.videoOutput.availableVideoPixelFormatTypes,
                "hlgFormats":device?.formats.filter { $0.supportedColorSpaces.contains(.HLG_BT2020) }.map { format -> [String:Any] in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return ["video":"\(dimensions.width)x\(dimensions.height)","photo":format.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" },"fov":format.videoFieldOfView,"highestPhoto":format.isHighestPhotoQualitySupported]
                } ?? [],
                "multiCam":AVCaptureMultiCamSession.isMultiCamSupported,
                "multiCamSets":AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInUltraWideCamera,.builtInWideAngleCamera,.builtInTelephotoCamera], mediaType:.video,position:.back).supportedMultiCamDeviceSets.map { $0.map { $0.deviceType.rawValue } },
                "activePhoto":device?.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" } ?? [],
                "activeColor":device?.activeColorSpace.rawValue ?? -1,
                "hdr":device?.isVideoHDREnabled ?? false]
            let text = (try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) } ?? "{}"
            DispatchQueue.main.async { completion(text) }
        }
    }
    /// 只读验证：在会话队列快照当前物理路由及格式能力，不改变48MP产品策略。
    func photoResolutionAuditForTesting(_ completion:@escaping ([String:String])->Void) {
        queue.async {
            guard let device = self.input?.device else { DispatchQueue.main.async { completion([:]) }; return }
            func sizes(_ values:[CMVideoDimensions])->String {
                values.map { "\($0.width)x\($0.height)" }.joined(separator:",")
            }
            let all = device.formats.flatMap(\.supportedMaxPhotoDimensions)
            let unique = Set(all.map { "\($0.width)x\($0.height)" }).sorted().joined(separator:",")
            let result = ["deviceID":device.uniqueID,"type":device.deviceType.rawValue,
                "position":String(device.position.rawValue),"virtual":String(device.isVirtualDevice),
                "physicalZoom":String(Double(device.videoZoomFactor)),
                "activeDimensions":sizes(device.activeFormat.supportedMaxPhotoDimensions),
                "allFormatDimensions":unique,"formatCount":String(device.formats.count),
                "formats48":String(device.formats.filter { $0.supportedMaxPhotoDimensions.contains { Int64($0.width)*Int64($0.height)>=40_000_000 } }.count),
                "outputMaximum":sizes([self.photoOutput.maxPhotoDimensions]),
                "responsive":String(self.photoOutput.isResponsiveCaptureEnabled)]
            DispatchQueue.main.async { completion(result) }
        }
    }
    private var lastInterruptionForTesting = "none"
    func sessionDetailsForTesting(_ completion: @escaping (String) -> Void) {
        let requested=runRequested, interruption=lastInterruptionForTesting
        queue.async {
            let text="requested=\(requested) wants=\(self.wantsRunning) running=\(self.session.isRunning) interrupted=\(self.session.isInterrupted) device=\(self.input?.device.deviceType.rawValue ?? "none") pressure=\(self.input?.device.systemPressureState.level.rawValue ?? "none") interruption=\(interruption)"
            DispatchQueue.main.async { completion(text) }
        }
    }
    /// 在实际拍摄队列读取当前取景参数，避免用界面状态代替成片输入状态。
    func captureLookForTesting(_ completion: @escaping (CaptureLook) -> Void) {
        queue.async {
            let value = self.captureLookOverride ?? self.look
            DispatchQueue.main.async { completion(value) }
        }
    }
    func frontPhotoLandscapeAppliedForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            let value = self.frontPhotoLandscapeApplied
            DispatchQueue.main.async { completion(value) }
        }
    }
    func frontPhotoCaptureRotationForTesting(_ completion: @escaping (CGFloat) -> Void) {
        queue.async {
            let angle = self.photoOutput.connection(with: .video)?.videoRotationAngle ?? 0
            DispatchQueue.main.async { completion(angle) }
        }
    }
    private var previewPairForTesting: ((UIImage, UIImage) -> Void)? // preview queue
    func readNextPreviewPairForTesting(_ completion: @escaping (UIImage, UIImage) -> Void) {
        previewQueue.async { self.previewPairForTesting = completion }
    }
    func frontPhotoAspectDiagnosticsForTesting(_ completion: @escaping (String) -> Void) {
        queue.async {
            let device = self.input?.device
            var ratio = "unavailable", dimensions = CMVideoDimensions(width: 0, height: 0)
            if #available(iOS 26.0, *), let device {
                ratio = device.dynamicAspectRatio?.rawValue ?? "nil"
                dimensions = device.dynamicDimensions
            }
            var officialRotation = "unavailable"
            if #available(iOS 27.0, *), let device {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                officialRotation = "portrait:\(coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)) capture:\(coordinator.videoRotationAngleForHorizonLevelCapture) device:\(UIDevice.current.orientation.rawValue)"
            }
            let state = self.livePreviewState.snapshot(), extent = state.extent
            let nativeDimensions = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
            let text = "intrinsics=\(state.intrinsicsForTesting) officialRotation=\(officialRotation) ratio=\(ratio) dynamic=\(dimensions.width)x\(dimensions.height) buffer=\(Int(extent.width))x\(Int(extent.height)) raw=\(state.rawBufferSizeForTesting) presentation=\(state.presentationSizeForTesting) clean=\(state.cleanBufferRectForTesting) native=\(state.nativeFrontPhotoSensor) quarterTurns=\(state.quarterTurns) rotation=\(self.videoOutput.connection(with: .video)?.videoRotationAngle ?? -1) format=\(String(describing: nativeDimensions)) settings=\(self.videoOutput.videoSettings ?? [:]) previewLook=\(self.look.landscape)"
            DispatchQueue.main.async { completion(text) }
        }
    }
    /// 诊断原生输出：普通照片返回原片；夜景只返回中间曝光，便于同一次拍摄作对照。
    var onOriginalProcessedPhotoForTesting: ((Data) -> Void)?
    // 定向真机诊断：仅测试启用，区分系统回调停滞和应用后处理耗时。
    var photoPhaseTracingForTesting = false
    private var automaticExposureLegacyForTesting = false // session queue，仅同场景A/B诊断使用
    private var automaticExposureRestartsForTesting = 0
    func setAutomaticExposureLegacyForTesting(_ enabled:Bool, completion:@escaping(Int)->Void) {
        queue.async {
            self.automaticExposureLegacyForTesting = enabled
            let count = self.automaticExposureRestartsForTesting
            DispatchQueue.main.async { completion(count) }
        }
    }
    var nativeCaptureTimeoutForTesting: TimeInterval?
    var nightDeliveryCountsForTesting: (active: Int, cancelled: Int) {
        (nightCaptureTokens.count, cancelledNightCaptureTokens.count)
    }
    var dropFinalPhotoCallbackForTesting = false
    private var droppedCaptureForTesting: CaptureContext? // session queue, 仅保留一个无图像的测试请求
    func droppedPhotoFinalForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async { let dropped = self.droppedCaptureForTesting != nil
            DispatchQueue.main.async { completion(dropped) }
        }
    }
    func droppedPhotoTokenForTesting(_ completion: @escaping (UUID?) -> Void) {
        queue.async { let token = self.droppedCaptureForTesting?.token
            DispatchQueue.main.async { completion(token) }
        }
    }
    func replayAndClearDroppedPhotoFinalForTesting() {
        queue.async {
            guard let capture = self.droppedCaptureForTesting else { return }
            self.droppedCaptureForTesting = nil
            // 直接重放同一 token 的终结，核对主线程的一次性交付保护。
            self.completeCapture(capture, photo: nil, message: nil)
            self.completeCapture(capture, photo: nil, message: nil)
        }
    }
    func photoOutputIdentityForTesting(_ completion: @escaping (String) -> Void) {
        queue.async { let id = String(describing: ObjectIdentifier(self.photoOutput))
            DispatchQueue.main.async { completion(id) }
        }
    }
    func portraitFallbackForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            let fallback = self.input.map { self.stalledPortraitDeviceIDs.contains($0.device.uniqueID) } ?? false
            DispatchQueue.main.async { completion(fallback) }
        }
    }
    func photoTaskStateForTesting(_ completion: @escaping (Int, Int, Int, Int) -> Void) {
        queue.async {
            let contexts = self.captureContexts.count
            DispatchQueue.main.async {
                completion(contexts, self.hardwareTokens.count, self.pendingCaptureTokens.count, self.completedCaptures.count)
            }
        }
    }
    var slowShutterManualBracketDisabledForTesting = false
    func photoMirroringForTesting(_ completion: @escaping (Bool?) -> Void) {
        queue.async { let value = self.photoOutput.connection(with:.video)?.isVideoMirrored; DispatchQueue.main.async { completion(value) } }
    }
    func previewMirroringForTesting(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            let value = self.livePreviewState.snapshot().mirrorFrontPreview
            DispatchQueue.main.async { completion(value) }
        }
    }
    func enqueueProcessingBarrierForTesting(_ gate: DispatchSemaphore) {
        processingQueue.async { _ = gate.wait(timeout: .now() + 15) }
    }

    struct ExposureColorState {
        let engineManual: Bool
        let engineCustom: Bool
        let requestedISO: Float?
        let requestedSeconds: Double?
        let virtual: Bool
        let deviceID: String
        let physicalZoomFactor: CGFloat
        let maximumExposureSeconds: Double
        let maximumAvailableExposureSeconds: Double
        let activeMinFrameSeconds: Double
        let activeMaxFrameSeconds: Double
        let previewExposureAssistEnabled: Bool
        let slowShutterPreviewOptimizationRequested: Bool
        let slowShutterAutoPreviewOptimizationActive: Bool
        let slowShutterAutomaticExposureMaximumSeconds: Double?
        let activeMaximumExposureSeconds: Double
        let iso: Float
        let seconds: Double
        let exposureMode: AVCaptureDevice.ExposureMode
        let focusMode: AVCaptureDevice.FocusMode
        let lensPosition: Float
        let focusPoint: CGPoint
        let adjustingFocus: Bool
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let gains: AVCaptureDevice.WhiteBalanceGains
        let colorSpace: AVCaptureColorSpace
        let hdr: Bool
        let exposureOffset: Float
        let automaticHDR: Bool
        let globalToneMapping: Bool
        let supportsGlobalToneMapping: Bool
    }
    func exposureColorState(_ completion: @escaping (ExposureColorState?) -> Void) {
        queue.async {
            let result = self.input.map { input in
                ExposureColorState(engineManual: self.manualMode, engineCustom: self.customExposureRequested,
                    requestedISO: self.manualExposureValues?.iso, requestedSeconds: self.manualExposureValues?.seconds,
                    virtual: input.device.isVirtualDevice, deviceID: input.device.uniqueID, physicalZoomFactor: input.device.videoZoomFactor, maximumExposureSeconds: CMTimeGetSeconds(input.device.activeFormat.maxExposureDuration),
                    maximumAvailableExposureSeconds: input.device.formats.map { CMTimeGetSeconds($0.maxExposureDuration) }.filter { $0.isFinite }.max() ?? 0,
                    activeMinFrameSeconds: CMTimeGetSeconds(input.device.activeVideoMinFrameDuration),
                    activeMaxFrameSeconds: CMTimeGetSeconds(input.device.activeVideoMaxFrameDuration),
                    previewExposureAssistEnabled: self.previewExposureAssistEnabled,
                    slowShutterPreviewOptimizationRequested: self.slowShutterPreviewOptimizationRequested,
                    slowShutterAutoPreviewOptimizationActive: self.slowShutterAutoPreviewOptimizationActive,
                    slowShutterAutomaticExposureMaximumSeconds: self.slowShutterAutomaticExposureMaximumSeconds,
                    activeMaximumExposureSeconds: CMTimeGetSeconds(input.device.activeMaxExposureDuration),
                    iso: input.device.iso, seconds: CMTimeGetSeconds(input.device.exposureDuration),
                    exposureMode: input.device.exposureMode, focusMode: input.device.focusMode, lensPosition: input.device.lensPosition, focusPoint: input.device.focusPointOfInterest, adjustingFocus: input.device.isAdjustingFocus,
                    whiteBalanceMode: input.device.whiteBalanceMode, gains: input.device.deviceWhiteBalanceGains,
                    colorSpace: input.device.activeColorSpace, hdr: input.device.isVideoHDREnabled,
                    exposureOffset: input.device.exposureTargetOffset, automaticHDR: input.device.automaticallyAdjustsVideoHDREnabled,
                    globalToneMapping: input.device.isGlobalToneMappingEnabled, supportsGlobalToneMapping: input.device.activeFormat.isGlobalToneMappingSupported)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func evaluateAutomaticSlowShutterPreviewForTesting(exposureSeconds: Double, completion: @escaping (Bool) -> Void) {
        queue.async {
            if let device = self.input?.device {
                self.activateAutomaticSlowShutterPreviewOptimizationIfNeeded(
                    deviceID: device.uniqueID, exposureSeconds: exposureSeconds)
            }
            let active = self.slowShutterAutoPreviewOptimizationActive
            DispatchQueue.main.async { completion(active) }
        }
    }
    #endif

    /// 等待已提交的会话配置，再在主队列继续UI流程；照片/视频和慢门正式路径也使用。
    func afterPendingSessionTasks(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    private func updateAudioLevels(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastAudioMeterUpdate >= 0.05 else { return }
        lastAudioMeterUpdate = now
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mBitsPerChannel == 16 || description.mBitsPerChannel == 32 else { return }

        let channelCount = max(1, Int(description.mChannelsPerFrame))
        let isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (description.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bufferCount = isNonInterleaved ? channelCount : 1
        let audioBuffers = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(audioBuffers.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: audioBuffers.unsafeMutablePointer,
            bufferListSize: bufferListSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, audioBuffers.count > 0, let leftData = audioBuffers[0].mData else { return }

        let bytesPerSample = Int(description.mBitsPerChannel) / 8
        let bytesPerFrame = Int(description.mBytesPerFrame)
        let frames: Int
        let leftSum: Float
        let rightSum: Float
        if isNonInterleaved {
            frames = Int(audioBuffers[0].mDataByteSize) / max(1, bytesPerSample)
            leftSum = audioSumSquares(leftData, frames: frames, channel: 0, channels: 1, isFloat: isFloat, bits: Int(description.mBitsPerChannel))
            if audioBuffers.count > 1, let rightData = audioBuffers[1].mData {
                rightSum = audioSumSquares(rightData, frames: frames, channel: 0, channels: 1, isFloat: isFloat, bits: Int(description.mBitsPerChannel))
            } else {
                rightSum = leftSum
            }
        } else {
            let frameBytes = bytesPerFrame > 0 ? bytesPerFrame : bytesPerSample * channelCount
            frames = Int(audioBuffers[0].mDataByteSize) / max(1, frameBytes)
            leftSum = audioSumSquares(leftData, frames: frames, channel: 0, channels: channelCount, isFloat: isFloat, bits: Int(description.mBitsPerChannel))
            rightSum = channelCount > 1
                ? audioSumSquares(leftData, frames: frames, channel: 1, channels: channelCount, isFloat: isFloat, bits: Int(description.mBitsPerChannel))
                : leftSum
        }
        guard frames > 0 else { return }

        let left = normalizedAudioLevel(sqrt(leftSum / Float(frames)))
        let right = normalizedAudioLevel(sqrt(rightSum / Float(frames)))
        DispatchQueue.main.async {
            self.audioLeftLevel = self.audioLeftLevel * 0.55 + left * 0.45
            self.audioRightLevel = self.audioRightLevel * 0.55 + right * 0.45
        }
    }

    private func audioSumSquares(_ data: UnsafeMutableRawPointer, frames: Int, channel: Int,
                                 channels: Int, isFloat: Bool, bits: Int) -> Float {
        var sum: Float = 0
        if isFloat, bits == 32 {
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let value = samples[frame * channels + channel]
                sum += value * value
            }
        } else if bits == 16 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames {
                let value = Float(samples[frame * channels + channel]) / 32_768
                sum += value * value
            }
        } else if bits == 32 {
            let samples = data.assumingMemoryBound(to: Int32.self)
            for frame in 0..<frames {
                let value = Float(samples[frame * channels + channel]) / 2_147_483_648
                sum += value * value
            }
        }
        return sum
    }

    private func normalizedAudioLevel(_ rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func report(_ text: String) { DispatchQueue.main.async { self.message = text } }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            movieRecorder?.appendAudio(sampleBuffer)
            updateAudioLevels(sampleBuffer)
            return
        }
        if output === recordingOutput {
            let state = livePreviewState.snapshot()
            let primary = state.device?.isVirtualDevice == true ? state.device?.activePrimaryConstituent : state.device
            let apertureAllowed = primary?.position == .back && (primary?.deviceType == .builtInWideAngleCamera || primary?.deviceType == .builtInTelephotoCamera)
            movieRecorder?.appendVideo(sampleBuffer, virtualApertureAllowed: apertureAllowed)
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard state.previewFromRecordingOutput, state.acceptsFrame(time: time),
                  LivePreviewCadence.accepts(time: time, lastFrameTime: lastRecordingPreviewEnqueueTime,
                                             frameRate: state.videoFrameRate,
                                             captureFrameRate: state.videoCaptureFrameRate),
                  livePreviewState.beginRecordingPreviewRender() else { return }
            lastRecordingPreviewEnqueueTime = time
            // 录制队列只负责快速送帧给写入器；预览渲染在独立队列完成，避免拖慢编码输入。
            previewQueue.async { [weak self] in
                defer { self?.livePreviewState.finishRecordingPreviewRender() }
                self?.renderPreviewFrame(sampleBuffer, fromRecordingOutput: true)
            }
            return
        }
        renderPreviewFrame(sampleBuffer, samplesIndependentNightMetering: output === videoOutput)
    }

    private func sampleIndependentNightMetering(time: TimeInterval, state: LivePreviewState.Snapshot) {
        guard let request = state.independentNightMeteringRequest,
              time >= request.startedAt,
              let device = state.device, device.uniqueID == request.deviceID else { return }
        let sourceID = device.activePrimaryConstituent?.uniqueID ?? device.uniqueID
        let sample = IndependentNightMetering.Sample(time: time, sourceID: "\(state.readingsGeneration):\(sourceID)",
            exposure: .init(seconds: device.exposureDuration.seconds, iso: Double(device.iso)), adjusting: device.isAdjustingExposure)
        livePreviewState.update {
            guard $0.independentNightMeteringRequest?.startedAt == request.startedAt,
                  $0.readingsGeneration == state.readingsGeneration else { return }
            $0.independentNightMeteringSample = sample
        }
    }

    /// 独立夜景视频帧仍走主预览的 Core Image 管线，保持 look/方向/滤镜一致。
    private func renderIndependentNightPreview(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice) {
        previewQueue.async {
            self.livePreviewState.update {
                $0.running = true
                $0.acceptsFrames = true
                $0.nightCapturePreviewHold = false
                $0.device = device
                $0.warmupFrames = 0
                $0.framesNotBefore = -Double.infinity
            }
            self.renderPreviewFrame(sampleBuffer)
        }
    }

    private func renderPreviewFrame(_ sampleBuffer: CMSampleBuffer, samplesIndependentNightMetering: Bool = false,
                                    fromRecordingOutput: Bool = false) {
        autoreleasepool {
            renderPreviewFrameInPool(sampleBuffer, samplesIndependentNightMetering: samplesIndependentNightMetering,
                                     fromRecordingOutput: fromRecordingOutput)
        }
    }

    #if DEBUG
    func setNightPreviewTraceStartForTesting(_ time: TimeInterval?) {
        livePreviewState.update { $0.nightPreviewTraceStartForTesting = time }
    }

    /// 仅在真机诊断时读取主预览的曝光，限频避免控制台输出拖慢取景。
    private func traceNightPreviewForTesting(time: TimeInterval, state: LivePreviewState.Snapshot) {
        guard let startedAt = state.nightPreviewTraceStartForTesting, time >= startedAt,
              time - lastNightPreviewTraceTime >= 0.10, let device = state.device else { return }
        lastNightPreviewTraceTime = time
        let primary = device.activePrimaryConstituent ?? device
        print("NIGHT-PREVIEW elapsed=\(time - startedAt) generation=\(state.readingsGeneration) route=\(device.deviceType.rawValue) primary=\(primary.deviceType.rawValue) mode=\(device.exposureMode.rawValue) adjusting=\(device.isAdjustingExposure) seconds=\(device.exposureDuration.seconds) iso=\(device.iso) offset=\(device.exposureTargetOffset) bias=\(device.exposureTargetBias) zoom=\(device.videoZoomFactor)")
    }
    #endif

    private func renderPreviewFrameInPool(_ sampleBuffer: CMSampleBuffer, samplesIndependentNightMetering: Bool,
                                          fromRecordingOutput: Bool) {
        let state = livePreviewState.snapshot()
        guard state.running, state.acceptsFrames, !state.nightCapturePreviewHold else { return }
        if fromRecordingOutput && !state.previewFromRecordingOutput { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard state.acceptsFrame(time: time),
              LivePreviewCadence.accepts(time: time, lastFrameTime: lastFrameTime,
                                         frameRate: state.videoFrameRate,
                                         captureFrameRate: state.videoCaptureFrameRate),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              livePreviewState.acceptsWarmFrame(generation: state.readingsGeneration) else { return }
        lastFrameTime = time
        #if DEBUG
        if samplesIndependentNightMetering {
            traceNightPreviewForTesting(time: time, state: state)
        }
        #endif
        if samplesIndependentNightMetering, state.independentNightMeteringRequest != nil {
            sampleIndependentNightMetering(time: time, state: state)
        }
        let refreshRequested = lastReadingsRefreshRevision != state.readingsRefreshRevision
        let readingsInterval = CACurrentMediaTime()<state.readingsFastUntil ? 0.08 : 0.4
        if refreshRequested || time-lastReadingsTime>=readingsInterval, let device = state.device {
            lastReadingsTime = time
            lastReadingsRefreshRevision = state.readingsRefreshRevision
            let exposureSeconds = CMTimeGetSeconds(device.exposureDuration)
            queue.async {
                self.activateAutomaticSlowShutterPreviewOptimizationIfNeeded(
                    deviceID: device.uniqueID, exposureSeconds: exposureSeconds)
            }
            let gains = device.deviceWhiteBalanceGains
            // AVFoundation throws an Objective-C exception for out-of-range gains.
            // Automatic/virtual cameras can report transient gains below one.
            let temperature = WhiteBalanceSafety.validated(gains, maximum: device.maxWhiteBalanceGain)
                .map { device.temperatureAndTintValues(for: $0) }
            let primary = device.isVirtualDevice ? device.activePrimaryConstituent : device
            let values = CameraReadings(iso: Double(device.iso), seconds: exposureSeconds, kelvin: Double(temperature?.temperature ?? 0), focus: Double(device.lensPosition), tint: temperature.map { Double($0.tint) }, adjustingFocus: primary?.isAdjustingFocus ?? device.isAdjustingFocus,
                customExposure:device.exposureMode == .custom,exposureTargetOffsetEV:Double(device.exposureTargetOffset),
                sampleHostTime:time,recommendationFocusPosition:primary.flatMap { $0.isFocusModeSupported(.autoFocus) ? Double($0.lensPosition) : nil },
                recommendationFocusDeviceID:primary?.uniqueID)
            let macro = CACurrentMediaTime() >= state.macroNotBefore && !state.macroRouteChangePending
                && (state.temporaryMacroPhysicalInput || CameraMacroPolicy.isActive(manual: state.manualMode, virtual: device.isVirtualDevice,
                    rear: device.position == .back, ultraWide: primary?.deviceType == .builtInUltraWideCamera,
                    displayZoom: device.isVirtualDevice ? device.videoZoomFactor * CameraLensCatalog.displayMultiplier(device) : 0,
                    routeChangePending: state.macroRouteChangePending))
            let macroRouteGeneration = state.macroRouteGeneration
            // 相机采样回调可能与 SwiftUI 当前帧的视图更新紧邻执行。
            // 延后一帧再发布 @Published，避免在视图更新事务内触发对象变更；
            // 同时用读取代次校验，丢弃镜头/会话切换前排队的旧读数。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
                let current = self.livePreviewState.snapshot()
                guard current.running, current.readingsGeneration == state.readingsGeneration,
                      current.readingsRefreshRevision == state.readingsRefreshRevision,
                      current.macroRouteGeneration == macroRouteGeneration else { return }
                if self.macroActive != macro {
                    self.macroActive = macro
                }
                self.readings = values.forDisplay(frameGeneration: state.readingsGeneration,
                                                 currentGeneration: current.readingsGeneration, running: current.running)
            }
        }
        let mirrorPreview = state.mirrorFrontPreview && state.device?.position == .front
        // Mirror in display orientation. Mirroring before the landscape quarter-turn
        // would turn a left-right selfie mirror into a top-bottom flip.
        // Log preview is an ungraded proxy of the recorded curve; never bake a
        // display conversion or LUT into the buffers sent to the movie writer.
        // The Log LUT library is applied through the existing sRGB display path.
        let bufferImage = state.videoColorSpace?.isLog == true
            ? CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            : CIImage(cvPixelBuffer: pixelBuffer)
        // 系统动态画幅决定实际视野。新前置的零旋转缓冲已经朝向竖屏上方，
        // 不因缓冲是横图或竖图额外转动；旧镜头和视频仍沿用原方向路线。
        let nativeSource = state.nativeFrontPhotoSensor || state.nativeFrontCenterStageSensor
            ? CaptureOrientation.nativeFrontPreviewFrame(bufferImage)
            : CaptureOrientation.portraitFrame(bufferImage)
        var source = nativeSource
        var nativeFocalLengths: (Float, Float)?
        if state.nativeFrontPhotoSensor,
           let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<simd_float3x3>.size {
            let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
            nativeFocalLengths = (matrix.columns.0.x, matrix.columns.1.y)
            source = CaptureOrientation.correctingIntrinsicScale(nativeSource, focalX: matrix.columns.0.x, focalY: matrix.columns.1.y)
        }
        // 切换完成回调与视频回调不在同一队列。丢弃宽高尚未匹配的新旧交界帧，
        // 保留最后一张有效预览，不能把横幅缓冲铺进竖幅显示框（反之亦然）。
        // 这里核对传感器实际画幅，而非裁切方向，避免横幅输入裁成 1:1 时所有新帧被丢弃。
        if state.nativeFrontPhotoSensor,
           (nativeSource.extent.width > nativeSource.extent.height) != state.nativeFrontSensorLandscape { return }
        livePreviewState.update {
            $0.extent = source.extent; $0.latestFrameHostTime = CACurrentMediaTime()
            if fromRecordingOutput { $0.latestRecordingPreviewFrameHostTime = $0.latestFrameHostTime }
            #if DEBUG
            $0.rawBufferSizeForTesting = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                $0.presentationSizeForTesting = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
            }
            $0.cleanBufferRectForTesting = CVImageBufferGetCleanRect(pixelBuffer)
            if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
               data.count >= MemoryLayout<simd_float3x3>.size {
                let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
                $0.intrinsicsForTesting = "fx:\(matrix.columns.0.x) fy:\(matrix.columns.1.y)"
            }
            #endif
        }
        if state.portraitPreviewEnabled {
            let route = "\(state.device?.uniqueID ?? "")/\(state.readingsGeneration)/\(state.nativeFrontPhotoSensor)/\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
            portraitPreviewProcessor.submit(pixelBuffer, time: CACurrentMediaTime(), generation: state.portraitPreviewGeneration, route: route)
        }
        if state.metering == .global, time - lastMeteringSampleTime >= 0.2 {
            lastMeteringSampleTime = time
            let cropped = state.look.ratio.crop(PreviewRotation.image(source, quarterTurns: state.quarterTurns), landscape: state.look.landscape)
            if let device = state.device {
                let analysis = GlobalMeteringPolicy.analyze(cropped, context: previewContext)
                let sample = GlobalMeteringPolicy.Sample(mean: analysis.mean, shape: analysis.shape,
                    exposureProduct: Double(device.iso) * device.exposureDuration.seconds / pow(max(Double(device.lensAperture), 0.1), 2),
                    deviceBias: Double(device.exposureTargetBias), userBias: 0,
                    time: time, route: "\(device.uniqueID)/\(device.activePrimaryConstituent?.uniqueID ?? device.uniqueID)/\(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription))/\(state.look.ratio)/\(Int((device.videoZoomFactor * 100).rounded()))")
                queue.async {
                    guard self.previewRevision.canRender(state.revision) else { return }
                    // 用户EV只在会话队列读取；取样亮度和曝光乘积来自同一轮预览回调。
                    let current = GlobalMeteringPolicy.Sample(mean: sample.mean, shape: sample.shape,
                        exposureProduct: sample.exposureProduct, deviceBias: sample.deviceBias,
                        userBias: Double(self.exposureBias), time: sample.time, route: sample.route)
                    self.updateGlobalMetering(current, deviceID: device.uniqueID, generation: state.readingsGeneration)
                }
            }
        }
        guard previewRevision.canRender(state.revision) else { return }
        // 先恢复方形像素，再按成片画幅裁切；滤镜处理和缩放仍等比进行。
        let framedSource = state.nativeFrontPhotoSensor ? state.look.ratio.crop(source, landscape: state.look.landscape) : source
        // 空间效果本来就在900px预览上计算；非空间滤镜也先缩到预览尺寸再套LUT，
        // 避免拖动浓度时对全分辨率反复做LUT+强度外推，导致GPU积压/黑屏。
        let previewScale = min(1, 900 / max(framedSource.extent.width, framedSource.extent.height))
        let renderSource = framedSource.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        // HDR 关仍然拿的是 HLG 10-bit 缓冲。只做 CIImage 色彩匹配时，
        // 低浓度会露出未 tone map 的 HLG（纸面全白、暗部全黑），最后再突然
        // 回到 SDR。这里先把照片预览物理渲染成8-bit sRGB，再进 LUT/强度。
        var workingSource = renderSource
        if !state.hdr, state.videoColorSpace == nil {
            if let colorSpace = renderSource.colorSpace, colorSpace.name != CGColorSpace.sRGB as CFString,
               let normalized = previewContext.createCGImage(renderSource, from: renderSource.extent,
                                                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                workingSource = CIImage(cgImage: normalized)
            }
        }
        var renderLook = state.look
        let physical = state.device?.isVirtualDevice == true ? state.device?.activePrimaryConstituent : state.device
        if physical?.position != .back || ![AVCaptureDevice.DeviceType.builtInWideAngleCamera, .builtInTelephotoCamera].contains(physical?.deviceType ?? .builtInUltraWideCamera) { renderLook.virtualAperture = nil }
        if renderLook.adjustments[.grainSize] > 0 {
            // 颗粒相位跟随实际送显的预览帧：照片是照片预览帧率，视频是节流后的视频预览帧率，
            // 慢动作已固定30fps，因此不会在采集帧率上额外跳动。
            grainFrameCounter &+= 1
            renderLook.grainPhase = Double((grainFrameCounter &* 73) % 4093)
            livePreviewState.update { $0.grainPhase = renderLook.grainPhase }
        }
        var assistedSource = workingSource
        if state.look.nightPreviewAssist && state.videoFrameRate == nil {
            if time-nightPreviewMeasurementTime > 0.25 {
                let target = NightPreviewRenderer.exposureEV(mean:Imaging.meanLuminance(renderSource,context:previewContext))
                nightPreviewEV += (target-nightPreviewEV)*0.35
                nightPreviewMeasurementTime = time
            }
            assistedSource = NightPreviewRenderer.apply(renderSource,ev:nightPreviewEV)
        } else { nightPreviewEV = 0; nightPreviewMeasurementTime = -Double.infinity }
        // 中性画面没有风格/调整/光圈/HDR时直接复用源图，避免为空滤镜链建立 Core Image 图。
        let needsLookProcessing = state.hdr || renderLook.requiresImageProcessing
        var lookImage = needsLookProcessing
            ? Imaging.filtered(assistedSource, look: renderLook, hdr: state.hdr)
            : assistedSource
        if state.hdr, #available(iOS 26.0, *) {
            lookImage = lookImage.settingContentHeadroom(HDRToneMapping.headroom)
        }
        if state.videoColorSpace?.isLog == true, let cube = state.logLUTCube {
            if state.logLUTLog2ToLog1 { lookImage = AppleLogLUTInput.log2ToLog1(lookImage) }
            lookImage = cube.apply(to: lookImage)
        }
        var effected = PreviewRotation.image(lookImage, quarterTurns: state.quarterTurns)
        if mirrorPreview { effected = effected.oriented(.upMirrored) }
        var filtered = effected.transformed(by: CGAffineTransform(scaleX: 900 / effected.extent.width, y: 900 / effected.extent.width))
        if state.portraitPreviewEnabled,
           let portrait = portraitPreviewProcessor.latestSnapshot(generation: state.portraitPreviewGeneration) {
            let foreground = portrait.mask
            var orientedMask = state.nativeFrontPhotoSensor
                ? CaptureOrientation.nativeFrontPreviewFrame(foreground)
                : CaptureOrientation.portraitFrame(foreground)
            if let (focalX, focalY) = nativeFocalLengths {
                orientedMask = CaptureOrientation.correctingIntrinsicScale(orientedMask, focalX: focalX, focalY: focalY)
                orientedMask = state.look.ratio.crop(orientedMask, landscape: state.look.landscape)
            }
            orientedMask = PreviewRotation.image(orientedMask, quarterTurns: state.quarterTurns)
            if mirrorPreview { orientedMask = orientedMask.oriented(.upMirrored) }
            orientedMask = orientedMask.transformed(by: CGAffineTransform(scaleX: 900 / orientedMask.extent.width,
                                                                           y: 900 / orientedMask.extent.width))
            let strength = portraitPreviewProcessor.smoothStrength(state.portraitBlurStrength,
                generation: state.portraitPreviewGeneration)
            let radius = PortraitPhotoRenderer.blurRadius(for: strength * portrait.visibility)
            filtered = PortraitPhotoRenderer.applyPreview(filtered, foregroundMask: orientedMask, radius: radius)
        }
        let orientedSource = PreviewRotation.image(framedSource, quarterTurns: state.quarterTurns)
        let analysisSource = mirrorPreview ? orientedSource.oriented(.upMirrored) : orientedSource
        let display = state.focusPeaking ? FocusPeakingRenderer.apply(to: filtered, analysis: analysisSource) : filtered
        let displaySpace = state.hdr ? CGColorSpace.extendedLinearDisplayP3 : state.videoColorSpace == .p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        guard let image = Imaging.ownedCGImage(display, from: display.extent, context: previewContext,
                                               format: state.hdr ? .RGBAh : .RGBA8,
                                               colorSpace: CGColorSpace(name: displaySpace)!,
                                               headroom: state.hdr ? HDRToneMapping.headroom : nil) else { return }
        if state.histogram {
            // Reuse the exact SDR pixels already rendered for the screen. Passing
            // the lazy filter graph to a second CIContext re-runs the whole look.
            // Keep HDR and peaking analysis on their existing unmodified path.
            let histogramSource = !state.hdr && !state.focusPeaking ? CIImage(cgImage: image) : filtered
            histogramThrottle.submit(HistogramFrame(image: state.look.ratio.crop(histogramSource, landscape: state.look.landscape), revision: state.revision,
                                                   generation: state.readingsGeneration))
        }
        #if DEBUG
        if let callback = previewPairForTesting {
            previewPairForTesting = nil
            let raw = mirrorPreview ? source.oriented(.upMirrored) : source
            let reduced = raw.transformed(by: CGAffineTransform(scaleX: 900 / raw.extent.width, y: 900 / raw.extent.width))
            if let rawCG = previewContext.createCGImage(reduced, from: reduced.extent) {
                print("PREVIEW-PAIR style=\(state.look.style) tone=\(state.look.tone) neutral=\(state.look.adjustments.isNeutral) portrait=\(state.portraitPreviewEnabled) peak=\(state.focusPeaking)")
                DispatchQueue.main.async { callback(UIImage(cgImage: rawCG), UIImage(cgImage: image)) }
            }
        }
        #endif
        publishPreview(UIImage(cgImage: image), revision: state.revision, generation: state.readingsGeneration, userSwitchID: state.userSwitchID, frontLandscape: state.nativeFrontPhotoSensor ? state.nativeFrontSensorLandscape : nil)
    }

}

extension CameraEngine: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // Cinematic 主体/对焦检测由系统处理；delegate 必须存在以驱动电影图。
    }
}

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // 系统给出的预期处理范围仅用于诊断，不把它误作硬性完成期限。
        let range = resolvedSettings.photoProcessingTimeRange
        tracePhotoPhase("will-begin id=\(resolvedSettings.uniqueID) expected=\(range.start.seconds)...\(CMTimeRangeGetEnd(range).seconds)")
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        tracePhotoPhase("will-capture")
        // Serialise with parameter and lens changes, immediately around the shutter event.
        queue.async {
            guard let capture = self.captureContexts[resolvedSettings.uniqueID], let device = self.input?.device else { return }
            if capture.options.nightMode && capture.nightBatchOffset > 0 { return }
            let primary = device.isVirtualDevice ? device.activePrimaryConstituent : device
            var info = PhotoCaptureDiagnostics()
            var parameters = PhotoCaptureParameters()
            parameters.location = capture.location
            parameters.mode = self.manualMode ? "M" : "A"
            parameters.shootingType = capture.options.shootingType == "夜景" && !capture.options.nightMode
                ? "普通" : capture.options.shootingType
            parameters.requestedExposureBiasEV = Double(self.exposureBias)
            if self.metering == .global {
                parameters.globalMeteringBiasEV = Double(self.globalBias)
                parameters.deviceExposureBiasEV = Double(device.exposureTargetBias)
            }
            parameters.requestedFormat = capture.options.format.rawValue
            parameters.requestedMegapixels = capture.options.resolution.rawValue
            parameters.flashMode = capture.flashMode.rawValue
            let look = capture.look
            parameters.ratio = look.ratio.rawValue
            parameters.filterID = look.style.rawValue
            parameters.filterName = look.style.title
            parameters.filterIntensity = look.style == .original ? nil : look.intensity
            parameters.filterAdjustments = look.adjustments
            parameters.toneID = look.tone.rawValue
            parameters.virtualAperture = look.virtualAperture
            parameters.borderEnabled = look.border
            parameters.sampledISO = device.iso.isFinite && device.iso > 0 ? Double(device.iso) : nil
            let duration = CMTimeGetSeconds(device.exposureDuration)
            parameters.sampledExposureSeconds = duration.isFinite && duration > 0 ? duration : nil
            parameters.whiteBalanceMode = self.automaticWhiteBalanceRequested ? "自动" : "手动/锁定"
            parameters.focusPosition = device.lensPosition.isFinite ? Double(device.lensPosition) : nil
            if let gains = WhiteBalanceSafety.validated(device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain) {
                let temperature = device.temperatureAndTintValues(for: gains)
                if temperature.temperature.isFinite { parameters.whiteBalanceKelvin = Double(temperature.temperature) }
                if temperature.tint.isFinite { parameters.whiteBalanceTint = Double(temperature.tint) }
            }
            info.add("拍摄模式", self.manualMode ? "M" : "A")
            let base = device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device) : (self.lensCatalog.first { $0.device.uniqueID == device.uniqueID }.map { $0.displayZoom / $0.zoomFactor } ?? 1)
            let displayed = device.videoZoomFactor * base
            parameters.displayedZoom = Double(displayed)
            info.add("拍摄倍率", String(format: "%.2f×", Double(displayed)))
            if let primary {
                let label: String
                switch primary.deviceType {
                case .builtInUltraWideCamera: label = "超广角"
                case .builtInWideAngleCamera: label = primary.position == .front ? "前置" : "主摄"
                case .builtInTelephotoCamera: label = "长焦"
                default: label = primary.localizedName
                }
                parameters.lensType = label
                parameters.lensName = primary.localizedName
                info.add("快门时主镜头", label)
                info.add("镜头设备", primary.localizedName)
                if let lens = self.lensCatalog.first(where: { $0.device.uniqueID == primary.uniqueID }) {
                    let primaryBase = lens.displayZoom / lens.zoomFactor
                    let factor = displayed / primaryBase
                    info.add("镜头内变焦倍率", String(format: "%.2f×", Double(factor)))
                    let native = primary.activeFormat.secondaryNativeResolutionZoomFactors
                    let match = abs(factor - 1) < 0.01 ? "物理镜头基准档位" : (native.contains { abs($0 - factor) < 0.01 } ? "匹配系统原生分辨率档位" : "未匹配系统原生档位")
                    info.add("档位能力匹配", match)
                    info.add("原生分辨率倍率", ([CGFloat(1)] + native).map { String(format: "%.2f×", Double($0)) }.joined(separator: "、"))
                }
            } else { info.add("快门时主镜头", "未知") }
            info.add("诊断说明", "主镜头为快门时状态快照；系统可能融合多个镜头。档位能力匹配不代表最终处理结果。")
            info.parameters = parameters
            capture.diagnostics = info
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        tracePhotoPhase("did-capture")
        queue.async {
            guard let capture = self.captureContexts[resolvedSettings.uniqueID] else { return }
            // didCapture只代表曝光阶段结束；原生照片管线尚未最终完成，不能此时恢复AE/HDR流。
            // 统一由finishPhotoCapture或失败清理恢复，避免预览策略影响仍在进行的成片处理。
            if !capture.options.nightMode { self.shutterFinished(token: capture.token) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        tracePhotoPhase("processed-callback")
        queue.async {
            guard let capture = self.captureContexts[photo.resolvedSettings.uniqueID] else { return }
            if capture.macroConstituentCapture, photo.sourceDeviceType != .builtInUltraWideCamera { return }
            if let error {
                if !capture.options.nightMode { capture.error = error }
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                if !capture.options.nightMode { capture.error = PhotoEncodingError.encoding }
                return
            }
            var isRepresentativeNightFrame = true
            if capture.options.nightMode {
                let localSequence = photo.sequenceCount > 0 ? photo.sequenceCount : capture.nightFrames.count - capture.nightBatchOffset + 1
                let sequence = capture.nightBatchOffset + localSequence
                capture.nightFrames.append((sequence, data))
                let progress = min(0.85,0.85*Double(capture.nightFrames.count)/Double(max(3,capture.nightTargetFrames)))
                DispatchQueue.main.async {
                    guard self.nightPreviewReveal?.id == capture.token else { return }
                    self.nightPreviewReveal?.progress = progress
                }
                #if DEBUG
                if let callback = self.onNightSourceForTesting { DispatchQueue.main.async { callback(data,sequence) } }
                #endif
                isRepresentativeNightFrame = sequence == 2
                if isRepresentativeNightFrame { capture.processed = data }
            } else if photo.isRawPhoto { capture.raw = data } else {
                capture.processed = data
                #if DEBUG
                if capture.options.usesHDRHEIF, let callback = self.onProcessedHEIFHDRForTesting {
                    DispatchQueue.main.async { callback(data) }
                }
                #endif
                if capture.options.portraitMode, let matte = photo.portraitEffectsMatte {
                    let orientationNumber = photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber
                    let orientation = CGImagePropertyOrientation(rawValue: orientationNumber?.uint32Value ?? 1) ?? .up
                    capture.portraitMatte = matte.applyingExifOrientation(orientation)
                }
            }
            #if DEBUG
            if (!capture.options.nightMode || isRepresentativeNightFrame), !photo.isRawPhoto, let callback = self.onOriginalProcessedPhotoForTesting { DispatchQueue.main.async { callback(data) } }
            #endif
            // For a bracket, keep EXIF and dimensions from the middle exposure as
            // the representative metadata for the merged output.
            if capture.options.nightMode && !isRepresentativeNightFrame { return }
            var info = capture.diagnostics ?? PhotoCaptureDiagnostics()
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            info.parameters?.updateEXIF(properties, overwrite: !photo.isRawPhoto)
            // Prefer processed EXIF when both processed and RAW callbacks arrive.
            info.rows = PhotoCaptureDiagnostics.merged(photo.isRawPhoto ? info.rows : PhotoCaptureDiagnostics.exposureRows(properties: properties), with: photo.isRawPhoto ? PhotoCaptureDiagnostics.exposureRows(properties: properties) : info.rows)
            let dimensions = photo.isRawPhoto ? photo.resolvedSettings.rawPhotoDimensions : photo.resolvedSettings.photoDimensions
            info.add(photo.isRawPhoto ? "传感器 RAW 输出" : "系统照片输出", "\(dimensions.width) × \(dimensions.height)")
            if photo.isRawPhoto, capture.options.usesHDRHEIF, capture.options.resolution == .high,
               Int64(dimensions.width) * Int64(dimensions.height) < 40_000_000,
               let device = self.input?.device {
                // maxPhotoDimensions是上限请求而非保证。保留真实RAW，绝不插值伪造48MP。
                self.reducedHDRResolutionDevices.insert(device.uniqueID)
                info.add("高像素请求", "48MP上限；系统HDR RAW实际输出\(dimensions.width)×\(dimensions.height)，已回退实际规格")
            }
            capture.diagnostics = info
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            guard let capture = self.captureContexts[resolvedSettings.uniqueID] else {
                try? FileManager.default.removeItem(at: outputFileURL); return
            }
            if let error { capture.error = error }
            else { capture.liveMovieReady = duration.seconds > 0 && photoDisplayTime.isValid }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        tracePhotoPhase("hardware-finished")
        queue.async {
            guard let capture = self.captureContexts[resolvedSettings.uniqueID] else { return }
            #if DEBUG
            // 注入“硬件已结束但应用漏掉最终回调”，不让真实系统请求持续占用硬件。
            if capture.dropsFinalCallbackForTesting {
                capture.raw = nil; capture.processed = nil; capture.portraitMatte = nil
                self.droppedCaptureForTesting = capture
                self.tracePhotoPhase("test-final-callback-dropped id=\(resolvedSettings.uniqueID)")
                return
            }
            #endif
            capture.waitingForNativeCompletion = false
            if capture.options.nightMode,
               self.continueAdaptiveNightCaptureIfNeeded(capture, uniqueID: resolvedSettings.uniqueID, error: error) { return }
            self.finishPhotoCapture(uniqueID: resolvedSettings.uniqueID, error: error)
        }
    }

    /// 最后一批完成后才归还硬件 token；普通照片仍按原有单请求路径完成。
    private func finishPhotoCapture(uniqueID: Int64, error: Error?) {
        guard let capture = self.captureContexts[uniqueID] else { return }
        // Live 电影文件可能仍在下发；此时保留 captureContexts，等 finishCapture 的等待循环收尾。
        if !(capture.options.live && capture.error == nil && !capture.liveMovieReady) {
            self.captureContexts.removeValue(forKey: uniqueID)
        }
        self.finishPreviewExposureAssistCapture(capture)
        self.reconcileLiveAudio()
        if self.captureContexts.isEmpty {
            self.hdrStillCapturePreparing = false
            self.refreshHDRPreviewConfiguration()
            if self.deferredPhotoGraphConfiguration, let device = self.input?.device {
                self.deferredPhotoGraphConfiguration = false
                self.configurePreviewOutput(device)
                self.configurePhotoOutput(device)
            }
        }
        self.hardwareFinished(token: capture.token)
        self.releaseNightPreviewHold(capture)
        if capture.options.usesHDRHEIF, capture.diagnostics?.rows.contains(where: { $0.title == "高像素请求" }) == true {
            // 原生捕获已经结束，才允许界面回落规格触发新的照片路由配置。
            DispatchQueue.main.async { self.supportsHighResolutionHEIFHDR = false }
        }
        let failure = error ?? capture.error
        if capture.options.nightMode {
            if capture.nightCancelled {
                self.completeCapture(capture, photo: nil, message: nil)
                return
            }
            var nightInfo = capture.diagnostics ?? PhotoCaptureDiagnostics()
            if let exposure = capture.nightAutomaticExposure {
                nightInfo.add("夜景自动曝光", String(format: "%.4f秒 · ISO %.0f", exposure.seconds, exposure.iso))
            }
            if let name = capture.nightPhysicalDeviceName { nightInfo.add("夜景曝光路线", "系统当前物理镜头：\(name)") }
            nightInfo.add("夜景计划帧数", "\(capture.nightTargetFrames) 帧")
            nightInfo.add("夜景实际采集", "\(capture.nightFrames.count) 帧")
            nightInfo.add("夜景自适应", capture.nightStopReason)
            if let index = capture.nightExposureIndex { nightInfo.add("夜景曝光需求", String(format: "%.1f", index)) }
            capture.diagnostics = nightInfo
            guard !capture.nightFrames.isEmpty else {
                self.completeCapture(capture, photo: nil, message: "夜景拍摄失败：没有收到可用曝光帧。")
                return
            }
            self.processingQueue.async {
                autoreleasepool {
                    let orderedFrames = capture.nightFrames.sorted { $0.sequence < $1.sequence }
                    let decodedFrames = orderedFrames.compactMap { frame -> (sequence: Int, image: CIImage)? in
                        guard let image = CIImage(data: frame.data, options: [.applyOrientationProperty: true]) else { return nil }
                        return (frame.sequence, image)
                    }
                    guard !decodedFrames.isEmpty else {
                        self.completeCapture(capture, photo: nil, message: "夜景处理失败：无法解码曝光帧。")
                        return
                    }
                    do {
                        var diagnostics = capture.diagnostics ?? PhotoCaptureDiagnostics()
                        // 两张有效曝光也可融合；参考始终是序号 2，不能因缺帧改用其他曝光作为基准。
                        if decodedFrames.count >= 2, let referenceIndex = decodedFrames.firstIndex(where: { $0.sequence == 2 }) {
                            self.tracePhotoPhase("night-merge-start")
                            let merged = try NightPhotoMerger.merge(decodedFrames.map(\.image), context: self.context, referenceIndex: referenceIndex,
                                                                  adaptiveTone: capture.nightAutomaticExposure != nil)
                            self.tracePhotoPhase("night-merge-end")
                            let output: CIImage
                            if merged.alignedFrameCount >= 2 {
                                diagnostics.add("夜景曝光合成", "\(merged.alignedFrameCount) 帧对齐融合")
                                diagnostics.add("夜景处理", "运动区域保护、暗部降噪与影调优化")
                                diagnostics.add("夜景边缘裁切", String(format: "%.1f%%", merged.croppedFraction * 100))
                                output = merged.image
                            } else {
                                diagnostics.add("夜景曝光合成", "帧对齐不足，使用中间曝光单帧")
                                output = decodedFrames.first(where: { $0.sequence == 2 })?.image ?? decodedFrames[0].image
                            }
                            capture.diagnostics = diagnostics
                            self.finishCapture(source: output, context: capture)
                        } else {
                            let fallback = decodedFrames.first(where: { $0.sequence == 2 })?.image ?? decodedFrames[0].image
                            diagnostics.add("夜景曝光合成", "曝光帧不完整，使用可用单帧")
                            capture.diagnostics = diagnostics
                            DispatchQueue.main.async { self.onNightCaptureUnavailable?() }
                            self.finishCapture(source: fallback, context: capture)
                        }
                    } catch {
                        self.completeCapture(capture, photo: nil, message: "夜景处理失败：\(error.localizedDescription)")
                    }
                }
            }
            return
        }
        guard failure == nil, let data = (capture.options.format == .heifPro ? capture.raw : capture.processed ?? capture.raw) else {
            if let url = capture.liveMovieURL { try? FileManager.default.removeItem(at: url) }
            self.completeCapture(capture, photo: nil, message: "拍照失败：\(failure?.localizedDescription ?? "无法读取照片")")
            return
        }
        self.processingQueue.async {
            autoreleasepool {
                let source: CIImage?
                let needsRAWFilter = capture.options.format == .heifPro
                    || (capture.options.portraitMode && capture.raw != nil)
                let rawFilter = needsRAWFilter ? CIRAWFilter(imageData: data, identifierHint: nil) : nil
                if needsRAWFilter, let filter = rawFilter {
                    if capture.options.adaptiveHighDynamic {
                        AdaptiveRAWDeveloper.configure(filter,adaptive:true,hdr:capture.options.hdr,adjustments:capture.look.adjustments)
                    } else {
                        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
                        if filter.isDetailSupported { filter.detailAmount = 0 }
                        filter.extendedDynamicRangeAmount = capture.options.hdr ? 1 : 0
                    }
                    source = filter.outputImage
                } else {
                    // 系统处理的 HDR HEIF 主图是 SDR 基底，HDR 在辅助增益图里；
                    // 不展开就只能拿到 SDR，开/关 HDR 的成片会几乎一样。
                    var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
                    if capture.options.hdr { options[.expandToHDR] = true }
                    source = CIImage(data: data, options: options)
                }
                guard let source else {
                    if let url = capture.liveMovieURL { try? FileManager.default.removeItem(at: url) }
                    self.completeCapture(capture, photo: nil, message: "无法解码照片，请更换格式后重试。")
                    return
                }
                let rawPortraitFilter: CIRAWFilter?
                if capture.options.portraitMode, let rawData = capture.raw {
                    rawPortraitFilter = rawData == data
                        ? rawFilter
                        : CIRAWFilter(imageData: rawData, identifierHint: nil)
                } else {
                    rawPortraitFilter = rawFilter
                }
                let rawPortraitMask = capture.options.portraitMode ? rawPortraitFilter?.portraitEffectsMatte : nil
                self.finishCapture(source: source, context: capture, portraitMask: rawPortraitMask)
            }
        }
    }
}

private enum CameraError: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法打开摄像头，请确认设备有可用摄像头。" }
}
