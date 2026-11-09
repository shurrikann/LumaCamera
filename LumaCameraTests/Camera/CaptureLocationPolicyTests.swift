import CoreLocation
import XCTest
@testable import LumaCamera

final class CaptureLocationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fix(age: TimeInterval, accuracy: CLLocationAccuracy) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.2, longitude: 121.4),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 0,
                   timestamp: now.addingTimeInterval(-age))
    }
    func testRejectsCoarseAndStaleLocationsButKeepsRecentAccurateFix() {
        XCTAssertTrue(CaptureLocationPolicy.accepts(fix(age: 5, accuracy: 10), now: now))
        XCTAssertTrue(CaptureLocationPolicy.accepts(fix(age: 5, accuracy: 50), now: now))
        XCTAssertFalse(CaptureLocationPolicy.accepts(fix(age: 5, accuracy: 51), now: now))
        XCTAssertFalse(CaptureLocationPolicy.accepts(fix(age: 61, accuracy: 10), now: now))
        XCTAssertFalse(CaptureLocationPolicy.accepts(fix(age: 5, accuracy: -1), now: now))
        XCTAssertEqual(CaptureLocationPolicy.distanceFilter, 10)
    }
}
