import XCTest
@testable import LumaCamera

final class LogLUTClassificationTests: XCTestCase {
    func testBundledLogLUTsSplitByAppleLogCurve() {
        let presets = LogLUTCubeRepository.presets()
        let log = presets.filter { $0.requiredColorSpace == .appleLog }
        let log2 = presets.filter { $0.requiredColorSpace == .appleLog2 }
        let both = presets.filter { $0.requiredColorSpace == nil }
        print("LOG-LUT-CLASS appleLog=\(log.count) appleLog2=\(log2.count) both=\(both.count) total=\(presets.count)")
        XCTAssertTrue(log.contains { $0.id == "AppleLog_Rec709" })
        XCTAssertTrue(log2.contains { $0.id == "AppleLog2_Rec709" })
        XCTAssertTrue(log2.contains { $0.id == "appleLog2_arri" })
        XCTAssertEqual(presets.count, log.count + log2.count + both.count)
        XCTAssertEqual(log.count, 86); XCTAssertEqual(log2.count, 2); XCTAssertEqual(both.count, 22)
        XCTAssertEqual(presets.count, 110)
        XCTAssertEqual(presets.filter { $0.category == .film }.count, 6)
        XCTAssertEqual(presets.filter { $0.category == .cinema }.count, 32)
        XCTAssertEqual(presets.filter { $0.category == .creative }.count, 34)
        XCTAssertEqual(presets.filter { $0.category == .restore }.count, 2)
    }
}
