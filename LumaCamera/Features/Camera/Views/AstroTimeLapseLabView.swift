import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AstroLabError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

@MainActor
final class AstroTimeLapseLab: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedFrames = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var savedInfo = ""
    @Published private(set) var error: String?
    @Published var intervalSeconds = 10
    let intervalOptions = [1, 2, 4, 10, 15, 20, 30]

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.astro-timelapse.session")
    private let videoQueue = DispatchQueue(label: "camera.astro-timelapse.video", qos: .userInitiated)
    private let renderContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    private var device: AVCaptureDevice?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var outputIndex = 0
    private var sourceIndex = 0
    private var capturing = false
    private var acceptedAt: CFTimeInterval = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.inputPriority) { self.session.sessionPreset = .inputPriority }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video) else {
                    throw AstroLabError.unavailable("没有可用后摄")
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
                    throw AstroLabError.unavailable("当前相机不支持 1fps / 1 秒曝光")
                }
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw AstroLabError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
                guard self.session.canAddOutput(self.output) else { throw AstroLabError.unavailable("无法加入视频输出") }
                self.session.addOutput(self.output)
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                self.session.commitConfiguration()
                self.device = device
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.status = "对准星空，保持手机稳定"
                    self.error = nil
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func begin() {
        guard !isRecording, !isFinishing, let device else { return }
        isRecording = true
        capturedFrames = 0
        savedInfo = ""
        error = nil
        outputIndex = 0
        sourceIndex = 0
        status = "正在拍摄星空延时"
        let interval = intervalSeconds
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: 1)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                let iso = device.activeFormat.minISO
                device.setExposureModeCustom(duration: duration, iso: iso)
                if device.isFocusModeSupported(.locked) { device.setFocusModeLocked(lensPosition: 1.0) }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                try self.setupWriter()
                self.capturing = true
                self.acceptedAt = CACurrentMediaTime() + 0.25
                DispatchQueue.main.async { self.status = "正在拍摄星空延时 · 间隔 \(interval) 秒" }
            } catch {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func setupWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AstroTimelapse-" + UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 2160,
            AVVideoHeightKey: 3840
        ]
        let h264: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920
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
        guard writer.canAdd(input) else { throw AstroLabError.unavailable("无法创建 HEVC/H.264 视频输入") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AstroLabError.unavailable("无法启动视频写入")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        self.outputURL = url
    }

    func stopAndSave() {
        guard isRecording else { return }
        capturing = false
        isRecording = false
        // A sub-second clip is not useful as a time-lapse. Discard it instead
        // of surfacing a Photos save error or keeping a 0.x s asset.
        guard outputIndex >= 30 else {
            writer?.cancelWriting()
            writer = nil; writerInput = nil; adaptor = nil
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            outputURL = nil
            capturedFrames = 0
            savedInfo = ""
            status = "不足 1 秒，已丢弃"
            isFinishing = false
            restoreAfterCapture()
            return
        }
        isFinishing = true
        status = "正在封装延时视频"
        restoreAfterCapture()
        guard let writer, let input = writerInput, let url = outputURL else {
            isFinishing = false
            status = "没有可用视频"
            return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard writer.status == .completed else {
                    self.isFinishing = false
                    self.status = "视频封装失败"
                    self.error = writer.error?.localizedDescription
                    return
                }
                do {
                    let data = try Data(contentsOf: url)
                    PHPhotoLibrary.shared().performChanges({
                        let request = PHAssetCreationRequest.forAsset()
                        request.creationDate = Date()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = url.lastPathComponent
                        options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                        request.addResource(with: .video, fileURL: url, options: options)
                    }) { success, error in
                        DispatchQueue.main.async {
                            self.isFinishing = false
                            if success {
                                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                                self.savedInfo = "已保存 \(self.capturedFrames) 帧 · \(size)"
                                self.status = "星空延时完成"
                            } else {
                                self.status = "保存失败"
                                self.error = error?.localizedDescription
                            }
                        }
                    }
                } catch {
                    self.isFinishing = false
                    self.status = "读取视频失败"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.capturing else { return }
            let now = CACurrentMediaTime()
            guard now >= self.acceptedAt else { return }
            self.sourceIndex += 1
            let interval = max(1, self.intervalSeconds)
            guard (self.sourceIndex - 1) % interval == 0 else { return }
            guard let adaptor = self.adaptor, let input = self.writerInput, input.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool else { return }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
            guard let out else { return }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = image.extent
            let scale = max(2160 / extent.width, 3840 / extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cropX = max(0, (image.extent.width - 2160) / 2)
            let cropY = max(0, (image.extent.height - 3840) / 2)
            image = image.cropped(to: CGRect(x: image.extent.minX + cropX, y: image.extent.minY + cropY, width: 2160, height: 3840))
            self.renderContext.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: 2160, height: 3840),
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let time = CMTime(value: Int64(self.outputIndex), timescale: 30)
            if adaptor.append(out, withPresentationTime: time) {
                self.outputIndex += 1
                self.capturedFrames = self.outputIndex
                self.status = "正在拍摄星空延时 · \(self.capturedFrames) 帧"
            }
        }
    }

    private func restoreAfterCapture() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func stop() {
        capturing = false
        if isRecording { cancel() }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
        }
    }
}

struct AstroTimeLapseLabView: View {
    @StateObject private var lab = AstroTimeLapseLab()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AstroPreview(session: lab.session).ignoresSafeArea()
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

private struct AstroPreview: UIViewRepresentable {
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
