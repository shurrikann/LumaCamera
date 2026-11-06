import AVFoundation
import CoreImage

/// 按 Apple AVMultiCamPiP 示例显式连接前后输入；两路有界时间差画面在编码前合成，只编码一次。
/// 会话操作由 CameraEngine.session 队列串行调用，帧处理仅在 recordingQueue 执行。
final class DualCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// 默认仍为已开放的1080p30 SDR；测试用同一管线核对其他组合，不据此自动开放界面。
    struct Configuration {
        var settings = VideoCaptureSettings()
        var frontSize = CGSize(width: 1920, height: 1080)
        var frontType = AVCaptureDevice.DeviceType.builtInWideAngleCamera
        var frontZoom: CGFloat = 1
        var frontFrameRate: Int32? = nil
    }
    private let configuration: Configuration
    private var fps: Int32 { Int32(configuration.settings.frameRate.rawValue) }

    enum Failure: LocalizedError {
        case unsupported, connection, budget
        var errorDescription: String? {
            switch self {
            case .unsupported: return "当前设备没有可用的前后同步双拍规格。"
            case .connection: return "无法连接同步双拍镜头，请重试。"
            case .budget: return "当前同步双拍规格超出设备采集预算。"
            }
        }
    }
    let session = AVCaptureMultiCamSession()
    let rear: AVCaptureDevice
    let front: AVCaptureDevice
    private let rearOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let frameQueue: DispatchQueue
    private var latestFrontSample: CMSampleBuffer? // recordingQueue，只保留一张副画面
    private(set) var maximumPairSkew = 0.0
    private struct Original {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let minimum: CMTime
        let maximum: CMTime
        let zoom: CGFloat
        let color: AVCaptureColorSpace
    }
    private var originals: [Original] = []
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace: CGColorSpace
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var frontIsMain = false // recordingQueue
    private(set) var insetRect = DualCaptureInsetLayout.initial // recordingQueue
    private var ratio: FrameRatio
    private(set) var includesAudio = false
    private(set) var frameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var renderDurations: [Double] = []
    #if DEBUG
    let identifierForTesting = UUID()
    #endif
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pressureObservations: [NSKeyValueObservation] = []
    /// 归一化显示坐标，UIKit 原点在左上；此常量只作初始竖幅，预览手势与实际烧录使用实例矩形。
    static let insetRect = DualCaptureInsetLayout.initial
    /// Adjust the currently displayed main camera without changing the inset.
    /// The dual graph keeps both devices connected; only the main zoom changes.
    func setMainZoom(_ factor: CGFloat, front isFront: Bool) {
        // 主画面选择由会话队列明确传入，不跨队列读取合成器的 frontIsMain。
        let device = isFront ? front : rear
        do {
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = clamped
        } catch {}
    }

    var mainZoomRange: ClosedRange<CGFloat> {
        let device = frontIsMain ? front : rear
        return device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
    }

    var outputSize: CGSize {
        let base = configuration.settings.resolution.dimensions
        let width = min(base.width, base.height), height = max(base.width, base.height)
        let aspect = ratio.portraitRatio
        return CGSize(width: max(2, (min(width, height * aspect) / 2).rounded() * 2),
                      height: max(2, (min(height, width / aspect) / 2).rounded() * 2))
    }

    init(frameQueue: DispatchQueue, ratio: FrameRatio, audio: Bool, configuration: Configuration = Configuration()) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              [.sdr, .p3].contains(configuration.settings.colorSpace),
              let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(configuration.frontType, for: .video, position: .front)
                ?? (configuration.frontType == .builtInWideAngleCamera
                    ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) : nil) else { throw Failure.unsupported }
        self.rear = rear; self.front = front; self.frameQueue = frameQueue; self.ratio = ratio
        self.configuration = configuration
        self.colorSpace = CGColorSpace(name: configuration.settings.colorSpace == .p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        super.init()
        // 同一前置传感器可能以广角/超广角别名公开；在修改任一别名前保存当前常规路线。
        // 退出按反序恢复，最后还原应用常用的超广角包装器，避免诊断/双拍污染照片画幅能力。
        let aliases = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front).devices.sorted { $0.deviceType == .builtInUltraWideCamera && $1.deviceType != .builtInUltraWideCamera }
        for alias in aliases where alias.uniqueID != front.uniqueID {
            originals.append(Original(device: alias, format: alias.activeFormat, minimum: alias.activeVideoMinFrameDuration,
                                      maximum: alias.activeVideoMaxFrameDuration, zoom: alias.videoZoomFactor, color: alias.activeColorSpace))
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                if let error {
                    NSLog("Dual capture session runtime error: %@ (%ld): %@ userInfo=%@",
                          error.domain,error.code,error.localizedDescription,String(reflecting:error.userInfo))
                }
                self?.onError?("同步双拍中断：" + (error?.localizedDescription ?? "相机会话发生错误。"))
            })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil) { [weak self] _ in self?.onError?("同步双拍被系统暂时中断，已结束录制。") })
        for device in [rear, front] {
            pressureObservations.append(device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
                if device.systemPressureState.level == .critical || device.systemPressureState.level == .shutdown {
                    self?.onError?("设备相机负载过高，已退出同步双拍。")
                }
            })
        }
        do { try configure(audio: audio) }
        catch { release(); throw error }
    }

    private func configure(audio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for (device, output) in [(rear, rearOutput), (front, frontOutput)] {
            let size = device.position == .back ? configuration.settings.resolution.dimensions : configuration.frontSize
            let captureFPS = device.position == .front ? configuration.frontFrameRate ?? fps : fps
            let rate = Double(captureFPS)
            let captureColor = configuration.settings.colorSpace.captureColorSpace ?? .sRGB
            // 检查所选组合的真实MultiCam能力，不能使用普通单摄格式代替。
            let formats = device.formats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.isMultiCamSupported && d.width == Int32(size.width) && d.height == Int32(size.height)
                    && CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    && $0.supportedColorSpaces.contains(captureColor)
                    && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }
            }.sorted { ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) }
            guard let format = formats.first else { throw Failure.unsupported }
            originals.append(Original(device: device, format: device.activeFormat, minimum: device.activeVideoMinFrameDuration, maximum: device.activeVideoMaxFrameDuration, zoom: device.videoZoomFactor, color: device.activeColorSpace))
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: captureFPS)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: captureFPS)
            device.activeColorSpace = captureColor
            device.videoZoomFactor = device.position == .front
                ? min(max(configuration.frontZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor) : 1
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: captureFPS)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.connection }
            session.addInputWithNoConnections(input); session.addOutputWithNoConnections(output)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw Failure.connection }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw Failure.connection }
            session.addConnection(connection)
            // 新前置传感器原生方向不同，不能假设所有镜头竖屏均旋转90度。
            if #available(iOS 27.0, *) {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                let angle = coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                #if DEBUG
                print("DUAL-ORIENTATION device=\(device.deviceType.rawValue) position=\(device.position.rawValue) portraitAngle=\(angle)")
                #endif
            } else if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        if audio, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio) {
            let input = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(input), session.canAddOutput(audioOutput) {
                session.addInput(input); session.addOutput(audioOutput)
                audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
                includesAudio = true
            }
        }

    }

    func start() throws {
        guard session.hardwareCost <= 1, session.systemPressureCost <= 1 else { throw Failure.budget }
        session.startRunning()
        guard session.isRunning else { throw Failure.connection }
    }
    func stop() {
        if session.isRunning { session.stopRunning() }
        frameQueue.sync { latestFrontSample = nil }
    }
    /// 先停机并拆除连接，再恢复原格式，防止两个相机会话争用相同硬件。
    func release() {
        pressureObservations.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        stop()
        rearOutput.setSampleBufferDelegate(nil, queue: nil)
        frontOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        for original in originals.reversed() {
            let device = original.device, format = original.format
            let minimum = original.minimum, maximum = original.maximum
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = minimum; device.activeVideoMaxFrameDuration = maximum
                device.videoZoomFactor = min(max(original.zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                if format.supportedColorSpaces.contains(original.color) { device.activeColorSpace = original.color }
                device.unlockForConfiguration()
            }
        }
        originals.removeAll()
    }
    func swap() { frontIsMain.toggle() } // recordingQueue
    func setInsetRect(_ rect: CGRect) { insetRect = DualCaptureInsetLayout.clamped(rect) }
    func setRatio(_ value: FrameRatio) {
        guard ratio != value else { return }
        ratio = value; pool = nil; formatDescription = nil
    }
    #if DEBUG
    func compositeForTesting(back: CVPixelBuffer, front: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        composite(back: back, front: front, time: time)
    }
    #endif

    /// 官方示例以主路回调驱动、缓存最近副路帧；两路传感器PTS不一定完全相同。
    /// 本实现额外限制最多相差两帧，避免阻塞/中断时把旧副画面继续烧录。
    private func processRearFrame(_ back: CMSampleBuffer) {
        guard let front = latestFrontSample,
              let backBuffer = CMSampleBufferGetImageBuffer(back),
              let frontBuffer = CMSampleBufferGetImageBuffer(front) else { droppedFrameCount += 1; return }
        let delta = abs((CMSampleBufferGetPresentationTimeStamp(back) - CMSampleBufferGetPresentationTimeStamp(front)).seconds)
        guard delta.isFinite, delta <= 2.0 / Double(min(fps, configuration.frontFrameRate ?? fps)) else { droppedFrameCount += 1; return }
        maximumPairSkew = max(maximumPairSkew, delta)
        autoreleasepool {
            let start = CACurrentMediaTime()
            guard let frame = composite(back: backBuffer, front: frontBuffer,
                                        time: CMSampleBufferGetPresentationTimeStamp(back)) else { droppedFrameCount += 1; return }
            frameCount += 1
            #if DEBUG
            if renderDurations.count < 600 { renderDurations.append(CACurrentMediaTime() - start) }
            #endif
            onVideo?(frame)
        }
    }
    private func composite(back: CVPixelBuffer, front: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        let size = outputSize, bounds = CGRect(origin: .zero, size: size)
        if pool == nil {
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        func fill(_ image: CIImage, in rect: CGRect) -> CIImage {
            let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX,
                                                           y: rect.midY - scaled.extent.midY)).cropped(to: rect)
        }
        let rearImage = CIImage(cvPixelBuffer: back), frontImage = CIImage(cvPixelBuffer: front)
        let main = fill(frontIsMain ? frontImage : rearImage, in: bounds)
        let normalized = insetRect
        let inset = CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
                           width: normalized.width * size.width, height: normalized.height * size.height)
        let small = fill(frontIsMain ? rearImage : frontImage, in: inset)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: inset),
                            "inputRadius": inset.width * 0.075, "inputColor": CIColor.white])!.outputImage!
        let result = small.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: main, kCIInputMaskImageKey: mask])
        context.render(result, to: buffer, bounds: bounds, colorSpace: colorSpace)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        if formatDescription == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription) }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: formatDescription,
                                                sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput { onAudio?(sampleBuffer) }
        else if output === frontOutput { latestFrontSample = sampleBuffer }
        else if output === rearOutput { processRearFrame(sampleBuffer) }
    }
}
