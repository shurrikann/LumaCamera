import CoreLocation
import MapKit
import XCTest
@testable import LumaCamera

final class LightPollutionSourceTests: XCTestCase {
    func testFalchiBundleLoadsAllCellsAndMetadata() {
        let source = Falchi2016Source()
        XCTAssertEqual(source.metadata.year, 2016)
        XCTAssertEqual(source.metadata.license, "CC BY-NC 4.0")
        XCTAssertFalse(source.metadata.isMeasured)
        XCTAssertEqual(source.overlays(in: .world).count, 731)
        XCTAssertNotNil(Falchi2016Source.image(named: "ArtificialSkyBrightness0.JPG"))
        XCTAssertNil(source.brightness(at: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47)))
    }

    func testFactoryExposesProtocolOnly() {
        let source: any LightPollutionSource = LightPollutionSources.current
        XCTAssertFalse(source.metadata.name.isEmpty)
        XCTAssertFalse(source.overlays(in: .world).isEmpty)
    }
}
