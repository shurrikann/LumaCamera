import XCTest
import CoreImage
import Combine
@testable import LumaCamera

final class ContinuousZoomTests: XCTestCase {
    func testRangeUsesPhysicalCamerasAndDeviceLimits() {
        let ultra = LensZoomCapabilities(id: "ultra", baseZoom: 0.5, minimum: 1, maximum: 6, nativeFactors: [])
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 10, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 4, minimum: 1, maximum: 10, nativeFactors: [2])
        XCTAssertEqual(ContinuousZoomPolicy.range([ultra, wide, tele]), 0.5...40)
        XCTAssertEqual(ContinuousZoomPolicy.range([wide]), 1...10)
        XCTAssertEqual(ContinuousZoomPolicy.range([]), 1...1)
        XCTAssertEqual(CameraZoomPolicy.select(1.5, from: [ultra, wide, tele])?.id, "wide")
        XCTAssertEqual(CameraZoomPolicy.select(6, from: [ultra, wide, tele])?.id, "tele")
        XCTAssertEqual(CameraZoomPolicy.select(40, from: [ultra, wide, tele])?.factor, 10)
    }
    func testLogarithmicDragIsConsistentAtEveryFixedAnchorAndClamps() {
        for anchor in [CGFloat(0.5), 1, 2, 4, 8] {
            XCTAssertEqual(ContinuousZoomPolicy.draggedValue(origin: anchor, translation: -100, width: 300, range: 0.5...40), anchor * 2, accuracy: 0.0001)
            XCTAssertEqual(ContinuousZoomPolicy.draggedValue(origin: anchor, translation: 0, width: 300, range: 0.5...40), anchor)
        }
        XCTAssertEqual(ContinuousZoomPolicy.draggedValue(origin: 1, translation: -10000, width: 300, range: 0.5...40), 40)
        XCTAssertEqual(ContinuousZoomPolicy.draggedValue(origin: 1, translation: 10000, width: 300, range: 0.5...40), 0.5)
    }
    func testDemoZoomCropStaysCenteredAndDoesNotPretendToBeHardware() {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 20, y: 30, width: 900, height: 1200))
        let result = ContinuousZoomPolicy.demoFrame(source, zoom: 2)
        XCTAssertEqual(result.extent.midX, source.extent.midX)
        XCTAssertEqual(result.extent.midY, source.extent.midY)
        XCTAssertEqual(result.extent.width, 450)
        XCTAssertEqual(result.extent.height, 600)
    }
    @MainActor
    func testDialGestureUpdatesZoomAndKeepsManualSettings() async {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Camera ready")
        let token = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { model.camera.stop(); token.cancel() }
        model.mode = .manual; model.manualExposure = true; model.iso = 640
        model.panel = .film
        model.beginZoomDial(at: 1)
        XCTAssertTrue(model.zoomDialVisible)
        XCTAssertNil(model.panel)
        model.dragZoomDial(translation: -100, width: 300)
        XCTAssertEqual(model.camera.currentZoom, 2, accuracy: 0.0001)
        model.finishZoomDrag()
        XCTAssertTrue(model.zoomDialVisible)
        // A second drag starts from the current value, without jumping to the old origin.
        model.beginZoomDial(at: model.camera.currentZoom)
        model.dragZoomDial(translation: -100, width: 300)
        XCTAssertEqual(model.camera.currentZoom, 4, accuracy: 0.0001)
        model.finishZoomDrag()
        XCTAssertTrue(model.zoomDialVisible)
        model.endZoomDial()
        XCTAssertFalse(model.zoomDialVisible)
        XCTAssertTrue(model.manualExposure)
        XCTAssertEqual(model.iso, 640)
        XCTAssertEqual(model.camera.currentZoom, 4)
        model.beginZoomDial(at: 4)
        model.dragZoomDial(translation: -100, width: 300)
        XCTAssertEqual(model.camera.currentZoom, 5) // Simulator demo limit, no fake native lens.
        model.dragZoomDial(translation: -1000, width: 300)
        XCTAssertEqual(model.camera.currentZoom, 5)
        model.dragZoomDial(translation: -990, width: 300)
        XCTAssertLessThan(model.camera.currentZoom, 5, "Reversing at the upper limit must respond immediately")
        model.dragZoomDial(translation: 1000, width: 300)
        XCTAssertEqual(model.camera.currentZoom, 1)
        model.dragZoomDial(translation: 990, width: 300)
        XCTAssertGreaterThan(model.camera.currentZoom, 1, "Reversing at the lower limit must respond immediately")
        model.endZoomDial()
        #endif
    }
    @MainActor
    func testPreviewPinchZoomUsesContinuousRouteClampsAndReversesAtBounds() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Camera ready")
        let token = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { model.camera.stop(); token.cancel() }

        model.camera.setContinuousZoom(2)
        model.updatePreviewPinchZoom(scale: 1.5)
        XCTAssertEqual(model.camera.currentZoom, 3, accuracy: 0.0001)
        model.updatePreviewPinchZoom(scale: 2)
        XCTAssertEqual(model.camera.currentZoom, 4, accuracy: 0.0001)
        model.finishPreviewPinchZoom()
        XCTAssertFalse(model.previewPinchActive)

        model.camera.setContinuousZoom(4.5)
        model.updatePreviewPinchZoom(scale: 2)
        XCTAssertEqual(model.camera.currentZoom, 5, accuracy: 0.0001)
        model.updatePreviewPinchZoom(scale: 1.9)
        XCTAssertLessThan(model.camera.currentZoom, 5, "Pinching back from the zoom limit must respond without a dead zone")
        model.finishPreviewPinchZoom()

        model.camera.setContinuousZoom(1.1)
        model.updatePreviewPinchZoom(scale: 0.1)
        XCTAssertEqual(model.camera.currentZoom, 1, accuracy: 0.0001)
        model.updatePreviewPinchZoom(scale: 0.11)
        XCTAssertGreaterThan(model.camera.currentZoom, 1, "Expanding from the lower zoom limit must respond immediately")
        model.finishPreviewPinchZoom()

        model.beginZoomDial(at: 2)
        model.finishZoomDrag()
        let before = model.camera.currentZoom
        model.updatePreviewPinchZoom(scale: 2)
        XCTAssertEqual(model.camera.currentZoom, before, "Pinch must not compete with the visible zoom wheel")
        model.endZoomDial()
        #endif
    }

    @MainActor
    func testReopeningWheelPreservesCurrentZoomInBothModes() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.start()
        defer { model.camera.stop() }
        for _ in 0..<100 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        for mode in [CameraShootingMode.auto, .manual] {
            model.setMode(mode)
            model.camera.setContinuousZoom(4)
            model.openZoomDial()
            XCTAssertEqual(model.camera.currentZoom, 4)
            model.dragZoomDial(translation: 20, width: 300)
            model.finishZoomDrag()
            let zoom = model.camera.currentZoom, lens = model.camera.selectedLens
            model.endZoomDial()
            model.openZoomDial()
            XCTAssertTrue(model.zoomDialVisible)
            XCTAssertEqual(model.camera.currentZoom, zoom)
            XCTAssertEqual(model.camera.selectedLens, lens)
            model.dragZoomDial(translation: 0, width: 300)
            XCTAssertEqual(model.camera.currentZoom, zoom)
            model.finishZoomDrag(); model.endZoomDial()
        }
        #endif
    }
    @MainActor
    func testFixedFocalTapDoesNotOpenWheelAndClearsPreviewTransition() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Camera ready")
        let token = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { model.camera.stop(); token.cancel() }
        for _ in 0..<50 {
            if model.camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.beginZoomDial(at: 2)
        model.finishZoomDrag()
        XCTAssertTrue(model.zoomDialVisible)
        model.selectDemoFocalLength()
        XCTAssertFalse(model.zoomDialVisible)
        XCTAssertEqual(model.camera.currentZoom, 1)
        XCTAssertNotNil(model.focalTransitionImage)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertNil(model.focalTransitionImage)
        XCTAssertFalse(model.zoomDialVisible)
        model.selectDemoFocalLength()
        XCTAssertFalse(model.zoomDialVisible)
        XCTAssertNil(model.focalTransitionImage)
        #endif
    }

}
