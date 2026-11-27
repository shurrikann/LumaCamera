@preconcurrency import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum AstroPhotoEngineError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

enum AstroPhotoExposure: String, CaseIterable, Identifiable {
    case s15 = "1/15"
    case s8 = "1/8"
    case s4 = "1/4"
    case s2 = "1/2"
    case s1 = "1"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .s15: return 1.0 / 15.0
        case .s8: return 1.0 / 8.0
        case .s4: return 1.0 / 4.0
        case .s2: return 1.0 / 2.0
        case .s1: return 1.0
        }
    }
}

@MainActor
final class AstroPhotoEngine: NSObject, ObservableObject {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedFrames = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var isSaving = false
    @Published private(set) var result: UIImage?
    @Published private(set) var info = ""
    @Published private(set) var luminanceText = ""
    @Published private(set) var lastFile = ""
    @Published private(set) var error: String?
    var outputOptions = AstroImageOptions()
    var autoSaveOnFinish = true
    private var captureOptions = AstroImageOptions()
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var activeDeviceType: AVCaptureDevice.DeviceType?
    @Published private(set) var isoRange: ClosedRange<Double> = 100...12800
    @Published private(set) var maxZoom: CGFloat = 1
    @Published var frameCount = 10
    @Published var exposure: AstroPhotoExposure = .s1
    @Published var manualSettings = AstroManualSettings()
    let frameOptions = [10, 30, 60]

