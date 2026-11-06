import AVFoundation
import CoreMedia
import XCTest
@testable import LumaCamera

final class VideoEditorWorkflowTests: XCTestCase {
    func testLogVideosExposeTrimAndLogFiltersButNoAdjustmentTool() {
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .appleLog), [.trim, .filters])
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .appleLog).count + 1, 3, "Log toolbar includes three equally-sized slots including Save")
    }

    func testSDRAndP3ExposeAdjustmentTool() {
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .sdr), [.trim, .filters, .adjustments])
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .p3), [.trim, .filters, .adjustments])
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .sdr).count + 1, 4, "SDR/P3 toolbar includes four equally-sized slots including Save")
        XCTAssertEqual(VideoEditorTool.available(colorSpace: .hdr), [.trim], "HDR is trim-only until its filter processing path is supported")
    }

    func testTrimPanelUsesCompactHeightWithoutMovingToolPanelForOtherModes() {
        XCTAssertEqual(VideoEditorPanelMetrics.height(for: .trim), 99)
        XCTAssertEqual(VideoEditorPanelMetrics.height(for: .filters), 186)
        XCTAssertEqual(VideoEditorPanelMetrics.height(for: .adjustments), 186)
    }

    func testVideoTransferMetadataMapsLogHDRP3AndSDR() {
        XCTAssertEqual(VideoColorSpaceDetector.detect(transferFunction: nil, logTransferFunction: kCMFormatDescriptionLogTransferFunction_AppleLog as String, colorPrimaries: nil), .appleLog)
        XCTAssertEqual(VideoColorSpaceDetector.detect(transferFunction: nil, logTransferFunction: "com.apple.apple-wide-gamut.apple-log", colorPrimaries: nil), .appleLog2)
        XCTAssertEqual(VideoColorSpaceDetector.detect(transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String, logTransferFunction: nil, colorPrimaries: nil), .hdr)
        XCTAssertEqual(VideoColorSpaceDetector.detect(transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, logTransferFunction: nil, colorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65 as String), .p3)
        XCTAssertEqual(VideoColorSpaceDetector.detect(transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, logTransferFunction: nil, colorPrimaries: nil), .sdr)
        XCTAssertNil(VideoColorSpaceDetector.detect(transferFunction: nil, logTransferFunction: nil, colorPrimaries: nil), "Unknown color metadata must not enable a possibly incompatible filter")
    }

    func testTrimSelectionClampsToVideoAndKeepsMinimumDuration() {
        let selection = VideoTrimSelection(start: 2.95, end: 2.99, totalDuration: 3)
        XCTAssertEqual(selection.totalDuration, 3)
        XCTAssertEqual(selection.duration, 0.1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(selection.start, 0)
        XCTAssertLessThanOrEqual(selection.end, 3)
        XCTAssertEqual(selection.timeRange.duration.seconds, selection.duration, accuracy: 0.002)
    }

    func testTrimSelectionHandlesInvalidValuesAndShortClips() {
        let short = VideoTrimSelection(start: .nan, end: .infinity, totalDuration: 0.05)
        XCTAssertEqual(short.start, 0)
        XCTAssertEqual(short.end, 0.05, accuracy: 0.001)
        XCTAssertEqual(short.duration, 0.05, accuracy: 0.001)
        let invalid = VideoTrimSelection(start: .infinity, end: .nan, totalDuration: .nan)
        XCTAssertEqual(invalid.duration, 0)
    }

    func testLivePhotoSelectionUsesPlayheadAndNeverExceedsThreeSeconds() {
        let centered = VideoTrimSelection.livePhoto(start: 2, end: 8, totalDuration: 10, playhead: 4.5)
        XCTAssertEqual(centered.start, 3, accuracy: 0.001)
        XCTAssertEqual(centered.end, 6, accuracy: 0.001)
        XCTAssertEqual(centered.duration, 3, accuracy: 0.001)

        let nearEnd = VideoTrimSelection.livePhoto(start: 2, end: 8, totalDuration: 10, playhead: 7.9)
        XCTAssertEqual(nearEnd.start, 5, accuracy: 0.001)
        XCTAssertEqual(nearEnd.end, 8, accuracy: 0.001)

        let shortSelection = VideoTrimSelection.livePhoto(start: 2, end: 4, totalDuration: 10, playhead: .nan)
        XCTAssertEqual(shortSelection.start, 2, accuracy: 0.001)
        XCTAssertEqual(shortSelection.end, 4, accuracy: 0.001)
        XCTAssertEqual(shortSelection.duration, 2, accuracy: 0.001)
    }
}
