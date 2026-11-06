import XCTest
@testable import LumaCamera

final class SlowShutterDurationTests: XCTestCase {
    func testOptionsAndDefault() {
        XCTAssertEqual(SlowShutterDuration.allCases.count, 10)
        XCTAssertEqual(SlowShutterDuration.allCases.map(\.title),
                       ["0.3s", "0.5s", "1s", "3s", "5s", "10s", "15s", "30s", "60s", "∞"])
        XCTAssertEqual(SlowShutterDuration.s1.seconds, 1)
        XCTAssertNil(SlowShutterDuration.infinite.seconds)
    }

    func testOneSecondScalesPresetDurationAndKeepsMinimumFrames() throws {
        let base = try XCTUnwrap(SlowShutterPreset.lightTrails.sequenceSpec)
        let one = base.applying(.s1)
        XCTAssertEqual(one.captureDuration, 1)
        XCTAssertGreaterThanOrEqual(one.frameCount, base.minimumFrames)
        XCTAssertLessThan(one.frameCount, base.frameCount)
        let infinite = base.applying(.infinite)
        XCTAssertNil(infinite.captureDuration)
        XCTAssertEqual(infinite.frameCount, Int.max)
    }

    func testPresetDurationRangesAndDefaults() {
        let all = Set(SlowShutterDuration.allCases)
        XCTAssertEqual(SlowShutterPreset.lightTrails.captureDurationRange, 10...30)
        XCTAssertEqual(SlowShutterDuration.allCases.filter { SlowShutterPreset.lightTrails.allows($0) },
                       [.s10, .s15, .s30])
        XCTAssertEqual(SlowShutterDuration.allCases.filter { SlowShutterPreset.silkyWater.allows($0) },
                       [.s5, .s10, .s15])
        XCTAssertEqual(SlowShutterDuration.allCases.filter { SlowShutterPreset.motionBlur.allows($0) },
                       [.s1, .s3])
        XCTAssertEqual(SlowShutterDuration.allCases.filter { SlowShutterPreset.panning.allows($0) },
                       [.s05, .s1])
        XCTAssertEqual(SlowShutterDuration.allCases.filter { SlowShutterPreset.starTrails.allows($0) },
                       [.s60, .infinite])
        XCTAssertEqual(SlowShutterPreset.lightTrails.defaultCaptureDuration, .s15)
        XCTAssertEqual(SlowShutterPreset.silkyWater.defaultCaptureDuration, .s10)
        XCTAssertEqual(SlowShutterPreset.motionBlur.defaultCaptureDuration, .s3)
        XCTAssertEqual(SlowShutterPreset.panning.defaultCaptureDuration, .s1)
        XCTAssertEqual(SlowShutterPreset.starTrails.defaultCaptureDuration, .s60)
        XCTAssertEqual(all.count, 10)
    }

    func testFivePerRowLayout() {
        // 10 options in 5 columns always produces two rows.
        XCTAssertEqual((SlowShutterDuration.allCases.count + 4) / 5, 2)
    }
}

final class SlowShutterProgressTests: XCTestCase {
    func testLongTargetAtWholeSecondStartsNewTurn() {
        let progress = SlowShutterSequenceProgress(completed: 5, total: 15,
                                                   elapsedSeconds: 5, targetSeconds: 15)
        XCTAssertEqual(progress.fraction, 0, accuracy: 0.001)
        XCTAssertEqual(progress.secondsText, "5s")
    }

    func testInfiniteProgressTurnsOncePerSecond() {
        let progress = SlowShutterSequenceProgress(completed: 65, total: 36000,
                                                   elapsedSeconds: 65.25, targetSeconds: nil)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress.secondsText, "65s")
    }

    func testSubSecondProgressUsesRealDurationAsOneTurn() {
        let progress = SlowShutterSequenceProgress(completed: 1, total: 8,
                                                   elapsedSeconds: 0.15, targetSeconds: 0.3)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.001)
    }

    func testLongProgressTurnsOncePerSecond() {
        let progress = SlowShutterSequenceProgress(completed: 1, total: 15,
                                                   elapsedSeconds: 5.75, targetSeconds: 15)
        XCTAssertEqual(progress.fraction, 0.75, accuracy: 0.001)
    }

    func testFrameFallbackWhenElapsedIsUnavailable() {
        let progress = SlowShutterSequenceProgress(completed: 3, total: 10)
        XCTAssertEqual(progress.fraction, 0.3, accuracy: 0.001)
        XCTAssertEqual(progress.secondsText, "3")
    }
}

final class SlowShutterCountdownTests: XCTestCase {
    func testFiniteCountdownShowsRemainingSeconds() {
        let progress = SlowShutterSequenceProgress(completed: 5, total: 15,
                                                   elapsedSeconds: 5, targetSeconds: 15)
        XCTAssertEqual(progress.countdownText, "10s")
        let nearEnd = SlowShutterSequenceProgress(completed: 14, total: 15,
                                                  elapsedSeconds: 14.6, targetSeconds: 15)
        XCTAssertEqual(nearEnd.countdownText, "0.4s")
        let short = SlowShutterSequenceProgress(completed: 1, total: 8,
                                                elapsedSeconds: 0.1, targetSeconds: 0.3)
        XCTAssertEqual(short.countdownText, "0.2s")
    }

    func testInfiniteCountdownShowsElapsedClock() {
        let progress = SlowShutterSequenceProgress(completed: 65, total: 36000,
                                                   elapsedSeconds: 65, targetSeconds: nil)
        XCTAssertEqual(progress.countdownText, "1:05")
    }
}
