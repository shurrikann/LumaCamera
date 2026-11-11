import SwiftUI
import AVFoundation
import Photos
import UIKit

/// Independent Cinematic camera built directly from Apple's sample order.
/// It deliberately shares no session, output graph, or writer with CameraEngine.
struct StandaloneCinematicView: View {
    @StateObject private var camera = StandaloneCinematicCamera()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                StandaloneCinematicPreview(session: camera.session)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topLeading) {
                        Text(camera.status)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        if camera.recording {
                            Circle().fill(.red).frame(width: 9, height: 9)
                                .padding(10)
                        }
                    }

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模拟光圈").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "f/%.1f", camera.aperture))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    Slider(value: Binding(get: { Double(camera.aperture) },
                                          set: { camera.setAperture(Float($0)) }),
                           in: Double(camera.apertureRange.lowerBound)...Double(camera.apertureRange.upperBound))
                        .tint(AppTheme.accent)
                        .disabled(camera.recording)
                }
                .padding(.horizontal, 4)

                Button {
                    camera.toggleRecording()
                } label: {
                    ZStack {
                        Circle().fill(camera.recording ? Color.red : Color.white)
                            .frame(width: 64, height: 64)
                        if camera.recording {
                            RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 20, height: 20)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!camera.ready)
                .opacity(camera.ready ? 1 : 0.45)

                if let error = camera.error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text("独立会话：DualWide + Cinematic format + 预览层 + 独立录制")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("独立电影模式")
        .navigationBarTitleDisplayMode(.inline)
        .task { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private struct StandaloneCinematicPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
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
final class StandaloneCinematicCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var aperture: Float = 2.8
    @Published private(set) var apertureRange: ClosedRange<Float> = 2...16
    @Published private(set) var status = "准备中"
    @Published private(set) var error: String?

    private let queue = DispatchQueue(label: "standalone.cinematic.session")
    private let videoOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var currentURL: URL?
    private var configured = false

    func start() {
        guard !configured else { return }
        status = "配置电影会话…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if #available(iOS 26.0, *) { try self.configure() }
                else { throw LabError.unavailable("需要 iOS 26") }
                DispatchQueue.main.async {
                    self.ready = true
                    self.status = "电影模式已启用"
                    self.error = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.ready = false
                    self.status = "启动失败"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.videoOutput.isRecording { self.videoOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.input = nil
            self.device = nil
            self.configured = false
            DispatchQueue.main.async { self.ready = false; self.recording = false; self.status = "已停止" }
        }
    }

    func setAperture(_ value: Float) {
        let clamped = min(max(value, apertureRange.lowerBound), apertureRange.upperBound)
        aperture = clamped
        queue.async {
            guard #available(iOS 26.0, *), let input = self.input,
                  input.isCinematicVideoCaptureEnabled else { return }
            input.simulatedAperture = clamped
        }
    }


    func toggleRecording() {
        guard ready else { return }
        if videoOutput.isRecording {
            videoOutput.stopRecording()
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaStandaloneCinematic-\(UUID().uuidString).mov")
        currentURL = url
        status = "录制中"
        videoOutput.startRecording(to: url, recordingDelegate: self)
    }

    @available(iOS 26.0, *)
    private func configure() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw LabError.unavailable("相机权限未开启")
        }
        guard let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            throw LabError.unavailable("没有 DualWide 后置相机")
        }
        let formats = device.formats.filter { format in
            format.isCinematicVideoCaptureSupported
                && CMVideoFormatDescriptionGetDimensions(format.formatDescription).width == 1920
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let format = formats.first else { throw LabError.unavailable("没有 1080p30 电影格式") }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard input.isCinematicVideoCaptureSupported else { throw LabError.unavailable("输入不支持电影") }
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw LabError.unavailable("无法加入电影输入") }
        session.addInput(input)
        input.isCinematicVideoCaptureEnabled = true
        let minA = format.minSimulatedAperture, maxA = format.maxSimulatedAperture
        if minA > 0, maxA >= minA {
            input.simulatedAperture = min(max(2.8, minA), maxA)
            aperture = input.simulatedAperture
            apertureRange = minA...maxA
        }
        guard session.canAddOutput(videoOutput) else { throw LabError.unavailable("无法加入电影录制输出") }
        session.addOutput(videoOutput)
        guard session.canAddOutput(metadataOutput) else { throw LabError.unavailable("无法加入电影 metadata 输出") }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
        let required = metadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture
        guard !required.isEmpty,
              required.allSatisfy(metadataOutput.availableMetadataObjectTypes.contains) else {
            throw LabError.unavailable("电影 metadata 类型不可用")
        }
        metadataOutput.metadataObjectTypes = required
        session.commitConfiguration()
        session.startRunning()
        self.device = device
        self.input = input
        self.configured = true
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        guard error == nil else {
            DispatchQueue.main.async { self.recording = false; self.error = error?.localizedDescription; self.status = "录制失败" }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.recording = false; self.status = "已录制到临时目录"; self.error = "未获得相册写入权限" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, error in
                DispatchQueue.main.async {
                    self.recording = false
                    self.status = success ? "已保存到相册" : "保存失败"
                    self.error = error?.localizedDescription
                    try? FileManager.default.removeItem(at: outputFileURL)
                }
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.recording = true }
    }

    private enum LabError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(s) = self { return s }; return nil }
    }
}

extension StandaloneCinematicCamera: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput metadataObjects: [AVMetadataObject],
                                   from connection: AVCaptureConnection) {}
}
