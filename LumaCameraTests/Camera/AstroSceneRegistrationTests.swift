import CoreImage
import XCTest
@testable import LumaCamera

final class AstroSceneRegistrationTests: XCTestCase {
    private let context = CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
    func testMatteSeparatesSkyFromCheckerboardAndAcceptsSensorRotation() throws {
        let source = scene()
        let mask = AstroSkyMatte.estimate(source,context:context)
        XCTAssertNotNil(mask.groundROI)
        XCTAssertGreaterThan(value(mask.image,at:CGPoint(x:256,y:450)),0.9)
        XCTAssertLessThan(value(mask.image,at:CGPoint(x:256,y:30)),0.1)
        let turned = source.oriented(.right)
        let rotated = AstroSkyMatte.estimate(turned,context:context)
        XCTAssertNotNil(rotated.groundROI)
        XCTAssertGreaterThan(rotated.confidence,0)
    }
    func testThinForegroundAndClearSkyAcrossSensorOrientations() {
        var scene = AstroSyntheticScene()
        scene.includesGround = true
        let frame = scene.frame(0)
        scene.includesGround = false
        let clear = scene.frame(0)
        let side = scene.extent.width
        let transforms: [CGAffineTransform] = [
            .identity,
            .init(a: 0, b: 1, c: -1, d: 0, tx: side, ty: 0),
            .init(a: -1, b: 0, c: 0, d: -1, tx: side, ty: side),
            .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: side)
        ]
        let start = ProcessInfo.processInfo.systemUptime
        for transform in transforms {
            let source = frame.transformed(by: transform)
            let matte = AstroSkyMatte.estimate(source, context: context)
            let ground = CGPoint(x: 140, y: 24).applying(transform)
            let sky = CGPoint(x: 315, y: 390).applying(transform)
            XCTAssertTrue(matte.groundROI?.contains(ground) == true)
            XCTAssertLessThan(value(matte.image, at: ground), 0.01)
            XCTAssertGreaterThan(value(matte.image, at: sky), 0.99)
            XCTAssertNil(AstroSkyMatte.estimate(clear.transformed(by: transform), context: context).groundROI)
        }
        print("ASTRO-THIN-GROUND samples=8 orientations=4 seconds=\(ProcessInfo.processInfo.systemUptime - start)")
    }

    func testSkyAndGroundReceiveSeparateTransformsWithoutLosingHDR() throws {
        let reference = scene()
        let movingSky = sky().clampedToExtent().transformed(by:CGAffineTransform(translationX:9,y:-3)).cropped(to:reference.extent)
        let movedGround = ground().transformed(by:CGAffineTransform(translationX:5,y:-3))
        let moving = bright(movedGround.composited(over:movingSky).cropped(to:reference.extent))
        let matte = AstroSkyMatte(image:gradient(), groundROI:CGRect(x:0,y:0,width:512,height:210),confidence:1)
        let registration = AstroSceneRegistration(reference:reference, context:context, matte:matte)
        let aligned = registration.align(moving)
        print("SCENE-DIAGNOSTIC \(registration.registrationDiagnostic) refStar=\(value(registration.reference,at:CGPoint(x:100,y:350))) sourceStar=\(value(reference,at:CGPoint(x:100,y:350))) refBottom=\(value(registration.reference,at:CGPoint(x:40,y:40)))")
        let error = aligned.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:reference])
        let roi = CGRect(x:40,y:40,width:400,height:130)
        let mean = error.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:roi)])
        XCTAssertLessThan(value(mean,at:.zero),0.03)
        XCTAssertGreaterThan(value(aligned,at:CGPoint(x:100,y:350)),1)
        // Trails register only the ground; they must retain celestial displacement.
        let trail = registration.stabilizeGround(moving)
        XCTAssertGreaterThan(value(trail,at:CGPoint(x:104,y:350)),value(trail,at:CGPoint(x:100,y:350)))
    }
    func testOffsetGroundROIUsesLocalCoordinates() {
        let reference = scene()
        let moving = reference.clampedToExtent().transformed(by:CGAffineTransform(translationX:5,y:-3)).cropped(to:reference.extent)
        let matte = AstroSkyMatte(image:gradient(),groundROI:CGRect(x:60,y:30,width:380,height:150),confidence:1)
        let registration = AstroSceneRegistration(reference:reference,context:context,matte:matte)
        let result = registration.stabilizeGround(moving)
        let error = result.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:reference])
        let mean = error.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:CGRect(x:80,y:50,width:300,height:100))])
        XCTAssertLessThan(value(mean,at:.zero),0.03)
    }
    func testRegistrationPerformanceAndRepeatedConstruction() {
        let reference = scene(), start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 {
            let registration = AstroSceneRegistration(reference:reference,context:context)
            let output = registration.align(reference)
            XCTAssertEqual(output.extent,reference.extent)
        }
        print("ASTRO-SCENE samples=8 pixels=512x512 seconds=\(ProcessInfo.processInfo.systemUptime-start); matte+registration graph, not FPS")
    }
    private func gradient() -> CIImage {
        CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:250),"inputPoint1":CIVector(x:0,y:270),"inputColor0":CIColor.black,"inputColor1":CIColor.white])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:512,height:512))
    }
    private func sky() -> CIImage {
        let extent = CGRect(x:0,y:0,width:512,height:512)
        var image = CIImage(color:CIColor(red:0.02,green:0.02,blue:0.02)).cropped(to:extent)
        for p in [CGPoint(x:100,y:350),CGPoint(x:200,y:440),CGPoint(x:350,y:370),CGPoint(x:400,y:460),CGPoint(x:280,y:320),CGPoint(x:50,y:460)] {
            let star = CIImage(color:CIColor(red:4,green:4,blue:4)).cropped(to:CGRect(x:p.x-2,y:p.y-2,width:5,height:5)).applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1])
            image = star.composited(over:image).cropped(to:extent)
        }
        return image
    }
    private func ground() -> CIImage {
        CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":16,"inputColor0":CIColor(red:0.08,green:0.08,blue:0.08),"inputColor1":CIColor(red:0.7,green:0.7,blue:0.7)])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:512,height:256))
    }
    private func scene() -> CIImage { bright(ground().composited(over:sky()).cropped(to:CGRect(x:0,y:0,width:512,height:512))) }
    private func bright(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:4,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:4,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:4,w:0)])
    }
    private func value(_ image: CIImage, at point: CGPoint) -> Float {
        var rgba = [Float](repeating:0,count:4)
        context.render(image,toBitmap:&rgba,rowBytes:16,bounds:CGRect(x:point.x,y:point.y,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        return rgba[1]
    }
}
