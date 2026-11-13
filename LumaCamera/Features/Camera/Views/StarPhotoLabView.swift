import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum StarPhotoLabError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

enum StarPhotoExposure: String, CaseIterable, Identifiable {
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
final class StarPhotoLab: NSObject, ObservableObject {
    @Published private(set) var status = "准备"
    @Published private(set) var capturedFrames = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var isSaving = false
    @Published private(set) var result: UIImage?
    @Published private(set) var info = ""
    @Published private(set) var luminanceText = ""
    @Published private(set) var lastFile = ""
    @Published private(set) var error: String?
    @Published var frameCount = 10
    @Published var exposure: StarPhotoExposure = .s1
    let frameOptions = [10, 30, 60]

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.star-photo-raw.session")
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    private var device: AVCaptureDevice?
    private var accumulator: CIImage?
    private var accumulatorBuffer: CVPixelBuffer?
    private var fusionExtent: CGRect = .zero
    private var capturing = false
    private var started = false
    private var framePTS: [Double] = []
    private var rawDelegates: [UUID: RawCaptureDelegate] = [:]

    func start() {
        guard !started else { return }
        started = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video) else {
                    throw StarPhotoLabError.unavailable("没有可用后摄")
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw StarPhotoLabError.unavailable("无法加入相机输入") }
                self.session.addInput(input)
                guard self.session.canAddOutput(self.photoOutput) else { throw StarPhotoLabError.unavailable("无法加入照片输出") }
                self.session.addOutput(self.photoOutput)
                if let twelve = device.activeFormat.supportedMaxPhotoDimensions.first(where: {
                    $0.width == 4032 && $0.height == 3024
                }) {
                    self.photoOutput.maxPhotoDimensions = twelve
                }
                self.session.commitConfiguration()
                self.device = device
                self.session.startRunning()
                DispatchQueue.main.async {
                    let hasRAW = !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
                    self.status = hasRAW ? "12MP RAW 星空照片测试" : "当前相机没有可用 RAW 格式"
                    if !hasRAW { self.error = "当前相机没有 Bayer RAW 格式" }
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func begin() {
        guard !isCapturing, let device else { return }
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            error = "当前相机没有可用 RAW 格式"
            return
        }
        isCapturing = true
        result = nil
        capturedFrames = 0
        accumulator = nil
        accumulatorBuffer = nil
        fusionExtent = .zero
        framePTS = []
        info = ""
        error = nil
        status = "正在拍摄 RAW 星空照片 0/\(frameCount)"
        let target = frameCount
        let exposureSeconds = exposure.seconds
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                let duration = CMTime(seconds: exposureSeconds, preferredTimescale: 1_000_000)
                device.setExposureModeCustom(duration: duration, iso: min(max(1600, device.activeFormat.minISO), device.activeFormat.maxISO))
                if device.isFocusModeSupported(.locked) { device.setFocusModeLocked(lensPosition: 1.0) }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                self.capturing = true
                DispatchQueue.main.async {
                    self.status = "正在拍摄 RAW 星空照片 0/\(target)"
                    self.acceptedAt = CACurrentMediaTime()
                    self.captureNext(rawType: rawType)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.status = "准备"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private var acceptedAt: CFTimeInterval = 0

    private func captureNext(rawType: OSType) {
        guard capturing else { return }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        settings.flashMode = .off
        settings.photoQualityPrioritization = .speed
        let token = UUID()
        let delegate = RawCaptureDelegate { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rawDelegates.removeValue(forKey: token)
                guard self.capturing else { return }
                switch result {
                case .success(let data):
                    guard let image = CIImage(data: data) else {
                        self.fail("DNG 解码失败")
                        return
                    }
                    guard self.fuse(image) else {
                        self.fail("RAW 累积失败")
                        return
                    }
                    self.framePTS.append(CACurrentMediaTime())
                    self.capturedFrames += 1
                    self.status = "正在拍摄 RAW 星空照片 \(self.capturedFrames)/\(self.frameCount)"
                    if self.capturedFrames >= self.frameCount {
                        self.finish()
                    } else {
                        // Let the photo pipeline settle between RAW captures.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(60))
                            guard let self, self.capturing else { return }
                            self.captureNext(rawType: rawType)
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
        capturing = false
        isCapturing = false
        error = message
        status = "拍摄失败"
        restoreAfterCapture()
    }

    func cancel() {
        capturing = false
        isCapturing = false
        rawDelegates.removeAll()
        accumulator = nil
        accumulatorBuffer = nil
        result = nil
        capturedFrames = 0
        status = "已取消"
        restoreAfterCapture()
    }

    func reset() {
        result = nil
        capturedFrames = 0
        info = ""
        status = "12MP RAW 星空照片测试"
    }

    private func fuse(_ frame: CIImage) -> Bool {
        let extent = frame.extent.integral
        if fusionExtent == .zero { fusionExtent = CGRect(origin: .zero, size: extent.size) }
        let normalized = frame.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: fusionExtent)
        let count = capturedFrames + 1
        let combined: CIImage
        if let accumulator {
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
            combined = current.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: previous])
        } else { combined = normalized }
        guard let next = materialize(combined) else { return false }
        accumulator = next.image
        accumulatorBuffer = next.buffer
        return true
    }

    private func materialize(_ image: CIImage) -> (image: CIImage, buffer: CVPixelBuffer)? {
        let width = Int(fusionExtent.width.rounded()), height = Int(fusionExtent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: linearSpace)
        return (CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearSpace]), buffer)
    }

