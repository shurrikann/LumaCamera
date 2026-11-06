import XCTest
import CoreImage
@testable import LumaCamera

/// 检查逐帧渲染的平均融合：静止区域不累积变亮，移动亮条留下均匀轨迹。
final class AdaptiveWaterComposerTests: XCTestCase {
    func testStreamingAveragePreservesStaticBrightnessAndMovingTrace() throws {
        let context = CIContext(options:[.cacheIntermediates:false])
        let extent = CGRect(x:0,y:0,width:320,height:240)
        let background = CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:extent)
        let composer = SlowShutterComposer(blend:.average,context:context,materializeFrames:true)
        for index in 0..<8 {
            let bar = CIImage(color:.white).cropped(to:CGRect(x:40+index*24,y:80,width:24,height:80))
            XCTAssertTrue(composer.add(bar.composited(over:background).cropped(to:extent)))
        }
        var pixels = [UInt8](repeating:0,count:320*240*4)
        context.render(try XCTUnwrap(composer.result),toBitmap:&pixels,rowBytes:320*4,
                       bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        var reference = [UInt8](repeating:0,count:4)
        context.render(background,toBitmap:&reference,rowBytes:4,bounds:CGRect(x:10,y:10,width:1,height:1),
                       format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        let staticValue = pixels[(20*320+20)*4]
        XCTAssertEqual(Double(staticValue),Double(reference[0]),accuracy:3)
        var trace = [UInt8]()
        for index in 0..<8 {
            let offset = (100*320+52+index*24)*4
            trace.append(pixels[offset])
        }
        XCTAssertTrue(trace.allSatisfy { $0 > staticValue+8 && $0 < 220 })
        XCTAssertLessThanOrEqual(Int(trace.max()!)-Int(trace.min()!),3)
        XCTAssertEqual(composer.frameCount,8)
        XCTAssertEqual(composer.result?.extent,extent)
        print("WATER-AVERAGE frames=8 size=320x240 static=\(staticValue) reference=\(reference[0]) trace=\(trace)")
    }


    func testHandheldAlignmentPreservesStaticDetailAndRejectsUnrelatedFrame() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: 640, height: 480)
        func texture(_ seed: Int) -> CIImage {
            var bytes = [UInt8](repeating: 255, count: 640 * 480 * 4)
            for y in 0..<480 {
                for x in 0..<640 {
                    let value = UInt8(((x / 3 * 37 + y / 3 * 79 + seed * 71) ^
                        (x / 5 * y / 5 * 13 + seed * 19)) & 255)
                    for channel in 0..<3 { bytes[(y * 640 + x) * 4 + channel] = value }
                }
            }
            return CIImage(bitmapData: Data(bytes), bytesPerRow: 640 * 4, size: extent.size,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        let reference = texture(3)
        let aligned = SlowShutterComposer(blend: .handheldAlignedAverage, context: context, materializeFrames: true)
        let ordinary = SlowShutterComposer(blend: .average, context: context, materializeFrames: true)
        let shifts: [(CGFloat, CGFloat)] = [(0, 0), (7, -4), (-5, 6), (10, 3)]
        let start = CACurrentMediaTime()
        for shift in shifts {
            let frame = reference.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: shift.0, y: shift.1))
                .cropped(to: extent)
            XCTAssertTrue(aligned.add(frame))
            XCTAssertTrue(ordinary.add(frame))
        }
        XCTAssertTrue(aligned.add(texture(91)))

        func difference(_ image: CIImage) throws -> Double {
            let area = CGRect(x: 80, y: 80, width: 480, height: 320)
            var pixels = [UInt8](repeating: 0, count: 480 * 320 * 4)
            let delta = image.applyingFilter("CIDifferenceBlendMode", parameters: [
                kCIInputBackgroundImageKey: reference
            ])
            context.render(delta, toBitmap: &pixels, rowBytes: 480 * 4, bounds: area,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) {
                $0 + Double(pixels[$1])
            } / Double(480 * 320)
        }

        let alignedError = try difference(XCTUnwrap(aligned.result))
        let ordinaryError = try difference(XCTUnwrap(ordinary.result))
        XCTAssertEqual(aligned.frameCount, 5)
        XCTAssertEqual(aligned.effectiveFrameCount, 4)
        XCTAssertEqual(aligned.rejectedFrameCount, 1)
        XCTAssertLessThan(alignedError, ordinaryError * 0.55)
        XCTAssertGreaterThan(aligned.result?.extent.width ?? 0, extent.width * 0.9)
        XCTAssertGreaterThan(aligned.result?.extent.height ?? 0, extent.height * 0.9)
        print("WATER-HANDHELD sources=5 accepted=\(aligned.effectiveFrameCount) rejected=\(aligned.rejectedFrameCount) alignedError=\(alignedError) ordinaryError=\(ordinaryError) seconds=\(CACurrentMediaTime()-start)")
    }
}
