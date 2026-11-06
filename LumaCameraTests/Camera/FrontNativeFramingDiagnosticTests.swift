import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import LumaCamera

/// 独立系统会话：排除应用的处理链和镜头路由，只记录动态画幅源像素。
final class FrontNativeFramingDiagnosticTests: XCTestCase {
    @MainActor func testNativeFrontBuffersAndPhotoWithoutAppProcessing() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实前置传感器")
        #else
        guard #available(iOS 26.0, *), let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) else { throw XCTSkip("无动态前置") }
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        let probe = NativeFrontProbe(device:device)
        let queue = DispatchQueue(label: "test.native.front")
        defer { queue.sync { probe.session.stopRunning() } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                let device = probe.device
                do {
                    probe.session.beginConfiguration()
                    probe.session.sessionPreset = .photo
                    probe.session.addInput(try AVCaptureDeviceInput(device: device))
                    probe.session.addOutput(probe.photos)
                    probe.video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    probe.video.setSampleBufferDelegate(probe, queue: queue)
                    probe.session.addOutput(probe.video)
                    if probe.photos.isCameraSensorOrientationCompensationSupported { probe.photos.isCameraSensorOrientationCompensationEnabled = false }
                    probe.session.commitConfiguration()
                    for output in [probe.video as AVCaptureOutput, probe.photos as AVCaptureOutput] {
                        if let connection = output.connection(with: .video) {
                            connection.videoRotationAngle = 0
                            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                        }
                    }
                    probe.session.startRunning()
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
        for (name, ratio) in [("portrait", AVCaptureDevice.AspectRatio.ratio4x3), ("landscape", .ratio3x4)] {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async {
                    let device = probe.device
                    do {
                        try device.lockForConfiguration()
                        device.setDynamicAspectRatio(ratio) { _, error in
                            if let error { c.resume(throwing: error) } else { c.resume() }
                        }
                        device.unlockForConfiguration()
                    } catch { c.resume(throwing: error) }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            let pair = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(UIImage?, Data), Error>) in
                queue.async {
                    let preview = probe.preview
                    probe.finished = { result in c.resume(with: result.map { (preview, $0) }) }
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    probe.photos.capturePhoto(with: settings, delegate: probe)
                }
            }
            if let preview = pair.0 {
                let attachment = XCTAttachment(image: preview); attachment.name = "native-buffer-" + name; attachment.lifetime = .keepAlways; add(attachment)
            }
            let ci = try XCTUnwrap(CIImage(data: pair.1, options: [.applyOrientationProperty: true]))
            let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
            let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "native-photo-" + name; attachment.lifetime = .keepAlways; add(attachment)
            print("NATIVE-FRONT \(name) buffer=\(String(describing: pair.0?.size)) photo=\(ci.extent.size) orientation=\(UIDevice.current.orientation.rawValue)")
        }
        #endif
    }
}

// 会话/设备和CIContext仅在配置/视频队列使用；跨队列预览与照片回调以lock保护。
private final class NativeFrontProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let device:AVCaptureDevice
    init(device:AVCaptureDevice) { self.device = device }
    let session = AVCaptureSession(), photos = AVCapturePhotoOutput(), video = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private let lock = NSLock()
    private var storedPreview:UIImage?
    private var storedFinished:((Result<Data,Error>)->Void)?
    var preview:UIImage? {
        get { lock.lock(); defer { lock.unlock() }; return storedPreview }
        set { lock.lock(); defer { lock.unlock() }; storedPreview = newValue }
    }
    var finished:((Result<Data,Error>)->Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedFinished }
        set { lock.lock(); defer { lock.unlock() }; storedFinished = newValue }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 900 / image.extent.width
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = context.createCGImage(resized, from: resized.extent) { preview = UIImage(cgImage: cg) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); let callback = storedFinished; storedFinished = nil; lock.unlock()
        if let error { callback?(.failure(error)) }
        else if let data = photo.fileDataRepresentation() { callback?(.success(data)) }
        else { callback?(.failure(PhotoEncodingError.encoding)) }
    }
}
