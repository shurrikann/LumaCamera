enum IndependentNightProfile: String, CaseIterable, Identifiable {
    case standard, balanced, denoise, highlight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "标准 3 帧"
        case .balanced: "均衡 4 帧"
        case .denoise: "降噪 5 帧"
        case .highlight: "高光保护 5 帧"
        }
    }
    var detail: String {
        switch self {
        case .standard: "3 帧正常曝光；速度快，降噪和高光保护最少。"
        case .balanced: "3 帧正常曝光 + 1 帧 -1EV；兼顾降噪与高光。"
        case .denoise: "5 帧正常曝光；噪点最低，高光仍可能溢出。"
        case .highlight: "3 帧正常曝光 + -1EV、-2EV 各一帧；高光保护最好，短帧噪点更高。"
        }
    }
    var exposureOffsets: [Double] {
        switch self {
        case .standard: [0, 0, 0]
        case .balanced: [0, 0, 0, -1]
        case .denoise: [0, 0, 0, 0, 0]
        case .highlight: [0, 0, 0, -1, -2]
        }
    }
}

import AVFoundation
import ImageIO
import Foundation

/// 夜景独立采集会话。只在夜景快门期间启动，避免与普通照片输出共用格式和尺寸。
/// 该会话不负责预览；调用方必须先暂停普通会话，采集结束后再恢复。
final class IndependentNightCapture: NSObject {
    struct Result {
        let frames: [Data]
        let dimensions: CMVideoDimensions
    }

    enum Failure: LocalizedError {
        case noDevice
        case cannotAddInput
        case cannotAddOutput
        case unsupportedFormat
        case startFailed
        case noFrames
        case cancelled
        case exposureMismatch(String)

