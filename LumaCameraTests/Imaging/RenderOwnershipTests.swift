import CoreImage
import UIKit
import XCTest
@testable import LumaCamera

final class RenderOwnershipTests: XCTestCase {
    func testOwnedImagesPreserveSDRP3AndHDRPixelsAfterContextRelease() throws {
        for (format,space) in [(CIFormat.RGBA8,CGColorSpace.sRGB),(.RGBA16,CGColorSpace.displayP3),(.RGBAh,CGColorSpace.extendedLinearDisplayP3)] {
            let context = CIContext(options:[.cacheIntermediates:false])
            let color = try XCTUnwrap(CGColorSpace(name:space))
            let extent=CGRect(x:0,y:0,width:128,height:96)
            let source=try XCTUnwrap(CIFilter(name:"CILinearGradient",parameters:[
                "inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:128,y:96),
                "inputColor0":CIColor(red:format == .RGBAh ? 2 : 0.8,green:0.3,blue:0.1),
                "inputColor1":CIColor(red:0.1,green:0.7,blue:0.4)
            ])?.outputImage?.cropped(to:extent))
            let original = try XCTUnwrap(context.createCGImage(source,from:source.extent,format:format,colorSpace:color,deferred:false))
            let image = try XCTUnwrap(Imaging.ownedCGImage(source,from:source.extent,context:context,format:format,colorSpace:color))
            context.clearCaches()
            XCTAssertEqual(image.bitsPerComponent,original.bitsPerComponent)
            XCTAssertEqual(image.bitsPerPixel,original.bitsPerPixel)
            XCTAssertEqual(image.contentHeadroom,original.contentHeadroom)
            if #available(iOS 26.0, *) { XCTAssertEqual(image.contentAverageLightLevel,original.contentAverageLightLevel) }
            let difference=CIImage(cgImage:image).applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:CIImage(cgImage:original)])
            XCTAssertLessThan(Imaging.meanLuminance(difference,context:context),format == .RGBA8 ? 0.004:0.0001)
            XCTAssertEqual(image.colorSpace?.name,original.colorSpace?.name)
        }
    }
    func testRetainedPreviewCyclesReleaseIndependentPixelsAndMeasureCost() throws {
        let context = CIContext(options:[.cacheIntermediates:false])
        let source = CIImage(color:CIColor(red:0.7,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:900,height:675))
        var samples=[Double]()
        for _ in 0..<4 {
            try autoreleasepool {
                var held=[CGImage]()
                for _ in 0..<30 {
                    let start=CACurrentMediaTime()
                    held.append(try XCTUnwrap(Imaging.ownedCGImage(source,from:source.extent,context:context)))
                    samples.append((CACurrentMediaTime()-start)*1000)
                }
                context.clearCaches()
                XCTAssertEqual(held.count,30)
                XCTAssertEqual(held.last?.width,900)
            }
        }
        samples.sort()
        print("OWNED-RENDER n=\(samples.count) size=900x675 retainedPerCycle=30 cycles=4 medianMS=\(samples[60]) maxMS=\(samples.last!) notDisplayFPS=true")
    }
}
