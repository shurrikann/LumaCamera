import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Builds the paired still/movie resources expected by Photos for a Live Photo.
/// PhotoKit requires one asset request containing both resources; the movie also
/// carries its content ID and a still-image-time metadata sample.
enum VideoToLivePhotoService {
    struct Pair {
        let stillImage: Data
        let movieURL: URL
    }

    static func makePair(from sourceURL: URL, coverTime: Double) async throws -> Pair {
        let identifier = UUID().uuidString
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VideoEditError.invalidDuration }
        let safeCoverTime = min(max(coverTime.isFinite ? coverTime : 0, 0), max(0, duration - 1.0 / 60.0))
        let (cover, _) = try await generator.image(at: CMTime(seconds: safeCoverTime, preferredTimescale: 600))
        let still = try pairedStillData(cover, identifier: identifier)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Luma-Video-Live-" + UUID().uuidString)
            .appendingPathExtension("mov")
        do {
            try await writePairedMovie(from: asset, to: outputURL, identifier: identifier, stillTime: safeCoverTime, duration: duration)
            return Pair(stillImage: still, movieURL: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func pairedStillData(_ image: CGImage, identifier: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw VideoEditError.exportUnavailable
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VideoEditError.exportUnavailable }
        return data as Data
    }

    private static func writePairedMovie(from asset: AVAsset, to outputURL: URL, identifier: String,
                                         stillTime: Double, duration: Double) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first,
              let description = try await videoTrack.load(.formatDescriptions).first else {
            throw VideoEditError.exportUnavailable
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw VideoEditError.exportUnavailable }
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else { throw VideoEditError.exportUnavailable }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let audioDescription = try await audioTrack.load(.formatDescriptions).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioDescription)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output); writer.add(input)
                audioOutput = output; audioInput = input
            }
        }

        let stillTimeAdaptor = try makeStillTimeAdaptor()
        guard writer.canAdd(stillTimeAdaptor.assetWriterInput) else { throw VideoEditError.exportUnavailable }
        writer.add(stillTimeAdaptor.assetWriterInput)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.value = identifier as NSString
        contentID.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [contentID]

        guard writer.startWriting() else { throw writer.error ?? VideoEditError.exportUnavailable }
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? VideoEditError.exportUnavailable }
        writer.startSession(atSourceTime: .zero)

        let marker = AVMutableMetadataItem()
        marker.key = "com.apple.quicktime.still-image-time" as NSString
        marker.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        marker.value = NSNumber(value: Int8(0))
        marker.dataType = "com.apple.metadata.datatype.int8"
        let markerDuration = min(1.0 / 30.0, duration)
        let markerGroup = AVTimedMetadataGroup(items: [marker],
            timeRange: CMTimeRange(start: CMTime(seconds: min(max(stillTime, 0), max(0, duration - markerDuration)), preferredTimescale: 600),
                                   duration: CMTime(seconds: markerDuration, preferredTimescale: 600)))
        guard stillTimeAdaptor.append(markerGroup) else {
            reader.cancelReading(); writer.cancelWriting()
            throw writer.error ?? VideoEditError.exportUnavailable
        }
        stillTimeAdaptor.assetWriterInput.markAsFinished()

        let remux = LivePhotoRemuxState(reader: reader, writer: writer)
        remux.pump(output: videoOutput, input: videoInput)
        if let audioOutput, let audioInput { remux.pump(output: audioOutput, input: audioInput) }
        try await remux.finishWhenTracksComplete()
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VideoEditError.exportUnavailable
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw VideoEditError.exportUnavailable }
    }

    private static func makeStillTimeAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [String: String] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw VideoEditError.exportUnavailable }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }
}

/// AVFoundation reader/writer objects are confined to one serial queue while pumping.
/// This unchecked boundary keeps those non-Sendable framework objects inside a queue-owned
/// state object instead of capturing them individually in AVFoundation's @Sendable callbacks.
private final class LivePhotoRemuxState: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "livephoto.remux.\(UUID().uuidString)", qos: .userInitiated)
    private let group = DispatchGroup()
    private let errorLock = NSLock()
    private var appendError: Error?

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    func pump(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        group.enter()
        let track = LivePhotoTrackPump(output: output, input: input, state: self)
        input.requestMediaDataWhenReady(on: queue) { [track] in track.pumpIfReady() }
    }

    func finishWhenTracksComplete() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.notify(queue: queue) { [self] in
                if let error = recordedError {
                    continuation.resume(throwing: error)
                    return
                }
                Task {
                    do {
                        try await finishWriting()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    fileprivate func record(_ error: Error) {
        errorLock.lock()
        if appendError == nil { appendError = error }
        errorLock.unlock()
        reader.cancelReading()
        writer.cancelWriting()
    }

    fileprivate func trackFinished() { group.leave() }

    fileprivate var readerStatus: AVAssetReader.Status { reader.status }
    fileprivate var readerError: Error? { reader.error }
    fileprivate var writerError: Error? { writer.error }

    private var recordedError: Error? {
        errorLock.lock(); defer { errorLock.unlock() }
        return appendError
    }

    private func finishWriting() async throws {
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoEditError.exportUnavailable }
    }
}

/// Each input callback is delivered on the remux state's serial queue.
private final class LivePhotoTrackPump: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let state: LivePhotoRemuxState
    private var finished = false

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, state: LivePhotoRemuxState) {
        self.output = output
        self.input = input
        self.state = state
    }

    func pumpIfReady() {
        guard !finished else { return }
        while input.isReadyForMoreMediaData {
            if state.readerStatus == .failed {
                finish(with: state.readerError ?? VideoEditError.exportUnavailable)
                return
            }
            guard let sample = output.copyNextSampleBuffer() else {
                if state.readerStatus == .failed {
                    finish(with: state.readerError ?? VideoEditError.exportUnavailable)
                } else {
                    input.markAsFinished()
                    finish()
                }
                return
            }
            if !input.append(sample) {
                finish(with: state.writerError ?? VideoEditError.exportUnavailable)
                return
            }
        }
    }

    private func finish(with error: Error? = nil) {
        guard !finished else { return }
        finished = true
        if let error { state.record(error) }
        state.trackFinished()
    }
}
