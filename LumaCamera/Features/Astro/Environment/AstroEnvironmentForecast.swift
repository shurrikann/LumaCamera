// Solar and lunar geometry adapted from SunCalc (c) 2014 Vladimir Agafonkin, BSD-2-Clause.

import CoreLocation
import Foundation
import Observation

struct AstroForecastPoint: Hashable, Sendable {
    private let latitude100: Int
    private let longitude100: Int

    init?(_ coordinate: CLLocationCoordinate2D) {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        latitude100 = Int((coordinate.latitude * 100).rounded())
        longitude100 = Int((coordinate.longitude * 100).rounded())
    }

    var latitude: Double { Double(latitude100) / 100 }
    var longitude: Double { Double(longitude100) / 100 }
}

struct AstroForecastHour: Identifiable, Sendable {
    let date: Date
    let temperature: Double?
    let humidity: Double?
    let dewPoint: Double?
    let cloud: Double?
    let lowCloud: Double?
    let middleCloud: Double?
    let highCloud: Double?
    let visibility: Double?
    let wind: Double?
    let windDirection: Double?
    let gust: Double?
    let precipitationChance: Double?

    var id: Date { date }
    var dewRisk: Bool {
        guard let temperature, let dewPoint else { return false }
        return temperature - dewPoint <= 2
    }
}

struct AstroForecast: Sendable {
    let hours: [AstroForecastHour]
    let timeZone: TimeZone
    let sourceName: String
    let sourceURL: URL

    func windows(at point: AstroForecastPoint, after now: Date,
                 lightPollution: LightPollutionLegend.Band? = nil) -> [DateInterval] {
        let sky = AstroDarkSkySuitability(band: lightPollution)
        guard sky != .severe else { return [] }
        let cloudLimit = sky == .high ? 25.0 : 50.0
        let moonlightLimit = sky == .high ? 0.25 : 0.5
        var windows: [(interval: DateInterval, score: Double)] = []
        var start: Date?
        var end: Date?
        var scores: [Double] = []

        func finish() {
            if let start, let end, end.timeIntervalSince(start) >= 1800 {
                windows.append((DateInterval(start: start, end: end), scores.reduce(0, +) / Double(scores.count)))
            }
            start = nil
            end = nil
            scores.removeAll(keepingCapacity: true)
        }

        for hour in hours {
            let hourEnd = hour.date.addingTimeInterval(3600)
            guard hourEnd > now else { continue }
            let hourStart = max(now, hour.date)
            let opening = AstroSkyPosition(at: hourStart, point: point)
            let closing = AstroSkyPosition(at: hourEnd, point: point)
            let moonlight = max(opening.moonlight, closing.moonlight)
            guard max(opening.sunAltitude, closing.sunAltitude) <= -18,
                  let cloud = hour.cloud, (0...cloudLimit).contains(cloud), moonlight <= moonlightLimit,
                  let precipitationChance = hour.precipitationChance,
                  (0..<35).contains(precipitationChance) else {
                finish()
                continue
            }
            if let end, hourStart > end { finish() }
            if start == nil { start = hourStart }
            end = hourEnd
            scores.append(max(cloud, hour.highCloud ?? cloud) + 60 * moonlight)
        }
        finish()
        return windows.sorted {
            if $0.score == $1.score { return $0.interval.start < $1.interval.start }
            return $0.score < $1.score
        }.prefix(2).map(\.interval).sorted { $0.start < $1.start }
    }
}

enum AstroDarkSkySuitability: Equatable {
    case unknown, normal, high, severe

    init(band: LightPollutionLegend.Band?) {
        switch band?.minimumRatio {
        case let ratio? where ratio >= 5.12: self = .severe
        case let ratio? where ratio >= 1.28: self = .high
        case .some: self = .normal
        case .none: self = .unknown
        }
    }
}

protocol AstroForecastProvider: Sendable {
    func forecast(at point: AstroForecastPoint) async throws -> AstroForecast
}

enum AstroForecastError: Error {
    case serviceUnavailable
    case transientFailure
    case invalidForecast
    case providerUnconfigured
    case rateLimited(retryAfter: TimeInterval?)
}

enum AstroWeatherRequest {
    static let cacheLifetime: TimeInterval = 1800