    private func finish() {
        guard capturing, let accumulator else { return }
        capturing = false
        isCapturing = false
        status = "正在合成 RAW 堆栈"
        guard let cg = context.createCGImage(accumulator, from: fusionExtent) else {
            fail("合成失败"); return
        }
        result = UIImage(cgImage: cg)
        if let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: accumulator,
            kCIInputExtentKey: CIVector(cgRect: fusionExtent)
        ])?.outputImage {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let luma = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
            luminanceText = String(format: "平均亮度 %.1f%% · RAW堆栈", luma * 100)
        }
        let duration = (framePTS.last ?? 0) - (framePTS.first ?? 0)
        info = "\(cg.width)x\(cg.height) · \(frameCount) 帧 RAW · 实际 \(String(format: "%.1f", duration))s"
        status = "RAW 星空照片完成"
        restoreAfterCapture()
    }

    func save() {
        guard let result, let cgImage = result.cgImage, !isSaving else { return }
        isSaving = true
        info = ""
        let width = cgImage.width, height = cgImage.height
        DispatchQueue.global(qos: .userInitiated).async {
            let data = NSMutableData()
            let type = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) != nil
                ? UTType.heic.identifier as CFString
                : UTType.jpeg.identifier as CFString
            guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
                DispatchQueue.main.async { self.isSaving = false; self.info = "编码失败" }
                return
            }
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: 1,
                kCGImagePropertyPixelWidth: width,
                kCGImagePropertyPixelHeight: height,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "Luma 12MP RAW star photo stack"
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                DispatchQueue.main.async { self.isSaving = false; self.info = "编码失败" }
                return
            }
            let encoded = data as Data
            let diagnostic = FileManager.default.temporaryDirectory
                .appendingPathComponent("Luma-StarPhoto-RAW.heic")
            try? encoded.write(to: diagnostic, options: .atomic)
            DispatchQueue.main.async { self.lastFile = diagnostic.lastPathComponent }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Luma-StarPhoto-\(width)x\(height).heic"
                request.addResource(with: .photo, data: encoded, options: options)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.isSaving = false
                    if success {
                        let size = ByteCountFormatter.string(fromByteCount: Int64(encoded.count), countStyle: .file)
                        self.info = "已保存 \(width)x\(height) · \(size)"
                    } else {
                        self.info = "保存失败：\(error?.localizedDescription ?? "未知")"
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
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func stop() {
        capturing = false
        rawDelegates.removeAll()
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

private final class RawCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<Data, Error>) -> Void
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(StarPhotoLabError.unavailable("RAW 文件为空"))); return
        }
        completion(.success(data))
    }
}

struct StarPhotoLabView: View {
    @StateObject private var lab = StarPhotoLab()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StarPhotoRAWPreview(session: lab.session).ignoresSafeArea()
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
                        ForEach(StarPhotoExposure.allCases) { value in Text(value.rawValue + "s").tag(value) }
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

private struct StarPhotoRAWPreview: UIViewRepresentable {
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
