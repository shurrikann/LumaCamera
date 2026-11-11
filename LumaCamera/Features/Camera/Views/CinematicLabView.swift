import SwiftUI
import AVFoundation
import UIKit

/// Isolated Apple-style Cinematic session for diagnosing frame delivery without
/// the main camera graph. Settings presents this while the normal camera is off.
struct CinematicLabView: View {
    @StateObject private var lab = CinematicLabModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("按 Apple Cinematic Video 文档单独建立会话，不接入主相机输出图。用于对比官方顺序是否连续出帧。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("对照配置", selection: $lab.configuration) {
                    ForEach(CinematicLabModel.Configuration.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(lab.running || lab.starting)
                .onChange(of: lab.configuration) { _, _ in lab.stop() }
                CinematicLabPreview(session: lab.session)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
                HStack {
                    Button(lab.running ? "停止" : "开始诊断") {
                        lab.running ? lab.stop() : lab.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(lab.starting)
                    Spacer()
                    if lab.starting { ProgressView() }
                }
                Group {
                    row("会话", lab.running ? "运行中" : "停止")
                    row("电影输入", lab.inputCinematic ? "已启用" : "未启用")
                    row("采集帧", "\(lab.frames)")
                    row("最近 1 秒", "\(lab.framesPerSecond) fps")
                    row("场景", lab.scene.isEmpty ? "正常" : lab.scene)
                    row("帧周期", lab.duration)
                    row("错误", lab.error ?? "无")
                }
                Text(lab.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .navigationTitle("电影模式诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { lab.stop() }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 13))
    }
}

private struct CinematicLabPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

@MainActor
final class CinematicLabModel: NSObject, ObservableObject {
    enum Configuration: String, CaseIterable, Identifiable {
        case official, appLike
        var id: String { rawValue }
        var title: String { self == .official ? "官方顺序" : "App 参数" }
    }
    @Published var configuration = Configuration.official
    let session = AVCaptureSession()
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var frames = 0
    @Published private(set) var framesPerSecond = 0
    @Published private(set) var inputCinematic = false
    @Published private(set) var scene = ""
    @Published private(set) var duration = "-"
    @Published private(set) var error: String?
    @Published private(set) var log = "尚未开始"

    private let queue = DispatchQueue(label: "cinematic.lab.session")
    private let videoQueue = DispatchQueue(label: "cinematic.lab.video")
    private let output = AVCaptureVideoDataOutput()
    private let metadata = AVCaptureMetadataOutput()
    private let photo = AVCapturePhotoOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private let counter = CinematicFrameCounter()
    private var statsTask: Task<Void, Never>?
    private var runtimeObserver: NSObjectProtocol?

    func start() {
        guard !starting, !running else { return }
        starting = true; error = nil; log = "配置中…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureOnQueue(configuration: self.configuration)
                self.session.startRunning()
                let configured: Bool
                if #available(iOS 26.0, *) {
                    configured = self.input?.isCinematicVideoCaptureEnabled == true
                } else { configured = false }
                let running = self.session.isRunning
                let message = "startRunning 前启用电影：\(configured)，会话运行：\(running)"
                DispatchQueue.main.async {
                    self.starting = false; self.running = running
                    self.inputCinematic = configured
                    self.log = message
                    self.startStats()
                }
            } catch {
                DispatchQueue.main.async {
                    self.starting = false; self.running = false
                    self.error = error.localizedDescription
                    self.log = "启动失败：\(error)"
                    self.teardownOnQueue()
                }
            }
        }
    }

    func stop() {
        statsTask?.cancel(); statsTask = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver); self.runtimeObserver = nil }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.teardownOnQueue()
            DispatchQueue.main.async {
                self.running = false; self.starting = false
                self.frames = 0; self.framesPerSecond = 0; self.inputCinematic = false
                self.log = "已停止"
            }
        }
    }

    private func configureOnQueue(configuration: Configuration) throws {
        teardownOnQueue()
        guard #available(iOS 26.0, *) else { throw LabError.unavailable("需要 iOS 26") }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw LabError.unavailable("相机权限未开启")
        }
        guard let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            throw LabError.unavailable("没有 DualWide 后置相机")
        }
        let candidates = device.formats.filter { format in
            format.isCinematicVideoCaptureSupported
                && CMVideoFormatDescriptionGetDimensions(format.formatDescription).width == 1920
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        guard let format = candidates.first else { throw LabError.unavailable("没有 1080p30 电影格式") }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
        device.unlockForConfiguration()
        self.device = device

        if configuration == .appLike, session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard input.isCinematicVideoCaptureSupported else { throw LabError.unavailable("输入不支持电影") }
        if configuration == .appLike, let microphone = AVCaptureDevice.default(for: .audio) {
            audioInput = try? AVCaptureDeviceInput(device: microphone)
        }
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw LabError.unavailable("无法加入电影输入") }
        session.addInput(input)
        self.input = input
        if configuration == .appLike, let audioInput, session.canAddInput(audioInput) {
            session.addInput(audioInput)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }

        // Apple: set cinematic enabled before startRunning, then add outputs.
        input.isCinematicVideoCaptureEnabled = true

        var outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if configuration == .appLike {
            outputSettings[kCVPixelBufferWidthKey as String] = 1920
            outputSettings[kCVPixelBufferHeightKey as String] = 1080
            outputSettings[AVVideoAllowWideColorKey] = false
        }
        output.videoSettings = outputSettings
        output.alwaysDiscardsLateVideoFrames = configuration == .official
        if configuration == .appLike {
            output.automaticallyConfiguresOutputBufferDimensions = false
            output.deliversPreviewSizedOutputBuffers = false
            input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30)
        }
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw LabError.unavailable("无法加入视频输出") }
        session.addOutput(output)

        metadata.setMetadataObjectsDelegate(self, queue: videoQueue)
        guard session.canAddOutput(metadata) else { throw LabError.unavailable("无法加入电影 metadata 输出") }
        session.addOutput(metadata)
        let required = metadata.requiredMetadataObjectTypesForCinematicVideoCapture
        guard !required.isEmpty, required.allSatisfy(metadata.availableMetadataObjectTypes.contains) else {
            throw LabError.unavailable("电影 metadata 类型不可用")
        }
        metadata.metadataObjectTypes = required
        if configuration == .appLike {
            guard session.canAddOutput(photo) else { throw LabError.unavailable("无法加入 PhotoOutput") }
            session.addOutput(photo)
        }
        session.commitConfiguration()

        runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "未知错误"
            self?.error = message
        }
        duration = String(format: "%.4fs", device.activeVideoMinFrameDuration.seconds)
        scene = "\(device.cinematicVideoCaptureSceneMonitoringStatuses)"
        counter.reset()
    }

    private func startStats() {
        statsTask?.cancel()
        var last = currentFrames()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = self.currentFrames()
                self.framesPerSecond = now - last
                self.frames = now
                last = now
                if let device = self.device {
                    self.scene = "\(device.cinematicVideoCaptureSceneMonitoringStatuses)"
                    self.duration = String(format: "%.4fs", device.activeVideoMinFrameDuration.seconds)
                }
            }
        }
    }

    private func currentFrames() -> Int { counter.value }

    private func teardownOnQueue() {
        if session.isRunning { session.stopRunning() }
        if session.inputs.contains(where: { $0 === input }) { session.removeInput(input!) }
        if let audioInput, session.inputs.contains(where: { $0 === audioInput }) { session.removeInput(audioInput) }
        if session.outputs.contains(output) { session.removeOutput(output) }
        if session.outputs.contains(metadata) { session.removeOutput(metadata) }
        if session.outputs.contains(photo) { session.removeOutput(photo) }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        output.setSampleBufferDelegate(nil, queue: nil)
        metadata.setMetadataObjectsDelegate(nil, queue: nil)
        input = nil
        audioInput = nil
        device = nil
        counter.reset()
    }

    private enum LabError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(text) = self { return text }; return nil }
    }
}

extension CinematicLabModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        counter.increment()
    }
    nonisolated func captureOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {}
}

private final class CinematicFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}
