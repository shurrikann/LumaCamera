import XCTest
import Combine
@testable import LumaCamera

final class PreviewIsolationTests: XCTestCase {
    @MainActor
    func testBlockedPreviewDoesNotBlockZoomOrCaptureAndThenResumesLatestFrame() async {
        #if targetEnvironment(simulator)
        let previewQueue = DispatchQueue(label: "test.blocked.preview")
        previewQueue.suspend()
        var resumed = false
        let camera = CameraEngine(previewQueue: previewQueue)
        defer {
            if !resumed { previewQueue.resume() }
            camera.stop()
        }
        let ready = expectation(description: "Control queue starts without preview")
        let readyToken = camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        camera.start()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNil(camera.preview)
        let captured = expectation(description: "Capture uses final zoom despite blocked renderer")
        camera.onPhotoCaptured = { image in
            guard let image else { XCTFail("Capture returned no image"); captured.fulfill(); return }
            XCTAssertEqual(image.size.width, 450)
            XCTAssertEqual(image.size.height, 600)
            captured.fulfill()
        }
        for index in 0..<500 { camera.setContinuousZoom(1 + CGFloat(index) / 499) }
        camera.capture(flash: false)
        await fulfillment(of: [captured], timeout: 5)
        XCTAssertEqual(camera.currentZoom, 2)
        XCTAssertFalse(camera.capturing)
        XCTAssertNil(camera.preview)
        let preview = expectation(description: "Renderer resumes with latest zoom")
        let previewToken = camera.$preview.compactMap { $0 }.first().sink { image in
            XCTAssertEqual(image.size.width, 450)
            preview.fulfill()
        }
        resumed = true
        previewQueue.resume()
        await fulfillment(of: [preview], timeout: 3)
        readyToken.cancel(); previewToken.cancel()
        #endif
    }
}
