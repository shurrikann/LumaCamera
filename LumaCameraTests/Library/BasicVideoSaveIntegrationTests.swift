import AVFoundation
import Photos
import XCTest
@testable import LumaCamera

final class BasicVideoSaveIntegrationTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testMovieSavesAsPlayableVideoAndAppearsInGallery() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Simulator Photos access is required; the test never writes to a physical library")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BasicVideo-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 12), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")

        let service = SystemPhotoLibraryService()
        let id = try await withCheckedThrowingContinuation { continuation in
            service.saveVideo(at: url) { continuation.resume(with: $0) }
        }
        // iOS 27 asks for a system confirmation when a test deletes a Photos asset.
        // Keep the fixture inside the disposable test simulator instead of leaving
        // an unhandled asynchronous deletion that can block later PhotoKit writes.
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        XCTAssertEqual(asset.mediaType, .video)
        let page = await withCheckedContinuation { continuation in
            service.fetchPhotos(offset: 0, limit: 100) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(page.photos.first(where: { $0.id == id })?.isVideo, true)
        let playable = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { value, _, _ in continuation.resume(returning: value) }
        }
        XCTAssertNotNil(playable)
    }
    #endif
}
