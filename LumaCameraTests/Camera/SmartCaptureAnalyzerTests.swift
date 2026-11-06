import XCTest
import UIKit
@testable import LumaCamera

final class SmartCaptureAnalyzerTests: XCTestCase {
    @MainActor func testAnalyzerReturnsNightForDarkPreview() throws {
        let image = Self.solidImage(.black)
        let result = SmartCaptureAnalyzer.analyze(image: image, readings: nil, activeSubmode: nil)
        XCTAssertEqual(result.suggestion?.kind, .night)
        XCTAssertEqual(result.suggestion?.actionTitle, "应用")
        XCTAssertFalse(result.hasPerson)
        let trackingOnly = SmartCaptureAnalyzer.analyze(image:image,readings:nil,activeSubmode:nil,nominateComposition:false)
        XCTAssertEqual(trackingOnly.suggestion,result.suggestion,"跳过重新提名不能丢掉夜景场景建议")
        XCTAssertTrue(trackingOnly.candidates.isEmpty)
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
