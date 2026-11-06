import XCTest
import CoreMedia
@testable import LumaCamera

final class TimeLapseSettingsTests: XCTestCase {
    func testIntervalAndFrameCountOptions() {
        XCTAssertEqual(TimeLapseInterval.allCases.map(\.title),
                       ["1s", "3s", "5s", "10s", "15s", "30s", "60s"])
        XCTAssertEqual(TimeLapseFrameCount.allCases.map(\.title),
                       ["60", "120", "150", "240", "300", "450", "600", "900", "∞"])
        XCTAssertNil(TimeLapseFrameCount.infinite.target)
        XCTAssertEqual(TimeLapseFrameCount.f60.target, 60)
    }

    func testPresetRecommendedCombinations() {
        XCTAssertEqual(TimeLapsePreset.allCases.map(\.recommendedInterval),
                       [.s1, .s3, .s5, .s10, .s15])
        XCTAssertTrue(TimeLapsePreset.allCases.allSatisfy { $0.recommendedFrameCount == .f300 })
    }

    @MainActor func testCancellingPresetRestoresOneSecondAnd120Frames() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        #endif
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<750 {
            if model.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipUnless(model.camera.ready, "Requires a live camera route")
        model.setCaptureKind(.video)
        for _ in 0..<750 {
            if model.camera.ready && !model.camera.videoConfiguring { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        model.toggleTimeLapseMode()
        for _ in 0..<750 {
            if model.timeLapseEnabled && !model.isPreparingSubmode { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        try XCTSkipUnless(model.timeLapseEnabled, "Timelapse unavailable")
        if model.selectedTimeLapsePreset != .traffic { model.selectTimeLapsePreset(.traffic) }
        XCTAssertEqual(model.timeLapseInterval, .s3)
        XCTAssertEqual(model.timeLapseFrameCount, .f300)
        model.selectTimeLapsePreset(.traffic)
        XCTAssertNil(model.selectedTimeLapsePreset)
        XCTAssertEqual(model.timeLapseInterval, .s1)
        XCTAssertEqual(model.timeLapseFrameCount, .f120)
        model.selectTimeLapseInterval(.s5); model.selectTimeLapseFrameCount(.f60)
        model.setMode(model.mode)
        XCTAssertEqual(model.timeLapseInterval,.s5); XCTAssertEqual(model.timeLapseFrameCount,.f60)
        model.setMode(.manual)
        XCTAssertEqual(model.timeLapseInterval,.s1); XCTAssertEqual(model.timeLapseFrameCount,.f120)
    }

    func testSchedulerStopsAtFrameLimit() throws {
        var scheduler = try XCTUnwrap(TimeLapseFrameScheduler(intervalSeconds: 1, frameRate: 30, maxFrames: 3))
        XCTAssertNotNil(scheduler.outputPresentationTime(for: CMTime(seconds: 0, preferredTimescale: 600)))
        XCTAssertFalse(scheduler.reachedLimit)
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime(seconds: 0.5, preferredTimescale: 600)))
        XCTAssertNotNil(scheduler.outputPresentationTime(for: CMTime(seconds: 1, preferredTimescale: 600)))
        XCTAssertNotNil(scheduler.outputPresentationTime(for: CMTime(seconds: 2, preferredTimescale: 600)))
        XCTAssertTrue(scheduler.reachedLimit)
        XCTAssertEqual(scheduler.acceptedFrameCount, 3)
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime(seconds: 3, preferredTimescale: 600)))
        XCTAssertEqual(scheduler.acceptedFrameCount, 3)
        XCTAssertNil(TimeLapseFrameScheduler(intervalSeconds: 1, frameRate: 30, maxFrames: 0))
    }
}
