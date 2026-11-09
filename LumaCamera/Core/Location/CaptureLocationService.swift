import CoreLocation

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
}

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
        manager.distanceFilter = CaptureLocationPolicy.distanceFilter
        // 相机页停留期间必须保持位置新鲜；不能靠系统暂停后的旧点写元数据。
        manager.pausesLocationUpdatesAutomatically = false
    }
    func setActive(_ enabled: Bool) {
        active = enabled
        #if !targetEnvironment(simulator)
        guard enabled else { manager.stopUpdatingLocation(); return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            // 连续更新可能沿用上一段缓存；进入相机立即请求一次新鲜定位。
            manager.requestLocation()
        default: latest = nil; manager.stopUpdatingLocation()
        }
        #endif
    }
    func snapshot() -> PhotoLocation? {
        guard active, manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse,
              let latest, CaptureLocationPolicy.accepts(latest) else { return nil }
        return PhotoLocation.recent(latest)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { setActive(active) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active else { return }
        if let value = locations.last(where: { CaptureLocationPolicy.accepts($0) }) {
            latest = value
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { latest = nil }
    }
}
