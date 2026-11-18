import CoreImage
import XCTest
@testable import LumaCamera

final class AstroSignalProcessingTests: XCTestCase {
    private let context = CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
    private let extent = CGRect(x:0,y:0,width:256,height:256)
    func testDenoisePreservesCompactHDRStarsAndForeground() {
        let base = constant(0.02)
        let point = constant(1).cropped(to:CGRect(x:100,y:100,width:1,height:1))
            .applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:3,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:3,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:3,w:0)])
        let source = point.composited(over:base)
        let cleaned = AstroSignalProtection.denoise(source,iso:6400,context:context)
        XCTAssertGreaterThan(value(cleaned,x:100,y:100),2.5)
        let unchanged = AstroPostProcessor.flattenBackground(source,sky:constant(0))
        XCTAssertEqual(value(unchanged,x:100,y:100),value(source,x:100,y:100),accuracy:0.001)
    }
    func testTemporalOutliersAreCappedButSupportedStarsCanBrighten() {
        let reference = patch(0.8,x:80,y:80,width:5,height:5).composited(over:constant(0.02))
        let current = patch(0.8,x:170,y:170,width:1,height:1).composited(over:patch(1,x:80,y:80,width:5,height:5).composited(over:constant(0.02)))
        let cleaned = AstroSignalProtection.temporalClean(current,reference:reference,noise:0.002,sky:constant(1))
        XCTAssertLessThan(value(cleaned,x:170,y:170),0.06)
        XCTAssertGreaterThan(value(cleaned,x:82,y:82),0.9)
    }
    func testQualityRejectsBlurAndReplacesWeakEarlyReference() {
        var gate = AstroFrameQualityGate()
        XCTAssertEqual(gate.consider(.init(median:0.1,noise:0.01,detail:1)),.accept)
        XCTAssertEqual(gate.consider(.init(median:0.1,noise:0.01,detail:0.1)),.reject)
        XCTAssertEqual(gate.consider(.init(median:0.1,noise:0.01,detail:2)),.replaceReference)
    }
    func testTemporalToneDampsAlternatingExposureAndRetainsHDR() {
        var tone = AstroTemporalTone(), output = [Double]()
        for i in 0..<20 {
            let level = i.isMultiple(of:2) ? 0.1 : 0.2
            output.append(Double(value(tone.process(constant(level),context:context),x:120,y:120)))
        }
        let before = Double(value(constant(0.2),x:1,y:1)-value(constant(0.1),x:1,y:1))
        XCTAssertLessThan((output.max()!-output.min()!),before*0.9)
        tone = AstroTemporalTone()
        let hdr = constant(1).applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:3,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:3,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:3,w:0)])
        XCTAssertGreaterThan(value(tone.process(hdr,context:context),x:120,y:120),2)
    }
    func testElongatedNewTrackIsRemovedWithoutRemovingPointStars() {
        let reference = patch(1,x:40,y:160,width:3,height:3).composited(over:constant(0.02))
        let current = patch(1,x:80,y:100,width:90,height:2).composited(over:reference)
        let cleaned = AstroTransientTracks.clean(current,previous:reference,sky:constant(1),context:context)
        XCTAssertLessThan(value(cleaned,x:120,y:100),0.1)
        XCTAssertGreaterThan(value(cleaned,x:41,y:161),0.8)
        let protected = AstroTransientTracks.clean(current,previous:reference,sky:constant(0),context:context)
        XCTAssertGreaterThan(value(protected,x:120,y:100),0.8)
    }
    func testTrailGapFollowsObservedDirectionAndProtectsGround() {
        var motion = AstroTrailMotion()
        var stars = constant(0.02)
        for p in [CGPoint(x:30,y:40),CGPoint(x:80,y:160),CGPoint(x:150,y:70),CGPoint(x:200,y:200),CGPoint(x:40,y:210)] {
            stars = patch(1,x:p.x,y:p.y,width:3,height:3).composited(over:stars)
        }
        for t in 0..<12 {
            motion.observe(stars.transformed(by:CGAffineTransform(translationX:Double(t)*2,y:0)).cropped(to:extent),
                sky:constant(1),time:Double(t),context:context)
        }
        XCTAssertGreaterThan(motion.velocity.x,1.5)
        XCTAssertLessThan(abs(motion.velocity.y),0.1)
        let broken = patch(1,x:80,y:100,width:10,height:3).composited(over:
            patch(1,x:92,y:100,width:10,height:3).composited(over:constant(0.02)))
        XCTAssertGreaterThan(value(motion.fill(broken,sky:constant(1)),x:90,y:101),0.8)
        XCTAssertLessThan(value(motion.fill(broken,sky:constant(0)),x:90,y:101),0.1)
        XCTAssertLessThan(value(motion.fill(broken,sky:constant(1)),x:90,y:106),0.1)
        XCTAssertLessThan(value(AstroTrailMotion().fill(broken,sky:constant(1)),x:90,y:101),0.1)
    }
    func testFrameAdmissionIsBoundedAndCanBeReused() {
        let gate = AstroFrameAdmission()
        for _ in 0..<1000 { XCTAssertTrue(gate.begin()); XCTAssertFalse(gate.begin()); gate.end() }
    }
    func testNoiseVarianceFallsWithoutLosingHDRStar() {
        var state: UInt64 = 41, rgba = [Float](repeating:1,count:256*256*4)
        for i in 0..<256*256 {
            state = state &* 6364136223846793005 &+ 1
            let noise = (Float((state >> 32) & 65535)/65535-0.5)*0.02
            for c in 0..<3 { rgba[i*4+c] = 0.04+noise }
        }
        for y in 99...101 { for x in 99...101 { for c in 0..<3 { rgba[(y*256+x)*4+c] = 3 } } }
        let image = CIImage(bitmapData:Data(bytes:rgba,count:rgba.count*4),bytesPerRow:256*16,
            size:CGSize(width:256,height:256),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        let result = AstroSignalProtection.denoise(image,iso:6400,context:context)
        func variance(_ image: CIImage) -> Double {
            var pixels = [Float](repeating:0,count:64*64*4)
            context.render(image,toBitmap:&pixels,rowBytes:64*16,bounds:CGRect(x:140,y:140,width:64,height:64),format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            return (0..<64*64).reduce(0.0) { $0+pow(Double(pixels[$1*4+1])-0.04,2) }/4096
        }
        let before = variance(image), after = variance(result)
        XCTAssertLessThan(after,before*0.9)
        // Bitmap rows are top-down; CIImage coordinates are bottom-up.
        XCTAssertGreaterThan(value(image,x:100,y:155),2.9)
        XCTAssertGreaterThan(value(result,x:100,y:155),2.5)
        print("ASTRO-NOISE syntheticLinearFlat=64x64 beforeMSE=\(before) afterMSE=\(after) HDRstar=\(value(result,x:100,y:155))")
    }
    func testProcessingPerformance() {
        let source = patch(1,x:100,y:100,width:5,height:5).composited(over:constant(0.02))
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            let result = AstroSignalProtection.denoise(source,iso:3200,context:context)
            XCTAssertNotNil(context.createCGImage(result,from:extent))
        }
        print("ASTRO-SIGNAL samples=12 pixels=256x256 seconds=\(ProcessInfo.processInfo.systemUptime-start); analysis+GPU materialization, not FPS")
    }
    private func constant(_ v: CGFloat) -> CIImage { CIImage(color:CIColor(red:v,green:v,blue:v)).cropped(to:extent) }
    private func patch(_ v: CGFloat,x:CGFloat,y:CGFloat,width:CGFloat,height:CGFloat) -> CIImage {
        CIImage(color:CIColor(red:v,green:v,blue:v)).cropped(to:CGRect(x:x,y:y,width:width,height:height))
    }
    private func value(_ image: CIImage,x:CGFloat,y:CGFloat) -> Float {
        var rgba = [Float](repeating:0,count:4)
        context.render(image,toBitmap:&rgba,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        return rgba[1]
    }
}
