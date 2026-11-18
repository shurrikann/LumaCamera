import XCTest
@testable import LumaCamera

final class AstroCaptureTimelineTests: XCTestCase {
    func testFusionCannotOutrunIntervalAndWallDeadlineIsIndependentOfFrameCount() {
        var clock = AstroCaptureTimeline(interval: 5, fusion: 30, duration: 60)
        XCTAssertEqual(clock.interval, 30)
        let ticks = (0...60).compactMap { clock.next(pts: 100 + Double($0)) }
        XCTAssertEqual(ticks.filter(\.complete).map(\.window), [0, 1])
        XCTAssertTrue(ticks.last!.finished)
        var dropped = AstroCaptureTimeline(interval: 5, fusion: 3, duration: 20)
        XCTAssertTrue(dropped.next(pts: 100)!.collect)
        XCTAssertEqual(dropped.next(pts: 112)!.window, 2)
        XCTAssertTrue(dropped.next(pts: 112) == nil)
        XCTAssertTrue(dropped.next(pts: 111) == nil)
        XCTAssertTrue(dropped.next(pts: 120)!.finished)
    }
    func testGapBeyondFusionFinalizesPartialWindowOnce() {
        var clock = AstroCaptureTimeline(interval: 10, fusion: 3, duration: nil)
        XCTAssertTrue(clock.next(pts: 0)!.collect)
        let gap = clock.next(pts: 6)!
        XCTAssertFalse(gap.collect); XCTAssertTrue(gap.complete)
        XCTAssertFalse(clock.next(pts: 7)!.complete)
        XCTAssertTrue(clock.next(pts: 10)!.newWindow)
    }
    func testStableCadenceAndRepeatedCancelledTimelines() {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 {
            var clock = AstroCaptureTimeline(interval: 5, fusion: 2, duration: nil)
            let ticks = (0..<30).compactMap { clock.next(pts: Double($0)) }
            XCTAssertEqual(ticks.filter(\.complete).map(\.window), [0, 1, 2, 3, 4, 5])
            XCTAssertNil(clock.next(pts: .nan))
        }
        print("ASTRO-TIMELINE sequences=1000 sourceTicks=30000 seconds=\(ProcessInfo.processInfo.systemUptime-start); CPU schedule cost, not FPS")
    }
}
