import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Isolated AF-tracking lab. It shares no CameraEngine session or state with the
/// main camera, so tracking experiments cannot destabilize capture.
struct AFTrackingLabView: View {
    @StateObject private var lab = AFTrackingLab()
    @State private var surfaceSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                let rect = AVMakeRect(aspectRatio: CGSize(width: 3, height: 4),
                                      insideRect: CGRect(origin: .zero, size: proxy.size))
                ZStack(alignment: .topLeading) {
                    ZStack {
                        AFLabPreview(lab: lab)
                            .frame(width: rect.width, height: rect.height)
                            .clipped()
                        if let box = lab.trackingBox {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(lab.reacquiring ? Color.yellow : (lab.lost ? Color.white.opacity(0.72) : Color.green),
                                        style: StrokeStyle(lineWidth: lab.lost ? 1.4 : 2,
                                                           dash: lab.reacquiring ? [6, 4] : []))
                                .frame(width: 54, height: 54)
                                .position(x: box.midX * rect.width, y: box.midY * rect.height)
                                .allowsHitTesting(false)
                        }
                        if let point = lab.focusIndicator {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.yellow)
                                .position(x: point.x * rect.width, y: point.y * rect.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                            .onEnded { value in
                                if case .second(true, let drag?) = value {
                                    lab.beginTracking(at: drag.startLocation,
                                                      size: CGSize(width: rect.width, height: rect.height))
                                }
                            }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { lab.endTracking() })
                    .position(x: rect.midX, y: rect.midY)
                    .onAppear { lab.updatePreviewSize(rect.size) }
                    .onChange(of: rect.size) { _, size in lab.updatePreviewSize(size) }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(lab.status).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(lab.systemDetail).font(.system(size: 9, design: .monospaced)).opacity(0.72)
                        Text(lab.detail).font(.system(size: 9, design: .monospaced)).opacity(0.72)
                        Text(lab.recoveryDebug).font(.system(size: 9, design: .monospaced)).opacity(0.72)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
            }
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Button(lab.trackingBox == nil ? "长按画面选择主体" : (lab.lost ? "跟踪丢失" : "主体已锁定")) {
                        if lab.trackingBox != nil { lab.endTracking() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(lab.lost ? .gray : AppTheme.accent)
                    .disabled(lab.trackingBox == nil)
                    Button("重新开始") { lab.restart() }
                        .buttonStyle(.bordered)
                }
                .padding(.bottom, 24)
            }
            if let error = lab.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding().background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle("AF追踪")
        .navigationBarTitleDisplayMode(.inline)
        .task { lab.start() }
        .onDisappear { lab.stop() }
    }
}

private struct AFLabPreview: UIViewRepresentable {
    let lab: AFTrackingLab
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = lab.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        lab.attach(previewLayer: view.previewLayer)
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== lab.session { uiView.previewLayer.session = lab.session }
    }
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

