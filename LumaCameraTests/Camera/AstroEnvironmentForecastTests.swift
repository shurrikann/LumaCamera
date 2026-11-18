import CoreLocation
import XCTest
@testable import LumaCamera

@MainActor
final class AstroEnvironmentForecastTests: XCTestCase {
    func testDecodeKeepsTimestampsTimeZoneAndMissingFields() throws {
        let data = Data("""
        {"timezone":"America/New_York","hourly":{
          "time":[1793509200,1793512800,1793520000],
          "temperature_2m":[8,7,6],"cloud_cover":[0,null,75],"cloud_cover_high":[5],
          "relative_humidity_2m":[85,90,92],"dew_point_2m":[7,6,4],"visibility":[10000],
          "wind_speed_10m":[12],"wind_gusts_10m":[24]}}
        """.utf8)
        let forecast = try OpenMeteoAstroForecastProvider.decode(data)
        XCTAssertEqual(forecast.timeZone.identifier, "America/New_York")
        XCTAssertEqual(forecast.hours.map(\.date.timeIntervalSince1970), [1793509200, 1793512800, 1793520000])
        XCTAssertEqual(forecast.hours.map(\.cloud), [0, nil, 75])
        XCTAssertEqual(forecast.hours.map(\.highCloud), [5, nil, nil])
        XCTAssertEqual(forecast.hours.first?.visibility, 10000)
        XCTAssertTrue(forecast.hours[0].dewRisk)
        XCTAssertThrowsError(try OpenMeteoAstroForecastProvider.decode(Data(
            #"{"timezone":"invalid","hourly":{"time":[1793509200]}}"#.utf8)))
    }

    func testWindowsRequireDarknessAndUsableWeather() throws {
        let point = try XCTUnwrap(AstroForecastPoint(.init(latitude: 31.23, longitude: 121.47)))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T10:00:00Z"))
        let forecast = try makeForecast(start: start) { index in index == 6 ? nil : (index == 7 ? 80 : 15) }
        let windows = forecast.windows(at: point, after: start)
        XCTAssertFalse(windows.isEmpty)
        for window in windows {
            XCTAssertLessThanOrEqual(AstroSkyPosition(at: window.start, point: point).sunAltitude, -18)
            XCTAssertLessThanOrEqual(AstroSkyPosition(at: window.end, point: point).sunAltitude, -18)
            XCTAssertFalse(window.contains(start.addingTimeInterval(6.5 * 3600)))
            XCTAssertFalse(window.contains(start.addingTimeInterval(7.5 * 3600)))
        }
        let midday = start.addingTimeInterval(18 * 3600)
        XCTAssertGreaterThan(AstroSkyPosition(at: midday, point: point).sunAltitude, 15)
        XCTAssertLessThan(AstroSkyPosition(at: start, point: point).illuminatedFraction, 0.1)
        let cloudy = try makeForecast(start: start) { _ in 100 }
        XCTAssertTrue(cloudy.windows(at: point, after: start).isEmpty)
        let expired = start.addingTimeInterval(48 * 3600)
        XCTAssertTrue(forecast.windows(at: point, after: expired).isEmpty)
    }

    func testCacheSeparatesSitesAndReusesNearbyPointsAfterSwitching() async throws {
        let current = try XCTUnwrap(AstroForecastPoint(.init(latitude: 31.23, longitude: 121.47)))
        let nearby = try XCTUnwrap(AstroForecastPoint(.init(latitude: 31.231, longitude: 121.471)))
        let alternate = try XCTUnwrap(AstroForecastPoint(.init(latitude: 30, longitude: 120)))
        let provider = CountingProvider(result: try makeForecast(start: Date()) { _ in 15 })
        let store = AstroForecastStore(provider: provider)
        for point in [current, nearby, alternate, current, alternate] { await store.load(point) }
        let requested = await provider.points
        XCTAssertEqual(requested, [current, alternate])
        XCTAssertNotNil(store.forecast(at: current))
        XCTAssertNotNil(store.forecast(at: alternate))
        let cancelled = Task { await store.refreshWhileVisible(current) }
        cancelled.cancel()
        await cancelled.value
        let afterCancellation = await provider.points
        XCTAssertEqual(afterCancellation.count, 2)
    }

    func testWindowCalculationWithRepeated48HourInputs() throws {
        let point = try XCTUnwrap(AstroForecastPoint(.init(latitude: 31.23, longitude: 121.47)))
        let start = Date()
        let forecast = try makeForecast(start: start) { _ in 20 }
        var finished = 0
        let first = CACurrentMediaTime()
        for _ in 0..<100 { finished += forecast.windows(at: point, after: start).count }
        print("ASTRO-FORECAST rankingRuns=100 hours=48 calculatedWindows=\(finished) totalMS=\((CACurrentMediaTime() - first) * 1000)")
    }

    #if DEBUG
    func testDevelopmentProviderWithPublicShanghaiCoordinate() async throws {
        let point = try XCTUnwrap(AstroForecastPoint(.init(latitude: 31.23, longitude: 121.47)))
        let start = CACurrentMediaTime()
        let forecast = try await OpenMeteoAstroForecastProvider().forecast(at: point)
        let elapsed = (CACurrentMediaTime() - start) * 1000
        XCTAssertEqual(forecast.hours.count, 48)
        XCTAssertEqual(forecast.timeZone.identifier, "Asia/Shanghai")
        XCTAssertTrue(forecast.hours.contains { $0.cloud != nil && $0.highCloud != nil && $0.wind != nil })
        print("ASTRO-FORECAST livePublicPoint=Shanghai samples=1 hours=\(forecast.hours.count) requestAndDecodeMS=\(elapsed)")
    }
    #endif

    private func makeForecast(start: Date, cloud: (Int) -> Int?) throws -> AstroForecast {
        let hours = (0..<48).map { index in
            AstroForecastHour(date: start.addingTimeInterval(Double(index) * 3600),
                              temperature: 9, humidity: 75, dewPoint: 6, cloud: cloud(index).map(Double.init),
                              lowCloud: nil, middleCloud: nil, highCloud: 10, visibility: 9000,
                              wind: 19, windDirection: 350, gust: 25, precipitationChance: 0)
        }
        return AstroForecast(hours: hours, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")),
                             sourceName: "Fixture", sourceURL: URL(fileURLWithPath: "/"))
    }
}

private actor CountingProvider: AstroForecastProvider {
    let result: AstroForecast
    private(set) var points: [AstroForecastPoint] = []

    init(result: AstroForecast) { self.result = result }

    func forecast(at point: AstroForecastPoint) async throws -> AstroForecast {
        points.append(point)
        return result
    }
}
