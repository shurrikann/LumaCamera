@preconcurrency import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AstroTimelapseEngineError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

@MainActor
final class AstroTimelapseEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedFrames = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var savedInfo = ""
    @Published private(set) var error: String?
    var outputOptions = AstroImageOptions()
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var activeDeviceType: AVCaptureDevice.DeviceType?
    @Published private(set) var isoRange: ClosedRange<Double> = 100...12800
    @Published private(set) var maxZoom: CGFloat = 1
    @Published var intervalSeconds = 10
    @Published var durationMinutes: Int? = 60
    @Published var manualSettings = AstroManualSettings()
    let intervalOptions = [5, 10, 15, 20, 30]
    var fusionExposureSeconds: Int { manualSettings.clampedFusionExposure }
    var effectiveIntervalSeconds: Int { max(1, intervalSeconds, fusionExposureSeconds) }

    private var preferredDeviceType: AVCaptureDevice.DeviceType
    init(deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera,
         sharedSession: AstroSharedCaptureSession? = nil) {
        self.preferredDeviceType = deviceType
        self.sharedSession = sharedSession
        self.session = sharedSession?.session ?? AVCaptureSession()
        self.sessionQueue = sharedSession?.queue ?? DispatchQueue(label: "camera.astro-timelapse.session")
    }

    // Immutable route handles; all graph mutations stay on sessionQueue.
    nonisolated(unsafe) let session: AVCaptureSession
    private let sharedSession: AstroSharedCaptureSession?
    private let sessionOwner = UUID()
    nonisolated private let startRevisionSlot = LockedCaptureValue<UUID>(UUID())
    nonisolated private var startRevision: UUID {
        get { startRevisionSlot.value }
        set { startRevisionSlot.value = newValue }
    }
    @Published private(set) var switchingLens = false
    var ownsCaptureRoute: Bool { sharedSession?.owns(sessionOwner) ?? session.isRunning }
    nonisolated(unsafe) private let output = AVCaptureVideoDataOutput()
    nonisolated let previewFrames = AstroPreviewFrameStore()
    nonisolated private let frameAdmission = AstroFrameAdmission()
    private let sessionQueue: DispatchQueue
    private let videoQueue = DispatchQueue(label: "camera.astro-timelapse.video", qos: .userInitiated)
    private let renderContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    nonisolated private let deviceSlot = LockedCaptureValue<AVCaptureDevice?>(nil)
    nonisolated private var device: AVCaptureDevice? {
        get { deviceSlot.value }
        set { deviceSlot.value = newValue }
    }
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var outputIndex = 0
    private var activeFusionFrames = 1
    private var fusionCount = 0
    private var fusionAccumulator: CIImage?
    private var fusionExtent: CGRect = .zero
    private(set) var samplingStartedAt: CFTimeInterval?
    private(set) var samplingEndedAt: CFTimeInterval?
    private var timeline = AstroCaptureTimeline(interval: 10, fusion: 1, duration: nil)
    private var deadlineTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var pendingOutput: CIImage?
    private var pendingWindow = 0
    private var currentWindow = -1
    private var movieScene: AstroSceneRegistration?
    private var groupScene: AstroSceneRegistration?
    private var groupQuality = AstroFrameQualityGate()
    private var tone = AstroTemporalTone()
    private let previewExposureGate = AstroPreviewExposureGate()
    nonisolated private let recoveryIDSlot = LockedCaptureValue<UUID?>(nil)
    nonisolated private var recoveryID: UUID? {
        get { recoveryIDSlot.value }
        set { recoveryIDSlot.value = newValue }
    }
    private var capturing = false
    private var acceptedAt: CFTimeInterval = 0
    nonisolated private let startedSlot = LockedCaptureValue<Bool>(false)
    nonisolated private var started: Bool {
        get { startedSlot.value }
        set { startedSlot.value = newValue }
    }
    private var preservingCaptureStatus = false

    func start() { start(replacingLens: false) }

    private func start(replacingLens: Bool) {
        guard !started || replacingLens else { return }
        switchingLens = true
        let startID = UUID()
        startRevision = startID
        started = true
        let preserveStatus = preservingCaptureStatus
        preservingCaptureStatus = false
        let previewSettings = manualSettings
        let lensType = preferredDeviceType
        sessionQueue.async { [weak self] in
            guard let self, self.started, self.startRevision == startID else { return }
            let reuseGraph = replacingLens && self.session.outputs.contains { $0 === self.output }
                && (self.sharedSession?.owns(self.sessionOwner) ?? true)
            let previousInputs = reuseGraph ? self.session.inputs : []
            do {
                self.session.beginConfiguration()
                if reuseGraph {
                    self.session.inputs.forEach { self.session.removeInput($0) }
                } else { self.sharedSession?.prepare(self.sessionOwner) }
                if self.session.sessionPreset != .inputPriority && self.session.canSetSessionPreset(.inputPriority) { self.session.sessionPreset = .inputPriority }
                guard let device = AVCaptureDevice.default(lensType, for: .video, position: .back)
                        ?? (replacingLens ? nil : AVCaptureDevice.default(for: .video)) else {
                    throw AstroTimelapseEngineError.unavailable("没有可用后摄")
                }
                let candidates = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let exposure = CMTimeGetSeconds(format.maxExposureDuration)
                    return dims.width == 3840 && dims.height == 2160 && exposure >= 0.999
                        && format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 29.999
                        }
                }
                guard let format = candidates.first else {
                    throw AstroTimelapseEngineError.unavailable("当前相机不支持 1fps / 1 秒曝光")
                }
                try device.lockForConfiguration()
                if device.activeFormat !== format { device.activeFormat = format }
                let previewDuration = CMTime(value: 1, timescale: 15)
                if CMTimeCompare(device.activeVideoMinFrameDuration, previewDuration) != 0 { device.activeVideoMinFrameDuration = previewDuration }
                if CMTimeCompare(device.activeVideoMaxFrameDuration, previewDuration) != 0 { device.activeVideoMaxFrameDuration = previewDuration }
                device.unlockForConfiguration()

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw AstroTimelapseEngineError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                if !self.session.outputs.contains(where: { $0 === self.output }) {
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
                    guard self.session.canAddOutput(self.output) else { throw AstroTimelapseEngineError.unavailable("无法加入视频输出") }
                    self.session.addOutput(self.output)
                }
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                if reuseGraph {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = 1
                    device.unlockForConfiguration()
                }
                self.session.commitConfiguration()
                self.previewFrames.reset(forDeviceID:device.uniqueID, fastStart:reuseGraph)
                self.device = device
                DispatchQueue.main.async {
                    guard self.started, self.startRevision == startID else { return }
                    self.switchingLens = false
                    self.zoomFactor = device.videoZoomFactor
                    self.activeDeviceType = device.deviceType
                    let format = device.activeFormat
                    self.isoRange = Double(format.minISO)...Double(format.maxISO)
                }
                DispatchQueue.main.async { if self.started, self.startRevision == startID { self.maxZoom = min(device.maxAvailableVideoZoomFactor, 10) } }
                self.applyPreviewSettingsOnQueue(previewSettings, device: device)
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    guard self.started, self.startRevision == startID else { return }
                    if !preserveStatus { self.status = "对准星空，保持手机稳定" }
                    if !preserveStatus { self.error = nil }
                }
            } catch {
                if reuseGraph {
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    for input in previousInputs where self.session.canAddInput(input) { self.session.addInput(input) }
                }
                self.session.commitConfiguration()
                self.previewFrames.reset(forDeviceID:self.device?.uniqueID, fastStart:reuseGraph)
                DispatchQueue.main.async {
                    guard self.started, self.startRevision == startID else { return }
                    self.switchingLens = false
                    if let old = self.device { self.preferredDeviceType = old.deviceType }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func refreshPreviewSettings() {
        guard previewExposureGate.permitsPreview else { return }
        let settings = manualSettings
        sessionQueue.async { [weak self] in
            guard let self, self.started, self.previewExposureGate.permitsPreview,
                  let device = self.device else { return }
            self.applyPreviewSettingsOnQueue(settings, device: device)
        }
    }

    nonisolated private func applyPreviewSettingsOnQueue(_ settings: AstroManualSettings, device: AVCaptureDevice) {
        guard previewExposureGate.permitsPreview else { return }
        if let shared = sharedSession, !shared.owns(sessionOwner) { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try device.applyAstroPreviewSettings(settings)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.error = error.localizedDescription }
        }
    }

    func setZoom(_ value: CGFloat) {
        guard !switchingLens, previewExposureGate.permitsPreview else { return }
        let requestRoute = startRevision
        sessionQueue.async { [weak self] in
            guard let self, self.started, self.startRevision == requestRoute, self.previewExposureGate.permitsPreview, let device = self.device else { return }
            if let shared = self.sharedSession, !shared.owns(self.sessionOwner) { return }
            let maximum = min(device.maxAvailableVideoZoomFactor, 10)
            let target = min(max(value, 1), maximum)
            do {
                try device.lockForConfiguration()
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = target
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.zoomFactor = target
                    self.maxZoom = maximum
                }
            } catch {}
        }
    }

    func setPreferredLens(_ type: AVCaptureDevice.DeviceType) {
        preferredDeviceType = type
    }

    func switchLens(to type: AVCaptureDevice.DeviceType) {
        guard preferredDeviceType != type, !isRecording, !isFinishing, previewExposureGate.permitsPreview else { return }
        preferredDeviceType = type
        guard started else { return }
        switchingLens = true
        error = nil
        start(replacingLens: true)
    }

    func setPreviewPaused(_ paused: Bool) {
        guard previewExposureGate.permitsPreview else { return }
        let settings = manualSettings
        sessionQueue.async { [weak self] in
            guard let self, self.started, self.previewExposureGate.permitsPreview else { return }
            if let shared = self.sharedSession, !shared.owns(self.sessionOwner) { return }
            if paused {
                if self.session.isRunning { self.session.stopRunning() }
            } else if !self.session.isRunning {
                if let device = self.device { self.applyPreviewSettingsOnQueue(settings, device: device) }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func begin() {
        guard !isRecording, !isFinishing, !switchingLens, ownsCaptureRoute, session.isRunning, let device else { return }
        if let previous = recoveryID { AstroRecoveryStore.shared.keep(previous) }
        let recovery = AstroRecoveryStore.shared.begin(kind: "星空延时", options: outputOptions)
        recoveryID = recovery
        previewExposureGate.setCaptureActive(true)
        isRecording = true
        capturedFrames = 0
        savedInfo = ""
        error = nil
        outputIndex = 0
        activeFusionFrames = fusionExposureSeconds
        timeline = AstroCaptureTimeline(interval: Double(effectiveIntervalSeconds), fusion: Double(activeFusionFrames),
            duration: durationMinutes.map { Double($0) * 60 })
        currentWindow = -1; pendingOutput = nil
        samplingStartedAt = nil; samplingEndedAt = nil
        movieScene = nil; groupScene = nil; tone = AstroTemporalTone(); groupQuality = AstroFrameQualityGate()
        deadlineTask?.cancel(); deadlineTask = nil
        fusionCount = 0
        fusionAccumulator = nil
        fusionExtent = .zero
        var settings = manualSettings
        settings.fusionExposureSeconds = activeFusionFrames
        status = "正在拍摄星空延时 · 融合 \(activeFusionFrames) 秒/帧"
        let interval = effectiveIntervalSeconds
        sessionQueue.async { [weak self] in
            guard let self, self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
            AstroCaptureExposurePreparation(device: device, settings: settings, shutter: 1,
                video: true, queue: self.sessionQueue,
                isCurrent: { self.recoveryID == recovery && !self.previewExposureGate.permitsPreview
                    && (self.sharedSession?.owns(self.sessionOwner) ?? true) }) { outcome in
                switch outcome {
                case .success:
                    DispatchQueue.main.async {
                        guard self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
                        do { try self.setupWriter(recoveryID: recovery) }
                        catch {
                            self.isRecording = false; self.error = error.localizedDescription
                            self.restoreAfterCapture()
                            return
                        }
                        self.capturing = true
                        self.acceptedAt = CACurrentMediaTime() + 0.25
                        self.status = "正在拍摄星空延时 · 间隔 \(interval) 秒"
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        guard self.recoveryID == recovery else { return }
                        self.isRecording = false
                        self.error = error.localizedDescription
                        self.restoreAfterCapture()
                    }
                }
            }.start()
        }
    }

    private func setupWriter(recoveryID: UUID) throws {
        let url = try AstroRecoveryStore.shared.journal.videoURL(id: recoveryID)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 30)
        writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 30)
        var metadata: [AVMetadataItem] = []
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Luma 星空延时" as NSString
        title.extendedLanguageTag = "und"
        metadata.append(title)
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = "LumaCamera" as NSString
        software.extendedLanguageTag = "und"
        metadata.append(software)
        let comment = AVMutableMetadataItem()
        comment.identifier = .commonIdentifierDescription
        comment.value = "Luma 星空延时 · \(effectiveIntervalSeconds)s 采样 · \(fusionExposureSeconds)s 融合" as NSString
        comment.extendedLanguageTag = "und"
        metadata.append(comment)
        writer.metadata = metadata
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 2160,
            AVVideoHeightKey: 3840,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false]
        ]
        let h264: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false]
        ]
        let settings = writer.canApply(outputSettings: hevc, forMediaType: .video) ? hevc : h264
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 2160,
            kCVPixelBufferHeightKey as String: 3840
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw AstroTimelapseEngineError.unavailable("无法创建 HEVC/H.264 视频输入") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AstroTimelapseEngineError.unavailable("无法启动视频写入")
        }
        writer.startSession(atSourceTime: .zero)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        self.outputURL = url
    }

    func stopAndSave(manual: Bool = true) {
        guard isRecording else { return }
        deadlineTask?.cancel(); deadlineTask = nil
        samplingEndedAt = CACurrentMediaTime()
        capturing = false; isRecording = false; isFinishing = true
        if pendingOutput == nil, let partial = fusionAccumulator, fusionCount > 0 {
            pendingOutput = partial; pendingWindow = currentWindow
            fusionCount = 0; fusionAccumulator = nil
        }
        if let id = recoveryID { AstroRecoveryStore.shared.protect(id) }
        restoreAfterCapture()
        let id = recoveryID
        finishTask = Task { @MainActor [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while let self, self.recoveryID == id, !Task.isCancelled {
                self.flushPendingOutput()
                if self.pendingOutput == nil || ProcessInfo.processInfo.systemUptime >= deadline {
                    self.finishSavingAfterDrain(manual: manual)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func finishSavingAfterDrain(manual: Bool) {
        guard AstroTimelapseStopPolicy.shouldSave(outputFrames: outputIndex, manual: manual) else {
            cancel(); status = "没有完整画面，已丢弃"; return
        }
        isFinishing = true; status = "正在封装延时视频"
        guard let writer, let input = writerInput, let url = outputURL, let id = recoveryID else {
            isFinishing = false; status = "没有可用视频"; return
        }
        guard writer.status == .writing else {
            isFinishing = false; error = writer.error?.localizedDescription ?? "延时视频写入失败"
            AstroRecoveryStore.shared.keep(id); return
        }
        input.markAsFinished()
        Task { @MainActor [weak self] in
            await writer.finishWriting()
            guard let self, self.recoveryID == id else { return }
            guard writer.status == .completed else {
                self.isFinishing = false; self.status = "视频封装失败"; self.error = writer.error?.localizedDescription
                AstroRecoveryStore.shared.keep(id); return
            }
            AstroRecoveryStore.shared.saveVideo(id: id, file: url) { [weak self] saved in
                guard let self, self.recoveryID == id else { return }; self.isFinishing = false
                switch saved {
                case .success:
                    self.status = "星空延时完成"
                    self.savedInfo = AstroRecoveryStore.shared.wasImported(id) ? "已保存到相册" : "已暂存，可稍后恢复"
                case .failure(let error): self.error = error.localizedDescription; self.status = "保存失败"
                }
            }
        }
    }

    /// Finalizes the current writer without saving to Photos. Used by the
    /// telephoto verification screen so diagnostics never enter the library.
    func finishVerification() {
        guard isRecording else { return }
        deadlineTask?.cancel(); deadlineTask = nil
        flushPendingOutput()
        capturing = false
        isRecording = false
        isFinishing = true
        restoreAfterCapture()
        guard outputIndex > 0, let writer, let input = writerInput, let url = outputURL else {
            isFinishing = false
            status = "没有采到 4K 帧"
            return
        }
        let captureID = recoveryID
        input.markAsFinished()
        Task { @MainActor [weak self] in
            await writer.finishWriting()
            let ok = writer.status == .completed
            try? FileManager.default.removeItem(at: url)
            guard let self, self.recoveryID == captureID else { return }
            if let id = self.recoveryID { AstroRecoveryStore.shared.discard(id); self.recoveryID = nil }
            self.isFinishing = false
            self.status = ok ? "4K 封装验证通过 · \(self.capturedFrames) 帧" : "4K 封装验证失败"
            if !ok { self.error = writer.error?.localizedDescription }
        }
    }

    func cancel() {
        finishTask?.cancel(); finishTask = nil
        deadlineTask?.cancel(); deadlineTask = nil; pendingOutput = nil
        if let id = recoveryID { AstroRecoveryStore.shared.discard(id); recoveryID = nil }

        capturing = false
        isRecording = false
        isFinishing = false
        writer?.cancelWriting()
        writer = nil; writerInput = nil; adaptor = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
        capturedFrames = 0
        status = "已取消"
        restoreAfterCapture()
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                  didOutput sampleBuffer: CMSampleBuffer,
                                  from connection: AVCaptureConnection) {
        previewFrames.receive(sampleBuffer, from:connection)
        guard !previewExposureGate.permitsPreview, frameAdmission.begin() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { frameAdmission.end(); return }
        let now = CACurrentMediaTime()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let admission = frameAdmission
        Task { @MainActor [weak self] in
            defer { admission.end() }
            guard let self, self.capturing else { return }
            guard now >= self.acceptedAt else { return }
            self.flushPendingOutput()
            guard self.pendingOutput == nil else { return }
            guard let tick = self.timeline.next(pts: pts) else { return }
            if self.samplingStartedAt == nil { self.samplingStartedAt = CACurrentMediaTime() }
            if self.deadlineTask == nil, let seconds = self.timeline.duration {
                let id = self.recoveryID
                self.deadlineTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled, let self, self.recoveryID == id, self.isRecording else { return }
                    self.stopAndSave(manual: false)
                }
            }
            if tick.finished { self.stopAndSave(manual: false); return }
            if tick.newWindow {
                if let partial = self.fusionAccumulator, self.fusionCount > 0 {
                    self.pendingOutput = partial; self.pendingWindow = self.currentWindow
                    self.flushPendingOutput()
                }
                self.fusionCount = 0; self.fusionAccumulator = nil
                self.currentWindow = tick.window
                self.groupScene = nil
                self.groupQuality = AstroFrameQualityGate()
            }
            if tick.complete, !tick.collect, let partial = self.fusionAccumulator, self.fusionCount > 0 {
                self.pendingOutput = partial; self.pendingWindow = tick.window
                self.fusionCount = 0; self.fusionAccumulator = nil
                self.flushPendingOutput()
            }
            guard tick.collect, self.pendingOutput == nil else { return }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = image.extent
            let scale = max(2160 / extent.width, 3840 / extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cropX = max(0, (image.extent.width - 2160) / 2)
            let cropY = max(0, (image.extent.height - 3840) / 2)
            image = image.cropped(to: CGRect(x: image.extent.minX + cropX, y: image.extent.minY + cropY, width: 2160, height: 3840))
            guard let fused = self.fuseTimelapseFrame(image) ?? self.fusionAccumulator else { return }
            self.status = "正在融合 \(self.fusionCount)/\(self.activeFusionFrames) 秒"
            if tick.complete {
                self.pendingOutput = fused; self.pendingWindow = tick.window
                self.fusionCount = 0; self.fusionAccumulator = nil
                self.flushPendingOutput()
            }
        }
    }

    private func flushPendingOutput() {
        guard let fused = pendingOutput, let adaptor, let input = writerInput,
              input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out else { return }
        let stableTone = tone.process(fused,context:renderContext)
        let rendered = outputOptions.watermark ? AstroWatermarkRenderer.overlay(on: stableTone) : stableTone
        renderContext.render(rendered, to: out, bounds: CGRect(x: 0, y: 0, width: 2160, height: 3840),
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        if adaptor.append(out, withPresentationTime: CMTime(value: Int64(pendingWindow), timescale: 30)) {
            outputIndex += 1; capturedFrames = outputIndex; pendingOutput = nil
            status = "正在拍摄星空延时 · \(capturedFrames) 帧"
        } else if let error = writer?.error { self.error = error.localizedDescription }
    }

    private func fuseTimelapseFrame(_ source: CIImage) -> CIImage? {
        if movieScene == nil { movieScene = AstroSceneRegistration(reference: source, context: renderContext) }
        let stable = movieScene?.stabilizeGround(source) ?? source
        if groupScene == nil { groupScene = AstroSceneRegistration(reference: stable, context: renderContext, matte: movieScene?.matte) }
        let statistics = AstroFrameStatistics.measure(stable,context:renderContext)
        switch groupQuality.consider(statistics) {
        case .reject: return nil
        case .replaceReference:
            groupScene = AstroSceneRegistration(reference:stable,context:renderContext,matte:movieScene?.matte)
            fusionCount = 0; fusionAccumulator = nil
        case .accept: break
        }
        var frame = groupScene?.align(stable, ground: false) ?? stable
        if let reference = fusionAccumulator, let sky = movieScene?.matte.image {
            frame = AstroTransientTracks.clean(frame,previous:reference,sky:sky,context:renderContext)
            frame = AstroSignalProtection.temporalClean(frame,reference:reference,noise:statistics.noise,sky:sky)
        }
        if fusionExtent == .zero { fusionExtent = CGRect(x: 0, y: 0, width: 2160, height: 3840) }
        let count = fusionCount + 1
        let alpha = 1.0 / Double(count)
        let combined: CIImage
        if let fusionAccumulator {
            let current = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let previous = fusionAccumulator.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            combined = current.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: previous])
        } else {
            combined = frame
        }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 2160, 3840, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        renderContext.render(combined, to: buffer, bounds: fusionExtent,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        fusionCount = count
        fusionAccumulator = CIImage(cvPixelBuffer: buffer)
        return fusionAccumulator
    }

    private func restoreAfterCapture() {
        previewExposureGate.setCaptureActive(false)
        if started, UIApplication.shared.applicationState != .background, let device,
           max(device.exposureDuration.seconds, device.activeVideoMaxFrameDuration.seconds) > 0.25 {
            // Automatic ISO can shorten exposure while retaining the 1 fps
            // capture cadence. Restore that graph just as for long exposures.
            sharedSession?.stopForLongExposureRecovery(sessionOwner)
            preservingCaptureStatus = true
            stop()
            start()
            return
        }
        let settings = manualSettings
        let restorePreview = started
        sessionQueue.async { [weak self] in
            guard let self, self.previewExposureGate.permitsPreview, let device = self.device else { return }
            if let shared = self.sharedSession, !shared.owns(self.sessionOwner) { return }
            if restorePreview, self.started {
                self.applyPreviewSettingsOnQueue(settings, device: device)
                return
            }
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeMaxExposureDuration = device.activeFormat.maxExposureDuration
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func stop() {
        switchingLens = false
        startRevision = UUID()
        guard started else { return }
        capturing = false
        started = false
        if isRecording { cancel() }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let shared = self.sharedSession {
                shared.release(self.sessionOwner)
                return
            }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
        }
    }
}

struct AstroTimelapseEngineView: View {
    @StateObject private var lab = AstroTimelapseEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AstroTimelapseEngineAVPreview(session: lab.session).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text("星空延时").font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(lab.status).font(.system(size: 11, design: .monospaced))
                if !lab.savedInfo.isEmpty {
                    Text(lab.savedInfo).font(.system(size: 10, design: .monospaced))
                }
                Spacer()
                if !lab.isRecording && !lab.isFinishing {
                    Picker("间隔", selection: $lab.intervalSeconds) {
                        ForEach(lab.intervalOptions, id: \.self) { value in
                            Text("每 \(value) 秒一帧").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
                HStack(spacing: 12) {
                    if lab.isRecording {
                        Button("停止并保存") { lab.stopAndSave() }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                    } else if !lab.isFinishing {
                        Button("开始拍摄") { lab.begin() }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                    }
                    if lab.isFinishing {
                        ProgressView().tint(.white)
                    }
                }
            }
            .foregroundStyle(.red)
            .shadow(color: .black.opacity(0.75), radius: 2)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = lab.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding().background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle("星空延时测试")
        .navigationBarTitleDisplayMode(.inline)
        .task { lab.start() }
        .onDisappear { lab.stop() }
    }
}

private struct AstroTimelapseEngineAVPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> View {
        let view = View()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }
    func updateUIView(_ uiView: View, context: Context) {}
}


enum AstroTimelapseStopPolicy {
    /// Both a finite recording and a manual stop keep any valid encoded frame.
    /// A short selected duration must not silently discard its completed clip.
    static func shouldSave(outputFrames: Int, manual: Bool) -> Bool {
        outputFrames > 0
    }
}
