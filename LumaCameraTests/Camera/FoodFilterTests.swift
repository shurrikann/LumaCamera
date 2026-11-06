import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class FoodFilterTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func pixel(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        let point = CGPoint(x: image.extent.midX.rounded(.down), y: image.extent.midY.rounded(.down))
        context.render(image, toBitmap: &values, rowBytes: 16,
                       bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return values
    }

    func testFoodIsTheImportedCubeAndReplacesTheOldBuiltInEntry() throws {
        let definition = try XCTUnwrap(ImportedFilterCatalog.definition(for: .food))
        let table = try XCTUnwrap(ImportedFilterCatalog.table(definition))
        XCTAssertEqual(definition.asset, "ImportedLUT-food")
        XCTAssertEqual(definition.dimension, 17)
        XCTAssertFalse(definition.compact)
        XCTAssertEqual(table.dimension, 17)
        XCTAssertEqual(table.data?.count, 17 * 17 * 17 * 4 * MemoryLayout<Float>.size)
        XCTAssertEqual(ImportedFilterCatalog.entries.filter { $0.style == .food }.count, 1)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0 == .food }.count, 1)
        XCTAssertEqual(FilmStyle.availableStyles.last, .food, "Replacing the previous entry should preserve its picker position")
        XCTAssertEqual(FilmStyle.food.title, "美食")

        let input = CIImage(color: CIColor(red: 0.82, green: 0.34, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let source = pixel(input)
        let lutReference = pixel(table.apply(to: input))
        let styleReference = pixel(FilmStyle.food.referenceImage(to: input))
        let filtered = pixel(FilmStyle.food.apply(to: input, intensity: 1))
        let defaultStrength = pixel(FilmStyle.food.apply(to: input, intensity: 0.8))
        XCTAssertGreaterThan(zip(source.prefix(3), filtered.prefix(3)).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }, 0.02,
                             "The imported cube must produce a visible color transform")
        for channel in 0..<4 {
            XCTAssertEqual(styleReference[channel], lutReference[channel], accuracy: 0.001,
                           "The old hand-authored food profile must no longer be in the render path")
            XCTAssertEqual(defaultStrength[channel], lutReference[channel], accuracy: 0.001)
        }
    }

    @MainActor
    func testImportedFoodLookKeepsFavoriteAndPhotoEditRoundTrip() throws {
        let suite = "food-lut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let picker = FilterPickerViewModel(defaults: defaults)
        XCTAssertTrue(picker.styles.contains(.food))
        picker.toggleFavorite(.food)
        picker.category = .favorites
        XCTAssertTrue(picker.styles.contains(.food))
        let restored = FilterPickerViewModel(defaults: defaults)
        restored.category = .favorites
        XCTAssertTrue(restored.styles.contains(.food))

        var recipe = PhotoAdjustments()
        recipe.filterID = FilmStyle.food.rawValue
        recipe.filterAdjustments[.saturation] = 8
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(recipe, decoded)
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        let look = CaptureLook(style: .food, intensity: 0.8, adjustments: recipe.filterAdjustments)
        let preview = Imaging.filtered(source, look: look)
        let edit = recipe.apply(to: source)
        XCTAssertEqual(preview.extent, source.extent)
        XCTAssertEqual(edit.extent, source.extent)
        let result = try PhotoEditRenderer.render(source: source, adjustments: recipe)
        XCTAssertEqual(result.filterApplied, true)
        XCTAssertFalse(result.resource.data.isEmpty)
    }
}
