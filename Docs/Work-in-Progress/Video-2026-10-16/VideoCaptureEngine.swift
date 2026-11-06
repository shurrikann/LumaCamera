@preconcurrency import AVFoundation
import CoreImage
import Combine
import UIKit

/// A separate session keeps video formats, audio and Log configuration out of the photo path.
final class VideoCaptureEngine: NSObject, @unchecked Sendable, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var preview: UIImage?
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var capabilities: [VideoConfiguration] = []
    @Published private(set) var isoRange: ClosedRange<Double> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = log2(1/8000.0)...log2(1/30.0)
    @Published private(set) var readings = CameraReadings(iso: 100, seconds: 1/60, kelvin: 5500, focus: 0.5)
    @Published var message: String?
    var onConfigurationChanged: ((VideoConfiguration) -> Void)?
    var onRecorded: ((URL, VideoConfiguration, CaptureLook) -> Void)?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "video.session", qos: .userInitiated)
    private let frames = DispatchQueue(label: "video.preview", qos: .userInitiated)
    private let movie = AVCaptureMovieFileOutput()
    private let data = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var input: AVCaptureDeviceInput?
    private var audio: AVCaptureDeviceInput?
    private var configuration = VideoConfiguration()
    private var controls = VideoManualSettings()
    private var look = CaptureLook()
    private var frozen: (VideoConfiguration, CaptureLook)?
    private var wantsRunning = false
    private var front = false
    private var physicalBase: CGFloat = 1
    private var lastReadings = -Double.infinity
    private var lastFrame = -Double.infinity
    private var observers: [NSObjectProtocol] = []
    private let stateLock = NSLock()
    private var frameState: (VideoConfiguration, CaptureLook, Bool, Bool, AVCaptureDevice?) = (VideoConfiguration(), CaptureLook(), false, false, nil)
    override init() {
        super.init()
        for name in [AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in guard let self, self.wantsRunning, !self.movie.isRecording else { return }; if !self.session.isRunning { self.session.startRunning() } }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func start() {
        Task {
            var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { camera = await AVCaptureDevice.requestAccess(for: .video) }
            guard camera else { DispatchQueue.main.async { self.message = "请在系统设置中允许相机访问。" }; return }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            queue.async {
                self.wantsRunning = true
                do {
                    if self.input == nil { try self.setup() }
                    if !self.session.isRunning { self.session.startRunning() }
                } catch { self.publishError(error) }
            }
        }
    }
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.wantsRunning = false; self.updateFrameState()
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false; completion?() }
        }
    }
    private func setup() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        try replaceInput()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, let microphone = AVCaptureDevice.default(for: .audio) {
            let audio = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(audio) { session.addInput(audio); self.audio = audio }
        }
        guard session.canAddOutput(movie), session.canAddOutput(data) else { throw VideoCaptureError.unavailable }
        session.addOutput(movie); session.addOutput(data)
        data.alwaysDiscardsLateVideoFrames = true
        data.automaticallyConfiguresOutputBufferDimensions = true
        data.deliversPreviewSizedOutputBuffers = true
        data.setSampleBufferDelegate(self, queue: frames)
        try configureDevice()
    }
    private func replaceInput(preferred: AVCaptureDevice? = nil) throws {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let camera = preferred ?? (!front ? (controls.manual ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) : CameraLensCatalog.preferredVirtualRearCamera()) : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position))
        guard let camera else { throw VideoCaptureError.unavailable }
        let replacement = try AVCaptureDeviceInput(device: camera)
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else { if let previous { session.addInput(previous) }; throw VideoCaptureError.unavailable }
        session.addInput(replacement); input = replacement
        let supported = VideoResolution.allCases.flatMap { resolution in VideoConfiguration.frameRates.flatMap { fps in VideoRatio.allCases.flatMap { ratio in VideoColorMode.allCases.compactMap { color -> VideoConfiguration? in
            var value = VideoConfiguration(); value.resolution = resolution; value.fps = fps; value.ratio = ratio; value.color = color
            return camera.formats.contains(where: value.supports) ? value : nil
        } } } }
        if !supported.contains(configuration) { configuration = supported.first(where: { $0 == VideoConfiguration() }) ?? supported.first ?? VideoConfiguration() }
        physicalBase = front ? 1 : camera.deviceType == .builtInUltraWideCamera ? 0.5 : camera.deviceType == .builtInTelephotoCamera ? 4 : 1
        DispatchQueue.main.async { self.capabilities = supported; self.onConfigurationChanged?(self.configuration) }
    }
    func configure(_ value: VideoConfiguration, look: CaptureLook) {
        queue.async {
            guard !self.movie.isRecording else { return }
            self.configuration = value; self.look = look
            guard self.input != nil else { self.updateFrameState(); return }
            do { self.session.beginConfiguration(); defer { self.session.commitConfiguration() }; try self.configureDevice() }
            catch { self.publishError(error) }
        }
    }
    private func configureDevice() throws {
        guard let device = input?.device, let color = configuration.color.captureSpace else { throw VideoCaptureError.unsupported }
        let formats = device.formats.filter(configuration.supports).sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int64(a.width)*Int64(a.height) < Int64(b.width)*Int64(b.height)
        }
        guard let format = formats.first else { throw VideoCaptureError.unsupported }
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        if device.activeFormat != format { device.activeFormat = format }
        if device.activeColorSpace != color { device.activeColorSpace = color }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(configuration.fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(configuration.fps))
        if device.isVirtualDevice, device.primaryConstituentDeviceSwitchingBehavior != .unsupported { device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: []) }
        if let connection = movie.connection(with: .video), movie.availableVideoCodecTypes.contains(.hevc) { movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection) }
        let pixel = configuration.color.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        guard data.availableVideoPixelFormatTypes.contains(pixel) else { throw VideoCaptureError.unsupported }
        data.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel]
        if let connection = data.connection(with: .video), connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        applyControls(device)
        updateFrameState()
        let maximum = min(CMTimeGetSeconds(format.maxExposureDuration), 1/Double(configuration.fps))
        DispatchQueue.main.async {
            self.isoRange = Double(format.minISO)...Double(format.maxISO)
            self.shutterRange = log2(max(CMTimeGetSeconds(format.minExposureDuration), 0.000001))...log2(max(maximum, 0.000001))
        }
    }
    private func updateFrameState() { stateLock.lock(); frameState = (configuration, look, front, wantsRunning, input?.device); stateLock.unlock() }
    func setControls(_ value: VideoManualSettings) {
        queue.async {
            let changed = self.controls.manual != value.manual; self.controls = value
            do {
                if changed, !self.front, !self.movie.isRecording, self.input != nil {
                    self.session.beginConfiguration(); defer { self.session.commitConfiguration() }
                    try self.replaceInput(); try self.configureDevice()
                } else if let device = self.input?.device { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; self.applyControls(device) }
            } catch { self.publishError(error) }
        }
    }
    private func applyControls(_ device: AVCaptureDevice) {
        let value = controls
        if value.manual, value.iso != nil || value.shutter != nil, device.isExposureModeSupported(.custom) {
            let iso = Float(min(max(value.iso ?? Double(device.iso), Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO)))
            let maxTime = min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration), 1/Double(configuration.fps))
            let duration = min(max(value.shutter ?? CMTimeGetSeconds(device.exposureDuration), CMTimeGetSeconds(device.activeFormat.minExposureDuration)), maxTime)
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: iso, completionHandler: nil)
        } else if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.setExposureTargetBias(min(max(Float(value.ev), device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
        if value.manual, let focus = value.focus, device.isLockingFocusWithCustomLensPositionSupported { device.setFocusModeLocked(lensPosition: Float(min(max(focus, 0), 1)), completionHandler: nil) }
        else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if value.manual, let kelvin = value.kelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: Float(value.tint)))
            if let safe = WhiteBalanceSafety.clamped(gains, maximum: device.maxWhiteBalanceGain) { device.setWhiteBalanceModeLocked(with: safe, completionHandler: nil) }
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }
    func zoom(_ value: Double) {
        queue.async { guard let device = self.input?.device, value.isFinite else { return }; do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            let factor = CGFloat(value) / (device.isVirtualDevice ? CameraLensCatalog.displayMultiplier(device) : self.physicalBase)
            device.ramp(toVideoZoomFactor: min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor), withRate: 12)
        } catch { self.publishError(error) } }
    }
    func selectZoom(_ value: Double) {
        queue.async {
            if self.controls.manual, !self.front, !self.movie.isRecording {
                let type: AVCaptureDevice.DeviceType = value < 1 ? .builtInUltraWideCamera : value >= 4 ? .builtInTelephotoCamera : .builtInWideAngleCamera
                if let preferred = AVCaptureDevice.default(type, for: .video, position: .back), preferred.uniqueID != self.input?.device.uniqueID {
                    do { self.session.beginConfiguration(); defer { self.session.commitConfiguration() }; try self.replaceInput(preferred: preferred); try self.configureDevice() }
                    catch { self.publishError(error) }
                }
            }
            self.zoom(value)
        }
    }
    func focus(_ point: CGPoint) {
        queue.async { guard let device = self.input?.device else { return }; do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: min(max(point.y,0),1), y: min(max(1-point.x,0),1)) }
            if self.controls.focus == nil, device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        } catch { self.publishError(error) } }
    }
    func flip() {
        queue.async { guard !self.movie.isRecording else { return }; do { self.session.beginConfiguration(); defer { self.session.commitConfiguration() }; self.front.toggle(); try self.replaceInput(); try self.configureDevice() } catch { self.publishError(error) } }
    }
    func record(rotation: Double, metadata: [AVMetadataItem]) {
        queue.async {
            guard self.wantsRunning, !self.movie.isRecording, self.session.isRunning else { return }
            guard let connection = self.movie.connection(with: .video), self.movie.availableVideoCodecTypes.contains(.hevc) else { self.publishError(VideoCaptureError.unsupported); return }
            let angle: CGFloat = rotation == 90 ? 0 : rotation == -90 ? 180 : rotation == 180 ? 270 : 90
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            self.movie.metadata = metadata
            self.frozen = (self.configuration, self.look)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-Recording-"+UUID().uuidString+".mov")
            self.movie.startRecording(to: url, recordingDelegate: self)
        }
    }
    func finish() { queue.async { if self.movie.isRecording { self.movie.stopRecording() } } }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { DispatchQueue.main.async { self.recording = true } }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        let snapshot = frozen
        let successful = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        DispatchQueue.main.async {
            self.recording = false
            if successful, let snapshot { self.onRecorded?(url, snapshot.0, snapshot.1) }
            else { self.message = error?.localizedDescription ?? VideoCaptureError.empty.localizedDescription }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time-lastFrame >= 1/30.0, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }; lastFrame = time
        stateLock.lock(); let (config, look, mirror, running, device) = frameState; stateLock.unlock()
        guard running else { return }
        if time - lastReadings > 0.25, let device {
            lastReadings = time
            let wb = WhiteBalanceSafety.validated(device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain).map { device.temperatureAndTintValues(for: $0) }
            let value = CameraReadings(iso: Double(device.iso), seconds: CMTimeGetSeconds(device.exposureDuration), kelvin: Double(wb?.temperature ?? 5500), focus: Double(device.lensPosition), tint: wb.map { Double($0.tint) })
            DispatchQueue.main.async { self.readings = value }
        }
        autoreleasepool {
            var image = CaptureOrientation.portraitFrame(CIImage(cvPixelBuffer: buffer), mirrored: mirror)
            image = image.transformed(by: CGAffineTransform(scaleX: min(1,900/image.extent.width), y: min(1,900/image.extent.width)))
            if config.color.filtersAllowed { var live = look; live.grainPhase = time*127.7; image = Imaging.filtered(image, look: live) }
            image = config.ratio.crop(image, landscape: false)
            if let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: config.color == .p3 ? CGColorSpace(name: CGColorSpace.displayP3)! : CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false) {
                DispatchQueue.main.async { self.preview = UIImage(cgImage: cg); if !self.ready { self.ready = true } }
            }
        }
    }
    private func publishError(_ error: Error) { DispatchQueue.main.async { self.message = error.localizedDescription } }
}
