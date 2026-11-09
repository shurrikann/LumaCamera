import XCTest
@testable import LumaCamera

final class LogLUTClassificationTests: XCTestCase {
    func testBundledLogLUTsSplitByAppleLogCurve() {
        let presets = LogLUTCubeRepository.presets()
        let log = presets.filter { $0.requiredColorSpace == .appleLog }
        let log2 = presets.filter { $0.requiredColorSpace == .appleLog2 }
        print("LOG-LUT-CLASS appleLog=\(log.count) appleLog2=\(log2.count) total=\(presets.count)")
        XCTAssertTrue(log.contains { $0.id == "AppleLog_Rec709" })
        XCTAssertTrue(log2.contains { $0.id == "AppleLog2_Rec709" })
        XCTAssertTrue(log2.contains { $0.id == "ARRI_AppleLog2" })
        XCTAssertEqual(presets.count, log.count + log2.count)
        XCTAssertEqual(Set(log.map(\.requiredColorSpace)), [.appleLog])
    }
}
