import XCTest
@testable import LumaCamera

final class CameraRulerMappingTests: XCTestCase {
    func testShutterScaleIsSlowOnLeftAndFastOnRight() {
        let range = -14.0...0
        let slow = log2(1.0 / 60), middle = log2(1.0 / 125), fast = log2(1.0 / 250)
        XCTAssertLessThan(CameraRulerMapping.fraction(value: slow, range: range, reversed: true),
                          CameraRulerMapping.fraction(value: fast, range: range, reversed: true))
        // Drag left brings the faster ticks on the right to the fixed centre indicator.
        let leftDrag = CameraRulerMapping.draggedValue(origin: middle, translation: -80, width: 300, range: range, reversed: true)
        let rightDrag = CameraRulerMapping.draggedValue(origin: middle, translation: 80, width: 300, range: range, reversed: true)
        XCTAssertLessThan(pow(2, leftDrag), 1.0 / 125)
        XCTAssertGreaterThan(pow(2, rightDrag), 1.0 / 125)
        XCTAssertGreaterThan(CameraRulerMapping.draggedValue(origin: 400, translation: -80, width: 300, range: 25...1600), 400)
        XCTAssertEqual(CameraRulerMapping.draggedValue(origin: middle, translation: .nan, width: 300, range: range, reversed: true), middle)
        XCTAssertEqual(CameraRulerMapping.draggedValue(origin: middle, translation: -10000, width: 300, range: range, reversed: true), range.lowerBound)
    }

    func testShutterTickValuesSnapToStandardFractions() {
        let range = log2(1.0 / 4000)...0.0
        let nearOneTenth = CameraShutterStops.snappedLog2Duration(log2(1.0 / 11.0), in: range)
        let nearOneThirteenth = CameraShutterStops.snappedLog2Duration(log2(1.0 / 12.0), in: range)

        XCTAssertEqual(CameraNumericText.shutter(pow(2, nearOneTenth)), "1/10")
        XCTAssertEqual(CameraNumericText.shutter(pow(2, nearOneThirteenth)), "1/13")
        XCTAssertTrue(CameraShutterStops.log2Durations(in: range).contains(log2(1.0 / 10.0)))
        XCTAssertTrue(CameraShutterStops.log2Durations(in: range).contains(log2(1.0 / 13.0)))

        let narrowRange = log2(1.0 / 11.5)...log2(1.0 / 10.5)
        let noStandardStop = CameraShutterStops.snappedLog2Duration(log2(1.0 / 11.0), in: narrowRange)
        XCTAssertEqual(noStandardStop, log2(1.0 / 11.0), accuracy: 0.000_001,
                       "Keep continuous control if the hardware range contains no standard stop")
        XCTAssertTrue(CameraRulerTickValues.values(for: .shutter, in: narrowRange).isEmpty,
                      "A hardware interval without standard stops must use continuous ruler mapping")
    }

    func testManualParameterDragAdvancesByVisibleQuantizedTicks() throws {
        let slowRange = log2(1.0 / 4)...0.0
        let slowTicks = CameraRulerTickValues.values(for: .shutter, in: slowRange)
        XCTAssertGreaterThanOrEqual(slowTicks.count, 4)
        let slowScale = CameraRulerMapping.scale(tickCount: slowTicks.count)
        let oneTickDistance = 300 * slowScale / CGFloat(slowTicks.count - 1)
        let first = CameraRulerMapping.draggedTickIndex(originIndex: 1, translation: -oneTickDistance,
            width: 300, tickCount: slowTicks.count, scale: slowScale)
        XCTAssertEqual(first, 2, "One visual detent of travel advances exactly one shutter tick")

        let isoTicks = CameraRulerTickValues.values(for: .iso, in: 25...6_400)
        let origin = try XCTUnwrap(CameraRulerTickValues.nearestIndex(to: 400, in: isoTicks))
        let scale = CameraRulerMapping.scale(tickCount: isoTicks.count)
        let distance = 300 * scale / CGFloat(isoTicks.count - 1)
        let next = CameraRulerMapping.draggedTickIndex(originIndex: origin, translation: -distance,
            width: 300, tickCount: isoTicks.count, scale: scale)
        XCTAssertEqual(next, origin + 1)
        XCTAssertEqual(isoTicks[next], 500, accuracy: 0.001,
                       "The value changes to the next displayed ISO detent, not an arbitrary interpolated value")

        let slowPresetRange = log2(0.25)...log2(1.0)
        let slowPresetTicks = CameraRulerTickValues.values(for: .shutter, in: slowPresetRange)
        let slowPresetScale = CameraRulerMapping.scale(tickCount: slowPresetTicks.count)
        let slowDetentDistance = 300 * slowPresetScale / CGFloat(slowPresetTicks.count - 1)
        XCTAssertLessThanOrEqual(slowDetentDistance, 30,
            "Sparse slow-shutter presets should remain reachable with a short, deliberate drag")
    }

    @MainActor
    func testAMToToolsDoesNotMovePreviewForAnyRatio() async throws {
        #if targetEnvironment(simulator)
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let oldRatio = model.ratio
        defer { model.closePopups(); model.ratio = oldRatio; model.setMode(.auto) }
        for ratio in FrameRatio.allCases {
            model.ratio = ratio; model.closePopups(); model.setMode(.manual)
            try await Task.sleep(for: .milliseconds(350))
            model.setMode(.auto)
            try await Task.sleep(for: .milliseconds(350))
            let before = model.previewFrameForTesting
            XCTAssertGreaterThan(before.width, 0)
            model.openTools()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.previewFrameForTesting, before, "Preview must remain fixed for \(ratio.rawValue)")
        }
        #else
        throw XCTSkip("Layout regression is exercised in the simulator")
        #endif
    }
}
