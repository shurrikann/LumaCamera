import XCTest
import UIKit
@testable import LumaCamera
final class FilterLandscapeTests: XCTestCase {
    @MainActor func testAllFiltersIncludeOriginalRenderTheSameBundledLandscape() async throws {
        XCTAssertNotNil(UIImage(named:"FilterLandscape"))
        let model = FilterPickerViewModel()
        model.prepareThumbnails()
        for _ in 0..<300 { if model.thumbnails.count == FilmStyle.availableStyles.count { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(model.thumbnails.count,FilmStyle.availableStyles.count)
        let original = try XCTUnwrap(model.thumbnails[.original])
        XCTAssertGreaterThan(original.size.width,0)
        let m9 = try XCTUnwrap(model.thumbnails[.leicaM9])
        XCTAssertNotEqual(original.pngData(),m9.pngData())
    }
}
