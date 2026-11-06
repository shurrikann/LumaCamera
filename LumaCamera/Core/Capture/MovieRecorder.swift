import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox

/// 按输入时间间隔抽帧，并为输出帧分配连续、匀速播放的时间戳。
/// 抽帧在滤镜渲染前完成，降低延时录像的图像处理负载。
struct TimeLapseFrameScheduler {
    let intervalSeconds: TimeInterval
    let frameRate: Int32
    let maxFrames: Int?
    private(set) var sourceOrigin: CMTime?
    private var lastAcceptedSourceSeconds: TimeInterval?
    private(set) var acceptedFrameCount: Int64 = 0
    var reachedLimit: Bool { maxFrames.map { acceptedFrameCount >= Int64($0) } ?? false }

    init?(intervalSeconds: TimeInterval, frameRate: Int, maxFrames: Int? = nil) {
        guard intervalSeconds.isFinite, intervalSeconds > 0,
              frameRate > 0, frameRate <= Int(Int32.max), maxFrames.map({ $0 > 0 }) ?? true else { return nil }
        self.intervalSeconds = intervalSeconds
        self.frameRate = Int32(frameRate)
        self.maxFrames = maxFrames
    }

    mutating func outputPresentationTime(for sourceTime: CMTime) -> CMTime? {
        let sourceSeconds = CMTimeGetSeconds(sourceTime)
        guard !reachedLimit, sourceTime.isValid, !sourceTime.isIndefinite, sourceSeconds.isFinite else { return nil }

        if sourceOrigin == nil {
            sourceOrigin = sourceTime
            lastAcceptedSourceSeconds = sourceSeconds
            acceptedFrameCount = 1
            return sourceTime
        }

        guard let lastAcceptedSourceSeconds,
              sourceSeconds - lastAcceptedSourceSeconds >= intervalSeconds - 0.002 else { return nil }
        guard let sourceOrigin else { return nil }

        let outputOffset = CMTime(value: acceptedFrameCount, timescale: frameRate)
        acceptedFrameCount += 1
        self.lastAcceptedSourceSeconds = sourceSeconds
        return CMTimeAdd(sourceOrigin, outputOffset)
    }
}

/// 将设备支持的高帧率采集帧按所选播放帧率连续排入时间轴，从而形成慢动作片段。
/// 每一帧都保留，声音轨道由录制入口关闭，避免声音与重排后的画面不同步。
struct SlowMotionFrameScheduler {
    let playbackFrameRate: Int32
    private(set) var sourceOrigin: CMTime?
    private var lastSourceSeconds: TimeInterval?
    private(set) var acceptedFrameCount: Int64 = 0

    init?(playbackFrameRate: Int, captureFrameRate: Int) {
        guard playbackFrameRate > 0, captureFrameRate > playbackFrameRate,
              playbackFrameRate <= Int(Int32.max), captureFrameRate <= Int(Int32.max) else { return nil }
        self.playbackFrameRate = Int32(playbackFrameRate)
    }

    mutating func outputPresentationTime(for sourceTime: CMTime) -> CMTime? {
        let seconds = CMTimeGetSeconds(sourceTime)
        guard sourceTime.isValid, !sourceTime.isIndefinite, seconds.isFinite else { return nil }
        if sourceOrigin == nil {
            sourceOrigin = sourceTime
            lastSourceSeconds = seconds
            acceptedFrameCount = 1
            return sourceTime
        }
        guard let lastSourceSeconds, seconds > lastSourceSeconds,
              let sourceOrigin else { return nil }
        let offset = CMTime(value: acceptedFrameCount, timescale: playbackFrameRate)
        acceptedFrameCount += 1
        self.lastSourceSeconds = seconds
        return CMTimeAdd(sourceOrigin, offset)
    }
}

