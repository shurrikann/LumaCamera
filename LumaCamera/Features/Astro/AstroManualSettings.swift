import AVFoundation
import CoreImage
import UIKit

/// Manual star-capture parameters shared by the three independent engines.
/// `photoShutterSeconds` is a real sensor shutter; `fusionExposureSeconds` is
/// the number of 1-second frames fused by trails/timelapse and is never passed
/// to `setExposureModeCustom` as one long exposure.
struct AstroManualSettings: Equatable {
    var photoShutterSeconds: Double = 1.0 / 15.0
    var fusionExposureSeconds: Int = 1
    var iso: Double = 100
    var exposureBias: Double = 0
    var whiteBalanceKelvin: Double = 5200
    var whiteBalanceTint: Double = 0
    var lensPosition: Double = 1
    var isoAutomatic = true
    var exposureBiasAutomatic = false
    var whiteBalanceAutomatic = false
    var tintAutomatic = false

    static let photoShutterRange = 1.0 / 15.0 ... 1.0
    static let photoShutterOptions: [Double] = [1, 1.0 / 2.0, 1.0 / 5.0, 1.0 / 10.0, 1.0 / 15.0]
    static let fusionExposureRange = 1 ... 30
    static let isoStops: [Double] = [100, 200, 400, 800, 1600, 3200, 6400, 12800]

    var clampedPhotoShutter: Double {
        min(max(photoShutterSeconds, Self.photoShutterRange.lowerBound), Self.photoShutterRange.upperBound)
    }

    var clampedFusionExposure: Int {
        min(max(fusionExposureSeconds, Self.fusionExposureRange.lowerBound), Self.fusionExposureRange.upperBound)
    }

    mutating func setISO(_ value: Double, in format: AVCaptureDevice.Format) {
        iso = min(max(value, Double(format.minISO)), Double(format.maxISO))
    }

    func resolvedISO(meteredISO: Double, meteredSeconds: Double, targetSeconds: Double,
                     meteredOffset: Double = 0, meteredBias: Double = 0,
                     range: ClosedRange<Double>) -> Double {
        let bias = exposureBiasAutomatic ? 0 : min(max(exposureBias, -5), 5)
        let base: Double
        if isoAutomatic, meteredISO.isFinite, meteredSeconds.isFinite, meteredSeconds > 0, targetSeconds > 0 {
            let correction = bias - (meteredOffset.isFinite ? meteredOffset : 0) - meteredBias
            base = meteredISO * meteredSeconds / targetSeconds * pow(2, min(max(correction, -16), 16))
        } else { base = iso * pow(2, bias) }
        return min(max(base.isFinite ? base : iso, range.lowerBound), range.upperBound)
    }
}

