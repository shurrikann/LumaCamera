import CoreLocation
import ImageIO

struct PhotoLocation: Codable, Equatable, Hashable {
    let latitude: Double
    let longitude: Double
    var altitude: Double? = nil
    var horizontalAccuracy: Double? = nil
    var timestamp: Date = Date()

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var clLocation: CLLocation { CLLocation(coordinate: coordinate, altitude: altitude ?? 0, horizontalAccuracy: horizontalAccuracy ?? -1, verticalAccuracy: altitude == nil ? -1 : 0, timestamp: timestamp) }
    var coordinateText: String { String(format: "%.5f, %.5f", latitude, longitude) }

    static func recorded(_ location: CLLocation) -> Self? {
        let value = Self(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                         altitude: location.verticalAccuracy >= 0 && location.altitude.isFinite ? location.altitude : nil,
                         horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil, timestamp: location.timestamp)
        return value.isValid ? value : nil
    }
    static func recent(_ location: CLLocation, now: Date = Date()) -> Self? {
        let value = Self(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                         altitude: location.verticalAccuracy >= 0 && location.altitude.isFinite ? location.altitude : nil,
                         horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp)
        guard value.isValid, location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
              abs(now.timeIntervalSince(location.timestamp)) <= 60 else { return nil }
        return value
    }
    var gpsMetadata: [String: Any] {
        guard isValid else { return [:] }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy:MM:dd"
        var result: [String: Any] = [kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSDateStamp as String: formatter.string(from: timestamp)]
        formatter.dateFormat = "HH:mm:ss.SSS"
        result[kCGImagePropertyGPSTimeStamp as String] = formatter.string(from: timestamp)
        if let altitude, altitude.isFinite {
            result[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            result[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return result
    }
    static func fromGPS(_ properties: [CFString: Any], date: Date = Date()) -> Self? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [String: Any],
              let lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue else { return nil }
        let latitude = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -abs(lat) : lat
        let longitude = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -abs(lon) : lon
        let altitude = (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue
        let below = (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue == 1
        let value = Self(latitude: latitude, longitude: longitude, altitude: altitude.flatMap { $0.isFinite ? (below ? -abs($0) : $0) : nil }, timestamp: date)
        return value.isValid ? value : nil
    }
}