    static func data(from url: URL, timeout: TimeInterval = 12) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout))
        guard let http = response as? HTTPURLResponse else {
            throw AstroForecastError.serviceUnavailable
        }
        switch http.statusCode {
        case 200: return data
        case 408, 500...599: throw AstroForecastError.transientFailure
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AstroForecastError.rateLimited(retryAfter: retryAfter)
        default: throw AstroForecastError.serviceUnavailable
        }
    }

    static func retryTransientFailure<Value>(after delay: Duration = .milliseconds(650),
                                              _ operation: () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch {
            switch error {
            case AstroForecastError.transientFailure:
                break
            case AstroForecastError.rateLimited(let retryAfter):
                try await Task.sleep(for: .seconds(max(1, retryAfter ?? 2)))
                return try await operation()
            case let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code):
                break
            default:
                throw error
            }
            try await Task.sleep(for: delay)
            return try await operation()
        }
    }
}

struct OpenMeteoAstroForecastProvider: AstroForecastProvider {
    private enum Field: String, CaseIterable {
        case temperature = "temperature_2m"
        case humidity = "relative_humidity_2m"
        case dewPoint = "dew_point_2m"
        case cloud = "cloud_cover"
        case lowCloud = "cloud_cover_low"
        case middleCloud = "cloud_cover_mid"
        case highCloud = "cloud_cover_high"
        case visibility
        case wind = "wind_speed_10m"
        case windDirection = "wind_direction_10m"
        case gust = "wind_gusts_10m"
        case precipitation = "precipitation_probability"
    }

    private struct Response: Decodable {
        let timezone: String
        let hourly: [String: [Double?]]
    }

    func forecast(at point: AstroForecastPoint) async throws -> AstroForecast {
        #if DEBUG
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(point.latitude)),
            URLQueryItem(name: "longitude", value: String(point.longitude)),
            URLQueryItem(name: "hourly", value: Field.allCases.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_hours", value: "48")
        ]
        guard let url = components.url else { throw AstroForecastError.serviceUnavailable }
        return try await Self.decode(AstroWeatherRequest.data(from: url))
        #else
        throw AstroForecastError.providerUnconfigured
        #endif
    }

    static func decode(_ data: Data) throws -> AstroForecast {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let times = response.hourly["time"], let timeZone = TimeZone(identifier: response.timezone),
              let sourceURL = URL(string: "https://open-meteo.com/") else {
            throw AstroForecastError.invalidForecast
        }

        var previousDate = Date.distantPast
        let hours = times.prefix(48).enumerated().compactMap { index, timestamp -> AstroForecastHour? in
            guard let timestamp, (946_684_800...4_102_444_800).contains(timestamp) else { return nil }
            let date = Date(timeIntervalSince1970: timestamp)
            guard date > previousDate else { return nil }
            previousDate = date
            func value(_ field: Field) -> Double? {
                guard let values = response.hourly[field.rawValue], values.indices.contains(index),
                      let value = values[index], value.isFinite else { return nil }
                return value
            }
            return AstroForecastHour(date: date, temperature: value(.temperature), humidity: value(.humidity),
                                     dewPoint: value(.dewPoint), cloud: value(.cloud), lowCloud: value(.lowCloud),
                                     middleCloud: value(.middleCloud), highCloud: value(.highCloud),
                                     visibility: value(.visibility), wind: value(.wind), windDirection: value(.windDirection),
                                     gust: value(.gust), precipitationChance: value(.precipitation))
        }
        guard !hours.isEmpty else { throw AstroForecastError.invalidForecast }
        return AstroForecast(hours: hours, timeZone: timeZone, sourceName: "Open-Meteo", sourceURL: sourceURL)
    }
}

@MainActor @Observable
final class AstroForecastStore {
    static let shared = AstroForecastStore()

    private struct Entry {
        let forecast: AstroForecast
        let loadedAt: Date
    }

    private let provider: any AstroForecastProvider
    private let refreshInterval = AstroWeatherRequest.cacheLifetime
    private var entries: [AstroForecastPoint: Entry] = [:]
    private(set) var failedPoint: AstroForecastPoint?
    private(set) var isUnconfigured = false

    init(provider: any AstroForecastProvider = OpenMeteoAstroForecastProvider()) {
        self.provider = provider
    }

    func forecast(at point: AstroForecastPoint?) -> AstroForecast? {
        guard let point, let forecast = entries[point]?.forecast,
              let last = forecast.hours.last, last.date.addingTimeInterval(3600) > Date() else { return nil }
        return forecast
    }