        var errorDescription: String? {
            switch self {
            case .noDevice: return "夜景独立采集没有可用镜头。"
            case .cannotAddInput: return "夜景独立采集无法连接镜头。"
            case .cannotAddOutput: return "夜景独立采集无法创建照片输出。"
            case .unsupportedFormat: return "夜景独立采集没有可用的 48MP 格式。"
            case .startFailed: return "夜景独立采集启动失败。"
            case .noFrames: return "夜景独立采集没有收到曝光帧。"
            case .cancelled: return "夜景独立采集已取消。"
            case .exposureMismatch(let detail): return "夜景帧曝光与计划不一致：\(detail)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.independentNight.preview", qos: .userInitiated)
    var onPreviewFrame: ((CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "camera.independentNight", qos: .userInitiated)
    private var completion: ((Swift.Result<Result, Error>) -> Void)?
    private var frames: [Data] = []
    private var expectedFrames = 0
    private var exposureOffsets: [Double] = []
    private var profile = IndependentNightProfile.balanced
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var capturedDimensions = CMVideoDimensions(width: 0, height: 0)
    private var remainingFrames = 0
    private var exposureSeconds: Double = 0.125
    private var iso: Float = 400
    private var largestDimensions = CMVideoDimensions(width: 0, height: 0)
    private var awaitingPreview = false
    private var captureStarted = false
    private var highResolutionPrepared = false
    private var focusPrepared = false
    private var finished = false
    private var pendingExpectedExposure: (seconds: Double, iso: Double)?

    func capture(device: AVCaptureDevice, exposureSeconds: Double, iso: Float,
                 rotationAngle: CGFloat? = nil,
                 profile: IndependentNightProfile = .balanced,
                 completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async {
            guard !self.session.isRunning else {
                completion(.failure(Failure.startFailed)); return
            }
            // 主会话 stopRunning 后硬件格式释放不是同步完成的；用短轮询等目标格式可用，
            // 不再固定睡 1 秒拖慢每次夜景。
            Thread.sleep(forTimeInterval: 0.20)
            self.completion = completion
            self.frames = []
            self.expectedFrames = 0
            self.finished = false
            do {
                let candidates = device.formats.filter { fmt in
                    fmt.supportedMaxPhotoDimensions.contains { Int64($0.width) * Int64($0.height) >= 40_000_000 }
                }
                guard let format = candidates.max(by: { a, b in
                    if a.isHighestPhotoQualitySupported != b.isHighestPhotoQualitySupported {
                        return !a.isHighestPhotoQualitySupported
                    }
                    let da = a.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                    let db = b.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                    return da < db
                }) else { throw Failure.unsupportedFormat }
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                try device.lockForConfiguration()
                if device.activeFormat != format { device.activeFormat = format }
                device.videoZoomFactor = 1
                // 继续主会话的可见对焦位置，避免新会话以错误焦距拍出整片模糊；
                // 不重新自动对焦，暗光下 AF 搜索只会拖慢并可能失焦。
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
                }
                device.unlockForConfiguration()
                guard device.activeFormat == format else { throw Failure.unsupportedFormat }
                guard let largest = format.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) else { throw Failure.unsupportedFormat }
                self.dimensions = largest
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw Failure.cannotAddInput }
                self.session.addInput(input)
                guard self.session.canAddOutput(self.output) else { throw Failure.cannotAddOutput }
                self.session.addOutput(self.output)
                guard self.session.canAddOutput(self.videoOutput) else { throw Failure.cannotAddOutput }
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.session.addOutput(self.videoOutput)
                self.output.maxPhotoQualityPrioritization = .quality
                if self.output.isAppleProRAWSupported { self.output.isAppleProRAWEnabled = true }
                if self.output.isResponsiveCaptureSupported { self.output.isResponsiveCaptureEnabled = false }
                self.output.maxPhotoDimensions = largest
                if let rotationAngle {
                    for target in [self.output as AVCaptureOutput, self.videoOutput as AVCaptureOutput] {
                        if let connection = target.connection(with: .video),
                           connection.isVideoRotationAngleSupported(rotationAngle) {
                            connection.videoRotationAngle = rotationAngle
                        }
                    }
                }
                self.profile = profile
                self.exposureOffsets = profile.exposureOffsets
                self.expectedFrames = profile.exposureOffsets.count
                self.remainingFrames = profile.exposureOffsets.count
                self.exposureSeconds = exposureSeconds
                self.iso = iso
                self.largestDimensions = largest
                self.session.commitConfiguration()
                self.awaitingPreview = true
                self.captureStarted = false
                self.highResolutionPrepared = false
                self.focusPrepared = false
                self.session.startRunning()
                guard self.session.isRunning else { throw Failure.startFailed }
                if let rotationAngle {
                    for target in [self.output as AVCaptureOutput, self.videoOutput as AVCaptureOutput] {
                        if let connection = target.connection(with: .video),
                           connection.isVideoRotationAngleSupported(rotationAngle) {
                            connection.videoRotationAngle = rotationAngle
                        }
                    }
                }
                // 普通 48MP 路径在会话运行中预分配高像素照片管线；独立会话同样处理。
                let prepared = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                prepared.maxPhotoDimensions = largest
                prepared.photoQualityPrioritization = .speed
                self.output.setPreparedPhotoSettingsArray([prepared]) { [weak self] _, _ in
                    guard let self else { return }
                    self.queue.async {
                        self.highResolutionPrepared = true
                        self.beginCaptureIfPreviewReady()
                    }
                }
                // 预览优先：首帧视频到达后再发照片请求；超时则无预览也继续，避免卡死。
                self.queue.asyncAfter(deadline: .now() + 1.2) {
                    self.highResolutionPrepared = true
                    self.beginCaptureIfPreviewReady()
                }
            } catch {
                self.session.stopRunning()
                self.finish(.failure(error))
            }
        }
    }

    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.session.stopRunning()
            self.finish(.failure(Failure.cancelled))
        }
    }

    private func beginCaptureIfPreviewReady() {
        guard !captureStarted, highResolutionPrepared else { return }
        if !focusPrepared {
            focusPrepared = true
            prepareFocusThenCapture()
            return
        }
        awaitingPreview = false
        captureStarted = true
        captureNextFrame()
    }

    /// 整组多帧只做一次自动对焦，随后锁定镜头位置；每帧重新 AF 会改变焦距，
    /// 让配准器把真实细节当成运动而糊掉。
    private func prepareFocusThenCapture() {
        guard let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else {
            beginCaptureIfPreviewReady(); return
        }
        let point = device.focusPointOfInterest
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.autoFocus) {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                device.focusMode = .autoFocus
            }
            device.unlockForConfiguration()
        } catch {
            beginCaptureIfPreviewReady(); return
        }
        let deadline = CACurrentMediaTime() + 0.9
        while device.isAdjustingFocus, CACurrentMediaTime() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
            }
            device.unlockForConfiguration()
        } catch {}
        #if DEBUG
        print("INDEPENDENT-NIGHT-FOCUS lens=\(String(format: "%.3f", device.lensPosition)) stable=\(!device.isAdjustingFocus)")
        #endif
        queue.async { self.beginCaptureIfPreviewReady() }
    }

    private func captureNextFrame() {
        guard remainingFrames > 0, !finished else { return }
        remainingFrames -= 1
        guard let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else {
            finish(.failure(Failure.noDevice)); return
        }
        // 不增加曝光补偿：多帧参考曝光用于降噪，最后一帧 -1EV 专保高光。
        // 参考帧保持在中间，避免融合把相位/色调基准落到欠曝帧。
        let frameIndex = max(0, expectedFrames - remainingFrames - 1)
        let offsetEV = exposureOffsets.indices.contains(frameIndex) ? exposureOffsets[frameIndex] : 0
        let maximumSeconds = min(device.activeFormat.maxExposureDuration.seconds,
                                 NightAdaptiveCapturePolicy.handheldMaximumExposureSeconds)
        let seconds = max(device.activeFormat.minExposureDuration.seconds,
                          min(maximumSeconds, exposureSeconds * pow(2, offsetEV)))
        let value = max(device.activeFormat.minISO, min(device.activeFormat.maxISO, iso))
        let codec: AVVideoCodecType = output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.maxPhotoDimensions = largestDimensions
        #if DEBUG
        print("INDEPENDENT-NIGHT-FRAME profile=\(profile.rawValue) index=\(frameIndex) offsetEV=\(offsetEV) seconds=\(seconds) iso=\(value) codec=\(codec.rawValue)")
        #endif
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        pendingExpectedExposure = (seconds, Double(value))
        do {
            try device.lockForConfiguration()
            // 必须等传感器接受本帧快门/ISO后再提交，否则照片可能沿用上一帧曝光。
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                         iso: value) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard !self.finished else { return }
                    let appliedSeconds = device.exposureDuration.seconds
                    let appliedISO = Double(device.iso)
                    guard abs(appliedSeconds - seconds) <= max(0.001, seconds * 0.02),
                          abs(appliedISO - Double(value)) <= max(1, Double(value) * 0.02) else {
                        self.finish(.failure(Failure.exposureMismatch(
                            "计划 \(seconds)s/ISO\(value)，设备 \(appliedSeconds)s/ISO\(appliedISO)")))
                        return
                    }
                    self.output.capturePhoto(with: settings, delegate: self)
                }
            }
            device.unlockForConfiguration()
        } catch {
            finish(.failure(error)); return
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !finished else { return }
        finished = true
        session.stopRunning()
        let callback = completion
        completion = nil
        let frames = self.frames
        self.frames = []
        switch result {
        case .success:
            callback?(.success(Result(frames: frames, dimensions: capturedDimensions.width > 0 ? capturedDimensions : dimensions)))
        case .failure(let error):
            callback?(.failure(error))
        }
    }
}