extension AVCaptureDevice {
    func supportsAstroAutoISO(shutter: Double) -> Bool {
        if #available(iOS 27.0, *) {
            return activeFormat.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000), iso: AVCaptureDevice.autoISO)
        }
        return false
    }
    var astroEquivalentFocalLength: Double? {
        if #available(iOS 26.0, *) {
            let value = Double(nominalFocalLengthIn35mmFilm) * Double(videoZoomFactor)
            return value.isFinite && value > 0 ? value : nil
        }
        return nil
    }

    /// Idle star preview and capture use the same device, so restore the
    /// preview explicitly rather than letting auto exposure choose a shutter.
    func applyAstroPreviewSettings(_ settings: AstroManualSettings) throws {
        if CMTimeCompare(activeMaxExposureDuration, activeFormat.maxExposureDuration) != 0 { activeMaxExposureDuration = activeFormat.maxExposureDuration }
        let duration = CMTime(value: 1, timescale: 15)
        if activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
            if CMTimeCompare(activeVideoMinFrameDuration, duration) != 0 { activeVideoMinFrameDuration = duration }
            if CMTimeCompare(activeVideoMaxFrameDuration, duration) != 0 { activeVideoMaxFrameDuration = duration }
        }
        try applyAstroManualSettings(settings, shutterSeconds: 1.0 / 15.0, preservesMatchingExposure: true)
    }

    /// Call while the device is locked for configuration. `shutterSeconds` is
    /// the real exposure for this frame; callers must not pass a fusion total.
    func applyAstroManualSettings(_ settings: AstroManualSettings, shutterSeconds: Double,
                                  lockAutomaticParameters: Bool = false,
                                  preservesMatchingExposure: Bool = false,
                                  exposureCompletion: (@Sendable (CMTime) -> Void)? = nil) throws {
        guard isExposureModeSupported(.custom) else {
            throw AstroManualSettingsError.customExposureUnsupported
        }
        let shutter = min(max(shutterSeconds, AstroManualSettings.photoShutterRange.lowerBound),
                          AstroManualSettings.photoShutterRange.upperBound)
        let bias = settings.exposureBiasAutomatic ? 0 : min(max(settings.exposureBias, -5), 5)
        // 66,667 microseconds is longer than a 1/15-second preview frame.
        // Keep this rational exact so exposure never exceeds its own cadence.
        let duration = abs(shutter-1.0/15.0) < 1e-9
            ? CMTime(value: 1, timescale: 15)
            : CMTime(seconds: shutter, preferredTimescale: 1_000_000)
        if #available(iOS 27.0, *), settings.isoAutomatic, !lockAutomaticParameters, supportsAstroAutoISO(shutter: shutter) {
            setExposureTargetBias(Float(min(max(bias, Double(minExposureTargetBias)), Double(maxExposureTargetBias))))
            setExposureModeCustom(duration: duration, iso: AVCaptureDevice.autoISO, completionHandler: exposureCompletion)
        } else {
            let resolved = settings.resolvedISO(meteredISO: Double(iso),
                meteredSeconds: CMTimeGetSeconds(exposureDuration), targetSeconds: shutter,
                meteredOffset: Double(exposureTargetOffset), meteredBias: Double(exposureTargetBias),
                range: Double(activeFormat.minISO)...Double(activeFormat.maxISO))
            let matches = exposureMode == .custom
                && abs(CMTimeGetSeconds(exposureDuration)-shutter) < 0.0001
                && abs(Double(iso)-resolved) <= max(0.5, resolved*0.001)
            if !preservesMatchingExposure || exposureCompletion != nil || !matches {
                setExposureModeCustom(duration: duration, iso: Float(resolved), completionHandler: exposureCompletion)
            }
        }
        let focus = Float(min(max(settings.lensPosition, 0), 1))
        if isFocusModeSupported(.locked), focusMode != .locked || abs(lensPosition-focus) > 0.002 {
            setFocusModeLocked(lensPosition: focus)
        }
        if settings.whiteBalanceAutomatic || settings.tintAutomatic {
            if lockAutomaticParameters, isWhiteBalanceModeSupported(.locked) {
                setWhiteBalanceModeLocked(with: deviceWhiteBalanceGains)
            } else if isWhiteBalanceModeSupported(.continuousAutoWhiteBalance), whiteBalanceMode != .continuousAutoWhiteBalance {
                whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } else if isWhiteBalanceModeSupported(.locked) {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(settings.whiteBalanceKelvin),
                tint: Float(settings.whiteBalanceTint))
            var gains = deviceWhiteBalanceGains(for: values)
            let maxGain = maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            let actual = deviceWhiteBalanceGains
            if whiteBalanceMode != .locked || abs(actual.redGain-gains.redGain) > 0.001
                || abs(actual.greenGain-gains.greenGain) > 0.001 || abs(actual.blueGain-gains.blueGain) > 0.001 {
                setWhiteBalanceModeLocked(with: gains)
            }
        }
    }
}

/// Covers capture preparation as well as acquisition. A pending preview task
/// must not change hardware after the user has already pressed the shutter.
final class AstroPreviewExposureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var captureActive = false
    var permitsPreview: Bool { lock.lock(); defer { lock.unlock() }; return !captureActive }
    func setCaptureActive(_ active: Bool) { lock.lock(); defer { lock.unlock() }; captureActive = active }
}

enum AstroManualSettingsError: LocalizedError {
    case customExposureUnsupported, captureCadenceUnsupported
    var errorDescription: String? {
        switch self {
        case .customExposureUnsupported: return "当前镜头不支持手动曝光"
        case .captureCadenceUnsupported: return "当前格式不支持星空长曝光帧率"
        }
    }
}

