import XCTest
@testable import LumaCamera

final class FilterAdjustmentStateTests: XCTestCase {
    @MainActor func testSettingsSurviveFilterModeFormatAndAppRecreationUntilExplicitReset() throws {
        let suite = "Luma.FilterAdjustments." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilterSettingsStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: store)
        model.filterParameterBinding(.brightness).wrappedValue = 12
        model.style = .leicaM9
        model.intensity = 0.62
        model.filterParameterBinding(.temperature).wrappedValue = 24
        model.filterParameterBinding(.grainSize).wrappedValue = 36
        let recipe = model.filterAdjustments
        model.closePopups(); model.setMode(.manual); model.setMode(.auto)
        model.photoFormat = .raw
        XCTAssertTrue(model.effectiveCaptureLook.adjustments.isNeutral)
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.photoFormat = .rawJPEG
        XCTAssertEqual(model.effectiveCaptureLook.adjustments, recipe)
        model.style = .original
        XCTAssertEqual(model.filterAdjustments[.brightness], 12)
        model.style = .leicaM9
        XCTAssertEqual(model.filterAdjustments, recipe); XCTAssertEqual(model.intensity, 0.62)
        model.flushFilterSettings()
        let restored = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: FilterSettingsStore(defaults: defaults))
        XCTAssertEqual(restored.style, .leicaM9)
        XCTAssertEqual(restored.filterAdjustments, recipe); XCTAssertEqual(restored.intensity, 0.62)
        restored.resetCurrentFilter()
        XCTAssertTrue(restored.filterAdjustments.isNeutral); XCTAssertEqual(restored.intensity, 0.8)
        let reopened = FilterSettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.settings(for: .leicaM9).adjustments.isNeutral)
        XCTAssertEqual(reopened.settings(for: .original).adjustments[.brightness], 12)
    }
    @MainActor func testOriginalDoesNotDisplayOrApplyAFilterConcentration() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertEqual(model.filterParameterText(.strength), "—")
        XCTAssertEqual(model.filterParameterBinding(.strength).wrappedValue, 0)
        model.filterParameterBinding(.strength).wrappedValue = 25
        XCTAssertEqual(model.intensity, 0.8)
        model.filterParameterBinding(.temperature).wrappedValue = 18
        XCTAssertEqual(model.filterAdjustments[.temperature], 18)
        model.style = .leicaM9
        XCTAssertEqual(model.filterParameterText(.strength), "72")
    }
    @MainActor func testVisibleCatalogTabsAndShootingEntriesMatchRequestedScope() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertEqual(model.filters.styles, FilmStyle.availableStyles)
        XCTAssertEqual(model.filters.styles.count, 256)
        XCTAssertEqual(FilterEditorTab.allCases.map(\.rawValue), ["色彩", "明暗", "质感"])
        // 原版明暗页恢复亮度，所有现有参数都有编辑入口。
        XCTAssertEqual(Set(FilterEditorTab.allCases.flatMap(\.parameters)),
                       Set(FilterParameter.allCases))
        let names = model.shootingFeatures.map(\.title)
        XCTAssertEqual(names, ["视频", "照片"])
    }
    @MainActor func testReopeningFilterAlwaysShowsListAndPreservesRecipe() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .leicaM9
        model.filterParameterBinding(.temperature).wrappedValue = 18
        model.togglePanel(.film); model.filters.showStrength = true
        model.closePopups(); model.togglePanel(.film)
        XCTAssertFalse(model.filters.showStrength)
        XCTAssertEqual(model.style, .leicaM9)
        XCTAssertEqual(model.filterAdjustments[.temperature], 18)
    }
    @MainActor func testDefault80BoostMigrationPreservesCustomRecipesAndOnlyRunsOnce() throws {
        let suite = "Luma.FilterDefaultMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var custom = FilterAdjustments(); custom[.temperature] = 12
        defaults.set(try JSONEncoder().encode([
            FilmStyle.leicaM9.rawValue: SavedFilterSettings(intensity: 1),
            FilmStyle.fujiNC.rawValue: SavedFilterSettings(intensity: 0.8, adjustments: custom),
            FilmStyle.fujiCC.rawValue: SavedFilterSettings(intensity: 0.65)
        ]), forKey: "camera.filterParameters.v1")
        let store = FilterSettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings(for: .leicaM9).intensity, 0.8)
        XCTAssertEqual(store.settings(for: .fujiNC).intensity, 0.8)
        XCTAssertEqual(store.settings(for: .fujiNC).adjustments, custom)
        XCTAssertEqual(store.settings(for: .fujiCC).intensity, 0.65)
        XCTAssertEqual(store.settings(for: .original).intensity, 0.8)
        store.set(SavedFilterSettings(intensity: 0.8), for: .leicaM9); store.flush()
        XCTAssertEqual(FilterSettingsStore(defaults: defaults).settings(for: .leicaM9).intensity, 0.8)
    }
    func testMalformedValuesAreClampedAndRecipesRoundTripInPhotoMetadata() throws {
        var settings = FilterAdjustments()
        settings[.temperature] = .nan; settings[.contrast] = .infinity
        XCTAssertTrue(settings.isNeutral)
        settings[.exposure] = 99; settings[.fade] = -4; settings[.shadows] = -999
        XCTAssertEqual(settings[.exposure], 5); XCTAssertEqual(settings[.fade], 0); XCTAssertEqual(settings[.shadows], -100)
        var parameters = PhotoCaptureParameters(); parameters.filterAdjustments = settings
        let restored = try JSONDecoder().decode(PhotoCaptureParameters.self, from: JSONEncoder().encode(parameters))
        XCTAssertEqual(restored.filterAdjustments, settings)
        XCTAssertTrue(restored.rows.contains { $0.title == "滤镜调整" })
        let legacy = try JSONDecoder().decode(PhotoCaptureParameters.self, from: Data("{\"capturedAt\":0}".utf8))
        XCTAssertNil(legacy.filterAdjustments)
    }
}
