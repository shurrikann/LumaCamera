import XCTest
import CoreImage
@testable import LumaCamera
final class FadeWarmthTests: XCTestCase {
    func testFadeAddsCreamyYellowAndWhiteLiftWithoutChangingAlpha() throws {
        let space = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, context=CIContext()
        func pixel(_ value:CGFloat,_ strength:Double)->[Float] {
            let image=CIImage(color:CIColor(red:value,green:value,blue:value,alpha:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:4,height:4))
            var settings=FilterAdjustments();settings[.fade]=strength
            let result=FilterAdjustmentRenderer.apply(settings,to:image)
            var output=[Float](repeating:0,count:4)
            context.render(result,toBitmap:&output,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
            return output
        }
        let neutral=pixel(0.5,0),half=pixel(0.5,50),full=pixel(0.5,100)
        XCTAssertEqual(neutral[0],neutral[2],accuracy:0.001)
        XCTAssertGreaterThan(full[0],full[1]);XCTAssertGreaterThan(full[1],full[2])
        XCTAssertGreaterThan(full[0]-full[2],half[0]-half[2])
        XCTAssertEqual(half[2],(neutral[2]+full[2])/2,accuracy:0.002)
        let black=pixel(0,100)
        XCTAssertEqual(black[0],0.14,accuracy:0.003);XCTAssertEqual(black[1],0.13,accuracy:0.003);XCTAssertEqual(black[2],0.095,accuracy:0.003)
        XCTAssertLessThan(black[0],full[0]);XCTAssertLessThan(black[1],full[1]);XCTAssertLessThan(black[2],full[2])
        let paper=pixel(1,100)
        XCTAssertGreaterThan(paper[0],paper[2]);XCTAssertGreaterThan(paper[2],0.6)
        XCTAssertLessThan(paper[0]-paper[2],0.5)
        XCTAssertEqual(full[3],1,accuracy:0.001)
    }
}
