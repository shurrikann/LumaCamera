import XCTest
import UIKit
@testable import LumaCamera

final class SmartCaptureAnalyzerTests: XCTestCase {
    @MainActor func testNightSuggestionIsRemovedForDarkPreview() throws {
        let image = Self.solidImage(.black)
        let result = SmartCaptureAnalyzer.analyze(image: image, readings: nil, activeSubmode: nil)
        XCTAssertNil(result.suggestion, "夜景功能已取消，不应再提出夜景建议")
        XCTAssertFalse(result.hasPerson)
        let trackingOnly = SmartCaptureAnalyzer.analyze(image:image,readings:nil,activeSubmode:nil,nominateComposition:false)
        XCTAssertNil(trackingOnly.suggestion)
        XCTAssertTrue(trackingOnly.candidates.isEmpty)
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