    func load(_ point: AstroForecastPoint, now: Date = Date()) async {
        guard !Task.isCancelled else { return }
        if let entry = entries[point], now.timeIntervalSince(entry.loadedAt) < refreshInterval,
           (entry.forecast.hours.last?.date.addingTimeInterval(3600) ?? .distantPast) > now {
            if failedPoint == point { failedPoint = nil }
            return
        }
        failedPoint = nil
        isUnconfigured = false
        do {
            let forecast = try await AstroWeatherRequest.retryTransientFailure {
                try await provider.forecast(at: point)
            }
            try Task.checkCancellation()
            entries[point] = Entry(forecast: forecast, loadedAt: now)
            if entries.count > 16, let oldest = entries.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failedPoint = point
            if case AstroForecastError.providerUnconfigured = error { isUnconfigured = true }
        }
    }

    func refreshWhileVisible(_ point: AstroForecastPoint) async {
        do {
            if forecast(at: point) == nil { try await Task.sleep(for: .milliseconds(250)) }
            while !Task.isCancelled {
                await load(point)
                let elapsed = failedPoint == point ? 0 : entries[point].map { Date().timeIntervalSince($0.loadedAt) } ?? 0
                try await Task.sleep(for: .seconds(max(1, refreshInterval - elapsed)))
            }
        } catch {
            // Selection, location or visibility changed.
        }
    }
}

// Low-precision SunCalc geometry for planning. See Resources/SunCalc-LICENSE.txt.
struct AstroSkyPosition {
    let sunAltitude: Double
    let moonAltitude: Double
    let sunAzimuth: Double
    let moonAzimuth: Double
    let moonRiseSetAltitude: Double
    let illuminatedFraction: Double
    var moonlight: Double { max(0, sin(moonAltitude * .pi / 180)) * illuminatedFraction }

    init(at date: Date, point: AstroForecastPoint) {
        let radians = Double.pi / 180
        let days = date.timeIntervalSince1970 / 86400 - 10957.5
        let obliquity = 23.4397 * radians
        let latitude = point.latitude * radians
        let siderealTime = (280.16 + 360.9856235 * days + point.longitude) * radians

        func equatorial(_ longitude: Double, _ latitude: Double) -> (ra: Double, dec: Double) {
            (atan2(sin(longitude) * cos(obliquity) - tan(latitude) * sin(obliquity), cos(longitude)),
             asin(sin(latitude) * cos(obliquity) + cos(latitude) * sin(obliquity) * sin(longitude)))
        }

        func altitude(_ body: (ra: Double, dec: Double)) -> Double {
            asin(sin(latitude) * sin(body.dec) + cos(latitude) * cos(body.dec) * cos(siderealTime - body.ra)) / radians
        }

        func azimuth(_ body: (ra: Double, dec: Double)) -> Double {
            let hourAngle = siderealTime - body.ra
            let east = -cos(body.dec) * sin(hourAngle)
            let north = sin(body.dec) * cos(latitude) - cos(body.dec) * cos(hourAngle) * sin(latitude)
            let degrees = atan2(east, north) / radians
            return degrees < 0 ? degrees + 360 : degrees
        }

        let solarAnomaly = (357.5291 + 0.98560028 * days) * radians
        let solarCenter = 1.9148 * sin(solarAnomaly) + 0.02 * sin(2 * solarAnomaly) + 0.0003 * sin(3 * solarAnomaly)
        let sun = equatorial(solarAnomaly + (solarCenter + 102.9372 + 180) * radians, 0)
        let lunarAnomaly = (134.963 + 13.064993 * days) * radians
        let lunarLongitude = 218.316 + 13.176396 * days + 6.289 * sin(lunarAnomaly)
        let lunarLatitude = 5.128 * sin((93.272 + 13.229350 * days) * radians)
        let moon = equatorial(lunarLongitude * radians, lunarLatitude * radians)
        let distance = 385001 - 20905 * cos(lunarAnomaly)
        let elongationCosine = sin(sun.dec) * sin(moon.dec) + cos(sun.dec) * cos(moon.dec) * cos(sun.ra - moon.ra)
        let elongation = acos(min(1, max(-1, elongationCosine)))
        let incidence = atan2(149_598_000 * sin(elongation), distance - 149_598_000 * cos(elongation))
        sunAltitude = altitude(sun)
        sunAzimuth = azimuth(sun)
        moonAzimuth = azimuth(moon)
        moonRiseSetAltitude = -(34.0 / 60 + asin(1737.4 / distance) / radians)
        // Approximate lunar horizontal parallax. Use the geometric horizon for planning.
        let moonGeocentricAltitude = altitude(moon)
        moonAltitude = moonGeocentricAltitude - (6378 / distance) * cos(moonGeocentricAltitude * radians) / radians
        illuminatedFraction = (1 + cos(incidence)) / 2
    }
}
