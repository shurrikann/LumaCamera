import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum LongExposureBlend: String, CaseIterable, Identifiable {
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
final class LongExposureLab: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedCount = 0
    @Published private(set) var result: UIImage?
    @Published private(set) var error: String?
    @Published private(set) var isCapturing = false
    @Published private(set) var timingText = ""
    @Published private(set) var exposureText = ""
    @Published private(set) var colorSpaceText = ""
    @Published private(set) var formatReport = ""
    @Published private(set) var actualBufferSize = ""
    @Published private(set) var isSaving = false
    @Published private(set) var savedInfo = ""
    @Published var blend: LongExposureBlend = .lighten
    @Published var durationSeconds = 30
    let durationOptions = [2, 5, 10, 15, 30, 60, 120, 180, 300]
    var targetFrames: Int { durationSeconds }
    @Published var prefer12MP = true

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.long-exposure.session")
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
    private nonisolated(unsafe) static let frameContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    private var device: AVCaptureDevice?
    private var accumulator: CIImage?
    private var accumulatorBuffer: CVPixelBuffer?
    private var fusionExtent: CGRect = .zero
    private var frameTimes: [TimeInterval] = []
    private var framePTS: [Double] = []
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
                if self.session.canSetSessionPreset(.inputPriority) {
                    self.session.sessionPreset = .inputPriority
                }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video) else {
                    throw LabError.unavailable("没有可用后摄")
                }
                let prefer12MP = self.prefer12MP
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
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw LabError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
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
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                self.session.commitConfiguration()
                self.device = device
                self.session.startRunning()
                DispatchQueue.main.async {
                    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    self.formatReport = "12MP候选=\(all.count) 4K候选=\(fourK.count) active=\(dims.width)x\(dims.height)"
                    self.status = "\(dims.width)×\(dims.height) 采集 · 增量累加"
                    self.actualBufferSize = "等待首帧实际尺寸"
                    self.error = nil
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func begin() {
        guard !isCapturing, let device else { return }
        isCapturing = true
        result = nil
        capturedCount = 0
        accumulator = nil
        accumulatorBuffer = nil
        fusionExtent = .zero
        frameTimes = []
        framePTS = []
        timingText = ""
        exposureText = ""
        colorSpaceText = ""
        let target = targetFrames
        status = "正在长曝光 0/\(targetFrames)"
        error = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 0.999
                }) else { throw LabError.unavailable("该格式不支持 1fps") }
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 1)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 1)
                let iso = device.activeFormat.minISO
                device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 1), iso: iso)
                // Stars are at optical infinity; continuous AF would hunt on a
                // dark, low-contrast sky and leave every frame defocused.
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: 1.0)
                }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                self.capturing = true
                self.acceptedAt = CACurrentMediaTime() + 0.25
                DispatchQueue.main.async { self.status = "正在长曝光 0/\(target)" }
            } catch {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.status = "准备"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        capturing = false
        isCapturing = false
        accumulator = nil
        accumulatorBuffer = nil
        result = nil
        capturedCount = 0
        status = "已取消"
        restoreAfterCapture()
    }

    func reset() {
        accumulator = nil
        accumulatorBuffer = nil
        fusionExtent = .zero
        result = nil
        capturedCount = 0
        timingText = ""
        status = "4K 采集 · 4K 增量累加"
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                  didOutput sampleBuffer: CMSampleBuffer,
                                  from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        // Copy the capture buffer immediately; holding cvPixelBuffer across
        // frames exhausts the video output pool.
        guard let cgImage = Self.frameContext.createCGImage(image, from: extent) else { return }
        let owned = CIImage(cgImage: cgImage)
        let now = CACurrentMediaTime()
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let colorSpace = (cgImage.colorSpace?.name as String?) ?? "nil"
        Task { @MainActor [weak self] in
            guard let self, self.capturing else { return }
            guard now >= self.acceptedAt else { return }
            self.actualBufferSize = "实际buffer=\(bufferWidth)x\(bufferHeight)"
            self.fuse(owned, at: now)
            self.frameTimes.append(now)
            self.framePTS.append(pts)
            if self.colorSpaceText.isEmpty { self.colorSpaceText = "CGImage: \(colorSpace)" }
            if let device = self.device {
                let actualExposure = CMTimeGetSeconds(device.exposureDuration)
                self.exposureText = String(format: "曝光 %.3fs · ISO %.0f", actualExposure, device.iso)
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
        let normalized = frame
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: fusionExtent)
        let count = capturedCount + 1
        let combined: CIImage
        if let accumulator {
            switch blend {
            case .lighten:
                combined = normalized.applyingFilter("CILightenBlendMode", parameters: [
                    kCIInputBackgroundImageKey: accumulator
                ])
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
        guard capturing, let accumulator else { return }
        capturing = false
        isCapturing = false
        status = "正在输出 4K"
        let extent = fusionExtent
        guard let cgImage = context.createCGImage(accumulator, from: extent) else {
            status = "合成失败"
            restoreAfterCapture()
            return
        }
        result = UIImage(cgImage: cgImage)
        if let first = framePTS.first, let last = framePTS.last, framePTS.count > 1 {
            let intervals = zip(framePTS.dropFirst(), framePTS).map { $0 - $1 }
            let average = intervals.reduce(0, +) / Double(intervals.count)
            timingText = String(format: "%d 帧 · PTS %.1fs · 间隔 %.3fs / 最大 %.3fs",
                                framePTS.count, last - first, average, intervals.max() ?? 0)
        } else {
            timingText = "\(framePTS.count) 帧"
        }
        status = "\(durationSeconds) 秒长曝光完成"
        restoreAfterCapture()
    }

    func saveResult() {
        guard let result, let cgImage = result.cgImage, !isSaving else { return }
        isSaving = true
        savedInfo = ""
        let width = cgImage.width, height = cgImage.height
        DispatchQueue.global(qos: .userInitiated).async {
            let data = NSMutableData()
            let type = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) != nil
                ? UTType.heic.identifier as CFString
                : UTType.jpeg.identifier as CFString
            guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
                DispatchQueue.main.async { self.isSaving = false; self.savedInfo = "编码失败" }
                return
            }
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: 1,
                kCGImagePropertyPixelWidth: width,
                kCGImagePropertyPixelHeight: height,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "Luma 12MP 1fps x 1s multi-frame long exposure"
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                DispatchQueue.main.async { self.isSaving = false; self.savedInfo = "编码失败" }
                return
            }
            let encoded = data as Data
            // DEBUG-ONLY: keep a retrievable copy so the real encoded file can
            // be pulled from the app container and inspected.
            let diagnostic = FileManager.default.temporaryDirectory
                .appendingPathComponent(type == UTType.heic.identifier as CFString ? "Luma-LastLongExposure.heic" : "Luma-LastLongExposure.jpg")
            try? encoded.write(to: diagnostic, options: .atomic)
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: encoded, options: nil)
            }) { success, error in
                DispatchQueue.main.async {
                    self.isSaving = false
                    if success {
                        let size = ByteCountFormatter.string(fromByteCount: Int64(encoded.count), countStyle: .file)
                        self.savedInfo = "已保存 \(width)x\(height) · \(size)"
                    } else {
                        self.savedInfo = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
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
        restoreAfterCapture()
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

struct LongExposureLabView: View {
    @StateObject private var lab = LongExposureLab()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                ZStack {
                    LongExposurePreview(session: lab.session)
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
                                ForEach(LongExposureBlend.allCases) { mode in
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

private struct LongExposurePreview: UIViewRepresentable {
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
