import CoreLocation
import MapKit

/// 位置元数据的接受策略；宁可没有位置，也不把明显偏离或过期的点写进照片。
enum CaptureLocationPolicy {
    static let distanceFilter: CLLocationDistance = 10
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 50
    static let maximumAge: TimeInterval = 60

    static func accepts(_ location: CLLocation, now: Date = Date()) -> Bool {
        guard location.coordinate.latitude.isFinite, location.coordinate.longitude.isFinite,
              (-90...90).contains(location.coordinate.latitude),
              (-180...180).contains(location.coordinate.longitude),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumHorizontalAccuracy else { return false }
        return abs(now.timeIntervalSince(location.timestamp)) <= maximumAge
    }
    static func acceptsWatermark(_ location: CLLocation, now: Date = Date()) -> Bool {
        guard location.horizontalAccuracy.isFinite,location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 10_000 else { return false }
        return PhotoLocation.recent(location,now:now) != nil
    }

}

/// Foreground-only positioning. A missing fix never delays the shutter or automatic saving.
@MainActor
final class CaptureLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onLocationChange: ((PhotoLocation?) -> Void)?
    var onHeadingChange: ((CLLocationDirection?) -> Void)?
    private(set) var heading: CLLocationDirection?
    private let manager = CLLocationManager()
    private let tracksHeading: Bool
    private var active = false
    private var latest: CLLocation?
    private var addressLocation: CLLocation?
    private var addressText: String?
    private var cityText: String?
    private var addressRequestedAt: Date?
    private var addressTask: Task<Void,Never>?
    init(tracksHeading: Bool = false) {
        self.tracksHeading = tracksHeading
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = CaptureLocationPolicy.distanceFilter
        if tracksHeading { manager.headingFilter = 1 }
        // 相机页停留期间必须保持位置新鲜；不能靠系统暂停后的旧点写元数据。
        manager.pausesLocationUpdatesAutomatically = false
    }
    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        synchronizeAuthorization()
    }
    private func synchronizeAuthorization() {
        let enabled = active
        #if !targetEnvironment(simulator)
        guard enabled else {
            manager.stopUpdatingLocation()
            stopHeading()
            addressTask?.cancel()
            addressTask = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            if tracksHeading, CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
            // 连续更新可能沿用上一段缓存；进入相机立即请求一次新鲜定位。
            manager.requestLocation()
        default:
            latest = nil
            manager.stopUpdatingLocation()
            stopHeading()
        }
        #endif
    }
    private func stopHeading() {
        guard tracksHeading else { return }
        manager.stopUpdatingHeading()
        updateHeading(nil)
    }

    private func updateHeading(_ value: CLLocationDirection?) {
        guard heading != value else { return }
        heading = value
        onHeadingChange?(value)
    }

    static func usableHeading(trueNorth: CLLocationDirection, magneticNorth: CLLocationDirection,
                              accuracy: CLLocationDirection) -> CLLocationDirection? {
        guard accuracy.isFinite, accuracy >= 0 else { return nil }
        return [trueNorth, magneticNorth].first { $0.isFinite && (0..<360).contains($0) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard active, tracksHeading,
              manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        updateHeading(Self.usableHeading(trueNorth: newHeading.trueHeading, magneticNorth: newHeading.magneticHeading,
                                        accuracy: newHeading.headingAccuracy))
    }
    func snapshot() -> PhotoLocation? {
        guard active, manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse,
              let latest, CaptureLocationPolicy.accepts(latest) else { return nil }
        var value = PhotoLocation.recent(latest)
        if let addressLocation, latest.distance(from:addressLocation) < 150 { value?.addressText = addressText }
        return value
    }
    func watermarkSnapshot() -> PhotoLocation? {
        guard active, manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse,
              let latest,CaptureLocationPolicy.acceptsWatermark(latest) else { return nil }
        var value = PhotoLocation.recent(latest)
        if let addressLocation,latest.distance(from:addressLocation)<150 {
            value?.addressText = latest.horizontalAccuracy <= CaptureLocationPolicy.maximumHorizontalAccuracy ? addressText : cityText
        }
        return value
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        synchronizeAuthorization()
        onLocationChange?(watermarkSnapshot())
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active else { return }
        if let value = locations.last(where: { CaptureLocationPolicy.acceptsWatermark($0) }) {
            latest = value
            resolveAddress(value)
            onLocationChange?(watermarkSnapshot())
        }
    }
    private func resolveAddress(_ location:CLLocation) {
        if let addressRequestedAt,Date().timeIntervalSince(addressRequestedAt)<60 { return }
        if let addressLocation,location.distance(from:addressLocation)<100,
           let addressRequestedAt,Date().timeIntervalSince(addressRequestedAt)<300 { return }
        guard addressTask == nil else { return }
        addressRequestedAt = Date()
        addressTask = Task { @MainActor [weak self] in
            let text: String?
            let city: String?
            if #available(iOS 26.0, *) {
                if let request = MKReverseGeocodingRequest(location:location) {
                    request.preferredLocale = Locale(identifier:"zh_CN")
                    let item = try? await request.mapItems.first
                    text = item?.address?.fullAddress
                    city = item?.addressRepresentations?.cityName
                } else { text = nil; city = nil }
            } else {
                let geocoder = CLGeocoder()
                if let place = try? await geocoder.reverseGeocodeLocation(location,preferredLocale:Locale(identifier:"zh_CN")).first {
                    text = [place.locality,place.subLocality,place.thoroughfare,place.subThoroughfare].compactMap{$0}.joined(separator:" · ")
                    city = place.locality
                } else { text = nil; city = nil }
            }
            guard let self,!Task.isCancelled else { return }
            if !(text ?? "").isEmpty || !(city ?? "").isEmpty {
                self.addressText = text; self.cityText = city; self.addressLocation = location
                self.onLocationChange?(self.watermarkSnapshot())
            }
            self.addressTask = nil
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            latest = nil
            onLocationChange?(nil)
            stopHeading()
        }
    }
}
