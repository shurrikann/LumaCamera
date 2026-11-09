import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Keep Apple's pairing identifier and timed metadata while applying the shutter-time look to both resources.
enum LivePhotoProcessor {
    static func pairedStill(_ resource: PhotoResource, original: Data) throws -> PhotoResource {
        guard let originalSource = CGImageSourceCreateWithData(original as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any], maker["17"] != nil,
              let source = CGImageSourceCreateWithData(resource.data as CFData, nil), let type = CGImageSourceGetType(source) else { throw PhotoEncodingError.encoding }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type, 1, nil) else { throw PhotoEncodingError.encoding }
        var output = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        output[kCGImagePropertyMakerAppleDictionary] = maker
        CGImageDestinationAddImageFromSource(destination, source, 0, output as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEncodingError.encoding }
        return PhotoResource(data: result as Data, filename: resource.filename)
    }

    static func process(_ photo: CapturedPhoto, original: Data, movie: URL, look: CaptureLook) async throws -> CapturedPhoto {
        guard let still = photo.resources.first(where: { !$0.alternate && !$0.pairedVideo }) else {
            NSLog("LIVE-FAIL stage=still resources=%d", photo.resources.count)
            throw PhotoEncodingError.encoding
        }
        let resource: PhotoResource
        do { resource = try pairedStill(still, original: original) }
        catch {
            NSLog("LIVE-FAIL stage=paired-still stillBytes=%d originalBytes=%d", still.data.count, original.count)
            throw PhotoEncodingError.encoding
        }
        let asset = AVURLAsset(url: movie)
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0, duration.seconds <= 10 else {
            NSLog("LIVE-FAIL stage=duration seconds=%.3f", duration.seconds)
            throw PhotoEncodingError.encoding
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("Live-render-" + UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition: AVMutableVideoComposition
        do {
            composition = try await VideoFilterComposition.make(asset: asset, handler: { request in
                autoreleasepool {
                    var frameLook = look
                    // Temporal grain has no stationary screen-space pattern during Live playback.
                    frameLook.grainPhase += request.compositionTime.seconds * 127.7
                    let source = request.sourceImage
                    if frameLook.border {
                        guard let image = Imaging.render(source, look: frameLook, context: context), let ci = CIImage(image: image) else {
                            request.finish(with: PhotoEncodingError.encoding); return
                        }
                        request.finish(with: ci, context: context)
                    } else {
                        let frame = frameLook.ratio.crop(Imaging.filtered(source, look: frameLook), landscape: frameLook.landscape)
                        request.finish(with: frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY)), context: context)
                    }
                }
            })
        } catch {
            NSLog("LIVE-FAIL stage=composition %@", error.localizedDescription)
            throw PhotoEncodingError.encoding
        }
        let extent = CGRect(origin: .zero, size: composition.renderSize)
        let crop = look.ratio.crop(CIImage(color: .black).cropped(to: extent), landscape: look.landscape).extent.size
        let rendered = look.border ? CGSize(width: crop.width * 1.07, height: crop.height + crop.width * 0.19) : crop
        // Video encoders require even dimensions. Scale the graph by at most one pixel.
        composition.renderSize = CGSize(width: max(2, floor(rendered.width / 2) * 2), height: max(2, floor(rendered.height / 2) * 2))
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            NSLog("LIVE-FAIL stage=exporter")
            throw PhotoEncodingError.encoding
        }
        exporter.videoComposition = composition
        exporter.metadata = try await asset.load(.metadata)
        try await exporter.export(to: outputURL, as: .mov)
        // A shared identifier alone is insufficient: the movie must retain its still-image-time track.
        let renderedAsset = AVURLAsset(url: outputURL)
        let tracks = try await renderedAsset.loadTracks(withMediaType: .metadata)
        guard !tracks.isEmpty else {
            NSLog("LIVE-FAIL stage=metadata-tracks")
            throw PhotoEncodingError.encoding
        }
        let renderedAudioTracks = try await renderedAsset.loadTracks(withMediaType: .audio)
        #if DEBUG
        NSLog("LIVE-AUDIO source tracks=%d rendered tracks=%d", sourceAudioTracks.count, renderedAudioTracks.count)
        #endif
        guard sourceAudioTracks.isEmpty || !renderedAudioTracks.isEmpty else {
            NSLog("LIVE-FAIL stage=audio source=%d rendered=%d", sourceAudioTracks.count, renderedAudioTracks.count)
            throw PhotoEncodingError.encoding
        }
        let bytes = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        guard bytes.count <= 48 * 1024 * 1024 else { throw PhotoEncodingError.encoding }
        return CapturedPhoto(preview: photo.preview,
                             resources: [resource, PhotoResource(data: bytes, filename: (resource.filename as NSString).deletingPathExtension + ".mov", pairedVideo: true)],
                             diagnostics: photo.diagnostics, location: photo.location, unfilteredOriginal: photo.unfilteredOriginal)
    }
}