/// Meter once at preview cadence, then keep one exposure across the fusion group.
/// The settling threshold is an application policy, not a hardware guarantee.
final class AstroCaptureExposurePreparation: @unchecked Sendable {
    struct Reading {
        let iso: Double, seconds: Double, offset: Double, bias: Double
        let appliedISO: Double, sensorISO: Double, sensorSeconds: Double, elapsed: Double
        let settled: Bool
    }
    private let device: AVCaptureDevice
    private let settings: AstroManualSettings
    private let shutter: Double
    private let video: Bool
    private let queue: DispatchQueue
    private let isCurrent: () -> Bool
    private let completion: (Result<Reading, Error>) -> Void
    private var previousProduct: Double?
    private var stableSamples = 0
    private var started = ProcessInfo.processInfo.systemUptime

    init(device: AVCaptureDevice, settings: AstroManualSettings, shutter: Double, video: Bool,
         queue: DispatchQueue, isCurrent: @escaping () -> Bool,
         completion: @escaping (Result<Reading, Error>) -> Void) {
        self.device = device; self.settings = settings; self.shutter = shutter; self.video = video
        self.queue = queue; self.isCurrent = isCurrent; self.completion = completion
    }
    func start() {
        guard isCurrent() else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if settings.isoAutomatic, device.isExposureModeSupported(.continuousAutoExposure) {
                let preview = CMTime(value: 1, timescale: 15)
                device.activeVideoMinFrameDuration = preview
                device.activeVideoMaxFrameDuration = preview
                device.activeMaxExposureDuration = preview
                device.setExposureTargetBias(0)
                device.exposureMode = .continuousAutoExposure
                started = ProcessInfo.processInfo.systemUptime
                queue.asyncAfter(deadline: .now() + 0.12) { self.poll() }
            } else {
                queue.async { self.apply(settled: true) }
            }
        } catch { completion(.failure(error)) }
    }
    private func poll() {
        guard isCurrent() else { return }
        let product = Double(device.iso) * CMTimeGetSeconds(device.exposureDuration)
        if let previousProduct, product > 0, previousProduct > 0,
           abs(log2(product / previousProduct)) < 0.06, !device.isAdjustingExposure,
           CMTimeGetSeconds(device.exposureDuration) <= 1.0 / 15.0 + 0.002,
           device.exposureMode == .continuousAutoExposure {
            stableSamples += 1
        } else { stableSamples = 0 }
        previousProduct = product
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if (elapsed >= 0.24 && stableSamples >= 2) || elapsed >= 1.5 {
            apply(settled: stableSamples >= 2)
        } else { queue.asyncAfter(deadline: .now() + 0.06) { self.poll() } }
    }
    private func apply(settled: Bool) {
        guard isCurrent() else { return }
        let iso = Double(device.iso), seconds = CMTimeGetSeconds(device.exposureDuration)
        let offset = Double(device.exposureTargetOffset), bias = Double(device.exposureTargetBias)
        let resolved = settings.resolvedISO(meteredISO: iso, meteredSeconds: seconds,
            targetSeconds: shutter, meteredOffset: offset, meteredBias: bias,
            range: Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if video {
                guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 0.999
                }) else { throw AstroManualSettingsError.captureCadenceUnsupported }
                let duration = CMTime(value: 1, timescale: 1)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.activeMaxExposureDuration = device.activeFormat.maxExposureDuration
            var locked = settings
            locked.isoAutomatic = false; locked.iso = resolved; locked.exposureBias = 0
            // Completion is delivered only after the sensor applies duration and ISO.
            try device.applyAstroManualSettings(locked, shutterSeconds: shutter, lockAutomaticParameters: true) { _ in
                self.queue.async {
                    guard self.isCurrent() else { return }
                    let reading = Reading(iso: iso, seconds: seconds, offset: offset, bias: bias,
                        appliedISO: resolved, sensorISO: Double(self.device.iso),
                        sensorSeconds: CMTimeGetSeconds(self.device.exposureDuration),
                        elapsed: ProcessInfo.processInfo.systemUptime - self.started, settled: settled)
                    self.completion(.success(reading))
                }
            }
        } catch { completion(.failure(error)) }
    }
}

