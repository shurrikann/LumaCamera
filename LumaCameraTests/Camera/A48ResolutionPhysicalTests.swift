import XCTest
import AVFoundation
@testable import LumaCamera

final class A48ResolutionPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testManualMode48MPAndAllFormats() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted
        var photos: [CapturedPhoto] = []
        camera.onCaptureCompleted = { if let p = $0 { photos.append(p) } }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false) }
        model.setCameraActive(true)
        func wait(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(name + " " + (camera.message ?? "")); throw CancellationError()
        }
        try await wait("启动") { camera.ready }
        if model.currentPosition != .back { model.flipCamera(); try await wait("后置") { camera.ready && model.currentPosition == .back } }
        model.setCaptureKind(.photo); model.setMode(.auto)
        try await wait("48MP能力") { camera.ready && camera.availableResolutions.contains(.high) }
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 必须禁用")
        model.setMode(.manual)
        try await wait("M挡") { camera.ready && model.mode == .manual }
        XCTAssertTrue(model.canSelectPhotoResolution(.high))
        model.photoResolution = .high
        try await wait("48MP路由") { camera.ready && !camera.highResolutionPhotoConfiguring && model.photoResolution == .high && camera.availablePhotoFormats.count >= 5 }
        let config = await withCheckedContinuation { c in camera.photoOutputConfigurationForTesting { c.resume(returning: $0) } }
        print("A48-CONFIG \(config)")
        var formats: [PhotoFileFormat] = [.jpeg, .heif, .tiff, .heifPro]
        if camera.availablePhotoFormats.contains(.raw) { formats += [.raw, .rawJPEG] }
        for format in formats {
            XCTAssertTrue(model.canSelectPhotoFormat(format), "format unavailable \(format)")
            model.photoFormat = format
            try await wait("格式 \(format)") { camera.ready && model.photoFormat == format }
            let before = photos.count
            camera.capture(flashMode: .off, options: model.photoOptions)
            try await wait("出片 \(format)") { photos.count > before && camera.pendingPhotoCount == 0 }
            let shot = try XCTUnwrap(photos.last)
            XCTAssertTrue(shot.resources.contains { $0.filename.hasSuffix(".dng") } || format != .raw && format != .rawJPEG)
            let encoded = shot.resources.first { !$0.alternate }
            let source = try XCTUnwrap(encoded.flatMap { CGImageSourceCreateWithData($0.data as CFData, nil) })
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            print("A48-DECODE format=\(format) props=\(w)x\(h) cg=\(cg.width)x\(cg.height)")
            XCTAssertGreaterThan(w * h, 40_000_000, "\(format) did not deliver 48MP")
            model.photoResolution = .high
        }
        print("A48-ALL-PASS formats=\(formats.count) resolution=high")
    }
    #endif
}
