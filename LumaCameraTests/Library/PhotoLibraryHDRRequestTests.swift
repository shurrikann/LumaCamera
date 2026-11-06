import XCTest
import Photos
@testable import LumaCamera

final class PhotoLibraryHDRRequestTests: XCTestCase {
    func testGalleryImageRequestsPreferGainMapHDR() {
        let options = SystemPhotoLibraryService.imageRequestOptions()
        XCTAssertTrue(options.preferHDR, "应用相册必须请求 HDR，否则只显示 SDR 基底")
        XCTAssertEqual(options.targetHDRHeadroom, 4.0, accuracy: 0.001)
        XCTAssertTrue(options.isNetworkAccessAllowed)
    }
}
