import XCTest
import CoreImage
@testable import LumaCamera

final class AdaptiveSlowShutterTests: XCTestCase {
    func testEveryPresetAdaptsAcrossBrightnessAndPreservesManualExposure() throws {
        for preset in SlowShutterPreset.allCases {
            for (iso,seconds) in [(54.0,1.0/2000),(200,1.0/125),(800,1.0/30),(1600,1.0/8)] {
                let plan = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset:preset,
                    meteredISO:iso,meteredSeconds:seconds,hardwareISO:54...6400,hardwareShutter:log2(1.0/64000)...0))
                XCTAssertLessThanOrEqual(abs(log2(plan.iso*plan.spec.frameExposureSeconds/(iso*seconds))),0.2)
                XCTAssertTrue(preset.shutterSeconds.contains(plan.spec.frameExposureSeconds))
                XCTAssertGreaterThanOrEqual(plan.spec.frameCount,plan.spec.minimumFrames)
                XCTAssertEqual(plan.spec.captureDuration,preset.sequenceSpec?.captureDuration)
            }
            let manual = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset:preset,
                meteredISO:800,meteredSeconds:0.03,hardwareISO:54...6400,hardwareShutter:log2(1.0/64000)...0,
                manualISO:400,manualSeconds:1.0/125))
            XCTAssertEqual(manual.iso,400); XCTAssertEqual(manual.spec.frameExposureSeconds,1.0/125)
            XCTAssertNil(AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:.nan,
                meteredSeconds:0.03,hardwareISO:54...6400,hardwareShutter:log2(1.0/64000)...0))
        }
    }

    /// 中央主体移动、背景向相反方向移动；对齐后主体应比普通平均清楚，背景仍变化。
    func testPanningCentralAlignmentAndUnreliableFallback() throws {
        let context = CIContext(options:[.cacheIntermediates:false])
        let extent = CGRect(x:0,y:0,width:640,height:480)
        func texture(_ seed: Int) -> CIImage {
            var bytes = [UInt8](repeating:255,count:640*480*4)
            for y in 0..<480 { for x in 0..<640 {
                let value = UInt8(((x/4*37+y/4*79+seed*71) ^ (x/4*y/4*13+seed*19)) & 255)
                for channel in 0..<3 { bytes[(y*640+x)*4+channel] = value }
            } }
            return CIImage(bitmapData:Data(bytes),bytesPerRow:640*4,size:extent.size,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        }
        let subject = texture(3).cropped(to:CGRect(x:150,y:110,width:340,height:260))
        let background = texture(7)
        let composer = SlowShutterComposer(blend:.subjectAlignedAverage,context:context,materializeFrames:true)
        let ordinary = SlowShutterComposer(blend:.average,context:context,materializeFrames:true)
        var first: CIImage?
        let start = CACurrentMediaTime()
        for index in 0..<4 {
            let scene = subject.transformed(by:CGAffineTransform(translationX:CGFloat(index)*4,y:CGFloat(index)*2))
                .composited(over:background.clampedToExtent().transformed(by:CGAffineTransform(translationX:-CGFloat(index)*12,y:0))).cropped(to:extent)
            if first == nil { first = scene }
            XCTAssertTrue(composer.add(scene)); XCTAssertTrue(ordinary.add(scene))
        }
        func error(_ image: CIImage) throws -> Double {
            let area = CGRect(x:220,y:180,width:180,height:120)
            var pixels = [UInt8](repeating:0,count:180*120*4)
            let difference = image.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:try XCTUnwrap(first)])
            context.render(difference,toBitmap:&pixels,rowBytes:180*4,bounds:area,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            return stride(from:0,to:pixels.count,by:4).reduce(0.0) { $0+Double(pixels[$1]) }/Double(180*120)
        }
        let alignedError = try error(XCTUnwrap(composer.result)), ordinaryError = try error(XCTUnwrap(ordinary.result))
        XCTAssertFalse(composer.usedSingleFrameFallback)
        XCTAssertEqual(composer.effectiveFrameCount,4)
        XCTAssertLessThan(alignedError,ordinaryError*0.5)
        let fallback = SlowShutterComposer(blend:.subjectAlignedAverage,context:context,materializeFrames:true)
        XCTAssertTrue(fallback.add(texture(1))); XCTAssertTrue(fallback.add(texture(99)))
        XCTAssertTrue(fallback.usedSingleFrameFallback)
        XCTAssertEqual(fallback.frameCount,2); XCTAssertEqual(fallback.effectiveFrameCount,1)
        XCTAssertTrue(fallback.add(texture(1))); XCTAssertTrue(fallback.add(texture(1)))
        XCTAssertFalse(fallback.usedSingleFrameFallback,"一次跟踪失败不能永久取消后续有效帧的效果")
        XCTAssertEqual(fallback.effectiveFrameCount,3); XCTAssertEqual(fallback.rejectedFrameCount,1)
        print("PANNING-SYNTHETIC frames=4 size=640x480 alignedError=\(alignedError) ordinaryError=\(ordinaryError) renderAndRegistrationSeconds=\(CACurrentMediaTime()-start) recoveredSources=4 effective=\(fallback.effectiveFrameCount) rejected=\(fallback.rejectedFrameCount)")
    }
}
