import Photos
import AVFoundation
import CoreImage
import ImageIO

/// Apple's editing context retains the paired identifier, still-image time and audio.
/// Both paths render from the same original input; a static copy never alters the Live.
enum LivePhotoEditRenderer {
    struct Output {
        let output: PHContentEditingOutput
        let resources: [PhotoResource]
    }
    static func frame(_ image: CIImage, adjustments: PhotoAdjustments, time: Double) -> CIImage {
        // PhotoKit supplies upright frame images. The context orientation describes
        // fullSizeImage only; applying it to frames would swap the flip axes.
        adjustments.apply(to: image, grainPhase: time.isFinite ? time * 127.7 : 0)
    }
    static func render(input: PHContentEditingInput, adjustments: PhotoAdjustments, copy: Bool) async throws -> Output {
        guard let context = PHLivePhotoEditingContext(livePhotoEditingInput: input) else { throw PhotoDetailError.editingUnsupported }
        let orientation = context.orientation
        context.audioVolume = 1
        context.frameProcessor = { frame, _ in
            autoreleasepool { Self.frame(frame.image, adjustments: adjustments, time: frame.time.seconds) }
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.shurrikann.LumaCamera.photo-edit", formatVersion: "5", data: try JSONEncoder().encode(adjustments))
        if !copy {
            try await context.saveLivePhoto(to: output, options: nil)
            return Output(output: output, resources: [])
        }
        // Playback preparations are preview-quality, not export resources. Read the
        // original pair from the editing input and encode a full-resolution copy.
        guard let originalLive = input.livePhoto else { throw PhotoDetailError.unavailable }
        let entries = PHAssetResource.assetResources(for: originalLive)
        guard let still = entries.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
              let movie = entries.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else { throw PhotoEncodingError.encoding }
        let originalStill = try await resourceData(still)
        let movieData = try await resourceData(movie)
        let metadata = CGImageSourceCreateWithData(originalStill as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        let rendered = try PhotoEditRenderer.render(source: context.fullSizeImage.oriented(orientation), adjustments: adjustments, metadata: metadata)
        let paired = try LivePhotoProcessor.pairedStill(rendered.resource, original: originalStill)
        let dynamic = try await renderMovie(movieData, adjustments: adjustments)
        return Output(output: output, resources: [paired, PhotoResource(data: dynamic, filename: (paired.filename as NSString).deletingPathExtension + ".mov", pairedVideo: true)])
    }
    private static func renderMovie(_ bytes: Data, adjustments: PhotoAdjustments) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Live-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("source.mov"), rendered = directory.appendingPathComponent("edited.mov")
        try bytes.write(to: original)
        let asset = AVURLAsset(url: original)
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition = try await VideoFilterComposition.make(asset: asset, handler: { request in
            autoreleasepool {
                let frame = adjustments.apply(to: request.sourceImage, grainPhase: request.compositionTime.seconds * 127.7)
                request.finish(with: frame, context: context)
            }
        })
        let extent = CGRect(origin: .zero, size: composition.renderSize)
        let size = adjustments.apply(to: CIImage(color: .black).cropped(to: extent)).extent.size
        composition.renderSize = CGSize(width: max(2, floor(size.width / 2) * 2), height: max(2, floor(size.height / 2) * 2))
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw PhotoEncodingError.encoding }
        export.videoComposition = composition
        export.metadata = try await asset.load(.metadata)
        try await export.export(to: rendered, as: .mov)
        let result = AVURLAsset(url: rendered)
        let markers = try await result.loadTracks(withMediaType: .metadata)
        let originalAudio = try await asset.loadTracks(withMediaType: .audio)
        let audio = try await result.loadTracks(withMediaType: .audio)
        guard !markers.isEmpty, originalAudio.isEmpty || !audio.isEmpty else { throw PhotoEncodingError.encoding }
        return try Data(contentsOf: rendered, options: .mappedIfSafe)
    }
    private static func resourceData(_ entry: PHAssetResource) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Live-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: entry, toFile: url, options: options)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
