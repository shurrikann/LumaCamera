import XCTest
import Photos
import AVFoundation
import CoreImage
import ImageIO
import UIKit
@testable import LumaCamera

final class LivePhotoEditorTests: XCTestCase {
    @MainActor func testSaveModeRoutingAndDuplicateSaveGuard() {
        var liveCopies: [Bool] = [], stillCopies = 0, replacements = 0
        var pending: ((Result<PhotoEditResult, Error>) -> Void)?
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 140))
        let session = PhotoEditSession(source: source, liveCommit: { _, copy, done in liveCopies.append(copy); pending = done }, copy: { _, done in stillCopies += 1; pending = done }) { _, done in replacements += 1; pending = done }
        let library = PhotoLibraryViewModel(service: LiveEditorLibraryStub())
        let model = PhotoEditorViewModel(session: session, library: library)
        XCTAssertTrue(session.supportsLiveEditing); XCTAssertTrue(model.preservesLive)
        model.save(asCopy: true) { _ in }; model.save(asCopy: false) { _ in }
        XCTAssertEqual(liveCopies, [true]); XCTAssertTrue(model.saving)
        pending?(.failure(PhotoDetailError.unavailable))
        XCTAssertFalse(model.saving); XCTAssertFalse(library.editing)
        model.save(asCopy: false) { _ in }; XCTAssertEqual(liveCopies, [true, false])
        pending?(.failure(PhotoDetailError.unavailable))
        model.preservesLive = false
        model.save(asCopy: false) { _ in }
        XCTAssertEqual(stillCopies, 1, "Static mode always keeps the original Live")
        XCTAssertEqual(replacements, 0)
        pending?(.failure(PhotoDetailError.unavailable))
        XCTAssertFalse(library.editing)
    }
    func testFrameGeometryMatchesStillEditorAcrossOrientationsAndCrops() {
        let raw = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        for value in 1...8 {
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(value))!
            for turns in 0...3 {
                var recipe = PhotoAdjustments(); recipe.quarterTurns = turns
                recipe.crop = PhotoCropRectangle(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
                recipe.flipHorizontal = true
                let expected = recipe.apply(to: raw.oriented(orientation))
                let actual = LivePhotoEditRenderer.frame(raw.oriented(orientation), adjustments: recipe, time: 0)
                XCTAssertEqual(actual.extent.size, expected.extent.size)
            }
        }
    }
    #if !targetEnvironment(simulator)
    /// Read an existing user's Live, render only to temporary Photos output and resources.
    /// No PHPhotoLibrary.performChanges call is allowed in diagnostics.
    @MainActor func testExistingLiveRendersCopyAndReplacementWithoutSavingToLibrary() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { throw XCTSkip("Photo access unavailable") }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0", PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoLive.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { throw XCTSkip("No existing Live to read; diagnostics must not create Photos assets") }
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { c in
            let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = true; options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input { c.resume(returning: input) } else { c.resume(throwing: info[PHContentEditingInputErrorKey] as? Error ?? PhotoDetailError.unavailable) }
            }
        }
        let original = try XCTUnwrap(PHLivePhotoEditingContext(livePhotoEditingInput: input))
        var recipe = PhotoAdjustments(); recipe.quarterTurns = 1; recipe.flipHorizontal = true
        recipe.crop = PhotoCropRectangle(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        recipe.filterAdjustments[.fade] = 45; recipe.filterAdjustments[.grainSize] = 30
        let copied = try await LivePhotoEditRenderer.render(input: input, adjustments: recipe, copy: true)
        XCTAssertEqual(copied.resources.count, 2)
        for resource in copied.resources {
            let attachment = XCTAttachment(data: resource.data, uniformTypeIdentifier: resource.pairedVideo ? "com.apple.quicktime-movie" : "public.jpeg")
            attachment.name = resource.pairedVideo ? "Live-Edited-Import.mov" : "Live-Edited-Import.jpg"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let still = try XCTUnwrap(copied.resources.first { !$0.pairedVideo }), movie = try XCTUnwrap(copied.resources.first { $0.pairedVideo })
        let source = try XCTUnwrap(CGImageSourceCreateWithData(still.data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        if let url = input.fullSizeImageURL, let originalSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let originalProperties = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any] {
            let originalRows = PhotoCaptureDiagnostics.exposureRows(properties: originalProperties)
            let copiedRows = PhotoCaptureDiagnostics.exposureRows(properties: props)
            for row in originalRows { XCTAssertTrue(copiedRows.contains(row), "Edited Live lost capture metadata: " + row.title) }
            print("LIVE-EDIT preserved capture metadata rows=\(originalRows.count)")
        }
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let extent = CIImage(cgImage: cg).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up).extent
        let expected = recipe.apply(to: original.fullSizeImage.oriented(original.orientation)).extent
        XCTAssertEqual(extent.width, expected.width, accuracy: 2, "Live copy must retain full still resolution")
        XCTAssertEqual(extent.height, expected.height, accuracy: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try movie.data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let encoded = AVURLAsset(url: url)
        let videos = try await encoded.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let naturalSize = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
        let videoSize = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        XCTAssertEqual(videoSize.width / videoSize.height, expected.width / expected.height, accuracy: 0.01)
        let duration = try await encoded.load(.duration)
        XCTAssertEqual(duration.seconds, original.duration.seconds, accuracy: 0.15)
        let metadata = try await encoded.loadTracks(withMediaType: .metadata)
        XCTAssertFalse(metadata.isEmpty)
        if let sourceAsset = input.audiovisualAsset, !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty {
            let audio = try await encoded.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audio.isEmpty)
        }
        let loader = LivePhotoPlayback()
        let playback = LivePhotoPlaybackSource(resources: copied.resources)
        loader.press(true, source: playback, size: CGSize(width: 300, height: 400))
        for _ in 0..<300 { if loader.photo != nil { break }; try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertNotNil(loader.photo, "Edited still and movie must remain a playable Live pair")
        loader.cancel()
        let replaced = try await LivePhotoEditRenderer.render(input: input, adjustments: recipe, copy: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.output.renderedContentURL.path))
        XCTAssertEqual(replaced.output.adjustmentData?.formatVersion, "5")
        let replacement = try XCTUnwrap(CIImage(contentsOf: replaced.output.renderedContentURL, options: [.applyOrientationProperty: true]))
        print("LIVE-EDIT replacement size=\(replacement.extent.size), expected=\(expected.size), video=\(videoSize)")
        XCTAssertEqual(replacement.extent.width / replacement.extent.height, expected.width / expected.height, accuracy: 0.01)
        let copiedImage = try XCTUnwrap(CIImage(data: still.data, options: [.applyOrientationProperty: true]))
        func pixels(_ image: CIImage) -> [Float] {
            let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let reduced = normalized.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 64 / image.extent.height))
            var result = [Float](repeating: 0, count: 64 * 64 * 4)
            result.withUnsafeMutableBytes { CIContext().render(reduced, toBitmap: $0.baseAddress!, rowBytes: 64 * 16, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
            return result
        }
        for (name, image) in [("copy", copiedImage), ("replacement", replacement)] {
            let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let thumbnail = normalized.transformed(by: CGAffineTransform(scaleX: 500 / normalized.extent.width, y: 500 / normalized.extent.width))
            if let cg = CIContext().createCGImage(thumbnail, from: thumbnail.extent) {
                let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "Live-Edit-" + name; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let reference = pixels(copiedImage), replacementPixels = pixels(replacement)
        let difference = zip(reference, replacementPixels).enumerated().filter { $0.offset % 4 != 3 }.map { abs($0.element.0 - $0.element.1) }.reduce(0, +) / Float(64 * 64 * 3)
        print("LIVE-EDIT copy/replacement pixel difference=\(difference)")
        XCTAssertLessThan(difference, 0.06, "Copy and replacement must preserve the same crop, flip and colour direction")
        print("LIVE-EDIT fullSize=\(extent.size), duration=\(duration.seconds), resources=\(copied.resources.map { $0.data.count })")
    }
    #endif
}
private final class LiveEditorLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("unused")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
