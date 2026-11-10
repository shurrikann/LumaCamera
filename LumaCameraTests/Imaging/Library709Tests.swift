import XCTest
import CoreImage
@testable import LumaCamera

final class Library709Tests: XCTestCase {
    func testImportedLibraryIsDeduplicatedAndClassified() throws {
        XCTAssertEqual(Library709.entries.count, 208)
        XCTAssertEqual(Set(Library709.entries.map(\.style)).count, 208)
        XCTAssertEqual(ImportedFilterCatalog.entries.count, 253)
        XCTAssertEqual(Set(FilmStyle.availableStyles).count, 256)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .street }.count, 74)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .film }.count, 35)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .mono }.count, 5)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .cinema }.count, 74)
        for entry in Library709.entries {
            XCTAssertTrue((16...64).contains(entry.dimension), entry.title)
            XCTAssertTrue(entry.compact, entry.title)
            XCTAssertNotNil(ImportedFilterCatalog.table(entry)?.data, entry.title)
            XCTAssertEqual(entry.style.filterCategory, Library709.categories[entry.style], entry.title)
        }
    }

    func testImported709FilterActuallyTransformsPixels() throws {
        let entry = try XCTUnwrap(Library709.entries.first { $0.title.contains("胶片") || $0.title.contains("冷暖") } ?? Library709.entries.first)
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(color: CIColor(red: 0.3, green: 0.55, blue: 0.25)).cropped(to: CGRect(x:0,y:0,width:4,height:4))
        func pixel(_ image: CIImage) -> [UInt8] { var p=[UInt8](repeating:0,count:4); context.render(image,toBitmap:&p,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)); return p }
        let before=pixel(input), after=pixel(entry.style.apply(to: input, intensity: 1))
        XCTAssertNotEqual(before, after, entry.title)
        XCTAssertEqual(after[3], 255)
    }
}
