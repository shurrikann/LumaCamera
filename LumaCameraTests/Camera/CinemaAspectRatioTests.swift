import AVFoundation
import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import LumaCamera

final class CinemaAspectRatioTests: XCTestCase {
    func testPhotoAndVideoShareThe239Crop() throws {
        XCTAssertEqual(FrameRatio.cinema.rawValue, "2.39:1")
        XCTAssertEqual(VideoRatio.cinema.rawValue, "2.39:1")
        XCTAssertEqual(VideoRatio.cinema.frameRatio.portraitRatio, 1 / 2.39, accuracy: 0.000001)
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 900, height: 1200))
        let result = try XCTUnwrap(Imaging.render(source, look: CaptureLook(ratio: .cinema), context: CIContext()))
        XCTAssertEqual(result.size.width / result.size.height, 1 / 2.39, accuracy: 0.002)
    }

    #if !targetEnvironment(simulator)
    @MainActor func testPhoto239AndAllVideoRatiosHaveMatchingFileDimensions() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let captureCallback = camera.onCaptureCompleted, videoCallback = camera.onVideoRecorded
        let idle = UIApplication.shared.isIdleTimerDisabled
        let videoRatio = model.videoRatio
        UIApplication.shared.isIdleTimerDisabled = true
        var photo: CapturedPhoto?, video: Result<URL, Error>?
        camera.onCaptureCompleted = { photo = $0 }
        camera.onVideoRecorded = { video = $0 }
        defer {
            camera.onCaptureCompleted = captureCallback; camera.onVideoRecorded = videoCallback
            if case .success(let url) = video { try? FileManager.default.removeItem(at: url) }
            model.videoResolution = .hd1080; model.videoFrameRate = .fps30
            model.videoRatio = videoRatio
            model.setCaptureKind(.photo); model.ratio = .standard; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.setMode(.auto); model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.ratio = .cinema
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for format in [PhotoFileFormat.jpeg, .heif] {
            camera.capture(flashMode: .off, options: PhotoOptions(format: format))
            for _ in 0..<1000 { if photo != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            let captured = try XCTUnwrap(photo, camera.message ?? "Photo capture failed")
            let resource = try XCTUnwrap(captured.resources.first)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Double)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Double)
            XCTAssertEqual(max(width, height) / min(width, height), 2.39, accuracy: 0.004)
            print("PHOTO-239 \(format) \(width)x\(height)")
            photo = nil
        }
        model.setCaptureKind(.video)
        camera.setVideoSettings(.init(resolution: .hd720, frameRate: .fps25))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let began = CACurrentMediaTime()
        for position in [AVCaptureDevice.Position.back, .front] {
            if model.currentPosition != position {
                model.flipCamera()
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            }
            for ratio in VideoRatio.aspectOptions {
                model.videoRatio = ratio
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                camera.startVideoRecording(aspect: ratio.frameRatio)
                for _ in 0..<300 { if camera.videoRecording || video != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(camera.videoRecording)
                try await Task.sleep(for: .milliseconds(550))
                camera.stopVideoRecording()
                for _ in 0..<600 { if video != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                let url = try XCTUnwrap(video?.get())
                let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
                let track = try XCTUnwrap(tracks.first)
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let displayed = size.applying(transform)
                let actualAspect = abs(displayed.width / displayed.height)
                let portraitAspect = ratio.frameRatio.portraitRatio
                XCTAssertTrue(abs(actualAspect - portraitAspect) < 0.003
                              || abs(actualAspect - 1 / portraitAspect) < 0.003,
                              "显示比例 \(actualAspect) 与目标 \(portraitAspect) 的任一方向不符")
                print("VIDEO-RATIO \(position.rawValue) \(ratio.rawValue) display=\(displayed)")
                try? FileManager.default.removeItem(at: url); video = nil
            }
        }
        print("VIDEO-RATIO-MATRIX count=10 elapsed=\(CACurrentMediaTime()-began)")
        model.flipCamera()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
    }
    #endif
}
