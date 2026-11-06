import XCTest
import UIKit
@testable import LumaCamera

final class CameraRulerDetentTests: XCTestCase {
    func testTicksMajorTicksFastDragAndJitterAcrossEveryManualParameterRange() {
        let ranges: [ClosedRange<Double>] = [-5...5, 32...12800, -14...log2(30), 2500...9000, -150...150, 0...1]
        for range in ranges {
            for reversed in [false, true] {
                func value(_ tick: Double) -> Double { range.lowerBound + (reversed ? 1 - tick / 100 : tick / 100) * (range.upperBound - range.lowerBound) }
                var gate = CameraRulerDetents()
                gate.reset(at: value(1.2), range: range, reversed: reversed)
                XCTAssertEqual(gate.move(to: value(2.2), range: range, reversed: reversed), .tick)
                XCTAssertNil(gate.move(to: value(2.3), range: range, reversed: reversed))
                XCTAssertEqual(gate.move(to: value(5.2), range: range, reversed: reversed), .major)
                XCTAssertNil(gate.move(to: value(4.99), range: range, reversed: reversed))
                XCTAssertNil(gate.move(to: value(5.01), range: range, reversed: reversed))
                XCTAssertEqual(gate.move(to: value(90.2), range: range, reversed: reversed), .major)
                XCTAssertEqual(gate.move(to: value(10), range: range, reversed: reversed), .major)
                XCTAssertNil(gate.move(to: .nan, range: range, reversed: reversed))
            }
        }
    }
    #if !targetEnvironment(simulator)
    @MainActor func testPhysicalExposureDurationLimits() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.stop(); UIApplication.shared.isIdleTimerDisabled = idle }
        camera.start()
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(camera.ready)
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let state: CameraEngine.ExposureColorState? = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
        let actual = try XCTUnwrap(state)
        print("EXPOSURE-LIMIT active=\(actual.maximumExposureSeconds) available=\(actual.maximumAvailableExposureSeconds) ui=\(pow(2,camera.shutterRange.upperBound))")
        XCTAssertGreaterThan(actual.maximumExposureSeconds, 0)
    }
    #endif
}
