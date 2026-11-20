import MapKit
import XCTest
@testable import LumaCamera

final class AstroHorizonEventTests: XCTestCase {
    func testShanghaiAgainstUSNO() throws {
        let request = try request(latitude: 31.23, longitude: 121.47, zone: "Asia/Shanghai", day: "2026-11-20T12:00:00+08:00")
        let events = request.events()
        XCTAssertEqual(events.map(\.kind), [.moonset, .sunrise, .moonrise, .sunset])
        let expected: [(AstroHorizonEvent.Kind, String, Double, ClosedRange<Double>)] = [
            (.moonset, "01:29", 10, 250...285),
            (.sunrise, "06:25", 3, 110...120),
            (.moonrise, "13:47", 10, 75...110),
            (.sunset, "16:54", 3, 240...250),
        ]
        for (kind, time, tolerance, bearing) in expected {
            let event = try XCTUnwrap(events.first { $0.kind == kind })
            let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T\(time):00+08:00"))
            let deltaMinutes = abs(event.date.timeIntervalSince(reference)) / 60
            print("ASTRO-HORIZON \(kind.rawValue) deltaMin=\(deltaMinutes) azimuth=\(event.azimuth)")
            XCTAssertLessThanOrEqual(deltaMinutes, tolerance)
            XCTAssertTrue(bearing.contains(event.azimuth))
        }
    }

    func testPolarDaysAndShortLocalDay() throws {
        let summer = try request(latitude: 78, longitude: 15, zone: "Europe/Oslo", day: "2026-06-21T12:00:00+02:00")
        let winter = try request(latitude: 78, longitude: 15, zone: "Europe/Oslo", day: "2026-12-21T12:00:00+01:00")
        XCTAssertFalse(summer.events().contains { $0.kind.isSolar })
        XCTAssertFalse(winter.events().contains { $0.kind.isSolar })
        let dst = try request(latitude: 40.71, longitude: -74.01, zone: "America/New_York", day: "2026-03-08T12:00:00-04:00")
        XCTAssertEqual(dst.day.duration, 23 * 3600)
        XCTAssertTrue(dst.events().allSatisfy { $0.date >= dst.day.start && $0.date < dst.day.end })
    }

    func testChangingDayAndPointProducesDeterministicResults() throws {
        let requests = try [
            request(latitude: 31.23, longitude: 121.47, zone: "Asia/Shanghai", day: "2026-11-20T12:00:00+08:00"),
            request(latitude: 31.23, longitude: 121.47, zone: "Asia/Shanghai", day: "2026-11-21T12:00:00+08:00"),
            request(latitude: 39.90, longitude: 116.41, zone: "Asia/Shanghai", day: "2026-11-20T12:00:00+08:00"),
        ]
        let reference = requests.map { $0.events() }
        XCTAssertNotEqual(reference[0], reference[1])
        XCTAssertNotEqual(reference[0], reference[2])
        let start = ContinuousClock.now
        for _ in 0..<10 {
            for (request, expected) in zip(requests, reference) { XCTAssertEqual(request.events(), expected) }
        }
        print("ASTRO-HORIZON samples=30 computeTotal=\(start.duration(to: .now))")
    }

    private func request(latitude: Double, longitude: Double, zone: String, day: String) throws -> AstroHorizonRequest {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let point = try XCTUnwrap(AstroForecastPoint(coordinate))
        let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: day))
        return try XCTUnwrap(AstroHorizonRequest(point: point, date: date, timeZone: timeZone))
    }
}