/// Owns a small preview bitmap, never a capture-pool pixel buffer. Used only for
/// user-requested mode handoffs; automatic physical-lens switches don't use it.
final class AstroPreviewFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var image: UIImage?
    private var targetDeviceID: String?
    private var fastStart = false
    private var generation: UInt64 = 0
    private var renderedAt: Double = 0
    private var renders = 0
    private var renderSeconds = 0.0
    private var maximumRenderSeconds = 0.0
    var metrics: (count: Int, totalSeconds: Double, maximumSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (renders, renderSeconds, maximumRenderSeconds)
    }
    var snapshot: UIImage? { lock.lock(); defer { lock.unlock() }; return image }
    func reset(forDeviceID deviceID: String? = nil, fastStart: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        targetDeviceID = deviceID; self.fastStart = fastStart
        generation &+= 1
        image = nil; renderedAt = ProcessInfo.processInfo.systemUptime
        renders = 0; renderSeconds = 0; maximumRenderSeconds = 0
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) { receive(sampleBuffer, from:connection) }
    func receive(_ sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let sourceID = connection?.inputPorts.compactMap { ($0.input as? AVCaptureDeviceInput)?.device.uniqueID }.first
        lock.lock()
        let version = generation
        let matchesDevice = targetDeviceID == nil || sourceID == targetDeviceID
        let interval = fastStart && renders == 0 ? 0 : fastStart && renders < 2 ? 1.0/30 : 0.25
        let shouldRender = matchesDevice && now - renderedAt >= interval
        lock.unlock()
        guard shouldRender, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 960 / max(source.extent.width, source.extent.height))
        let reduced = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(reduced, from: reduced.extent) else { return }
        let cost = ProcessInfo.processInfo.systemUptime - now
        lock.lock()
        guard version == generation else { lock.unlock(); return }
        image = UIImage(cgImage: cg); renderedAt = now
        renders += 1; renderSeconds += cost; maximumRenderSeconds = max(maximumRenderSeconds, cost)
        lock.unlock()
    }
}

