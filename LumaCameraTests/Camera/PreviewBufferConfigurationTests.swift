import XCTest
@testable import LumaCamera

final class PreviewBufferConfigurationTests: XCTestCase {
    func testActiveFormatsRetainExactAspectAndStayWithinProcessingBudget() throws {
        for (width,height) in [(4032,3024),(1920,1440),(1920,1080),(4224,2376),(1280,720),(640,480),(720,1280)] {
            let result = try XCTUnwrap(PreviewBufferConfiguration.dimensions(width:width,height:height))
            XCTAssertEqual(result.width*height,result.height*width)
            XCTAssertLessThanOrEqual(max(result.width,result.height),1280)
            XCTAssertLessThanOrEqual(result.width,width); XCTAssertLessThanOrEqual(result.height,height)
            XCTAssertEqual(result.width % 2,0); XCTAssertEqual(result.height % 2,0)
        }
    }
    func testInvalidAndUnrepresentableSizesDoNotRequestIllegalBufferDimensions() {
        XCTAssertNil(PreviewBufferConfiguration.dimensions(width:0,height:720))
        XCTAssertNil(PreviewBufferConfiguration.dimensions(width:4031,height:3023))
    }
}
