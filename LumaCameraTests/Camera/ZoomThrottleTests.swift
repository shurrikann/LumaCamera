import XCTest
import Combine
@testable import LumaCamera

final class ZoomThrottleTests: XCTestCase {
    func testThousandsOfDragEventsDeliverOnlyTheLatestPendingValue() async {
        let queue = DispatchQueue(label: "test.zoom.throttle")
        queue.suspend()
        let delivered = expectation(description: "Latest zoom delivered")
        var values: [Int] = []
        let throttle = LatestValueThrottle<Int>(queue: queue, interval: 0.02) { value in values.append(value); delivered.fulfill() }
        for value in 0..<5000 { throttle.submit(value) }
        queue.resume()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(queue.sync { values }, [4999])
        withExtendedLifetime(throttle) {}
    }
    func testFlushAppliesFinalZoomBeforeCaptureAndDoesNotDeliverTwice() async throws {
        let queue = DispatchQueue(label: "test.zoom.flush")
        var values: [Int] = []
        let throttle = LatestValueThrottle<Int>(queue: queue, interval: 0.05) { values.append($0) }
        for value in 0..<100 { throttle.submit(value) }
        queue.sync { throttle.flush() }
        XCTAssertEqual(queue.sync { values }, [99])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queue.sync { values }, [99])
    }
    func testCancelDiscardsOldTargetAndAllowsNewGesture() async {
        let queue = DispatchQueue(label: "test.zoom.cancel")
        queue.suspend()
        let delivered = expectation(description: "New gesture delivered")
        var values: [Int] = []
        let throttle = LatestValueThrottle<Int>(queue: queue, interval: 0.02) { values.append($0); delivered.fulfill() }
        throttle.submit(4); throttle.cancel(); throttle.submit(8)
        queue.resume()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(queue.sync { values }, [8])
        withExtendedLifetime(throttle) {}
    }
    func testLensBoundaryHysteresisAvoidsRepeatedPhysicalSwitches() {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 10, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 4, minimum: 1, maximum: 10, nativeFactors: [2])
        let cameras = [wide, tele]
        for zoom in [CGFloat(3.98), 4.01, 3.99, 4.1, 4.05] {
            XCTAssertEqual(CameraZoomPolicy.selectContinuous(zoom, from: cameras, currentID: "wide")?.id, "wide")
        }
        XCTAssertEqual(CameraZoomPolicy.selectContinuous(4.3, from: cameras, currentID: "wide")?.id, "tele")
        XCTAssertEqual(CameraZoomPolicy.selectContinuous(4.1, from: cameras, currentID: "tele")?.id, "tele")
        XCTAssertEqual(CameraZoomPolicy.selectContinuous(3.99, from: cameras, currentID: "tele")?.id, "wide")
    }
    @MainActor
    func testPreviewKeepsUpdatingThroughoutRapidZoomDragAndRecovers() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ready = expectation(description: "Camera ready")
        let readyToken = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { readyToken.cancel(); model.camera.stop() }
        var frames = 0
        let token = model.camera.$preview.dropFirst().compactMap { $0 }.sink { _ in frames += 1 }
        defer { token.cancel() }
        model.beginZoomDial(at: 1)
        for index in 0..<100 {
            model.dragZoomDial(translation: -CGFloat(index), width: 300)
            try await Task.sleep(for: .milliseconds(3))
        }
        let framesDuringDrag = frames
        XCTAssertGreaterThan(framesDuringDrag, 0, "Dragging must not invalidate every preview frame")
        model.endZoomDial()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.zoomDialVisible)
        XCTAssertTrue(model.camera.ready)
        model.beginZoomDial(at: 1)
        model.dragZoomDial(translation: -100, width: 300)
        model.endZoomDial()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.camera.currentZoom, 2, accuracy: 0.0001)
        XCTAssertGreaterThan(frames, framesDuringDrag)
        #endif
    }
}
