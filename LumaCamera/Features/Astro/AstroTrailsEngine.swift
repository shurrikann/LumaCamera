@preconcurrency import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum AstroTrailBlend: String, CaseIterable, Identifiable {
    case lighten = "星轨"
    case average = "平均"
    case sum = "累加"
    var id: String { rawValue }
}

private enum LabError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

@MainActor
final class AstroTrailsEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedCount = 0
    @Published private(set) var result: UIImage?
    @Published private(set) var error: String?
    var outputOptions = AstroImageOptions()
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var activeDeviceType: AVCaptureDevice.DeviceType?
    @Published private(set) var isoRange: ClosedRange<Double> = 100...12800
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var isCapturing = false
    @Published private(set) var timingText = ""
    @Published private(set) var exposureText = ""
    @Published private(set) var colorSpaceText = ""
    @Published private(set) var formatReport = ""
    @Published private(set) var actualBufferSize = ""
    @Published private(set) var isSaving = false
    @Published private(set) var savedInfo = ""
    @Published var blend: AstroTrailBlend = .lighten
    @Published var durationSeconds = 30
    @Published var captureDurationSeconds: Double? = 1800
    @Published var autoSaveOnFinish = true
    @Published var manualSettings = AstroManualSettings()
    let durationOptions = [1, 2, 5, 10, 15, 20, 25, 30]
    var targetFrames: Int {
        guard let captureDurationSeconds, captureDurationSeconds.isFinite, captureDurationSeconds > 0 else { return Int.max }
        return max(1, Int(captureDurationSeconds.rounded()))
    }
    @Published var prefer12MP = true

    private var preferredDeviceType: AVCaptureDevice.DeviceType
    init(deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera,
         sharedSession: AstroSharedCaptureSession? = nil) {
        self.preferredDeviceType = deviceType
        self.sharedSession = sharedSession
        self.session = sharedSession?.session ?? AVCaptureSession()
        self.sessionQueue = sharedSession?.queue ?? DispatchQueue(label: "camera.long-exposure.session")
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
    private let videoQueue = DispatchQueue(label: "camera.long-exposure.video", qos: .userInitiated)
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    /// Intermediate accumulation must stay linear. Using the display/output
    /// context here would gamma-encode every accumulated frame.
    private let accumulatorContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    ])
    private nonisolated static let frameContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    nonisolated private let deviceSlot = LockedCaptureValue<AVCaptureDevice?>(nil)
    nonisolated private var device: AVCaptureDevice? {
        get { deviceSlot.value }
        set { deviceSlot.value = newValue }
    }
    private var accumulator: CIImage?
    private var accumulatorBuffer: CVPixelBuffer?
    private var fusionExtent: CGRect = .zero
    private var sceneRegistration: AstroSceneRegistration?
    private var qualityGate = AstroFrameQualityGate()
    private var captureDeadline: Task<Void, Never>?
    private var trailMotion = AstroTrailMotion()
    private var previousTrail: CIImage?
    private var frameTimes: [TimeInterval] = []
    private var framePTS: [Double] = []
    private let previewExposureGate = AstroPreviewExposureGate()
    private var captureMetadata = AstroImageOptions()
    private var savedCaptureID: UUID?
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
        let uses12MP = prefer12MP
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
                if self.session.sessionPreset != .inputPriority && self.session.canSetSessionPreset(.inputPriority) {
                    self.session.sessionPreset = .inputPriority
                }
                guard let device = AVCaptureDevice.default(lensType, for: .video, position: .back)
                        ?? (replacingLens ? nil : AVCaptureDevice.default(for: .video)) else {
                    throw LabError.unavailable("没有可用后摄")
                }
                let prefer12MP = uses12MP
                let all = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let pixels = Int(dims.width) * Int(dims.height)
                    let exposure = CMTimeGetSeconds(format.maxExposureDuration)
                    return pixels >= 12_000_000 && exposure >= 0.999
                        && format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 29.999
                        }
                }
                let fourK = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let exposure = CMTimeGetSeconds(format.maxExposureDuration)
                    return dims.width == 3840 && dims.height == 2160 && exposure >= 0.999
                        && format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 29.999
                        }
                }
                let fullHD = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let exposure = CMTimeGetSeconds(format.maxExposureDuration)
                    return dims.width == 1920 && dims.height == 1080 && exposure >= 0.999
                        && format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 29.999
                        }
                }
                let selected12MP = prefer12MP ? all.first : nil
                let format = selected12MP ?? fourK.first ?? fullHD.first
                guard let format else {
                    throw LabError.unavailable("当前相机不支持 1fps / 1 秒曝光")
                }
                try device.lockForConfiguration()
                if device.activeFormat !== format { device.activeFormat = format }
                let previewDuration = CMTime(value: 1, timescale: 15)
                if CMTimeCompare(device.activeVideoMinFrameDuration, previewDuration) != 0 { device.activeVideoMinFrameDuration = previewDuration }
                if CMTimeCompare(device.activeVideoMaxFrameDuration, previewDuration) != 0 { device.activeVideoMaxFrameDuration = previewDuration }
                device.unlockForConfiguration()

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw LabError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                if !self.session.outputs.contains(where: { $0 === self.output }) {
                    self.output.alwaysDiscardsLateVideoFrames = true
                    let desiredPixel = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    if self.output.availableVideoPixelFormatTypes.contains(desiredPixel) {
                        self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: desiredPixel]
                    } else {
                        self.output.videoSettings = [:]
                    }
                    self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
                    guard self.session.canAddOutput(self.output) else { throw LabError.unavailable("无法加入视频输出") }
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
                    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    self.formatReport = "12MP候选=\(all.count) 4K候选=\(fourK.count) active=\(dims.width)x\(dims.height)"
                    if !preserveStatus { self.status = "\(dims.width)×\(dims.height) 采集 · 增量累加" }
                    self.actualBufferSize = "等待首帧实际尺寸"
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
        guard preferredDeviceType != type, !isCapturing, !isSaving, previewExposureGate.permitsPreview else { return }
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

    func begin() { begin(location: nil) }

    func begin(location: PhotoLocation?) {
        guard !isCapturing, !isSaving, !switchingLens, let device else { return }
        if let previous = recoveryID { AstroRecoveryStore.shared.keep(previous) }
        captureMetadata = outputOptions
        captureMetadata.recordCaptureStart(mode: "星轨", location: location, settings: manualSettings)
        savedCaptureID = nil
        let recovery = AstroRecoveryStore.shared.begin(kind: "星轨", options: captureMetadata)
        recoveryID = recovery
        previewExposureGate.setCaptureActive(true)
        isCapturing = true
        result = nil
        capturedCount = 0
        qualityGate = AstroFrameQualityGate(); trailMotion = AstroTrailMotion(); previousTrail = nil
        captureDeadline?.cancel(); captureDeadline = nil
        self.accumulator = nil
        self.accumulatorBuffer = nil
        fusionExtent = .zero
        sceneRegistration = nil
        frameTimes = []
        framePTS = []
        timingText = ""
        exposureText = ""
        colorSpaceText = ""
        let target = targetFrames
        var settings = manualSettings
        settings.fusionExposureSeconds = target
        status = "正在长曝光 0/\(targetFrames)"
        error = nil
        sessionQueue.async { [weak self] in
            guard let self, self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
            AstroCaptureExposurePreparation(device: device, settings: settings, shutter: 1,
                video: true, queue: self.sessionQueue,
                isCurrent: { self.recoveryID == recovery && !self.previewExposureGate.permitsPreview
                    && (self.sharedSession?.owns(self.sessionOwner) ?? true) }) { outcome in
                switch outcome {
                case .success(let reading):
                    DispatchQueue.main.async {
                        guard self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
                        self.captureMetadata.recordCaptureDevice(device, settings: settings, reading: reading)
                        self.capturing = true
                        self.acceptedAt = CACurrentMediaTime() + 0.25
                        self.status = "正在长曝光 0/\(target)"
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        guard self.recoveryID == recovery else { return }
                        self.isCapturing = false; self.status = "准备"
                        self.error = error.localizedDescription
                        self.restoreAfterCapture()
                    }
                }
            }.start()
        }
    }

    func cancel() {
        guard !isSaving else { return }
        captureDeadline?.cancel(); captureDeadline = nil
        if let id = recoveryID { AstroRecoveryStore.shared.discard(id); recoveryID = nil }

        capturing = false
        isCapturing = false
        self.accumulator = nil
        self.accumulatorBuffer = nil
        result = nil
        capturedCount = 0
        status = "已取消"
        restoreAfterCapture()
    }

    func reset() {
        guard !isSaving else { return }
        if let id = recoveryID { AstroRecoveryStore.shared.discard(id); recoveryID = nil }

        self.accumulator = nil
        self.accumulatorBuffer = nil
        fusionExtent = .zero
        sceneRegistration = nil
        result = nil
        capturedCount = 0
        timingText = ""
        status = "4K 采集 · 4K 增量累加"
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                  didOutput sampleBuffer: CMSampleBuffer,
                                  from connection: AVCaptureConnection) {
        previewFrames.receive(sampleBuffer, from:connection)
        guard !previewExposureGate.permitsPreview, frameAdmission.begin() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { frameAdmission.end(); return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { frameAdmission.end(); return }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        // Copy the capture buffer immediately; holding cvPixelBuffer across
        // frames exhausts the video output pool.
        guard let cgImage = Self.frameContext.createCGImage(image, from: extent) else { frameAdmission.end(); return }
        let owned = CIImage(cgImage: cgImage)
        let now = CACurrentMediaTime()
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let colorSpace = (cgImage.colorSpace?.name as String?) ?? "nil"
        let admission = frameAdmission
        Task { @MainActor [weak self] in
            defer { admission.end() }
            guard let self, self.capturing else { return }
            guard now >= self.acceptedAt else { return }
            self.actualBufferSize = "实际buffer=\(bufferWidth)x\(bufferHeight)"
            if self.captureDeadline == nil, let seconds = self.captureDurationSeconds {
                let id = self.recoveryID
                self.captureDeadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(for:.seconds(max(0.1,seconds-0.9)))
                    guard !Task.isCancelled, let self, self.recoveryID == id, self.isCapturing else { return }
                    self.stopAndSave()
                }
            }
            self.fuse(owned, at: pts)
            self.frameTimes.append(now)
            self.framePTS.append(pts)
            if self.colorSpaceText.isEmpty { self.colorSpaceText = "CGImage: \(colorSpace)" }
            self.exposureText = String(format: "曝光 %.3fs · ISO %.0f", self.captureMetadata.exposureSeconds, self.captureMetadata.iso)
            if let id = self.recoveryID, let image = self.accumulator {
                self.captureMetadata.frameCount = self.capturedCount
                AstroRecoveryStore.shared.checkpoint(id: id, image: image, options: self.captureMetadata)
            }
            self.status = "正在长曝光 \(self.capturedCount)/\(self.targetFrames)"
            if self.capturedCount >= self.targetFrames {
                self.finish()
            }
        }
    }

    private func fuse(_ frame: CIImage, at now: CFTimeInterval) {
        let extent = frame.extent.integral
        guard extent.width > 0, extent.height > 0 else { return }
        if fusionExtent == .zero { fusionExtent = CGRect(origin: .zero, size: extent.size) }
        let raw = frame
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: fusionExtent)
        let statistics = AstroFrameStatistics.measure(raw,context:accumulatorContext)
        if qualityGate.consider(statistics) == .reject { return }
        if sceneRegistration == nil { sceneRegistration = AstroSceneRegistration(reference: raw, context: accumulatorContext) }
        // Register the static ground only; stellar motion is the desired trail.
        var normalized = sceneRegistration?.stabilizeGround(raw) ?? raw
        if let sky = sceneRegistration?.matte.image {
            normalized = AstroTransientTracks.clean(normalized,previous:previousTrail,sky:sky,context:accumulatorContext)
            trailMotion.observe(normalized,sky:sky,time:now,context:accumulatorContext)
            previousTrail = AstroSceneRegistration(reference:normalized,context:accumulatorContext,matte:sceneRegistration?.matte).reference
        }
        let count = capturedCount + 1
        let combined: CIImage
        if let accumulator {
            switch blend {
            case .lighten:
                let sky = normalized.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: accumulator])
                if let matte = sceneRegistration?.matte, matte.confidence > 0.01 {
                    let a = 1.0/Double(count)
                    let current = normalized.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:a,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:a,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:a,w:0)])
                    let old = accumulator.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:1-a,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:1-a,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:1-a,w:0)])
                    let average = current.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:old])
                    combined = sky.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:average,kCIInputMaskImageKey:matte.image])
                } else { combined = sky }
            case .sum:
                combined = normalized.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: accumulator
                ])
            case .average:
                let alpha = 1.0 / Double(count)
                let current = normalized.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                let previous = accumulator.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 - alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 - alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 - alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                combined = current.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: previous
                ])
            }
        } else {
            combined = normalized
        }
        guard let next = materialize(combined) else {
            status = "累积失败"
            capturing = false
            isCapturing = false
            restoreAfterCapture()
            return
        }
        accumulator = next.image
        accumulatorBuffer = next.buffer
        capturedCount = count
        _ = now
    }

    private func materialize(_ image: CIImage) -> (image: CIImage, buffer: CVPixelBuffer)? {
        let width = Int(fusionExtent.width.rounded())
        let height = Int(fusionExtent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_64RGBAHalf,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        accumulatorContext.render(image, to: buffer,
                                 bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                 colorSpace: linearSpace)
        // The half-float buffer contains linear-light values. Attach the same
        // color space explicitly; CIImage(cvPixelBuffer:) otherwise has no
        // reliable linear tag and the next blend treats it as sRGB.
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearSpace])
        return (image, buffer)
    }

    private func finish() {
        captureDeadline?.cancel(); captureDeadline = nil
        guard capturing, let accumulator else {
            if isCapturing || capturing { cancel() }
            return
        }
        capturing = false
        isCapturing = false
        status = "正在输出 4K"
        let extent = fusionExtent
        var finished = AstroPostProcessor.flattenBackground(accumulator, sky:sceneRegistration?.matte.image)
        finished = AstroSignalProtection.denoise(finished,iso:captureMetadata.iso,context:context,sky:sceneRegistration?.matte.image)
        if let sky = sceneRegistration?.matte.image { finished = trailMotion.fill(finished,sky:sky) }
        finished = AstroPostProcessor.enhanceTrails(finished)
        guard let cgImage = context.createCGImage(finished, from: extent) else {
            status = "合成失败"
            restoreAfterCapture()
            return
        }
        result = UIImage(cgImage: cgImage)
        captureMetadata.frameCount = capturedCount
        if !autoSaveOnFinish, let id = recoveryID {
            AstroRecoveryStore.shared.checkpoint(id: id, image: finished, options: captureMetadata, final: true)
        }
        self.accumulator = nil
        self.accumulatorBuffer = nil
        if let first = framePTS.first, let last = framePTS.last, framePTS.count > 1 {
            let intervals = zip(framePTS.dropFirst(), framePTS).map { $0 - $1 }
            let average = intervals.reduce(0, +) / Double(intervals.count)
            timingText = String(format: "%d 帧 · PTS %.1fs · 间隔 %.3fs / 最大 %.3fs",
                                framePTS.count, last - first, average, intervals.max() ?? 0)
        } else {
            timingText = "\(framePTS.count) 帧"
        }
        status = "星轨完成 · \(framePTS.count) 帧"
        restoreAfterCapture()
        if autoSaveOnFinish { saveResult() }
    }

    func keepResultForRecovery() {
        if result != nil, !isSaving, let id = recoveryID { AstroRecoveryStore.shared.keep(id) }
    }

    func stopAndSave() {
        guard isCapturing || capturing else { return }
        if let id = recoveryID { AstroRecoveryStore.shared.protect(id) }
        guard capturedCount > 0 else { cancel(); return }
        finish()
    }

    func saveResult() {
        guard let cgImage = result?.cgImage, !isSaving, savedCaptureID == nil else { return }
        isSaving = true; savedInfo = ""
        let options = captureMetadata
        let id = recoveryID ?? AstroRecoveryStore.shared.begin(kind: "星轨", options: options)
        recoveryID = id
        AstroRecoveryStore.shared.saveImage(id: id, image: cgImage, options: options) { [weak self] saved in
            guard let self else { return }; self.isSaving = false
            switch saved {
            case .success:
                self.savedCaptureID = id
                self.savedInfo = AstroRecoveryStore.shared.wasImported(id) ? "已保存到相册" : "已暂存，可稍后恢复"
            case .failure(let error): self.savedInfo = "保存失败：\(error.localizedDescription)"; self.error = error.localizedDescription
            }
        }
    }

    private func restoreAfterCapture() {
        previewExposureGate.setCaptureActive(false)
        if started, UIApplication.shared.applicationState != .background, let device, CMTimeGetSeconds(device.exposureDuration) > 0.25 {
            // Rebuild the idle route after acquisition; simply restarting the
            // running graph does not reliably retain the preview exposure.
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
        captureDeadline?.cancel(); captureDeadline = nil
        switchingLens = false
        startRevision = UUID()
        guard started else { return }
        capturing = false
        started = false
        restoreAfterCapture()
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

struct AstroTrailsEngineView: View {
    @StateObject private var lab = AstroTrailsEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                ZStack {
                    AstroTrailsEngineAVPreview(session: lab.session)
                        .ignoresSafeArea()
                    if let result = lab.result {
                        Image(uiImage: result)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.92))
                    }
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(lab.durationSeconds) 秒多帧长曝光")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        Text(lab.status)
                            .font(.system(size: 11, design: .monospaced))
                        if !lab.exposureText.isEmpty {
                            Text(lab.exposureText)
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.75)
                        }
                        if !lab.timingText.isEmpty {
                            Text(lab.timingText)
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.75)
                        }
                        if !lab.colorSpaceText.isEmpty {
                            Text(lab.colorSpaceText)
                                .font(.system(size: 9, design: .monospaced))
                                .opacity(0.55)
                        }
                        if !lab.formatReport.isEmpty {
                            Text(lab.formatReport)
                                .font(.system(size: 9, design: .monospaced))
                                .opacity(0.65)
                        }
                        if !lab.actualBufferSize.isEmpty {
                            Text(lab.actualBufferSize)
                                .font(.system(size: 9, design: .monospaced))
                                .opacity(0.65)
                        }
                        if !lab.savedInfo.isEmpty {
                            Text(lab.savedInfo)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if lab.isCapturing {
                            ProgressView(value: Double(lab.capturedCount), total: Double(lab.targetFrames))
                                .tint(AppTheme.accent)
                                .frame(width: min(220, proxy.size.width - 40))
                        }
                    }
                    .foregroundStyle(.red)
                    .shadow(color: .black.opacity(0.75), radius: 2)
                    .padding(14)
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        if !lab.isCapturing {
                            Picker("时长", selection: $lab.durationSeconds) {
                                ForEach(lab.durationOptions, id: \.self) { value in
                                    Text("\(value) 秒").tag(value)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                            .frame(width: 220)
                            Toggle("优先 12MP", isOn: $lab.prefer12MP)
                                .font(.system(size: 11))
                                .frame(width: 220)
                            Picker("融合", selection: $lab.blend) {
                                ForEach(AstroTrailBlend.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        HStack(spacing: 12) {
                        if lab.isCapturing {
                            Button("取消") { lab.cancel() }
                                .buttonStyle(.bordered)
                        } else if lab.result != nil {
                            Button("保存到相册") { lab.saveResult() }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.accent)
                                .disabled(lab.isSaving)
                            Button("重新拍摄") { lab.reset() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("开始 \(lab.durationSeconds) 秒") { lab.begin() }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.accent)
                        }
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            if let error = lab.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle("长曝光测试")
        .navigationBarTitleDisplayMode(.inline)
        .task { lab.start() }
        .onDisappear { lab.stop() }
    }
}

private struct AstroTrailsEngineAVPreview: UIViewRepresentable {
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
