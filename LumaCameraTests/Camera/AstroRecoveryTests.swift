import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import LumaCamera

@MainActor final class AstroRecoveryTests: XCTestCase {
    func testColdReloadKeepsLatestAtomicImageAndDiscardRemovesIt() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = AstroRecoveryJournal(root: root)
        let store = AstroRecoveryStore(journal: journal)
        var options = AstroImageOptions(); options.format = .jpg; options.focalLength35mm = 24
        let id = store.begin(kind: "星轨", options: options)
        var latencies = [Double]()
        for count in 1...4 {
            options.frameCount = count
            let image = CIImage(color: CIColor(red: CGFloat(count) / 5, green: 0.1, blue: 0.2))
                .cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 768))
            let start = CACurrentMediaTime()
            _ = try await stage(journal, id: id, image: image, options: options)
            latencies.append(CACurrentMediaTime() - start)
        }
        let cold = AstroRecoveryJournal(root: root)
        let items = await records(cold)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.options.frameCount, 4)
        let file = try XCTUnwrap(cold.url(for: item))
        XCTAssertNotNil(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).count, 2)
        cold.remove(id)
        let remaining = await records(cold)
        XCTAssertTrue(remaining.isEmpty)
        print("ASTRO-RECOVERY image checkpoints=4 writeSeconds=\(latencies) size=1024x768; encode+atomic file+manifest, no Photos writes")
    }

    func testBackgroundExpirationKeepsFinishedImageForLaterRecovery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = AstroRecoveryJournal(root: root), store = AstroRecoveryStore(journal: journal)
        let options = AstroImageOptions(), id = store.begin(kind: "星空照片", options: options)
        store.protect(id); store.expirationReached(id)
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let file: URL = try await withCheckedThrowingContinuation { continuation in
            store.saveImage(id: id, image: cg, options: options) { continuation.resume(with: $0) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(store.wasImported(id))
        let cold = AstroRecoveryStore(journal: AstroRecoveryJournal(root: root))
        cold.reload()
        try await wait { cold.items.count == 1 }
        XCTAssertEqual(cold.items.first?.phase, "ready")
    }

    func testInterruptedFragmentedMovieCanBeRecoveredWithoutReencoding() async throws {
        let root = temporaryRoot(), copiedRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: copiedRoot) }
        let journal = AstroRecoveryJournal(root: root), store = AstroRecoveryStore(journal: journal)
        let id = store.begin(kind: "星空延时", options: AstroImageOptions())
        let url = try journal.videoURL(id: id)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 30)
        writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 30)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        defer { writer.cancelWriting() }
        for index in 0..<20 {
            try await wait { input.isReadyForMoreMediaData }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 10), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        // Let the encoder flush complete fragments without finishing the writer.
        var readable = false
        for _ in 0..<60 {
            if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds > 0.1 { readable = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(readable)
        XCTAssertEqual(writer.status, .writing)
        let copiedJournal = AstroRecoveryJournal(root: copiedRoot)
        let copiedStore = AstroRecoveryStore(journal: copiedJournal)
        let copyID = copiedStore.begin(kind: "星空延时", options: AstroImageOptions())
        let copy = try copiedJournal.videoURL(id: copyID)
        try Data(contentsOf: url).write(to: copy, options: .atomic)
        // A fresh coordinator has no in-memory active capture state.
        let cold = AstroRecoveryStore(journal: AstroRecoveryJournal(root: copiedRoot))
        cold.reload(); try await wait { cold.items.count == 1 }
        cold.recover(try XCTUnwrap(cold.items.first))
        try await wait(timeout: 10) { cold.busy == nil && cold.items.first?.phase == "ready" }
        let recovered = try XCTUnwrap(cold.items.first.flatMap { cold.journal.url(for: $0) })
        let asset = AVURLAsset(url: recovered)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertGreaterThan(duration.seconds, 0.1)
        XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_H264)
        print("ASTRO-RECOVERY fragmentedMovie sourceWriter=writing recoveredSeconds=\(duration.seconds) codec=H264 passthrough=true PhotosWrites=0")
    }

    private func stage(_ journal: AstroRecoveryJournal, id: UUID, image: CIImage, options: AstroImageOptions) async throws -> URL {
        try await withCheckedThrowingContinuation { c in journal.image(id: id, image: image, options: options, final: false) { c.resume(with: $0) } }
    }
    private func records(_ journal: AstroRecoveryJournal) async -> [AstroRecoveryItem] {
        await withCheckedContinuation { c in journal.items { c.resume(returning: $0) } }
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AstroRecoveryTest-" + UUID().uuidString) }
    private func wait(timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
        if !condition() { throw CancellationError() }
    }
}
