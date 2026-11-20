import Foundation

struct AstroHorizonEvent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case sunrise = "日出"
        case sunset = "日落"
        case moonrise = "月升"
        case moonset = "月落"

        var isSolar: Bool { self == .sunrise || self == .sunset }
        var isRise: Bool { self == .sunrise || self == .moonrise }
    }

    let kind: Kind
    let date: Date
    let azimuth: Double

    var direction: String {
        let sectors = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        return sectors[Int((azimuth / 45).rounded()) % sectors.count] + " " + String(Int(azimuth.rounded()) % 360) + "°"
    }
}

struct AstroHorizonRequest: Equatable, Sendable {
    let point: AstroForecastPoint
    let day: DateInterval
    let timeZone: TimeZone

    init?(point: AstroForecastPoint, date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = calendar.dateInterval(of: .day, for: date) else { return nil }
        self.point = point
        self.day = day
        self.timeZone = timeZone
    }

    func events() -> [AstroHorizonEvent] {
        var results: [AstroHorizonEvent] = []
        var previousTime = day.start
        var previousSky = AstroSkyPosition(at: previousTime, point: point)
        while previousTime < day.end {
            let time = min(previousTime.addingTimeInterval(300), day.end)
            let sky = AstroSkyPosition(at: time, point: point)
            for solar in [true, false] {
                let initial = altitude(previousSky, solar: solar)
                let final = altitude(sky, solar: solar)
                guard (initial >= 0) != (final >= 0) else { continue }
                let rising = final > initial
                let kind: AstroHorizonEvent.Kind = solar ? (rising ? .sunrise : .sunset) : (rising ? .moonrise : .moonset)
                var lower = previousTime
                var upper = time
                while upper.timeIntervalSince(lower) > 0.5 {
                    let midpoint = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
                    let above = altitude(AstroSkyPosition(at: midpoint, point: point), solar: solar) >= 0
                    if above == rising { upper = midpoint } else { lower = midpoint }
                }
                guard upper < day.end else { continue }
                let event = AstroSkyPosition(at: upper, point: point)
                results.append(.init(kind: kind, date: upper, azimuth: solar ? event.sunAzimuth : event.moonAzimuth))
            }
            previousTime = time
            previousSky = sky
        }
        return results.sorted { $0.date < $1.date }
    }

    private func altitude(_ sky: AstroSkyPosition, solar: Bool) -> Double {
        // Approximate upper-limb contact for an unobstructed horizon and standard refraction.
        solar ? sky.sunAltitude + 50.0 / 60 : sky.moonAltitude - sky.moonRiseSetAltitude
    }
}