extension IndependentNightCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        onPreviewFrame?(sampleBuffer)
        if awaitingPreview {
            queue.async { self.beginCaptureIfPreviewReady() }
        }
    }
}

extension IndependentNightCapture: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            guard !self.finished else { return }
            if let error {
                self.finish(.failure(error)); return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.finish(.failure(Failure.noFrames)); return
            }
            self.frames.append(data)
            if let expected = self.pendingExpectedExposure,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
                let actualSeconds = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
                let actualISO = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
                if let actualSeconds, let actualISO {
                    let secondsOK = abs(actualSeconds - expected.seconds) <= max(0.002, expected.seconds * 0.15)
                    let isoOK = abs(actualISO - expected.iso) <= max(1, expected.iso * 0.15)
                    if !secondsOK || !isoOK {
                        self.finish(.failure(Failure.exposureMismatch(
                            "文件 \(actualSeconds)s/ISO\(actualISO)，计划 \(expected.seconds)s/ISO\(expected.iso)")))
                        return
                    }
                }
            }
            self.pendingExpectedExposure = nil
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let width = props[kCGImagePropertyPixelWidth as String] as? Int,
               let height = props[kCGImagePropertyPixelHeight as String] as? Int {
                self.capturedDimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
            }
            if self.frames.count >= self.expectedFrames {
                self.finish(.success(Result(frames: self.frames, dimensions: self.capturedDimensions)))
            } else {
                self.captureNextFrame()
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        queue.async {
            guard !self.finished else { return }
            if let error { self.finish(.failure(error)) }
        }
    }
}
