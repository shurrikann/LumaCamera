import XCTest
import Photos
import AVFoundation
import ImageIO
import UIKit
@testable import LumaCamera

/// Read-only inspection of recently saved resources; never saves or edits Photos assets.
final class LibrarySavedMediaDirectionTests: XCTestCase {
    @MainActor func testInspectRecentSavedPhotoAndVideoDirections() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_INSPECT_SAVED_MEDIA"] == "1" else { throw XCTSkip("Explicit read-only saved-media diagnostic only") }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            throw XCTSkip("Existing Photos read access is required; no authorization prompt")
        }
        print("SAVED_MEDIA_DEVICE orientation=\(UIDevice.current.orientation.rawValue) freshAngle=\(CaptureControlOrientation().degrees)")
        for kind: PHAssetMediaType in [.image, .video] {
            let options = PHFetchOptions(); options.fetchLimit = 3; options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let selected = ProcessInfo.processInfo.environment["LUMA_DIRECTION_ASSET_IDS"]?.split(separator: "|").map(String.init) ?? []
            let assets = selected.isEmpty ? PHAsset.fetchAssets(with: kind, options: options) : PHAsset.fetchAssets(withLocalIdentifiers: selected, options: nil)
            for index in 0..<assets.count {
                let asset = assets.object(at: index)
                guard asset.mediaType == kind else { continue }
                if kind == .image {
                    let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
                        let o = PHContentEditingInputRequestOptions(); o.isNetworkAccessAllowed = false
                        asset.requestContentEditingInput(with: o) { input, _ in continuation.resume(returning: input) }
                    }
                    var tag = -1, stored = CGSize.zero
                    if let url = input?.fullSizeImageURL, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                        tag = p[kCGImagePropertyOrientation] as? Int ?? 1
                        stored = CGSize(width: p[kCGImagePropertyPixelWidth] as? Int ?? 0, height: p[kCGImagePropertyPixelHeight] as? Int ?? 0)
                        if let decoded = UIImage(contentsOfFile: url.path) { attach(decoded, "Saved-photo-file-\(index)") }
                    }
                    let image: UIImage? = await withCheckedContinuation { continuation in
                        let o = PHImageRequestOptions(); o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = false
                        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: o) { image, _ in continuation.resume(returning: image) }
                    }
                    if let image { attach(image, "Saved-photo-Photos-preview-\(index)") }
                    print("SAVED_PHOTO index=\(index) asset=\(asset.pixelWidth)x\(asset.pixelHeight) exif=\(tag) editingOrientation=\(input?.fullSizeImageOrientation ?? 0) stored=\(stored) ui=\(String(describing:image?.size)) uiOrientation=\(image?.imageOrientation.rawValue ?? -1)")
                } else {
                    let video: AVAsset? = await withCheckedContinuation { continuation in
                        let o = PHVideoRequestOptions(); o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = false
                        PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, _ in continuation.resume(returning: av) }
                    }
                    guard let video, let track = try await video.loadTracks(withMediaType: .video).first else { continue }
                    let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                    let generator = AVAssetImageGenerator(asset: video); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1200, height: 1200)
                    let frame = try await generator.image(at: .zero).image
                    attach(UIImage(cgImage: frame), "Saved-video-display-frame-\(index)")
                    print("SAVED_VIDEO index=\(index) asset=\(asset.pixelWidth)x\(asset.pixelHeight) natural=\(size) transform=\(transform) displayed=\(CGRect(origin:.zero,size:size).applying(transform).size)")
                }
            }
        }
    }
    @MainActor private func attach(_ image: UIImage, _ name: String) {
        let scale = min(1, 1200 / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: CGSize(width:image.size.width*scale,height:image.size.height*scale), format:format).image { _ in
            image.draw(in:CGRect(x:0,y:0,width:image.size.width*scale,height:image.size.height*scale))
        }
        let attachment = XCTAttachment(image: normalized); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
