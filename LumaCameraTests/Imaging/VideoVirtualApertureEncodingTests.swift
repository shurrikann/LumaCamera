import XCTest
import AVFoundation
import CoreImage
@testable import LumaCamera

final class VideoVirtualApertureEncodingTests: XCTestCase {
    /// 直接编码合成光点并解码成片像素，证明效果不止存在于UI预览；临时文件结束即删除。
    func testPointRaysAreBakedIntoSDRAndP3MoviesAndMacroBypass() async throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!, context = CIContext(options: [.cacheIntermediates:false])
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer), extent = CGRect(x:0,y:0,width:640,height:360)
        let image = CIImage(color:.white).cropped(to:CGRect(x:317,y:177,width:6,height:6))
            .composited(over:CIImage(color:.black).cropped(to:extent))
        context.render(image, to:source, bounds:extent, colorSpace:space)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:source,formatDescriptionOut:&format),noErr)
        for (color, allowed) in [(VideoColorSpace.sdr,true),(.p3,true),(.sdr,false)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aperture-Encoded-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at:url) }
            let recorder = try MovieRecorder(url:url,sourceSize:CGSize(width:640,height:360),ratio:.wide,mirrored:false,includeAudio:false,
                settings:VideoCaptureSettings(resolution:.hd720,colorSpace:color),look:CaptureLook(virtualAperture:16))
            let begin = CACurrentMediaTime()
            for n in 0..<24 {
                var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(n),timescale:30),decodeTimeStamp:.invalid)
                var sample: CMSampleBuffer?
                XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:source,formatDescription:try XCTUnwrap(format),sampleTiming:&timing,sampleBufferOut:&sample),noErr)
                recorder.appendVideo(try XCTUnwrap(sample),virtualApertureAllowed:allowed)
                try await Task.sleep(for:.milliseconds(34))
            }
            await withCheckedContinuation { c in recorder.finish { _ in c.resume() } }
            let asset = AVURLAsset(url:url), tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first), reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0, rayEnergy = 0.0
            while let sample = output.copyNextSampleBuffer() {
                count += 1
                if count == 5, let decoded = CMSampleBufferGetImageBuffer(sample) {
                    CVPixelBufferLockBaseAddress(decoded,.readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(decoded,.readOnly) }
                    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to:UInt8.self)
                    let row = CVPixelBufferGetBytesPerRow(decoded)
                    for y in 163..<197 { for x in 303..<337 where abs(x-320)>5 || abs(y-180)>5 { rayEnergy += Double(bytes[y*row+x*4+2]) } }
                }
            }
            XCTAssertGreaterThan(count,12); XCTAssertEqual(reader.status,.completed)
            if allowed { XCTAssertGreaterThan(rayEnergy,500) } else { XCTAssertLessThan(rayEnergy,200) }
            print("VIDEO-APERTURE-ENCODE color=\(color) allowed=\(allowed) decoded=\(count) rayEnergy=\(rayEnergy) wall=\(CACurrentMediaTime()-begin) writer=\(recorder.frameCountsForTesting)")
        }
    }
}
