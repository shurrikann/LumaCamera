import CoreLocation

/// Foreground-only positioning. A missing fix never delays the shutter or automatic saving.
@MainActor
final class CaptureLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var active = false
    private var latest: CLLocation?
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }
    func setActive(_ enabled: Bool) {
        active = enabled
        #if !targetEnvironment(simulator)
        guard enabled else { manager.stopUpdatingLocation(); return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        default: latest = nil; manager.stopUpdatingLocation()
        }
        #endif
    }
    func snapshot() -> PhotoLocation? {
        guard active, manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse,
              let latest else { return nil }
        return PhotoLocation.recent(latest)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { setActive(active) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active else { return }
        latest = locations.last { PhotoLocation.recent($0) != nil } ?? latest
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { latest = nil }
    }
}