/// One session and one configuration queue, with exclusive ownership of its graph.
/// Retains the normal graph while Astro installs its own inputs/outputs. Algorithms
/// and durable saving remain in the existing engines.
final class AstroSharedCaptureSession: @unchecked Sendable {
    let session: AVCaptureSession
    let queue: DispatchQueue
    private let lock = NSLock()
    private var reserved = false
    private var owner: UUID?
    private struct DeviceState {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let minimum: CMTime, maximum: CMTime
        let colorSpace: AVCaptureColorSpace
        let zoom: CGFloat
        let automaticHDR: Bool, hdr: Bool
    }
    private struct ConnectionState {
        let output: AVCaptureOutput
        let angle: CGFloat
        let mirrored: Bool, automaticMirroring: Bool, enabled: Bool
        let stabilization: AVCaptureVideoStabilizationMode
    }
    private struct Graph {
        let inputs: [AVCaptureInput]
        let outputs: [AVCaptureOutput]
        let preset: AVCaptureSession.Preset
        let formats: [DeviceState]
        let connections: [ConnectionState]
        let dimensions: [(AVCapturePhotoOutput, CMVideoDimensions)]
    }
    private var normal: Graph? // configuration queue only
    init(session: AVCaptureSession, queue: DispatchQueue) { self.session = session; self.queue = queue }
    var isReserved: Bool { lock.lock(); defer { lock.unlock() }; return reserved }
    func reserve() { lock.lock(); reserved = true; lock.unlock() }
    func owns(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return owner == id }
    func readPreviewParameters() async -> CameraReadings? {
        await withCheckedContinuation { continuation in
            queue.async {
                let device = self.session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
                    .first { $0.hasMediaType(.video) }
                guard self.isReserved, self.session.isRunning, let device else {
                    continuation.resume(returning: nil)
                    return
                }
                let balance = WhiteBalanceSafety.validated(device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain)
                    .map { device.temperatureAndTintValues(for: $0) }
                continuation.resume(returning: CameraReadings(
                    iso: Double(device.iso), seconds: device.exposureDuration.seconds,
                    kelvin: Double(balance?.temperature ?? 0), focus: Double(device.lensPosition),
                    tint: balance.map { Double($0.tint) }).validated)
            }
        }
    }
    /// Must run on the session queue before an engine configures its graph.
    func prepare(_ id: UUID) {
        if normal == nil {
            normal = Graph(inputs: session.inputs, outputs: session.outputs, preset: session.sessionPreset,
                formats: session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.filter { $0.hasMediaType(.video) }.map {
                    DeviceState(device: $0, format: $0.activeFormat,
                        minimum: $0.activeVideoMinFrameDuration, maximum: $0.activeVideoMaxFrameDuration,
                        colorSpace: $0.activeColorSpace, zoom: $0.videoZoomFactor,
                        automaticHDR: $0.automaticallyAdjustsVideoHDREnabled, hdr: $0.isVideoHDREnabled)
                }, connections: session.outputs.compactMap { output in
                    guard let connection = output.connection(with: .video) else { return nil }
                    return ConnectionState(output: output, angle: connection.videoRotationAngle,
                        mirrored: connection.isVideoMirrored, automaticMirroring: connection.automaticallyAdjustsVideoMirroring,
                        enabled: connection.isEnabled, stabilization: connection.preferredVideoStabilizationMode)
                }, dimensions: session.outputs.compactMap { output in
                    guard let photo = output as? AVCapturePhotoOutput else { return nil }
                    return (photo, photo.maxPhotoDimensions)
                })
        }
        lock.lock(); owner = id; reserved = true; lock.unlock()
        removeGraph()
    }
    private func removeGraph() {
        session.beginConfiguration()
        session.outputs.forEach { session.removeOutput($0) }
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
    }
    /// Stop only this owner's graph. A late cleanup can't tear down a new route.
    func release(_ id: UUID) {
        guard owns(id) else { return }
        lock.lock(); owner = nil; lock.unlock()
        // Keep the old graph until the next owner's atomic configuration, so
        // a standalone empty-graph commit cannot tear down the running pipeline.
    }
    func restoreNormal() {
        queue.async {
            self.lock.lock(); self.owner = nil; self.reserved = false; self.lock.unlock()
            guard let graph = self.normal else { return }
            self.session.beginConfiguration()
            self.removeGraph()
            self.session.sessionPreset = graph.preset
            for input in graph.inputs where self.session.canAddInput(input) { self.session.addInput(input) }
            for output in graph.outputs where self.session.canAddOutput(output) { self.session.addOutput(output) }
            for state in graph.formats {
                let device = state.device
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = state.format
                    device.activeVideoMinFrameDuration = state.minimum
                    device.activeVideoMaxFrameDuration = state.maximum
                    device.activeMaxExposureDuration = state.format.maxExposureDuration
                    if state.format.supportedColorSpaces.contains(state.colorSpace) { device.activeColorSpace = state.colorSpace }
                    device.videoZoomFactor = min(max(state.zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                    device.automaticallyAdjustsVideoHDREnabled = state.automaticHDR
                    if !state.automaticHDR, state.format.isVideoHDRSupported { device.isVideoHDREnabled = state.hdr }
                    device.unlockForConfiguration()
                } catch { /* The normal engine reports a route error if configuration cannot resume. */ }
            }
            for (output, dimensions) in graph.dimensions { output.maxPhotoDimensions = dimensions }
            for state in graph.connections {
                guard let connection = state.output.connection(with: .video) else { continue }
                if connection.isVideoRotationAngleSupported(state.angle) { connection.videoRotationAngle = state.angle }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = state.automaticMirroring
                    if !state.automaticMirroring { connection.isVideoMirrored = state.mirrored }
                }
                connection.isEnabled = state.enabled
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = state.stabilization }
            }
            self.session.commitConfiguration()
            self.normal = nil
        }
    }
    func pause() { queue.async { if self.isReserved, self.session.isRunning { self.session.stopRunning() } } }
    func pauseWhenHidden() {
        queue.async {
            self.lock.lock(); let shouldPause = self.reserved && self.owner == nil; self.lock.unlock()
            if shouldPause, self.session.isRunning { self.session.stopRunning() }
        }
    }
    func stopForLongExposureRecovery(_ id: UUID) {
        queue.async { if self.owns(id), self.session.isRunning { self.session.stopRunning() } }
    }
}
