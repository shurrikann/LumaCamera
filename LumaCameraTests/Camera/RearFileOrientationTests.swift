import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import LumaCamera

final class RearFileOrientationTests: XCTestCase {
    func testRearMovieFilesKeepAllFourDirectionsAndAllVideoRatios() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer), context = CIContext()
        context.render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360)), to: source)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:source,formatDescriptionOut:&description),noErr)
        var costs: [Double] = []
        for angle: CGFloat in [0, 90, 180, 270] {
            for ratio: FrameRatio in [.standard, .square, .wide, .panorama, .cinema] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("RearOrientation-\(UUID().uuidString).mov")
                defer { try? FileManager.default.removeItem(at: url) }
                let began = CACurrentMediaTime()
                let recorder = try MovieRecorder(url: url, sourceSize: CGSize(width:640,height:360), ratio:ratio, mirrored:false, includeAudio:false,
                    settings:VideoCaptureSettings(resolution:.hd720,frameRate:.fps30,colorSpace:.sdr,codec:.hevc), outputBaseSize:CGSize(width:640,height:360), rearCaptureRotationAngle:angle)
                for n in 0..<6 {
                    var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(n),timescale:30),decodeTimeStamp:.invalid)
                    var sample: CMSampleBuffer?
                    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:source,formatDescription:try XCTUnwrap(description),sampleTiming:&timing,sampleBufferOut:&sample),noErr)
                    recorder.appendVideo(try XCTUnwrap(sample)); try await Task.sleep(for:.milliseconds(35))
                }
                let result: Result<URL, Error> = await withCheckedContinuation { c in recorder.finish { c.resume(returning:$0) } }
                _ = try result.get()
                let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video)
                let track = try XCTUnwrap(tracks.first), size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let displayed = CGRect(origin:.zero,size:size).applying(transform)
                let expected = CaptureOrientation.rearLandscape(angle:angle) ? ratio.landscapeRatio : ratio.portraitRatio
                XCTAssertEqual(abs(displayed.width/displayed.height),expected,accuracy:0.015)
                let radians = atan2(transform.b,transform.a), actual = (radians * 180 / .pi + 360).truncatingRemainder(dividingBy:360)
                XCTAssertEqual(actual,angle,accuracy:0.01)
                let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading()); var frames = 0
                while output.copyNextSampleBuffer() != nil { frames += 1 }
                XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThanOrEqual(frames,4)
                costs.append((CACurrentMediaTime()-began)*1000)
            }
        }
        print("REAR_MOVIE_FILES count=\(costs.count) encodeDecodeWallMS=\(costs)")
    }

    func testRearPhotoCaptureAxesAndCardinalAngles() {
        for (input, expected): (CGFloat,CGFloat) in [(0,0),(89,90),(180,180),(269,270),(360,0),(-90,270)] {
            XCTAssertEqual(CaptureOrientation.cardinalAngle(input),expected)
            XCTAssertEqual(CaptureOrientation.rearLandscape(angle:input),expected == 0 || expected == 180)
        }
    }

    @MainActor func testRealRearPhotoAndMovieAtCurrentHoldingDirection() async throws {
        guard let pose = ProcessInfo.processInfo.environment["LUMA_REAR_ORIENTATION_POSE"], ["portrait","landscape"].contains(pose) else {
            throw XCTSkip("Requires user-held physical direction and explicit test environment")
        }
        let landscape = pose == "landscape"
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldPhoto = camera.onCaptureCompleted, oldVideo = camera.onVideoRecorded
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var photo: CapturedPhoto?, movie: Result<URL,Error>?
        camera.onCaptureCompleted = { photo = $0 }; camera.onVideoRecorded = { movie = $0 }
        defer { camera.stopVideoRecording(); model.setCameraActive(false); camera.onCaptureCompleted = oldPhoto; camera.onVideoRecorded = oldVideo; UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ name:String,_ p:()->Bool) async throws {
            let end=CACurrentMediaTime()+35
            while !p() && CACurrentMediaTime()<end { try await Task.sleep(for:.milliseconds(25)) }
            XCTAssertTrue(p(),name); if !p() { throw CancellationError() }
        }
        model.setCameraActive(true); try await wait("camera ready"){camera.ready && camera.preview != nil}
        model.setCaptureKind(.photo); model.setMode(.auto); model.photoFormat = .jpeg; model.photoResolution = .standard; model.ratio = .wide
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(500))
        camera.capture(flashMode:.off,options:model.photoOptions)
        try await wait("photo"){photo != nil && camera.pendingPhotoCount == 0}
        let captured = try XCTUnwrap(photo), resource = try XCTUnwrap(captured.resources.first { !$0.pairedVideo })
        let src = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil)), p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any])
        let width = try XCTUnwrap(p[kCGImagePropertyPixelWidth] as? Int), height = try XCTUnwrap(p[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(width > height,landscape); XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int,1)
        let photoShot = XCTAttachment(image:captured.preview); photoShot.name="Rear-physical-photo-\(pose)"; photoShot.lifetime = .keepAlways; add(photoShot)
        model.setCaptureKind(.video); model.videoCodec = .hevc; model.videoResolution = .hd1080; model.videoFrameRate = .fps30; model.videoColorSpace = .sdr; model.videoRatio = .ratio16x9
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"rear orientation",timeout:20)
        camera.startVideoRecording(aspect:.wide); try await wait("recording"){camera.videoRecording || movie != nil}
        try await Task.sleep(for:.milliseconds(1200)); camera.stopVideoRecording(); try await wait("movie"){movie != nil && !camera.videoBusy}
        let url = try XCTUnwrap(movie?.get()); defer {try? FileManager.default.removeItem(at:url)}
        let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video), track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform), display = CGRect(origin:.zero,size:size).applying(transform)
        XCTAssertEqual(abs(display.width) > abs(display.height),landscape)
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:1000,height:1000)
        let frame=try await generator.image(at:.zero).image
        let videoShot=XCTAttachment(image:UIImage(cgImage:frame));videoShot.name="Rear-physical-video-\(pose)";videoShot.lifetime = .keepAlways;add(videoShot)
        print("REAR_PHYSICAL pose=\(pose) devicePose=\(UIDevice.current.orientation.rawValue) photo=\(width)x\(height) videoNatural=\(size) videoTransform=\(transform) videoDisplay=\(display.size)")
    }
}
