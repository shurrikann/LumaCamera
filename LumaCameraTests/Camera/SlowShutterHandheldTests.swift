import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import LumaCamera

final class SlowShutterHandheldTests:XCTestCase {
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let extent = CGRect(x:0,y:0,width:320,height:240)
    private func scene(_ frame:Int,water:Bool)->CIImage {
        var bytes = [UInt8](repeating:255,count:320*240*4)
        for y in 0..<240 { for x in 0..<320 {
            var state = UInt64(x/19+1) &* 6364136223846793005 ^ UInt64(y/17+1) &* 1442695040888963407
            state ^= state>>23; state = state &* 2862933555777941757
            var value = UInt8(30+(state>>32)%180)
            if water && y<85 { value = UInt8(35+((x+frame*13)/7+y/4*3)%120) }
            if !water && y>35 && y<43 && x>35+frame*24 && x<43+frame*24 { value = 250 }
            for c in 0..<3 { bytes[(y*320+x)*4+c] = value }
        } }
        return CIImage(bitmapData:Data(bytes),bytesPerRow:1280,size:extent.size,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
    }
    private func error(_ a:CIImage,_ b:CIImage,rect:CGRect)->Double {
        let diff = a.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:b]).cropped(to:rect)
        return Imaging.meanLuminance(diff,context:context)
    }
    func testFlowAndLightTrailsPreserveBackgroundAcrossRotationAndRejectedFrame() throws {
        var timings = [Double]()
        for blend in [SlowShutterBlendMode.handheldAlignedAverage,.handheldAlignedLighten] {
            let composer = SlowShutterComposer(blend:blend,context:context,materializeFrames:true)
            let ordinary = SlowShutterComposer(blend:blend == .handheldAlignedAverage ? .average:.lighten,context:context,materializeFrames:true)
            let water = blend == .handheldAlignedAverage, reference = scene(0,water:water)
            for index in 0..<8 {
                let angle = index == 0 ? 0:Double(index%3-1)*1.5
                let shift = index == 0 ? 0:Double(index%3-1)*5
                let transform = CGAffineTransform(translationX:-160,y:-120)
                    .concatenating(CGAffineTransform(rotationAngle:angle * .pi/180))
                    .concatenating(CGAffineTransform(translationX:160+shift,y:120-shift/2))
                let source = scene(index,water:water).transformed(by:transform)
                    .composited(over:CIImage(color:.black).cropped(to:extent)).cropped(to:extent)
                let t = CACurrentMediaTime(); XCTAssertTrue(composer.add(source)); timings.append(CACurrentMediaTime()-t)
                XCTAssertTrue(ordinary.add(source))
                if index == 3 { XCTAssertTrue(composer.add(.empty()) == false) }
                if index == 3 { XCTAssertTrue(composer.add(reference.applyingFilter("CIColorInvert"))) }
            }
            let result = try XCTUnwrap(composer.result), unaligned = try XCTUnwrap(ordinary.result)
            let region = CGRect(x:45,y:130,width:210,height:65)
            let alignedError = error(result,reference,rect:region), rawError = error(unaligned,reference,rect:region)
            XCTAssertGreaterThanOrEqual(composer.effectiveFrameCount,5)
            XCTAssertGreaterThanOrEqual(composer.rejectedFrameCount,1,"无关画面应跳过，后续正常帧仍继续融合")
            XCTAssertLessThan(alignedError,rawError*0.70)
            if water {
                XCTAssertGreaterThan(error(result,reference,rect:CGRect(x:45,y:25,width:210,height:40)),0.003,"水流必须参与时间平均，不能只返回静态单帧")
            }
            print("SLOW-HANDHELD blend=\(blend) sources=8 effective=\(composer.effectiveFrameCount) rejected=\(composer.rejectedFrameCount) staticLinearError=\(alignedError) unaligned=\(rawError)")
        }
        timings.sort(); print("SLOW-HANDHELD-PERF samples=\(timings.count) medianSeconds=\(timings[timings.count/2]) maxSeconds=\(timings.last!) size=320x240 includesRegistrationAndRenderedCheckpoint=true notFPS=true")
    }
    func testAllPresetsPreferHandheldExposureAndKeepManualValues() throws {
        for preset in SlowShutterPreset.allCases {
            let plan = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:200,meteredSeconds:1.0/30,
                hardwareISO:50...6400,hardwareShutter:log2(1.0/64000)...0))
            XCTAssertLessThanOrEqual(plan.spec.frameExposureSeconds,preset.handheldPreferredExposure+0.0001)
            XCTAssertLessThanOrEqual(abs(log2(plan.iso*plan.spec.frameExposureSeconds/(200.0/30))),0.2)
            let manual = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:200,meteredSeconds:1.0/30,
                hardwareISO:50...6400,hardwareShutter:log2(1.0/64000)...0,manualISO:200,manualSeconds:1.0/30))
            XCTAssertEqual(manual.spec.frameExposureSeconds,1.0/30); XCTAssertEqual(manual.iso,200)
        }
    }

    func testAlignedAccumulationKeepsReferenceCanvasAndOpaqueEdgesAcrossRepeatedShifts() throws {
        let reference=scene(0,water:false)
        let shifts:[(CGFloat,CGFloat)]=[(0,0),(8,-5),(-9,6),(6,8),(-7,-6)]
        for blend in [SlowShutterBlendMode.handheldAlignedAverage,.handheldAlignedLighten] {
            let composer=SlowShutterComposer(blend:blend,context:context,materializeFrames:true)
            let started=CACurrentMediaTime()
            for index in 0..<20 {
                let shift=shifts[index%shifts.count]
                let frame=reference.clampedToExtent().transformed(by:CGAffineTransform(translationX:shift.0,y:shift.1)).cropped(to:extent)
                XCTAssertTrue(composer.add(frame))
                let result=try XCTUnwrap(composer.result)
                XCTAssertEqual(result.extent,extent,"不能逐帧缩小成片画布或依靠放大补像素")
                var pixel=[UInt8](repeating:0,count:4)
                for point in [CGPoint(x:1,y:1),CGPoint(x:318,y:1),CGPoint(x:1,y:238),CGPoint(x:318,y:238)] {
                    context.render(result,toBitmap:&pixel,rowBytes:4,bounds:CGRect(origin:point,size:CGSize(width:1,height:1)),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
                    XCTAssertEqual(pixel[3],255,"未覆盖边沿应保留已有有效像素")
                    XCTAssertGreaterThan(pixel[0],10,"不能用黑色边框凑足画布")
                }
            }
            XCTAssertGreaterThanOrEqual(composer.effectiveFrameCount,16)
            print("SLOW-CANVAS blend=\(blend) frames=20 accepted=\(composer.effectiveFrameCount) size=320x240 renderedSeconds=\(CACurrentMediaTime()-started)")
        }
    }

    func testAlignedSlowShutterEncodesEveryRatioAndOrientation() throws {
        let composer = SlowShutterComposer(blend:.handheldAlignedAverage,context:context,materializeFrames:true)
        let base = scene(0,water:true)
        XCTAssertTrue(composer.add(base))
        let shifted = scene(1,water:true).transformed(by:CGAffineTransform(translationX:5,y:-3))
            .composited(over:CIImage(color:.black).cropped(to:extent)).cropped(to:extent)
        XCTAssertTrue(composer.add(shifted)); XCTAssertEqual(composer.effectiveFrameCount,2)
        for ratio in FrameRatio.photoOptions { for landscape in [false,true] {
            let result = try PhotoEncoder.encode(source:try XCTUnwrap(composer.result),raw:nil,
                look:CaptureLook(ratio:ratio,landscape:landscape),options:PhotoOptions(format:.jpeg),context:context)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(result.resources.first?.data) as CFData,nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            XCTAssertEqual(Double(image.width)/Double(image.height),Double(landscape ? ratio.landscapeRatio:ratio.portraitRatio),accuracy:0.02)
        } }
        print("SLOW-HANDHELD-LAYOUT actualJPEGs=14 ratios=7 contentOrientations=2 noPhotosWrites=true")
    }

    func testAccumulationPreviewUsesRealBlendAndDoesNotMutateFullResolutionResult() throws {
        let composer = SlowShutterComposer(blend:.lighten,context:context,materializeFrames:true)
        var timings = [Double](), earlier:UIImage?
        for index in 0..<12 {
            XCTAssertTrue(composer.add(scene(index%8,water:false)))
            let t = CACurrentMediaTime()
            let preview = try XCTUnwrap(composer.renderPreview(look:CaptureLook(),maximumDimension:180))
            timings.append(CACurrentMediaTime()-t)
            XCTAssertLessThanOrEqual(max(preview.size.width,preview.size.height),180)
            if index == 0 { earlier = preview }
            if index == 11 {
                let a = try XCTUnwrap(CIImage(image:earlier!)), b = try XCTUnwrap(CIImage(image:preview))
                XCTAssertGreaterThan(Imaging.meanLuminance(b,context:context),Imaging.meanLuminance(a,context:context))
            }
        }
        let before = try XCTUnwrap(context.jpegRepresentation(of:try XCTUnwrap(composer.result),colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,options:[:]))
        _ = composer.renderPreview(look:CaptureLook(ratio:.square),maximumDimension:160)
        let after = try XCTUnwrap(context.jpegRepresentation(of:try XCTUnwrap(composer.result),colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,options:[:]))
        XCTAssertEqual(before,after); XCTAssertEqual(composer.effectiveFrameCount,12)
        timings.sort(); print("SLOW-ACCUMULATION-RENDER n=12 source=320x240 previewMax=180 medianSeconds=\(timings[6]) maxSeconds=\(timings.last!) resultUnchanged=true notFPS=true")
        let full = SlowShutterComposer(blend:.average,context:context,materializeFrames:true)
        XCTAssertTrue(full.add(scene(0,water:true).transformed(by:CGAffineTransform(scaleX:12.6,y:12.6))))
        var fullTimes = [Double]()
        for _ in 0..<12 {
            let t = CACurrentMediaTime()
            let size = autoreleasepool { full.renderPreview(look:CaptureLook(landscape:true))?.size }
            fullTimes.append(CACurrentMediaTime()-t)
            XCTAssertEqual(max(size?.width ?? 0,size?.height ?? 0),900,accuracy:1)
        }
        fullTimes.sort(); print("SLOW-ACCUMULATION-FULL n=12 source=4032x3024 previewMax=900 medianSeconds=\(fullTimes[6]) maxSeconds=\(fullTimes.last!) notFPS=true")
    }
}