@MainActor
final class AFTrackingLab: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published private(set) var trackingBox: CGRect?
    @Published private(set) var focusIndicator: CGPoint?
    @Published private(set) var lost = false
    @Published private(set) var reacquiring = false
    @Published private(set) var status = "准备中"
    @Published private(set) var detail = ""
    @Published private(set) var systemDetail = "系统 AF: 未检测"
    @Published private(set) var recoveryDebug = ""
    @Published private(set) var error: String?

    private let sessionQueue = DispatchQueue(label: "af.lab.session")
    private let frameQueue = DispatchQueue(label: "af.lab.frames")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let output = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var systemTracking = false
    private var systemTrackingAvailable = false
    private var systemMetadataSubscribed = false
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var tracker: VisionSubjectTracker?
    private var previewSize: CGSize = .zero
    private var lastTrackTime: TimeInterval = 0
    private var lastFocusTime: TimeInterval = 0
    private var lastFocusCenter = CGPoint(x: -1, y: -1)
    private var lostFocusCentered = false
    private var started = false

    func attach(previewLayer: AVCaptureVideoPreviewLayer) { self.previewLayer = previewLayer }
    func updatePreviewSize(_ size: CGSize) { previewSize = size }

    func start() {
        guard !started else { return }
        started = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.inputPriority) { self.session.sessionPreset = .inputPriority }
                let discovered: (device: AVCaptureDevice, format: AVCaptureDevice.Format)?
                if #available(iOS 27.0, *) {
                    let types: [AVCaptureDevice.DeviceType] = [
                        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                        .builtInWideAngleCamera, .builtInUltraWideCamera,
                        .builtInTelephotoCamera, .builtInTrueDepthCamera
                    ]
                    let sessionDevices = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                                          mediaType: .video,
                                                                          position: .unspecified).devices
                    discovered = sessionDevices.lazy.compactMap { candidate -> (AVCaptureDevice, AVCaptureDevice.Format)? in
                        guard let format = candidate.formats.first(where: { $0.isContinuousAutoFocusTrackingSupported }) else { return nil }
                        return (candidate, format)
                    }.first
                } else {
                    discovered = nil
                }
                let device = discovered?.device
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video)
                guard let device else { throw LabError.unavailable("没有可用后摄") }
                var preferredFormat: AVCaptureDevice.Format?
                if #available(iOS 27.0, *) {
                    let candidates = device.formats.filter { $0.isContinuousAutoFocusTrackingSupported }
                    preferredFormat = discovered?.format ?? candidates.first {
                        let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return dims.width == 1920 && dims.height == 1080
                    } ?? candidates.first
                    if let preferred = preferredFormat {
                        do {
                            try device.lockForConfiguration()
                            device.activeFormat = preferred
                            device.unlockForConfiguration()
                        } catch {}
                    }
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw LabError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(self.output) else { throw LabError.unavailable("无法加入预览输出") }
                self.session.addOutput(self.output)
                // Rotate the data output itself so sample buffers and the
                // preview layer share one portrait coordinate system.
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                if self.session.canAddOutput(self.metadataOutput) {
                    self.session.addOutput(self.metadataOutput)
                    self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.frameQueue)
                }
                self.session.commitConfiguration()
                // A session preset can overwrite activeFormat on commit; reapply
                // the format that actually supports continuous AF tracking.
                if let preferredFormat {
                    do {
                        try device.lockForConfiguration()
                        device.activeFormat = preferredFormat
                        let ranges = preferredFormat.videoSupportedFrameRateRanges
                        if ranges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        }
                        device.unlockForConfiguration()
                    } catch {}
                }
                self.device = device
                self.input = input
                if #available(iOS 27.0, *), device.activeFormat.isContinuousAutoFocusTrackingSupported {
                    do {
                        try device.lockForConfiguration()
                        device.isContinuousAutoFocusTrackingEnabled = true
                        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                        device.unlockForConfiguration()
                        if self.metadataOutput.availableMetadataObjectTypes.contains(.focusTrackedObject) {
                            self.metadataOutput.metadataObjectTypes = [.focusTrackedObject]
                            self.systemMetadataSubscribed = true
                        }
                    } catch {
                        self.systemMetadataSubscribed = false
                    }
                }
                self.session.startRunning()
                if #available(iOS 27.0, *) {
                    let supported = device.activeFormat.isContinuousAutoFocusTrackingSupported
                    let enabled = device.isContinuousAutoFocusTrackingEnabled
                    let acquired = device.isContinuousAutoFocusTrackingSubjectAcquired
                    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    let supportedCount = device.formats.filter { $0.isContinuousAutoFocusTrackingSupported }.count
                    self.systemDetail = "系统AF supported=\(supported) enabled=\(enabled) acquired=\(acquired) format=\(dims.width)x\(dims.height) device=\(device.deviceType.rawValue) formats=\(supportedCount)/\(device.formats.count)"
                }
                self.systemTrackingAvailable = self.systemMetadataSubscribed
                DispatchQueue.main.async {
                    self.status = self.systemTrackingAvailable ? "系统 AF 追踪就绪，长按主体" : "系统 AE/AF 追踪不可用，使用 Vision"
                    self.detail = "focusMode=\(device.focusMode) lens=\(String(format: "%.3f", device.lensPosition))"
                }
            } catch {
                DispatchQueue.main.async { self.status = "启动失败"; self.error = error.localizedDescription }
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        sessionQueue.async {
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
        }
        tracker = nil
    }

    func restart() {
        endTracking()
        status = "重新等待主体"
    }

    func beginTracking(at point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0, let _ = previewLayer else { return }
        tracker = nil
        trackingBox = nil
        lost = false
        reacquiring = false
        lastTrackTime = 0
        lastFocusTime = CACurrentMediaTime()
        lastFocusCenter = point
        lostFocusCentered = false
        focusIndicator = CGPoint(x: point.x / size.width, y: point.y / size.height)
        let side = min(size.width, size.height) * 0.35
        let rect = CGRect(x: point.x / size.width, y: point.y / size.height, width: 0, height: 0)
        let seed = CGRect(x: min(max(rect.midX - side / size.width / 2, 0), 1),
                           y: min(max(rect.midY - side / size.height / 2, 0), 1),
                           width: side / size.width, height: side / size.height)
        // In the lab, test the exact user rectangle without saliency/mask rewriting it.
        if systemTrackingAvailable, let device, let layer = previewLayer {
            systemTracking = true
            tracker = nil
            trackingBox = seed
            status = "系统 AF 锁定中"
            let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    if #available(iOS 27.0, *) { device.isContinuousAutoFocusTrackingEnabled = true }
                    if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    device.unlockForConfiguration()
                    if #available(iOS 27.0, *), device.activeFormat.isContinuousAutoFocusTrackingSupported,
                       self.metadataOutput.availableMetadataObjectTypes.contains(.focusTrackedObject) {
                        self.metadataOutput.metadataObjectTypes = [.focusTrackedObject]
                        self.systemMetadataSubscribed = true
                    }
                } catch {}
            }
            return
        }
        systemTracking = false
        tracker = VisionSubjectTracker()
        tracker?.start(box: seed)
        trackingBox = seed
        status = "正在锁定主体"
        if let device, let layer = previewLayer {
            let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    device.unlockForConfiguration()
                } catch {}
            }
        }
    }

    func endTracking() {
        if #available(iOS 27.0, *), systemTracking, let device {
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    device.isContinuousAutoFocusTrackingEnabled = false
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    device.unlockForConfiguration()
                    self.metadataOutput.metadataObjectTypes = []
                } catch {}
            }
        }
        systemTracking = false
        tracker = nil
        trackingBox = nil
        focusIndicator = nil
        lost = false
        reacquiring = false
        status = "长按主体开始追踪"
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.processFrame(pixel)
        }
    }

    @MainActor
    private func processFrame(_ pixel: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastTrackTime >= 1.0 / 30.0 else { return }
        let portrait = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 320 / max(portrait.extent.width, portrait.extent.height))
        let small = portrait.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent),
              let tracker else { return }
        lastTrackTime = now
        tracker.process(cg) { [weak self] box, phase, debug in
            Task { @MainActor [weak self] in
                guard let self, self.tracker != nil else { return }
                if phase == .tracking, let box {
                    self.trackingBox = box
                    self.lost = false
                    self.reacquiring = false
                    self.lostFocusCentered = false
                    self.status = "主体已锁定"
                    let focusTime = CACurrentMediaTime()
                    let boxCenter = CGPoint(x: box.midX * self.previewSize.width,
                                            y: box.midY * self.previewSize.height)
                    let moved = hypot(boxCenter.x - self.lastFocusCenter.x,
                                      boxCenter.y - self.lastFocusCenter.y) > min(self.previewSize.width, self.previewSize.height) * 0.015
                    if moved, focusTime - self.lastFocusTime >= 0.10,
                       let layer = self.previewLayer,
                       self.previewSize.width > 0, self.previewSize.height > 0 {
                        self.lastFocusTime = focusTime
                        let previousCenter = self.lastFocusCenter
                        self.lastFocusCenter = CGPoint(
                            x: previousCenter.x + (boxCenter.x - previousCenter.x) * 0.75,
                            y: previousCenter.y + (boxCenter.y - previousCenter.y) * 0.75)
                        self.focusIndicator = CGPoint(x: self.lastFocusCenter.x / self.previewSize.width,
                                                      y: self.lastFocusCenter.y / self.previewSize.height)
                        let layerPoint = self.lastFocusCenter
                        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
                        self.sessionQueue.async {
                            guard let device = self.device else { return }
                            do {
                                try device.lockForConfiguration()
                                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                                device.unlockForConfiguration()
                            } catch {}
                        }
                    }
                } else {
                    self.lost = phase == .lost
                    self.reacquiring = phase == .reacquiring
                    self.status = phase == .reacquiring ? "正在重新寻找主体" : "跟踪丢失"
                    if !self.lostFocusCentered {
                        self.lostFocusCentered = true
                        self.focusIndicator = CGPoint(x: 0.5, y: 0.5)
                        self.lastFocusCenter = CGPoint(x: self.previewSize.width / 2,
                                                       y: self.previewSize.height / 2)
                        if let layer = self.previewLayer {
                            let center = layer.captureDevicePointConverted(
                                fromLayerPoint: CGPoint(x: self.previewSize.width / 2,
                                                        y: self.previewSize.height / 2))
                            self.sessionQueue.async {
                                guard let device = self.device else { return }
                                do {
                                    try device.lockForConfiguration()
                                    if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
                                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                                    device.unlockForConfiguration()
                                } catch {}
                            }
                        }
                    }
                }
                self.detail = "system=\(self.systemTrackingAvailable) phase=\(phase == .tracking ? "tracking" : phase == .reacquiring ? "reacquiring" : "lost") box=\(String(format: "%.3f,%.3f", self.trackingBox?.midX ?? -1, self.trackingBox?.midY ?? -1))"
                self.recoveryDebug = "candidates=\(debug.candidateCount) matched=\(debug.identityMatched) count=\(debug.matches) elapsed=\(String(format: "%.1f", debug.elapsed))s"
            }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let box = metadataObjects.first?.bounds
        Task { @MainActor [weak self] in
            guard let self, self.systemTracking else { return }
            if let box {
                self.trackingBox = box
                self.lost = false
                self.status = "系统 AF 锁定"
                var acquired = false
                if #available(iOS 27.0, *), let device = self.device {
                    acquired = device.isContinuousAutoFocusTrackingSubjectAcquired
                }
                self.systemDetail = "系统AF acquired=\(acquired) box=\(String(format: "%.3f,%.3f", box.midX, box.midY))"
            } else {
                self.lost = true
                self.status = "系统 AF 丢失"
            }
        }
    }

    private enum LabError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(s) = self { return s }; return nil }
    }
}
