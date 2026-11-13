import AVFoundation
import XCTest
@testable import LumaCamera

/// 独立系统会话只用于区分 Live 源文件问题，不写入照片图库。
final class LiveNativeControlPhysicalTests: XCTestCase {
    @MainActor func testMinimalNativeLiveHasVideoTrack() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实相机")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(false)
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        let queue = DispatchQueue(label: "LiveNativeControl")
        let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
        let input = try AVCaptureDeviceInput(device: device)
        await withCheckedContinuation { c in queue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.addInput(input); session.addOutput(output)
            session.commitConfiguration()
            output.isLivePhotoCaptureEnabled = output.isLivePhotoCaptureSupported
            session.startRunning()
            c.resume()
        } }
        defer { queue.async { session.stopRunning() } }
        XCTAssertTrue(output.isLivePhotoCaptureEnabled)
        try await Task.sleep(for: .seconds(2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let done = expectation(description: "原生 Live 完成")
        let delegate = NativeLiveDelegate(done: done)
        let settings = AVCapturePhotoSettings()
        settings.livePhotoMovieFileURL = url
        queue.async { output.capturePhoto(with: settings, delegate: delegate) }
        await fulfillment(of: [done], timeout: 15)
        XCTAssertNil(delegate.error)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "最简系统会话也必须交付视频轨道")
        print("NATIVE-LIVE-CONTROL tracks=\(tracks.count) bytes=\((try? Data(contentsOf: url).count) ?? 0)")
        #endif
    }
}

private final class NativeLiveDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let done: XCTestExpectation
    var error: Error?
    init(done: XCTestExpectation) { self.done = done }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { self.error = error }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { self.error = error }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { self.error = error }
        done.fulfill()
    }
}
