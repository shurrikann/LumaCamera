import XCTest
import CoreImage
@testable import LumaCamera

final class FilmColorLUTTests: XCTestCase {
    func testM9ReferencePNGCoordinatesSurviveConversionAndColourManagement() throws {
        XCTAssertEqual(FilmColorLUT.m9.dimension, 64)
        XCTAssertEqual(try XCTUnwrap(FilmColorLUT.m9.data).count, 4_194_304)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let samples: [([Int], [Int])] = [
            ([0,0,0],[0,0,0]), ([63,0,0],[255,0,0]),
            ([0,63,0],[78,254,79]), ([0,0,63],[0,12,246]),
            ([63,63,63],[251,251,251]), ([32,32,32],[109,109,109]),
            ([40,25,18],[154,74,48]), ([10,35,15],[17,127,40]), ([12,20,48],[28,58,188])
        ]
        for software in [false,true] {
            let context = CIContext(options:[.useSoftwareRenderer:software])
            for (input,expected) in samples {
                let colour = try XCTUnwrap(CIColor(red:CGFloat(input[0])/63,green:CGFloat(input[1])/63,
                                                   blue:CGFloat(input[2])/63,alpha:1,colorSpace:space))
                let source = CIImage(color:colour).cropped(to:CGRect(x:0,y:0,width:8,height:8))
                let result = FilmStyle.leicaM9.referenceImage(to: source)
                var bytes = [UInt8](repeating:0,count:4)
                bytes.withUnsafeMutableBytes { context.render(result,toBitmap:$0.baseAddress!,rowBytes:4,
                    bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:space) }
                for channel in 0..<3 { XCTAssertEqual(Int(bytes[channel]),expected[channel],accuracy:2,"sample \(input), software \(software)") }
                XCTAssertEqual(bytes[3],255)
            }
        }
    }
}
