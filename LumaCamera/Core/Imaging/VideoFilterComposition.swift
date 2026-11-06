import AVFoundation

/// AVFoundation can return (nil, nil) while preparing a newly finalised Live movie.
/// The generated async importer force-unwraps that value. Keep the nullable callback
/// and convert it to an ordinary error instead of terminating the camera process.
enum VideoFilterComposition {
    static func make(asset: AVAsset, handler: @escaping @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void) async throws -> AVMutableVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard let track = tracks.first, duration > 0 else { throw PhotoEncodingError.encoding }
        _ = try await track.load(.formatDescriptions, .preferredTransform, .naturalSize, .timeRange)
        return try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: handler) { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else {
                    continuation.resume(throwing: error ?? PhotoEncodingError.encoding)
                }
            }
        }
    }
}
