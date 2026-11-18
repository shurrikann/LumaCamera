import XCTest
@testable import LumaCamera

final class AstroTimeRulerTests: XCTestCase {
    func testPointerMapsAcrossFull48HoursAndClampsEdges() {
        let width: CGFloat = 300
        XCTAssertEqual(AstroTimeRuler.hour(at: 0, width: width, maxHour: 47), 0)
        XCTAssertEqual(AstroTimeRuler.hour(at: width, width: width, maxHour: 47), 47)
        XCTAssertEqual(AstroTimeRuler.hour(at: width / 2, width: width, maxHour: 47), 24)
        XCTAssertEqual(AstroTimeRuler.hour(at: -40, width: width, maxHour: 47), 0)
        XCTAssertEqual(AstroTimeRuler.hour(at: width + 40, width: width, maxHour: 47), 47)
        XCTAssertEqual(AstroTimeRuler.hour(at: width / 4, width: width, maxHour: 47), 12)
    }

    func testInvalidWidthDoesNotProduceNaN() {
        XCTAssertEqual(AstroTimeRuler.hour(at: 10, width: 0, maxHour: 47), 0)
        XCTAssertEqual(AstroTimeRuler.hour(at: 10, width: .nan, maxHour: 47), 0)
    }
}
