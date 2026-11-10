import XCTest
@testable import LumaCamera

final class FilterPickerTests: XCTestCase {
    @MainActor
    func testHorizontalPreviewSwipeMovesThroughFiltersOnlyWhilePickerIsOpen() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .original
        model.swipeFilter(translation: CGSize(width: -100, height: 0))
        XCTAssertEqual(model.style, .original)
        model.togglePanel(.film)
        model.swipeFilter(translation: CGSize(width: -100, height: 10))
        XCTAssertEqual(model.style, .daylightNegative400)
        model.swipeFilter(translation: CGSize(width: 100, height: 0))
        XCTAssertEqual(model.style, .original)
        model.togglePanel(.film)
        model.swipeFilter(translation: CGSize(width: -100, height: 0))
        XCTAssertEqual(model.style, .original)
    }

    @MainActor
    func testVerticalAndShortDragsDoNotChangeFilter() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .leicaM9
        model.togglePanel(.film)
        model.swipeFilter(translation: CGSize(width: 12, height: 0))
        model.swipeFilter(translation: CGSize(width: 80, height: 100))
        model.swipeFilter(translation: CGSize(width: 0, height: -120))
        XCTAssertEqual(model.style, .leicaM9)
    }

    @MainActor
    func testFilterSwipeStopsAtEdgesAndRespectsCategory() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.togglePanel(.film)
        model.style = .original
        model.swipeFilter(translation: CGSize(width: 100, height: 0))
        XCTAssertEqual(model.style, .original)
        model.style = FilmStyle.availableStyles.last!
        model.swipeFilter(translation: CGSize(width: -100, height: 0))
        XCTAssertEqual(model.style, FilmStyle.availableStyles.last!)
        model.style = .leicaM9
        let alreadyFavorite = model.filters.favorites.contains(.leicaM9)
        if !alreadyFavorite { model.filters.toggleFavorite(.leicaM9) }
        defer { if !alreadyFavorite { model.filters.toggleFavorite(.leicaM9) } }
        model.selectFilterCategory(.favorites)
        XCTAssertTrue(model.filters.styles.contains(model.style))
        let finalFavorite = model.filters.styles.last!
        model.style = finalFavorite
        model.swipeFilter(translation: CGSize(width: -100, height: 0))
        XCTAssertEqual(model.style, finalFavorite)
    }

    @MainActor
    func testFavoritesPersistAndCollectionShowsOnlySavedStyles() async throws {
        let suite = "LumaCamera.FilterPickerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let picker = FilterPickerViewModel(defaults: defaults)
        picker.category = .favorites
        XCTAssertTrue(picker.styles.isEmpty)
        picker.toggleFavorite(.original)
        picker.toggleFavorite(.leicaM9)
        XCTAssertEqual(picker.styles, [.original, .leicaM9])
        let restored = FilterPickerViewModel(defaults: defaults)
        restored.category = .favorites
        XCTAssertEqual(restored.styles, [.original, .leicaM9])
        restored.toggleFavorite(.original)
        XCTAssertEqual(restored.styles, [.leicaM9])
    }
}
