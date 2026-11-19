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

    func testFalchiLegendAndClassifiedPhotographicSites() throws {
        let source = Falchi2016Source()
        let bands = try XCTUnwrap(source.legend).bands
        XCTAssertEqual(bands.count, 14)
        XCTAssertEqual(bands.map(\.minimumRatio), bands.map(\.minimumRatio).sorted())
        XCTAssertEqual(Set(bands.map(\.rgb)).count, bands.count)
        let city = LightPollutionPoint(.init(latitude: 40.758, longitude: -73.985))
        let sea = LightPollutionPoint(.init(latitude: 30, longitude: -45))
        let beyondAtlas = LightPollutionPoint(.init(latitude: -82, longitude: 0))
        let start = CACurrentMediaTime()
        var measurements = [Double]()
        for _ in 0..<20 {
            let sample = CACurrentMediaTime()
            XCTAssertEqual(source.band(at: city), bands.last)
            XCTAssertEqual(source.band(at: sea), bands.first)
            XCTAssertNil(source.band(at: beyondAtlas))
            measurements.append((CACurrentMediaTime() - sample) * 1000)
        }
        print("FALCHI-POINT-SAMPLING cycles=\(measurements.count) pointsPerCycle=3 firstMS=\(measurements[0]) totalMS=\((CACurrentMediaTime() - start) * 1000)")
    }
}
