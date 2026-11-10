import XCTest
@testable import LumaCamera

final class VideoFilterInfoTests: XCTestCase {
    func testSDRBadgeAddsFilterIntensityAndAdjustments() {
        var look = CaptureLook(style: .leicaM9, intensity: 0.72)
        look.adjustments[.temperature] = 12
        let badges = VideoCaptureBadges.forRecording(colorSpace: .sdr, burnedLogLUT: false, look: look)
        let rows = VideoDetailsReader.filterRows(for: badges)
        XCTAssertTrue(rows.contains { $0.title == "滤镜" && $0.value == "徕卡 M9" })
        XCTAssertTrue(rows.contains { $0.title == "滤镜浓度" && $0.value == "72%" })
        XCTAssertTrue(rows.contains { $0.title == "滤镜调整" && $0.value.contains("色温") })
    }

    func testBurnedLogBadgeAddsLUTNameAndWriteState() {
        let badges = VideoCaptureBadges.forRecording(colorSpace: .appleLog, burnedLogLUT: true,
                                                     look: CaptureLook(), logLUTID: "AppleLog_Rec709")
        let rows = VideoDetailsReader.filterRows(for: badges)
        XCTAssertTrue(rows.contains { $0.title == "Log LUT" && $0.value == "Log Rec709" })
        XCTAssertTrue(rows.contains { $0.title == "LUT 写入" && $0.value == "已烧录到画面" })
    }

    func testPreviewOnlyLogDoesNotClaimFilterInformation() {
        let badges = VideoCaptureBadges.forRecording(colorSpace: .appleLog, burnedLogLUT: false)
        XCTAssertTrue(VideoDetailsReader.filterRows(for: badges).isEmpty)
    }
}
