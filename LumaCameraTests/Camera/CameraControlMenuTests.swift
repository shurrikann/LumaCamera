import XCTest
import UIKit
@testable import LumaCamera

final class CameraControlMenuTests: XCTestCase {
    @MainActor func testMenuLayoutAndShutterDirection() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertEqual(model.hardwareControlSpecs.map(\.id), ["A.zoom"])
        model.mode = .manual
        let specs = model.hardwareControlSpecs
        XCTAssertEqual(specs.map(\.id), ["M.S", "M.ISO", "M.MF", "M.EV", "M.WB", "M.TINT"])
        let shutter = specs[0]
        XCTAssertGreaterThan(shutter.choices.count, 1)
        XCTAssertGreaterThan(shutter.choices.first!, shutter.choices.last!)
        XCTAssertEqual(shutter.choices.count, shutter.choiceTitles.count)
        XCTAssertTrue(shutter.choiceTitles.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(shutter.choiceTitles.contains("1/10"))
        XCTAssertFalse(shutter.choiceTitles.contains("1/11"), "The shutter menu should use photographic stop values")
        XCTAssertEqual(specs[3].range, -5...5)
    }

    #if targetEnvironment(simulator)
    @MainActor func testHardwareAdjustmentsIgnoreInactiveAndObsoleteModeEvents() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let before = model.camera.currentZoom
        model.handleHardwareAdjustment(id: "A.zoom", value: 4)
        XCTAssertEqual(model.camera.currentZoom, before)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 { if model.camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.handleHardwareAdjustment(id: "A.zoom", value: 4)
        XCTAssertEqual(model.camera.currentZoom, 4)
        model.mode = .manual
        model.handleHardwareAdjustment(id: "A.zoom", value: 2)
        XCTAssertEqual(model.camera.currentZoom, 4)
        let iso = model.iso
        model.handleHardwareAdjustment(id: "M.ISO", value: .nan)
        XCTAssertEqual(model.iso, iso)
        model.review = true
        model.handleHardwareAdjustment(id: "M.ISO", value: 800)
        XCTAssertEqual(model.iso, iso)
    }
    #else
    @MainActor func testPhysicalMenusAndManualBindingsWithoutSavingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let mode = model.mode, oldISO = model.iso, oldShutter = model.shutter, oldWB = model.wb, oldTint = model.whiteBalanceTint
        let oldFocus = model.focus, oldEV = model.ev, oldExposure = model.manualExposure, oldManualWB = model.manualWB, oldManualFocus = model.manualFocus
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setMode(mode); model.iso = oldISO; model.shutter = oldShutter; model.wb = oldWB; model.whiteBalanceTint = oldTint
            model.focus = oldFocus; model.ev = oldEV; model.manualExposure = oldExposure; model.manualWB = oldManualWB; model.manualFocus = oldManualFocus
            model.applyExposure(); model.applyWhiteBalance(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.setMode(.auto)
        try await Task.sleep(for: .seconds(2))
        let autoIDs = await withCheckedContinuation { c in camera.hardwareControlIdentifiersForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(autoIDs, ["A.zoom"])
        model.setMode(.manual)
        try await Task.sleep(for: .seconds(2))
        let manualIDs = await withCheckedContinuation { c in camera.hardwareControlIdentifiersForTesting { c.resume(returning: $0) } }
        XCTAssertEqual(manualIDs, ["M.S", "M.ISO", "M.MF", "M.EV", "M.WB", "M.TINT"])
        XCTAssertTrue(camera.supportsExposure); XCTAssertTrue(camera.supportsWB); XCTAssertTrue(camera.supportsFocus)
        model.handleHardwareAdjustment(id: "M.S", value: Float(log2(1.0 / 125)))
        model.handleHardwareAdjustment(id: "M.ISO", value: 400)
        XCTAssertTrue(model.manualExposure)
        XCTAssertEqual(model.iso, 400); XCTAssertEqual(model.shutter, log2(1.0 / 125), accuracy: 0.00001)
        model.handleHardwareAdjustment(id: "M.WB", value: 5500)
        model.handleHardwareAdjustment(id: "M.TINT", value: 15)
        XCTAssertTrue(model.manualWB); XCTAssertEqual(model.wb, 5500); XCTAssertEqual(model.whiteBalanceTint, 15)
        model.handleHardwareAdjustment(id: "M.MF", value: 0.6)
        XCTAssertTrue(model.manualFocus); XCTAssertEqual(model.focus, 0.6, accuracy: 0.00001)
        model.handleHardwareAdjustment(id: "M.EV", value: 1)
        XCTAssertFalse(model.manualExposure); XCTAssertEqual(model.ev, 1)
        model.setMode(.auto)
        let iso = model.iso
        model.handleHardwareAdjustment(id: "M.ISO", value: 800)
        XCTAssertEqual(model.iso, iso)
        XCTAssertNil(camera.message)
    }
    #endif
}
