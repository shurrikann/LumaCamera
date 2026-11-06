import XCTest
@testable import LumaCamera

final class PhotoCurrentFilterTests: XCTestCase {
    func testCopiesAndReversibleOverwriteShowCurrentFilterWithoutLosingCaptureFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoCaptureDiagnosticsStore(directory: directory)
        var captured = PhotoCaptureParameters(); captured.filterID = FilmStyle.leicaM9.rawValue
        captured.filterName = FilmStyle.leicaM9.title; captured.filterIntensity = 0.8; captured.iso = 1250; captured.exposureSeconds = 0.0125
        let original = PhotoCaptureDiagnostics(parameters: captured)
        store.save(original, assetID: "camera")
        var nc = PhotoAdjustments(); nc.filterID = FilmStyle.fujiNC.rawValue; nc.filterIntensity = 0.65
        store.copyRecord(from: "camera", to: "copy", adjustments: nc)
        let copy = try XCTUnwrap(store.load(assetID: "copy"))
        XCTAssertEqual(copy.parameters, captured)
        XCTAssertEqual(copy.currentParameters?.filterName, FilmStyle.fujiNC.title)
        XCTAssertEqual(copy.currentParameters?.filterIntensity, 0.65)
        XCTAssertEqual(copy.currentParameters?.iso, 1250)
        XCTAssertEqual(copy.detailRows.first { $0.title == "滤镜" }?.value, FilmStyle.fujiNC.title)
        XCTAssertEqual(copy.detailRows.first { $0.title == "滤镜强度" }?.value, "65%")
        XCTAssertEqual(store.load(assetID: "camera"), original)
        // Crop-only/original selection cannot remove an already baked-in filter.
        store.copyRecord(from: "copy", to: "cropped", adjustments: PhotoAdjustments())
        XCTAssertEqual(store.load(assetID: "cropped")?.currentFilter, copy.currentFilter)
        // Overwrite keeps a reversible base so selecting Original removes just the edit.
        store.copyRecord(from: "camera", to: "camera", adjustments: nc)
        XCTAssertEqual(store.load(assetID: "camera")?.currentFilter?.id, FilmStyle.fujiNC.rawValue)
        store.copyRecord(from: "camera", to: "camera", adjustments: PhotoAdjustments(), sourceIsOriginal: true)
        XCTAssertEqual(store.load(assetID: "camera")?.currentFilter?.id, FilmStyle.leicaM9.rawValue)
        XCTAssertEqual(store.load(assetID: "camera")?.currentFilter?.intensity, 0.8)
        var cc = nc; cc.filterID = FilmStyle.fujiCC.rawValue
        store.copyRecord(from: "copy", to: "copy", adjustments: cc)
        store.copyRecord(from: "copy", to: "copy", adjustments: PhotoAdjustments(), sourceIsOriginal: true)
        XCTAssertEqual(store.load(assetID: "copy")?.currentFilter?.id, FilmStyle.fujiNC.rawValue)
    }
    func testExternalPhotosAndLegacyRecordsShowEditedFilterWithoutInventingCaptureFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoCaptureDiagnosticsStore(directory: directory)
        var recipe = PhotoAdjustments(); recipe.filterID = FilmStyle.leicaM9.rawValue
        XCTAssertTrue(store.copyRecord(from: "external", to: "new", adjustments: recipe))
        let record = try XCTUnwrap(store.load(assetID: "new"))
        XCTAssertNil(record.parameters); XCTAssertNil(record.currentParameters)
        XCTAssertEqual(record.detailRows.first { $0.title == "滤镜" }?.value, FilmStyle.leicaM9.title)
        let legacy = PhotoCaptureDiagnostics(rows: [.init(title: "编辑滤镜", value: FilmStyle.fujiNC.title), .init(title: "编辑滤镜浓度", value: "70%")])
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: data)
        XCTAssertEqual(decoded.currentFilter?.id, FilmStyle.fujiNC.rawValue)
        XCTAssertEqual(decoded.currentFilter?.intensity, 0.7)
        XCTAssertEqual(decoded.detailRows.first { $0.title == "滤镜" }?.value, FilmStyle.fujiNC.title)
        let old = try JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: Data("{\"rows\":[]}".utf8))
        XCTAssertNil(old.bakedFilter); XCTAssertNil(old.editedFilter)
    }
}
