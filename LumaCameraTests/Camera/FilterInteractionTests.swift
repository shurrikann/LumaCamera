import XCTest
import Combine
@testable import LumaCamera

final class FilterInteractionTests: XCTestCase {
    func testInteractiveFramesProgressInOrderAndFinishAtExactLatestRevision() {
        let gate = PreviewRevision()
        let first = gate.advance()
        gate.setInteractive(true)
        let second = gate.advance()
        let third = gate.advance()
        XCTAssertTrue(gate.acceptsPublication(first))
        XCTAssertTrue(gate.acceptsPublication(second))
        XCTAssertFalse(gate.acceptsPublication(first))
        gate.setInteractive(false)
        XCTAssertFalse(gate.canRender(second))
        XCTAssertTrue(gate.acceptsPublication(third))
        gate.setInteractive(true)
        let structural = gate.advance(resetInteractiveFloor: true)
        let latest = gate.advance()
        XCTAssertFalse(gate.canRender(third))
        XCTAssertTrue(gate.acceptsPublication(structural))
        gate.setInteractive(false)
        XCTAssertTrue(gate.acceptsPublication(latest))
    }

    @MainActor func testResetCancelConfirmationLateSliderEventsAndOtherFilterIsolation() {
        let store = FilterSettingsStore()
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: store)
        model.filterParameterBinding(.brightness).wrappedValue = 18
        model.style = .leicaM9
        for _ in 0..<30 {
            let oldBinding = model.filterParameterBinding(.temperature)
            oldBinding.wrappedValue = 36.25
            model.presentFilterReset()
            oldBinding.wrappedValue = 60
            XCTAssertEqual(model.filterAdjustments[.temperature], 36.25)
            model.dismissFilterReset()
            XCTAssertEqual(model.filterAdjustments[.temperature], 36.25)
            model.presentFilterReset(); model.confirmFilterReset()
            oldBinding.wrappedValue = 90
            XCTAssertTrue(model.filterAdjustments.isNeutral)
            XCTAssertEqual(model.intensity, 0.8)
            XCTAssertFalse(model.filterResetVisible)
            XCTAssertTrue(store.settings(for: .leicaM9).adjustments.isNeutral)
        }
        model.filterParameterBinding(.temperature).wrappedValue = 22
        XCTAssertEqual(model.filterAdjustments[.temperature], 22)
        model.presentFilterReset(); model.style = .original; model.confirmFilterReset()
        XCTAssertEqual(model.filterAdjustments[.brightness], 18)
        model.style = .leicaM9
        XCTAssertEqual(model.filterAdjustments[.temperature], 22)
    }

    #if targetEnvironment(simulator)
    @MainActor func testContinuousSliderInputStillPublishesPreviewBeforeRelease() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.start(); defer { model.camera.stop() }
        for _ in 0..<200 {
            if model.camera.ready && model.camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var frames = 0
        let token = model.camera.$preview.dropFirst().sink { if $0 != nil { frames += 1 } }
        defer { token.cancel() }
        model.setFilterParameterEditing(true)
        for i in 0..<120 {
            model.filterParameterBinding(.temperature).wrappedValue = Double(i) - 60
            try await Task.sleep(for: .milliseconds(8))
        }
        let duringDrag = frames
        model.setFilterParameterEditing(false)
        XCTAssertGreaterThan(duringDrag, 5, "Continuous changes must not starve preview frames")
        print("FILTER-SIM-DRAG frames=\(duringDrag)")
    }
    #endif
}
