import MapKit
import XCTest
@testable import LumaCamera

@MainActor
final class AstroCloudForecastTests: XCTestCase {
    func testCloudLayerAppearsInActualMapPixels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let map = MKMapView()
        let controller = UIViewController()
        controller.view = map
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        map.overrideUserInterfaceStyle = .dark
        map.setRegion(.init(center: .init(latitude: 31.23, longitude: 121.47),
                            latitudinalMeters: 80_000, longitudinalMeters: 80_000), animated: false)
        let region = try XCTUnwrap(AstroCloudRegion(map.visibleMapRect))
        var requestedRegion: AstroCloudRegion?
        let coordinator = AstroNightLightsMap.Coordinator(source: TestLightSource(bounds: region.mapRect),
                                                         onCenterChange: { _ in },
                                                         onRegionChange: { requestedRegion = $0 })
        map.delegate = coordinator
        let now = Date()
        let frame = AstroCloudFrame(gridID: UUID(), date: now, region: region,
                                    values: .init(repeating: 70, count: AstroCloudRegion.sampleCount))
        try await Task.sleep(for: .milliseconds(500))
        let before = try cyanRatio(in: map)
        let start = CACurrentMediaTime()
        coordinator.updateCloudViewport(for: .cloud, zoomToken: UUID(), focus: nil, on: map)
        coordinator.updateLayers(.cloud, cloudFrame: frame, on: map)
        await Task.yield()
        XCTAssertEqual(requestedRegion, region)
        var after = before
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            after = try cyanRatio(in: map)
            if after > before + 0.15 { break }
        }
        print("ASTRO-CLOUD pixelsBefore=\(before) pixelsAfter=\(after) captureAndPollingMS=\((CACurrentMediaTime() - start) * 1000)")
        XCTAssertGreaterThan(after, before + 0.15)
    }

    func testPartialAndClearForecastFramesRemainUsable() throws {
        let region = try sampleRegion()
        let date = Date()
        let grid = AstroCloudGrid(region: region, hours: [
            date: [10, nil] + .init(repeating: 0, count: AstroCloudRegion.sampleCount - 2),
            date.addingTimeInterval(3600): .init(repeating: 0, count: AstroCloudRegion.sampleCount)
        ])
        let partial = try XCTUnwrap(grid.frame(at: date))
        XCTAssertTrue(try XCTUnwrap(partial.coverageSummary).isPartial)
        let image = try XCTUnwrap(partial.makeImage())
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertGreaterThan(bytes[3], 20)
        // Sample index 1 is missing; at the 193px raster it sits at x=16.
        XCTAssertEqual(bytes[16 * 4 + 3], 0)
        let clear = try XCTUnwrap(grid.frame(at: date.addingTimeInterval(3600)))
        let summary = try XCTUnwrap(clear.coverageSummary)
        XCTAssertEqual(summary.mean, 0)
        XCTAssertFalse(summary.isPartial)
    }



    func testLowCloudEdgeOpacityIsVisibleAndMonotonic() {
        XCTAssertEqual(AstroCloudFrame.displayOpacity(for: 0), 0)
        XCTAssertGreaterThan(AstroCloudFrame.displayOpacity(for: 20), 0.30)
        XCTAssertGreaterThan(AstroCloudFrame.displayOpacity(for: 50), AstroCloudFrame.displayOpacity(for: 20))
        XCTAssertGreaterThan(AstroCloudFrame.displayOpacity(for: 100), AstroCloudFrame.displayOpacity(for: 50))
        XCTAssertLessThanOrEqual(AstroCloudFrame.displayOpacity(for: 150), 1)
    }

    private func cyanRatio(in map: MKMapView) throws -> Double {
        let image = UIGraphicsImageRenderer(bounds: map.bounds).image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        let hits = stride(from: 0, to: bytes.count, by: 4).filter {
            let (r, g, b) = (Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2]))
            return b >= 110 && b - r >= 15 && g - r >= 10
        }.count
        return Double(hits) / Double(size * size)
    }

    func testBatchedHoursAndRasterUseViewportOrder() throws {
        let region = try sampleRegion()
        XCTAssertEqual(region.samples.count, 169)
        let last = region.samples.count - 1
        XCTAssertGreaterThan(region.samples[0].latitude, region.samples[last].latitude)
        XCTAssertLessThan(region.samples[0].longitude, region.samples[last].longitude)
        XCTAssertNil(AstroCloudRegion(.world))

        let times = [1794981600, 1794985200, 1794988800]
        let payload: [[String: Any]] = (0..<AstroCloudRegion.sampleCount).map { index in
            let cloud = Double(index) * 100 / Double(AstroCloudRegion.sampleCount - 1)
            return ["hourly": ["time": times, "cloud_cover": [cloud, 100 - cloud, 25]]]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let grid = try OpenMeteoAstroCloudProvider.decode(data, for: region)
        let start = Date(timeIntervalSince1970: TimeInterval(times[0]))
        let frame = try XCTUnwrap(grid.frame(at: start))
        let next = try XCTUnwrap(grid.frame(at: start.addingTimeInterval(3600)))
        XCTAssertEqual(frame.values.first?.flatMap { $0 }, 0)
        XCTAssertEqual(next.values.first?.flatMap { $0 }, 100)
        XCTAssertNil(grid.frame(at: start.addingTimeInterval(10_800)))

        let image = try XCTUnwrap(next.makeImage())
        XCTAssertEqual(image.width, 193)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(bytes[3], 255)
        XCTAssertEqual(bytes.last, 0)
        XCTAssertGreaterThan(bytes[3], bytes[(image.width / 2) * 4 + 3])
    }

    func testRapidFrameChangesKeepOneOverlayAndSwitchModes() async throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 360, height: 250))
        let region = try sampleRegion()
        map.setVisibleMapRect(region.mapRect, animated: false)
        let source = TestLightSource(bounds: region.mapRect)
        let coordinator = AstroNightLightsMap.Coordinator(source: source, onCenterChange: { _ in })
        map.delegate = coordinator
        coordinator.refreshOverlays(on: map)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(map.overlays.first is LightPollutionImageOverlay)
        let date = Date()
        let id = UUID()
        func frame(_ step: Int) -> AstroCloudFrame {
            AstroCloudFrame(gridID: id, date: date.addingTimeInterval(Double(step) * 3600),
                            region: region, values: .init(repeating: Double(step % 100), count: AstroCloudRegion.sampleCount))
        }
        coordinator.updateLayers(.combined, cloudFrame: frame(0), on: map)
        XCTAssertEqual(map.overlays.count, 2)
        let original = try XCTUnwrap(map.overlays.last as? AstroCloudOverlay)
        let start = CACurrentMediaTime()
        for step in 1...96 {
            coordinator.updateLayers(.combined, cloudFrame: frame(step), on: map)
            XCTAssertTrue(map.overlays.last === original)
        }
        print("ASTRO-CLOUD samples=96 rasterAndUpdateMS=\((CACurrentMediaTime() - start) * 1000)")
        coordinator.updateLayers(.cloud, cloudFrame: frame(2), on: map)
        XCTAssertEqual(map.overlays.count, 1)
        XCTAssertTrue(map.overlays.first === original)
        coordinator.updateLayers(.combined, cloudFrame: frame(3), on: map)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(map.overlays.first is LightPollutionImageOverlay)
        XCTAssertTrue(map.overlays.last === original)
        coordinator.updateLayers(.pollution, cloudFrame: frame(4), on: map)
        XCTAssertEqual(map.overlays.count, 1)
        XCTAssertTrue(map.overlays.first is LightPollutionImageOverlay)
        // A fast switch away from pollution cancels previously scheduled batches.
        for _ in 0..<20 {
            coordinator.updateLayers(.combined, cloudFrame: frame(5), on: map)
            coordinator.updateLayers(.cloud, cloudFrame: frame(5), on: map)
        }
        await Task.yield()
        XCTAssertEqual(map.overlays.count, 1)
        XCTAssertTrue(map.overlays.first is AstroCloudOverlay)
    }

    func testSitesRestoreAfterReopeningAndDeletionPersists() throws {
        let domain = "AstroCloudSites." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = AstroPlannedSite(slot: 1, coordinate: .init(latitude: 31.234567, longitude: 121.4789))
        let second = AstroPlannedSite(slot: 2, coordinate: .init(latitude: 30.53, longitude: 120.12))
        AstroPlannedSite.save([first, second], to: defaults)
        let replay = try XCTUnwrap(UserDefaults(suiteName: domain))
        for _ in 0..<20 {
            let sites = AstroPlannedSite.restore(from: replay)
            XCTAssertEqual(sites.map(\.id), [first.id, second.id])
            XCTAssertEqual(sites[0].coordinate.latitude, first.coordinate.latitude)
        }
        AstroPlannedSite.save([second], to: replay)
        XCTAssertEqual(AstroPlannedSite.restore(from: defaults).map(\.id), [second.id])
        AstroPlannedSite.save([], to: defaults)
        XCTAssertTrue(AstroPlannedSite.restore(from: replay).isEmpty)
    }

    #if DEBUG
    func testLiveRegionalCloudForecast() async throws {
        let region = try sampleRegion()
        let start = CACurrentMediaTime()
        let grid = try await OpenMeteoAstroCloudProvider().grid(for: region)
        XCTAssertEqual(grid.hours.count, 49)
        let first = try XCTUnwrap(grid.firstForecastHour)
        let frame = try XCTUnwrap(grid.frame(at: first))
        XCTAssertEqual(frame.values.compactMap { $0 }.count, 169)
        print("ASTRO-CLOUD livePublicRegion=Shanghai samples=\(AstroCloudRegion.sampleCount) hours=\(grid.hours.count) elapsedMS=\((CACurrentMediaTime() - start) * 1000)")
    }
    #endif

    private func sampleRegion() throws -> AstroCloudRegion {
        let center = MKMapPoint(.init(latitude: 31.23, longitude: 121.47))
        return try XCTUnwrap(AstroCloudRegion(.init(x: center.x - 350_000, y: center.y - 270_000,
                                                   width: 700_000, height: 540_000)))
    }
}

private struct TestLightSource: LightPollutionSource {
    let bounds: MKMapRect
    var metadata: LightPollutionMetadata { .init(name: "Test", year: 2026, license: "", attribution: "", isMeasured: false) }
    var legend: LightPollutionLegend? { nil }

    func overlays(in mapRect: MKMapRect) -> [MKOverlay] {
        [LightPollutionImageOverlay(id: "test", coordinate: MKMapPoint(x: bounds.midX, y: bounds.midY).coordinate,
                                    boundingMapRect: bounds, attribution: "", imageProvider: { nil })]
    }

    func brightness(at coordinate: CLLocationCoordinate2D) -> SkyBrightness? { nil }
}