    private var preferredDeviceType: AVCaptureDevice.DeviceType
    init(deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera,
         sharedSession: AstroSharedCaptureSession? = nil) {
        self.preferredDeviceType = deviceType
        self.sharedSession = sharedSession
        self.session = sharedSession?.session ?? AVCaptureSession()
        self.sessionQueue = sharedSession?.queue ?? DispatchQueue(label: "camera.star-photo-raw.session")
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
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let previewOutput = AVCaptureVideoDataOutput()
    nonisolated let previewFrames = AstroPreviewFrameStore()
    private let previewQueue = DispatchQueue(label: "camera.star-photo.preview")
    private let sessionQueue: DispatchQueue
    nonisolated private let deviceSlot = LockedCaptureValue<AVCaptureDevice?>(nil)
    nonisolated private var device: AVCaptureDevice? {
        get { deviceSlot.value }
        set { deviceSlot.value = newValue }
    }
    private let stackWorker = AstroPhotoStackWorker()
    private var frameBudget = AstroPhotoFrameBudget(target: 10)
    private var attemptedFrames = 0
    private var deadlineTask: Task<Void, Never>?
    private var forceSaveOnFinish = false
    private let previewExposureGate = AstroPreviewExposureGate()
    nonisolated private let recoveryIDSlot = LockedCaptureValue<UUID?>(nil)
    nonisolated private var recoveryID: UUID? {
        get { recoveryIDSlot.value }
        set { recoveryIDSlot.value = newValue }
    }
    private var finishingCapture = false
    private var capturing = false
    nonisolated private let startedSlot = LockedCaptureValue<Bool>(false)
    nonisolated private var started: Bool {
        get { startedSlot.value }
        set { startedSlot.value = newValue }
    }
    private var framePTS: [Double] = []
    private var rawDelegates: [UUID: RawCaptureDelegate] = [:]

    func start() { start(replacingLens: false) }

    private func start(replacingLens: Bool) {
        guard !started || replacingLens else { return }
        switchingLens = true
        let startID = UUID()
        startRevision = startID
        started = true
        let previewSettings = manualSettings
        let lensType = preferredDeviceType
        sessionQueue.async { [weak self] in
            guard let self, self.started, self.startRevision == startID else { return }
            let reuseGraph = replacingLens && self.session.outputs.contains { $0 === self.photoOutput }
                && (self.sharedSession?.owns(self.sessionOwner) ?? true)
            let previousInputs = reuseGraph ? self.session.inputs : []
            do {
                self.session.beginConfiguration()
                if reuseGraph {
                    self.session.inputs.forEach { self.session.removeInput($0) }
                } else { self.sharedSession?.prepare(self.sessionOwner) }
                if self.session.sessionPreset != .photo { self.session.sessionPreset = .photo }
                guard let device = AVCaptureDevice.default(lensType, for: .video, position: .back)
                        ?? (replacingLens ? nil : AVCaptureDevice.default(for: .video)) else {
                    throw AstroPhotoEngineError.unavailable("没有可用后摄")
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw AstroPhotoEngineError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                if !self.session.outputs.contains(where: { $0 === self.photoOutput }) {
                    guard self.session.canAddOutput(self.photoOutput) else { throw AstroPhotoEngineError.unavailable("无法加入照片输出") }
                    self.session.addOutput(self.photoOutput)
                }
                if !self.session.outputs.contains(where: { $0 === self.previewOutput }) {
                    self.previewOutput.alwaysDiscardsLateVideoFrames = true
                    self.previewOutput.automaticallyConfiguresOutputBufferDimensions = false
                    self.previewOutput.deliversPreviewSizedOutputBuffers = true
                    self.previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.previewOutput.setSampleBufferDelegate(self.previewFrames, queue: self.previewQueue)
                    guard self.session.canAddOutput(self.previewOutput) else { throw AstroPhotoEngineError.unavailable("无法加入取景输出") }
                    self.session.addOutput(self.previewOutput)
                }
                if let connection = self.previewOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                if let twelve = device.activeFormat.supportedMaxPhotoDimensions.first(where: {
                    $0.width == 4032 && $0.height == 3024
                }) {
                    if self.photoOutput.maxPhotoDimensions.width != twelve.width || self.photoOutput.maxPhotoDimensions.height != twelve.height {
                        self.photoOutput.maxPhotoDimensions = twelve
                    }
                }
                if reuseGraph {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = 1
                    device.unlockForConfiguration()
                }
                self.session.commitConfiguration()
                // Collect the first two route-matched frames promptly; steady-state snapshots stay at 4 Hz.
                self.previewFrames.reset(forDeviceID:device.uniqueID, fastStart:true)
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
                    let hasRAW = !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
                    self.status = hasRAW ? "12MP RAW 星空照片测试" : "当前相机没有可用 RAW 格式"
                    if !hasRAW { self.error = "当前相机没有 Bayer RAW 格式" }
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
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            error = "当前相机没有可用 RAW 格式"
            return
        }
        if let previous = recoveryID { AstroRecoveryStore.shared.keep(previous) }
        captureOptions = outputOptions
        captureOptions.recordCaptureStart(mode: "星空照片", location: location, settings: manualSettings)
        lastFile = ""
        let recovery = AstroRecoveryStore.shared.begin(kind: "星空照片", options: captureOptions)
        recoveryID = recovery
        previewExposureGate.setCaptureActive(true)
        isCapturing = true
        finishingCapture = false
        result = nil
        capturedFrames = 0
        stackWorker.begin(recovery)
        frameBudget = AstroPhotoFrameBudget(target: frameCount)
        attemptedFrames = 0
        forceSaveOnFinish = false
        deadlineTask?.cancel(); deadlineTask = nil
        framePTS = []
        lastExposureReading = nil
        info = ""
        error = nil
        status = "正在拍摄 RAW 星空照片 0/\(frameCount)"
        let target = frameCount
        let exposureSeconds = manualSettings.clampedPhotoShutter
        let settings = manualSettings
        sessionQueue.async { [weak self] in
            guard let self, self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
            AstroCaptureExposurePreparation(device: device, settings: settings, shutter: exposureSeconds,
                video: false, queue: self.sessionQueue,
                isCurrent: { self.recoveryID == recovery && !self.previewExposureGate.permitsPreview
                    && (self.sharedSession?.owns(self.sessionOwner) ?? true) }) { outcome in
                switch outcome {
                case .success(let reading):
                    DispatchQueue.main.async {
                        guard self.recoveryID == recovery, !self.previewExposureGate.permitsPreview else { return }
                        self.lastExposureReading = reading
                        self.captureOptions.recordCaptureDevice(device, settings: settings, reading: reading)
                        self.capturing = true
                        self.status = "正在拍摄 RAW 星空照片 0/\(target)"
                        self.acceptedAt = CACurrentMediaTime()
                        let limit = max(45, Double(self.frameBudget.maximumAttempts) * (reading.sensorSeconds + 2))
                        self.deadlineTask = Task { @MainActor [weak self = self] in
                            try? await Task.sleep(for: .seconds(limit))
                            guard !Task.isCancelled, let self, self.recoveryID == recovery, self.capturing else { return }
                            self.finish()
                        }
                        self.captureNext(rawType: rawType)
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

    private(set) var lastExposureReading: AstroCaptureExposurePreparation.Reading?

    private var acceptedAt: CFTimeInterval = 0

    private func captureNext(rawType: OSType) {
        guard capturing else { return }
        captureFrame(rawType: rawType)
    }

    private func captureFrame(rawType: OSType) {
        guard capturing else { return }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        settings.flashMode = .off
        settings.photoQualityPrioritization = .speed
        let token = UUID()
        let captureID = recoveryID
        let delegate = RawCaptureDelegate { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rawDelegates.removeValue(forKey: token)
                guard self.capturing, self.recoveryID == captureID else { return }
                switch result {
                case .success(let rawFrame):
                    if let seconds = rawFrame.exposureSeconds, seconds.isFinite, seconds > 0 { self.captureOptions.exposureSeconds = seconds }
                    if let iso = rawFrame.iso, iso.isFinite, iso > 0 { self.captureOptions.iso = iso }
                    if let focal = rawFrame.focalLength, focal.isFinite, focal > 0 { self.captureOptions.focalLengthMM = focal }
                    if let aperture = rawFrame.aperture, aperture.isFinite, aperture > 0 {
                        self.captureOptions.parameters?.aperture = aperture
                    }
                    self.attemptedFrames += 1
                    guard let captureID else { return }
                    self.stackWorker.append(rawFrame.data, id: captureID) { [weak self] snapshot in
                        Task { @MainActor [weak self] in
                            guard let self, self.capturing, self.recoveryID == captureID else { return }
                            guard let snapshot else { self.fail("RAW 累积失败"); return }
                            self.capturedFrames = snapshot.acceptedFrames
                            self.framePTS.append(CACurrentMediaTime())
                            if let image = snapshot.image {
                                self.captureOptions.frameCount = snapshot.acceptedFrames
                                AstroRecoveryStore.shared.checkpoint(id: captureID, image: image, options: self.captureOptions)
                            }
                            self.status = "正在拍摄 RAW 星空照片 \(self.capturedFrames)/\(self.frameBudget.target)"
                            if self.frameBudget.shouldContinue(accepted: self.capturedFrames, attempted: self.attemptedFrames) {
                                self.captureNext(rawType: rawType)
                            } else {
                                self.finish()
                            }
                        }
                    }
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
        rawDelegates[token] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func fail(_ message: String) {
        if let id = recoveryID { AstroRecoveryStore.shared.keep(id); stackWorker.cancel(id) }
        deadlineTask?.cancel(); deadlineTask = nil
        capturing = false
        isCapturing = false
        finishingCapture = false
        error = message
        status = "拍摄失败"
        restoreAfterCapture()
    }

    func cancel() {
        guard !isSaving else { return }
        if let id = recoveryID { AstroRecoveryStore.shared.discard(id); stackWorker.cancel(id); recoveryID = nil }
        deadlineTask?.cancel(); deadlineTask = nil

        capturing = false
        isCapturing = false
        finishingCapture = false
        rawDelegates.removeAll()
        result = nil
        capturedFrames = 0
        status = "已取消"
        restoreAfterCapture()
    }

    func reset() {
        guard !isSaving else { return }
        if let id = recoveryID { AstroRecoveryStore.shared.discard(id); recoveryID = nil }

        result = nil
        capturedFrames = 0
        info = ""
        status = "12MP RAW 星空照片测试"
    }

    private func finish() {
        guard capturing, let id = recoveryID else { return }
        capturing = false
        finishingCapture = true
        deadlineTask?.cancel(); deadlineTask = nil
        status = "正在合成 RAW 堆栈"
        let iso = captureOptions.iso
        stackWorker.finish(id: id, iso: iso) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.recoveryID == id, self.isCapturing else { return }
                guard let snapshot, let cg = snapshot.rendered else { self.fail("没有可合成帧"); return }
                self.result = UIImage(cgImage: cg)
                self.capturedFrames = snapshot.acceptedFrames
                self.captureOptions.frameCount = snapshot.acceptedFrames
                if !self.autoSaveOnFinish, !self.forceSaveOnFinish, let image = snapshot.image {
                    AstroRecoveryStore.shared.checkpoint(id: id, image: image, options: self.captureOptions, final: true)
                }
                self.info = "\(cg.width)x\(cg.height) · \(snapshot.acceptedFrames) 帧有效 RAW · 3 组中值"
                self.status = "RAW 星空照片完成"
                self.isCapturing = false
                self.finishingCapture = false
                self.restoreAfterCapture()
                if self.autoSaveOnFinish || self.forceSaveOnFinish { self.save() }
            }
        }
    }

    func keepResultForRecovery() {
        if result != nil, !isSaving, let id = recoveryID { AstroRecoveryStore.shared.keep(id) }
    }

    func interruptAndSave() {
        guard isCapturing || capturing else { return }
        guard capturedFrames > 0 else { cancel(); return }
        if let id = recoveryID { AstroRecoveryStore.shared.protect(id) }
        forceSaveOnFinish = true
        finish()
    }

    func save() {
        guard let cgImage = result?.cgImage, !isSaving, lastFile.isEmpty else { return }
        isSaving = true; info = ""
        let options = captureOptions
        let id = recoveryID ?? AstroRecoveryStore.shared.begin(kind: "星空照片", options: options)
        recoveryID = id
        AstroRecoveryStore.shared.saveImage(id: id, image: cgImage, options: options) { [weak self] saved in
            guard let self else { return }; self.isSaving = false
            switch saved {
            case .success(let file):
                self.lastFile = file.lastPathComponent
                self.info = AstroRecoveryStore.shared.wasImported(id) ? "已保存到相册" : "已暂存，可稍后恢复"
            case .failure(let error): self.info = "保存失败：\(error.localizedDescription)"; self.error = error.localizedDescription
            }
        }
    }

    private func restoreAfterCapture() {
        previewExposureGate.setCaptureActive(false)
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
        deadlineTask?.cancel(); deadlineTask = nil
        if !finishingCapture {
            if let id = recoveryID { stackWorker.cancel(id) }
            isCapturing = false
        }
        guard started else { return }
        capturing = false
        started = false
        rawDelegates.removeAll()
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

struct AstroRawFrame {
    let data: Data
    let focalLength: Double?
    let iso: Double?
    var exposureSeconds: Double? = nil
    var aperture: Double? = nil
}

private final class RawCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<AstroRawFrame, Error>) -> Void
    init(completion: @escaping (Result<AstroRawFrame, Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(AstroPhotoEngineError.unavailable("RAW 文件为空"))); return
        }
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let focal = (exif?[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        completion(.success(AstroRawFrame(data: data, focalLength: focal, iso: iso,
            exposureSeconds: (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
            aperture: (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue)))
    }
}

struct AstroPhotoEnginePreview: View {
    @StateObject private var lab = AstroPhotoEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AstroPhotoEngineAVPreview(session: lab.session).ignoresSafeArea()
            if let result = lab.result {
                Image(uiImage: result).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("星空照片 RAW 测试").font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(lab.status).font(.system(size: 11, design: .monospaced))
                if !lab.info.isEmpty { Text(lab.info).font(.system(size: 10, design: .monospaced)) }
                if !lab.luminanceText.isEmpty { Text(lab.luminanceText).font(.system(size: 10, design: .monospaced)) }
                if !lab.lastFile.isEmpty { Text("副本：\(lab.lastFile)").font(.system(size: 9, design: .monospaced)) }
                Spacer()
                if !lab.isCapturing {
                    Picker("帧数", selection: $lab.frameCount) {
                        ForEach(lab.frameOptions, id: \.self) { value in Text("\(value) 帧 RAW").tag(value) }
                    }.pickerStyle(.menu).tint(.white)
                    Picker("单帧曝光", selection: $lab.exposure) {
                        ForEach(AstroPhotoExposure.allCases) { value in Text(value.rawValue + "s").tag(value) }
                    }.pickerStyle(.menu).tint(.white)
                }
                if lab.isCapturing {
                    ProgressView(value: Double(lab.capturedFrames), total: Double(lab.frameCount)).tint(AppTheme.accent).frame(width: 220)
                }
                HStack(spacing: 12) {
                    if lab.isCapturing {
                        Button("取消") { lab.cancel() }.buttonStyle(.bordered)
                    } else if lab.result != nil {
                        Button("保存到相册") { lab.save() }.buttonStyle(.borderedProminent).tint(AppTheme.accent).disabled(lab.isSaving)
                        Button("重新拍摄") { lab.reset() }.buttonStyle(.bordered)
                    } else {
                        Button("开始拍摄") { lab.begin() }.buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    }
                }
            }
            .foregroundStyle(.red).shadow(color: .black.opacity(0.75), radius: 2)
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = lab.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding().background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle("星空照片 RAW 测试")
        .navigationBarTitleDisplayMode(.inline)
        .task { lab.start() }
        .onDisappear { lab.stop() }
    }
}

private struct AstroPhotoEngineAVPreview: UIViewRepresentable {
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
           connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        return view
    }
    func updateUIView(_ uiView: View, context: Context) {}
}
