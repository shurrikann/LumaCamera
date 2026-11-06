import AVFoundation
import CoreImage
import UIKit

/// 后置长焦+广角导航。使用独立视频输出，不跨会话迁移系统输出，不把导航烧入主路。
/// 照片拍摄前回到保留的原会话，避免MultiCam改变Live/RAW等真实照片能力。
final class FocusNavigatorGraph: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Failure: LocalizedError {
        case unsupported, connection, budget
        var errorDescription: String? {
            switch self {
            case .unsupported: return "当前规格没有可用的后置双路导航格式。"
            case .connection: return "当前相机输出无法连接对焦辅助。"
            case .budget: return "当前双路取景超过相机资源预算。"
            }
        }
    }
    struct Original {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let minimum: CMTime, maximum: CMTime
        let zoom: CGFloat
        let color: AVCaptureColorSpace
    }
    let session = AVCaptureMultiCamSession()
    let originalSession: AVCaptureSession
    let originalInput: AVCaptureDeviceInput
    let mainInput: AVCaptureDeviceInput
    let main: AVCaptureDevice
    let wide: AVCaptureDevice
    let mainBase: CGFloat
    private let navigationOutput = AVCaptureVideoDataOutput()
    private var originals: [Original] = []
    private let primaryOutput = AVCaptureVideoDataOutput()
    private var wantedZoom: CGFloat = 1
    var onVideo: ((CMSampleBuffer) -> Void)?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var observers: [NSObjectProtocol] = []
    private var pressureObservations: [NSKeyValueObservation] = []
    private var lastFrame = -Double.infinity
    private var released = false
    var onFrame: ((UIImage) -> Void)?
    var onError: (() -> Void)?
    private(set) var frames = 0
    private(set) var renderSeconds = 0.0

    init(originalSession: AVCaptureSession, originalInput: AVCaptureDeviceInput,
         zoom: CGFloat,
         mainBase: CGFloat, navigationType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera, navigationFPS: Int = 15, frameQueue: DispatchQueue, primaryQueue: DispatchQueue) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let main = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
              let wide = AVCaptureDevice.default(navigationType, for: .video, position: .back) else { throw Failure.unsupported }
        let sets = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).supportedMultiCamDeviceSets
        guard sets.contains(where: { $0.contains(main) && $0.contains(wide) }) else { throw Failure.unsupported }
        self.main = main; self.wide = wide; self.mainBase = mainBase
        self.mainInput = try AVCaptureDeviceInput(device: main)
        self.originalSession = originalSession; self.originalInput = originalInput
        super.init()
        // 保留虚拟设备包装器和两物理镜头原参数；恢复时最后还原原路由，避免污染后续拍照。
        for device in [main, wide, originalInput.device] {
            originals.append(Original(device: device, format: device.activeFormat,
                minimum: device.activeVideoMinFrameDuration, maximum: device.activeVideoMaxFrameDuration,
                zoom: device.videoZoomFactor, color: device.activeColorSpace))
        }
        do {
            let fps = 30
            let dimensions = CGSize(width: 1440, height: 1080)
            let color = AVCaptureColorSpace.sRGB
            guard let mainFormat = Self.format(main, dimensions: dimensions, fps: fps, color: color),
                  let wideFormat = Self.format(wide, dimensions: CGSize(width: 640, height: 480), fps: navigationFPS, color: .sRGB) else { throw Failure.unsupported }
            originalSession.stopRunning()
            try Self.apply(main, format: mainFormat, fps: fps, color: color, zoom: zoom / mainBase)
            try Self.apply(wide, format: wideFormat, fps: navigationFPS, color: .sRGB, zoom: 1)
            session.beginConfiguration()
            do {
                guard session.canAddInput(mainInput) else { throw Failure.connection }
                // MultiCam预算按输入允许的最快帧率估计；声明主路真实采集周期，避免按格式最高帧率预留资源。
                mainInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: Int32(fps))
                session.addInput(mainInput)
                primaryOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                primaryOutput.alwaysDiscardsLateVideoFrames = true
                primaryOutput.setSampleBufferDelegate(self, queue: primaryQueue)
                guard session.canAddOutput(primaryOutput) else { throw Failure.connection }
                session.addOutput(primaryOutput)
                if let connection = primaryOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                let wideInput = try AVCaptureDeviceInput(device: wide)
                guard session.canAddInput(wideInput), session.canAddOutput(navigationOutput) else { throw Failure.connection }
                wideInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: Int32(navigationFPS))
                session.addInputWithNoConnections(wideInput)
                navigationOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                navigationOutput.alwaysDiscardsLateVideoFrames = true
                navigationOutput.setSampleBufferDelegate(self, queue: frameQueue)
                session.addOutputWithNoConnections(navigationOutput)
                guard let port = wideInput.ports.first(where: { $0.mediaType == .video }) else { throw Failure.connection }
                let connection = AVCaptureConnection(inputPorts: [port], output: navigationOutput)
                guard session.canAddConnection(connection) else { throw Failure.connection }
                session.addConnection(connection)
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } catch {
                session.commitConfiguration(); throw error
            }
            session.commitConfiguration()
            wantedZoom = zoom / mainBase
            #if DEBUG
            print("FOCUS-NAV-BUDGET size=\(dimensions) fps=\(fps) nav=\(wide.deviceType.rawValue) navFPS=\(navigationFPS) hardware=\(session.hardwareCost) pressure=\(session.systemPressureCost)")
            #endif
            guard session.hardwareCost <= 1, session.systemPressureCost <= 1 else { throw Failure.budget }
            for device in [main, wide] {
                pressureObservations.append(device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
                    if device.systemPressureState.level == .critical || device.systemPressureState.level == .shutdown { self?.onError?() }
                })
            }
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in self?.onError?() })
            }
        } catch { restore(); throw error }
    }
    private static func format(_ device: AVCaptureDevice, dimensions: CGSize, fps: Int, color: AVCaptureColorSpace) -> AVCaptureDevice.Format? {
        device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.isMultiCamSupported && size.width == Int32(dimensions.width) && size.height == Int32(dimensions.height)
                && CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && $0.supportedColorSpaces.contains(color)
                && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
        }.sorted { ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) }.first
    }
    private static func apply(_ device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int, color: AVCaptureColorSpace, zoom: CGFloat) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps)); device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
        device.activeColorSpace = color
        device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }
    func start() throws {
        session.startRunning(); if !session.isRunning { throw Failure.connection }
        // 输入/输出最终提交可能重置倍率；启动后恢复真实长焦裁切，不只修改UI的倍率数字。
        try main.lockForConfiguration()
        main.videoZoomFactor = min(max(wantedZoom, main.minAvailableVideoZoomFactor), main.maxAvailableVideoZoomFactor)
        main.unlockForConfiguration()
    }
    func restore() {
        guard !released else { return }; released = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        pressureObservations.removeAll()
        session.stopRunning(); navigationOutput.setSampleBufferDelegate(nil, queue: nil)
        primaryOutput.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        session.outputs.forEach { session.removeOutput($0) }; session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        for original in originals {
            if (try? original.device.lockForConfiguration()) != nil {
                original.device.activeFormat = original.format
                original.device.activeVideoMinFrameDuration = original.minimum; original.device.activeVideoMaxFrameDuration = original.maximum
                if original.format.supportedColorSpaces.contains(original.color) { original.device.activeColorSpace = original.color }
                original.device.videoZoomFactor = min(max(original.zoom, original.device.minAvailableVideoZoomFactor), original.device.maxAvailableVideoZoomFactor)
                original.device.unlockForConfiguration()
            }
        }

    }
    /// 视场角估算范围框，不把近距视差当作精确标定。主画面与导航均为竖直像素，主画幅再作居中裁切。
    func region(zoom: CGFloat, ratio: CGFloat) -> CGRect {
        let d = CMVideoFormatDescriptionGetDimensions(main.activeFormat.formatDescription)
        let relative = CGFloat(tan(Double(main.activeFormat.videoFieldOfView) * .pi / 360) / tan(Double(wide.activeFormat.videoFieldOfView) * .pi / 360)) / max(1, zoom / mainBase)
        let nativeRatio = CGFloat(d.height) / CGFloat(d.width)
        var w = relative * nativeRatio / 0.75, h = relative
        if ratio < nativeRatio { w *= ratio / nativeRatio } else { h *= nativeRatio / ratio }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: min(1, w), height: min(1, h))
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === primaryOutput { onVideo?(sampleBuffer); return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time - lastFrame >= 1.0 / 15 - 0.0005, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = time
        autoreleasepool {
            let began = CACurrentMediaTime(), image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 240 / image.extent.height)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = Imaging.ownedCGImage(small, from: small.extent, context: context) { frames += 1; onFrame?(UIImage(cgImage: cg)) }
            renderSeconds += CACurrentMediaTime() - began
        }
    }
}
