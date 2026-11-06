import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class RAWFilterPolicyTests: XCTestCase {
    @MainActor func testRAWDisablesFilterPanelAndPreservesSelectionForProcessedFormats() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .mono; model.intensity = 0.6
        model.togglePanel(.film)
        XCTAssertEqual(model.panel, .film)
        model.photoFormat = .raw
        XCTAssertFalse(model.filtersEnabled); XCTAssertNil(model.panel)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original)
        model.togglePanel(.film)
        XCTAssertNil(model.panel)
        model.photoFormat = .rawJPEG
        XCTAssertTrue(model.filtersEnabled)
        XCTAssertEqual(model.effectiveCaptureLook.style, .mono)
        XCTAssertEqual(model.effectiveCaptureLook.intensity, 0.6)
    }
    func testRAWPreviewBypassesFilmAndPairOnlyFiltersJPEGWhilePreservingDNGBytes() throws {
        let source = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 60, height: 80))
        let context = CIContext()
        let raw = Data([1, 9, 3, 7])
        let look = CaptureLook(style: .mono, intensity: 1)
        let original = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(), options: PhotoOptions(format: .raw), context: context)
        let unfiltered = try PhotoEncoder.encode(source: source, raw: raw, look: look, options: PhotoOptions(format: .raw), context: context)
        XCTAssertEqual(original.preview.pngData(), unfiltered.preview.pngData())
        XCTAssertEqual(unfiltered.resources[0].data, raw)
        let pair = try PhotoEncoder.encode(source: source, raw: raw, look: look, options: PhotoOptions(format: .rawJPEG), context: context)
        XCTAssertEqual(pair.resources.count, 2)
        XCTAssertEqual(pair.resources[1].data, raw)
        XCTAssertNotEqual(pair.preview.pngData(), original.preview.pngData())
        let plainJPEG = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(), options: PhotoOptions(format: .jpeg), context: context)
        XCTAssertNotEqual(pair.resources[0].data, plainJPEG.resources[0].data)
    }
}
