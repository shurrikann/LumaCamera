@preconcurrency import AVFoundation
import CoreImage
import VideoToolbox

/// Offline processing keeps native recording frame rate independent of the LUT cost.
/// HDR/Log use a geometry-only graph; Log values are never linearised or graded.
enum VideoPostProcessor {
    static func render(url: URL, configuration: VideoConfiguration, look: CaptureLook) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoCaptureError.empty }
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        let landscape = oriented.width > oriented.height
        let size = configuration.dimensions(landscape: landscape)
        let reader = try AVAssetReader(asset: asset)
        let sourceType = configuration.color.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let video = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: sourceType])
        video.alwaysCopiesSampleData = false; reader.add(video)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-Video-"+UUID().uuidString+".mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)
        let formats = try await track.load(.formatDescriptions)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: max(4_000_000, Int(size.width*size.height)*configuration.fps/4), AVVideoExpectedSourceFrameRateKey: configuration.fps]
        if configuration.color.tenBit { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoCompressionPropertiesKey: compression, AVVideoAllowWideColorKey: true]
        if let colors = configuration.color.colorProperties { settings[AVVideoColorPropertiesKey] = colors }
        if #available(iOS 27, *), configuration.color.isLog {
            settings[AVVideoColorPropertiesKey] = [AVVideoLogTransferFunctionKey: configuration.color == .log ? AVVideoLogTransferFunction_AppleLog : AVVideoLogTransferFunction_AppleLog2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020].merging(configuration.color == .log ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020] : [:]) { a, _ in a }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: formats.first)
        guard writer.canAdd(input) else { throw VideoCaptureError.unsupported }; writer.add(input)
        let bufferType = configuration.color.tenBit ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: bufferType, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        var audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let descriptions = try await audio.load(.formatDescriptions)
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            let into = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            if reader.canAdd(out), writer.canAdd(into) { reader.add(out); writer.add(into); audioOutput = out; audioInput = into }
        }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? VideoCaptureError.encoding }
        writer.startSession(atSourceTime: .zero)
        let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: configuration.color.isLog ? NSNull() : CGColorSpace(name: configuration.color == .p3 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearSRGB)!])
        let orientation: CGImagePropertyOrientation = abs(transform.b)>0.5 ? (transform.b>0 ? .right : .left) : (transform.a<0 ? .down : .up)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = VideoExportCompletion(writer: writer, reader: reader, count: audioInput == nil ? 1 : 2, continuation: continuation)
                let queue = DispatchQueue(label: "video.export.frames", qos: .userInitiated)
                var ended = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData && !ended {
                        guard let sample = video.copyNextSampleBuffer() else { ended = true; input.markAsFinished(); completion.done(); return }
                        do {
                            try autoreleasepool {
                                guard let pixels = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { throw VideoCaptureError.encoding }
                                var buffer: CVPixelBuffer?
                                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw VideoCaptureError.encoding }
                                CVBufferPropagateAttachments(pixels, buffer)
                                CVBufferRemoveAttachment(buffer, kCVImageBufferCleanApertureKey)
                                var frame = CIImage(cvPixelBuffer: pixels, options: configuration.color.isLog ? [.colorSpace: NSNull()] : [:]).oriented(orientation)
                                if configuration.color.filtersAllowed { var frameLook = look; frameLook.grainPhase = sample.presentationTimeStamp.seconds * 127.7; frame = Imaging.filtered(frame, look: frameLook) }
                                frame = configuration.ratio.crop(frame, landscape: landscape)
                                frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
                                frame = frame.transformed(by: CGAffineTransform(scaleX: size.width/frame.extent.width, y: size.height/frame.extent.height))
                                ci.render(frame, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: configuration.color.isLog ? nil : configuration.color.outputSpace)
                                guard adaptor.append(buffer, withPresentationTime: sample.presentationTimeStamp) else { throw writer.error ?? VideoCaptureError.encoding }
                            }
                        } catch { ended = true; completion.fail(error); return }
                    }
                }
                if let out = audioOutput, let into = audioInput {
                    let audioQueue = DispatchQueue(label: "video.export.audio", qos: .userInitiated)
                    var audioEnded = false
                    into.requestMediaDataWhenReady(on: audioQueue) {
                        while into.isReadyForMoreMediaData && !audioEnded {
                            guard let sample = out.copyNextSampleBuffer() else { audioEnded = true; into.markAsFinished(); completion.done(); return }
                            if !into.append(sample) { audioEnded = true; completion.fail(writer.error ?? VideoCaptureError.encoding); return }
                        }
                    }
                }
            }
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
private final class VideoExportCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var finished = false
    let writer: AVAssetWriter
    let reader: AVAssetReader
    let continuation: CheckedContinuation<Void, Error>
    init(writer: AVAssetWriter, reader: AVAssetReader, count: Int, continuation: CheckedContinuation<Void, Error>) { self.writer = writer; self.reader = reader; remaining = count; self.continuation = continuation }
    func done() {
        lock.lock(); remaining -= 1; let last = remaining == 0 && !finished; if last { finished = true }; lock.unlock()
        if last {
            if let error = reader.error { writer.cancelWriting(); continuation.resume(throwing: error); return }
            writer.finishWriting { if self.writer.status == .completed { self.continuation.resume() } else { self.continuation.resume(throwing: self.writer.error ?? VideoCaptureError.encoding) } }
        }
    }
    func fail(_ error: Error) {
        lock.lock(); let first = !finished; finished = true; lock.unlock()
        if first { reader.cancelReading(); writer.cancelWriting(); continuation.resume(throwing: error) }
    }
}