/// Writes captured video/audio directly at the cropped output size. The camera
/// keeps delivering its native 16:9 buffers; AVFoundation's resize-aspect-fill
/// mode performs the center crop while encoding, so no second encode is needed.
final class MovieRecorder {
    // Creation, append and finish are confined to CameraEngine.recordingQueue.
    var onStarted: (() -> Void)?
    var onFailure: (() -> Void)?
    enum RecorderError: LocalizedError {
        case cannotStart(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotStart(let message): return message
            case .writeFailed(let message): return message
            }
        }
    }

    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    #if DEBUG
    private var receivedFrameCount = 0
    private var writtenFrameCount = 0
    private var notReadyFrameCount = 0
    private var rejectedFrameCount = 0
    private var unscheduledFrameCount = 0
    private var pressureSampleTimes: [Double] = []
    private var firstReceivedTime: CMTime?
    private var lastReceivedTime: CMTime?
    var frameCountsForTesting: (received: Int, written: Int, span: Double) {
        let span = firstReceivedTime.flatMap { first in lastReceivedTime.map { ($0-first).seconds } } ?? 0
        return (receivedFrameCount,writtenFrameCount,span)
    }
    #endif
    private var hasWrittenVideo = false
    private var firstVideoTime: CMTime?
    private var finished = false
    private let externalRecordingAccess: ExternalVideoStorage.RecordingAccess?
    private let rawCapture: Bool
    private var filterLook: CaptureLook?
    private let filterColorSpace: CGColorSpace?
    private let logLUTCube: LogLUTCube?
    private let frameFilterRenderer = VideoFrameFilterRenderer()
    private var filterFrameCounter: UInt64 = 0
    private var timeLapseScheduler: TimeLapseFrameScheduler?
    private var slowMotionScheduler: SlowMotionFrameScheduler?
    var onTimeLapseLimitReached: (() -> Void)?
    var onTimeLapseFrameAccepted: ((Int) -> Void)?
    private var timeLapseLimitNotified = false
    deinit { externalRecordingAccess?.stop() }

    init(url: URL, sourceSize: CGSize, ratio: FrameRatio, mirrored: Bool, includeAudio: Bool,
         settings: VideoCaptureSettings = VideoCaptureSettings(), pixelFormat: OSType = kCVPixelFormatType_32BGRA,
         metadata: [AVMetadataItem] = [], outputBaseSize: CGSize? = nil,
         rawSettings: [String: Any]? = nil,
         externalRecordingAccess: ExternalVideoStorage.RecordingAccess? = nil,
         look: CaptureLook = CaptureLook(),
         logLUTCube: LogLUTCube? = nil, timeLapseInterval: TimeInterval? = nil,
         timeLapseFrameLimit: Int? = nil,
         nativeCaptureRotationAngle: CGFloat? = nil,
         rearCaptureRotationAngle: CGFloat? = nil) throws {
        self.url = url
        self.externalRecordingAccess = externalRecordingAccess
        guard !settings.isRAW || externalRecordingAccess != nil else {
            throw RecorderError.cannotStart("外接存储访问已失效，请重新连接后再试。")
        }
        rawCapture = settings.isRAW
        guard timeLapseInterval == nil || settings.captureFrameRate == nil else {
            throw RecorderError.cannotStart("延时摄影与慢动作不能同时使用。")
        }
        if let timeLapseInterval {
            guard !settings.isRAW else {
                throw RecorderError.cannotStart("ProRes RAW 保留原始帧时间戳，暂不支持延时摄影。")
            }
            guard let scheduler = TimeLapseFrameScheduler(intervalSeconds: timeLapseInterval,
                                                          frameRate: settings.frameRate.rawValue,
                                                          maxFrames: timeLapseFrameLimit) else {
                throw RecorderError.cannotStart("延时摄影的采样间隔无效。")
            }
            timeLapseScheduler = scheduler
        } else {
            timeLapseScheduler = nil
        }
        if let captureFrameRate = settings.captureFrameRate {
            guard !settings.isRAW, !includeAudio,
                  let scheduler = SlowMotionFrameScheduler(playbackFrameRate: settings.frameRate.rawValue,
                                                          captureFrameRate: captureFrameRate.rawValue) else {
                throw RecorderError.cannotStart("当前慢动作采集设置无效。")
            }
            slowMotionScheduler = scheduler
        } else {
            slowMotionScheduler = nil
        }
        let colorSpace: CGColorSpace? = switch settings.colorSpace {
        case .sdr: CGColorSpace(name: CGColorSpace.sRGB)
        case .p3: CGColorSpace(name: CGColorSpace.displayP3)
        default: nil
        }
        guard look.virtualAperture == nil || (!settings.isRAW && colorSpace != nil) else {
            throw RecorderError.cannotStart("虚拟光圈仅支持可处理的SDR或P3视频。")
        }
        let appliesFilter = !settings.isRAW && colorSpace != nil && look.requiresImageProcessing
        filterLook = appliesFilter ? look : nil
        filterColorSpace = appliesFilter ? colorSpace : nil
        self.logLUTCube = !settings.isRAW && settings.colorSpace.isLog && filterLook == nil ? logLUTCube : nil
        try? FileManager.default.removeItem(at: url)

        let sourceIsPortrait = nativeCaptureRotationAngle != nil || sourceSize.height >= sourceSize.width
        let baseSize = outputBaseSize ?? sourceSize
        let displayLandscape = rearCaptureRotationAngle.map { CaptureOrientation.rearLandscape(angle: $0) } ?? false
        let displaySize = displayLandscape
            ? CGSize(width: max(baseSize.width, baseSize.height), height: min(baseSize.width, baseSize.height))
            : CGSize(width: min(baseSize.width, baseSize.height), height: max(baseSize.width, baseSize.height))
        let portraitAspect = settings.isRAW || ratio == .openGate
            ? min(sourceSize.width, sourceSize.height) / max(sourceSize.width, sourceSize.height)
            : ratio.portraitRatio
        let targetAspect = displayLandscape ? 1 / portraitAspect : portraitAspect
        var displayWidth = displaySize.width
        var displayHeight = displaySize.height
        if displayWidth / displayHeight > targetAspect {
            displayWidth = displayHeight * targetAspect
        } else {
            displayHeight = displayWidth / targetAspect
        }
        displayWidth = max(2, (displayWidth / 2).rounded() * 2)
        displayHeight = max(2, (displayHeight / 2).rounded() * 2)

        // AVAssetWriter expects buffers in their source orientation. A landscape
        // source is rotated by the track transform, so its encoded size is the
        // display crop with width/height swapped.
        let outputSize: CGSize
        if let angle = rearCaptureRotationAngle {
            outputSize = CaptureOrientation.rearLandscape(angle: angle)
                ? CGSize(width: displayWidth, height: displayHeight)
                : CGSize(width: displayHeight, height: displayWidth)
        } else {
            outputSize = sourceIsPortrait
                ? CGSize(width: displayWidth, height: displayHeight)
                : CGSize(width: displayHeight, height: displayWidth)
        }

        var transform = CGAffineTransform.identity
        if let angle = rearCaptureRotationAngle ?? nativeCaptureRotationAngle {
            // 使用官方RotationCoordinator在录制开始时的方向；整段轨道保持固定，
            // 不按新传感器缓冲宽高推断内容方向，也不增加逐帧软件旋转或二次编码。
            transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            let bounds = CGRect(origin:.zero,size:outputSize).applying(transform)
            transform = transform.concatenating(CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY))
        } else if !sourceIsPortrait {
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: outputSize.height, ty: 0)
        }
        if mirrored {
            let displayWidth = CGRect(origin:.zero,size:outputSize).applying(transform).width
            transform = transform.concatenating(
                CGAffineTransform(translationX: displayWidth, y: 0).scaledBy(x: -1, y: 1))
        }

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        // 慢动作文件按播放帧率排列PTS，但编码器实时收到的是120/240帧，需按真实输入预算配置。
        // 此官方键只提供编码提示，不改写由PTS决定的成片播放帧率。
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: (settings.captureFrameRate ?? settings.frameRate).rawValue]
        if settings.codec != .proRes {
            if let bitRate = settings.writerAverageBitRate {
                compression[AVVideoAverageBitRateKey] = bitRate
            }
            compression[AVVideoProfileLevelKey] = settings.codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : settings.colorSpace.profile
        }
        if settings.colorSpace == .hdr {
            // HLG/BT.2020 与 10-bit Main10 是 Dolby Vision 8.4 写入的基础条件；
            // Auto 仅在采集帧带有系统 HDR 元数据且编码器支持时插入动态元数据。
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
            if #available(iOS 26.0, *) {
                compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = kCFBooleanTrue
            }
        }
        let videoSettings: [String: Any] = rawSettings ?? [
            AVVideoCodecKey: settings.avCodec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: settings.colorSpace.encodingColorProperties,
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.cannotStart("当前设备不支持此色彩空间与编码组合。")
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // 慢动作提交的是放慢后的媒体时间轴。此路径实测实时提示会持续反压，
        // 因而仅对重定时输入关闭该提示；普通/RAW录像仍保持实时输入。
        // 不增加应用层积压队列，成片仍由同一写入器一次编码。
        videoInput.expectsMediaDataInRealTime = settings.captureFrameRate == nil
        videoInput.transform = transform
        videoAdaptor = settings.isRAW ? nil : AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: filterLook == nil ? pixelFormat : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(sourceSize.width),
                kCVPixelBufferHeightKey as String: Int(sourceSize.height)
            ])
        guard writer.canAdd(videoInput) else {
            throw RecorderError.cannotStart("无法添加视频写入轨道。")
        }
        writer.add(videoInput)

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw RecorderError.cannotStart(writer.error?.localizedDescription ?? "无法开始视频写入。")
        }
    }

    /// Keep the recording look in sync with live preview edits such as the
    /// virtual aperture slider. Only valid when the writer was configured
    /// with an image-processing look at start.
    func updateLook(_ look: CaptureLook) {
        guard filterLook != nil, !rawCapture, filterColorSpace != nil else { return }
        filterLook = look
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, virtualApertureAllowed: Bool = true) {
        if writer.status == .failed { reportFailure(); return }
        guard !finished, writer.status == .writing, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        #if DEBUG
        receivedFrameCount += 1
        if firstReceivedTime == nil { firstReceivedTime = sourceTime }
        lastReceivedTime = sourceTime
        #endif
        guard sourceTime.isValid, !sourceTime.isIndefinite else { return }
        guard videoInput.isReadyForMoreMediaData else {
            #if DEBUG
            notReadyFrameCount += 1
            if pressureSampleTimes.count < 12, let firstReceivedTime { pressureSampleTimes.append((sourceTime-firstReceivedTime).seconds) }
            #endif
            return
        }
        let presentationTime: CMTime
        var acceptedTimeLapseScheduler: TimeLapseFrameScheduler?
        if var scheduler = timeLapseScheduler {
            // 不合采样间隔的帧在滤镜和编码之前丢弃；成片时间轴按选择帧率连续排列。
            guard let scheduledTime = scheduler.outputPresentationTime(for: sourceTime) else { return }
            acceptedTimeLapseScheduler = scheduler
            presentationTime = scheduledTime
        } else if var scheduler = slowMotionScheduler {
            // 按输出帧率放慢媒体时间轴；采集样本按设备实际高帧率到达。
            guard let scheduledTime = scheduler.outputPresentationTime(for: sourceTime) else {
                #if DEBUG
                unscheduledFrameCount += 1
                #endif
                return
            }
            slowMotionScheduler = scheduler
            presentationTime = scheduledTime
        } else {
            presentationTime = sourceTime
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: sourceTime)
            firstVideoTime = sourceTime
            sessionStarted = true
        }
        var outputBuffer = pixelBuffer
        if let logLUTCube {
            guard let videoAdaptor, let pool = videoAdaptor.pixelBufferPool else { reportFailure(); return }
            var filteredBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &filteredBuffer) == kCVReturnSuccess,
                  let filteredBuffer else { reportFailure(); return }
            frameFilterRenderer.renderLogLUT(source: pixelBuffer, destination: filteredBuffer, cube: logLUTCube)
            outputBuffer = filteredBuffer
        } else if let filterLook {
            guard let videoAdaptor, let pool = videoAdaptor.pixelBufferPool, let filterColorSpace else {
                reportFailure()
                return
            }
            var filteredBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &filteredBuffer) == kCVReturnSuccess,
                  let filteredBuffer else {
                reportFailure()
                return
            }
            filterFrameCounter &+= 1
            let phase = Double((filterFrameCounter &* 73) % 4093)
            // A挡系统自动微距时由超广角供图，暂停星芒但保持同一编码流程；回主摄后恢复。
            var frameLook = filterLook
            if !virtualApertureAllowed { frameLook.virtualAperture = nil }
            frameFilterRenderer.render(source: pixelBuffer, destination: filteredBuffer, look: frameLook,
                                       colorSpace: filterColorSpace, grainPhase: phase)
            outputBuffer = filteredBuffer
        }
        let appended = rawCapture ? videoInput.append(sampleBuffer) : (videoAdaptor?.append(outputBuffer, withPresentationTime: presentationTime) ?? false)
        // 只有编码器真正接受的帧才计入张数；写入失败不能提前结束有限张数延时。
        if appended, let scheduler = acceptedTimeLapseScheduler { timeLapseScheduler = scheduler }
        #if DEBUG
        if appended { writtenFrameCount += 1 }
        else { rejectedFrameCount += 1 }
        #endif
        if appended, !hasWrittenVideo {
            hasWrittenVideo = true
            let started = onStarted; onStarted = nil
            started?()
        }
        if let scheduler = timeLapseScheduler {
            onTimeLapseFrameAccepted?(Int(scheduler.acceptedFrameCount))
            if scheduler.reachedLimit, !timeLapseLimitNotified {
                timeLapseLimitNotified = true
                onTimeLapseLimitReached?()
            }
        }
        if writer.status == .failed { reportFailure() }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        if writer.status == .failed { reportFailure(); return }
        guard !finished, sessionStarted, writer.status == .writing, let audioInput else { return }
        if let firstVideoTime, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) < firstVideoTime { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
        if writer.status == .failed { reportFailure() }
    }

    private func reportFailure() {
        let failed = onFailure; onFailure = nil
        failed?()
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finished else { return }
        finished = true
        #if DEBUG
        let span = firstReceivedTime.flatMap { first in lastReceivedTime.map { CMTimeGetSeconds($0 - first) } } ?? 0
        print("MOVIE-INPUT received=\(receivedFrameCount) written=\(writtenFrameCount) span=\(span) deliveredFPS=\(span > 0 ? Double(max(0, receivedFrameCount - 1)) / span : 0)")
        print("MOVIE-PRESSURE notReady=\(notReadyFrameCount) appendRejected=\(rejectedFrameCount) unscheduled=\(unscheduledFrameCount) firstDropOffsets=\(pressureSampleTimes)")
        #endif
        onStarted = nil
        onFailure = nil
        guard writer.status == .writing else {
            try? FileManager.default.removeItem(at: url)
            externalRecordingAccess?.stop()
            completion(.failure(RecorderError.writeFailed(writer.error?.localizedDescription ?? "视频写入失败。")))
            return
        }
        guard hasWrittenVideo else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            externalRecordingAccess?.stop()
            completion(.failure(CancellationError()))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [url] in
            // 写入器关闭文件后、通知 Files 或界面录制已完成前，释放 AVFoundation 安全作用域。
            self.externalRecordingAccess?.stop()
            switch self.writer.status {
            case .completed:
                completion(.success(url))
            case .cancelled:
                try? FileManager.default.removeItem(at: url)
                completion(.failure(RecorderError.writeFailed("视频写入已取消。")))
            default:
                try? FileManager.default.removeItem(at: url)
                completion(.failure(RecorderError.writeFailed(
                    self.writer.error?.localizedDescription ?? "视频写入失败。")))
            }
        }
    }
}
