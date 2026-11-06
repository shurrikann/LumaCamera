import XCTest
@testable import LumaCamera

final class HistogramAnimationTests: XCTestCase {
    func testWaveformInterpolatesWithoutDroppingBinsOrInvalidNumbers() {
        let start = HistogramVector([0, .nan, .infinity, -2, 3])
        let end = HistogramVector([1, 1, 1, 1, 0])
        var delta = end - start
        delta.scale(by: 0.5)
        let midpoint = start + delta
        XCTAssertEqual(midpoint.bins.count, 128)
        XCTAssertEqual(midpoint.bins[0], 0.5)
        XCTAssertEqual(midpoint.bins[4], 0.5)
        XCTAssertTrue(midpoint.bins.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertEqual((start + HistogramVector.zero).bins, start.bins)
        XCTAssertEqual((end - end).magnitudeSquared, 0)
    }

    func testTransitionRejectsFramesCapturedBeforeConnectionWasReady() {
        var state = LivePreviewState.Snapshot()
        state.running = true
        state.framesNotBefore = 42
        XCTAssertFalse(state.acceptsFrame(time: 41.999))
        XCTAssertFalse(state.acceptsFrame(time: .nan))
        XCTAssertTrue(state.acceptsFrame(time: 42))
        state.nightCapturePreviewHold = true
        XCTAssertFalse(state.acceptsFrame(time: 43), "夜景跨批次保留画面时不接收曝光切换帧")
        state.nightCapturePreviewHold = false
        XCTAssertTrue(state.acceptsFrame(time: 43))
        state.acceptsFrames = false
        XCTAssertFalse(state.acceptsFrame(time: 43))
        state.acceptsFrames = true; state.running = false
        XCTAssertFalse(state.acceptsFrame(time: 43))
    }
}
