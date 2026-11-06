import XCTest
@testable import LumaCamera

final class PhotoResourceKindTests: XCTestCase {
    func testRawUTIAndCaseInsensitiveFilenameFallback() {
        XCTAssertTrue(PhotoResourceKind.isRAW(typeIdentifier: "public.camera-raw-image", filename: "photo"))
        XCTAssertTrue(PhotoResourceKind.isRAW(typeIdentifier: nil, filename: "IMG_001.DNG"))
        XCTAssertTrue(PhotoResourceKind.isRAW(typeIdentifier: nil, filename: "photo.CR3"))
        XCTAssertFalse(PhotoResourceKind.isRAW(typeIdentifier: "public.jpeg", filename: "photo.dng"))
        XCTAssertFalse(PhotoResourceKind.isRAW(typeIdentifier: "public.heic", filename: "photo.heic"))
        XCTAssertFalse(PhotoResourceKind.isRAW(typeIdentifier: nil, filename: "photo.mov"))
    }

}
