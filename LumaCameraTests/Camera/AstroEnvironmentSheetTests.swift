import MapKit
import SwiftUI
import XCTest
@testable import LumaCamera

@MainActor
final class AstroEnvironmentSheetTests: XCTestCase {
    func testHorizonPanelFitsCompactMap() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00-04:00"))
        let point = try XCTUnwrap(AstroForecastPoint(.init(latitude: 40.71, longitude: -74.01)))
        let request = try XCTUnwrap(AstroHorizonRequest(point: point, date: date, timeZone: zone))
        let panel = AstroHorizonPanel(request: request, events: request.events())
        let renderer = ImageRenderer(content: panel
            .frame(width: 288)
            .environment(\.locale, Locale(identifier: "zh_CN")))
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 288, accuracy: 1)
        XCTAssertLessThan(image.size.height, 95)
        print("ASTRO-HORIZON panelPoints=\(image.size)")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Horizon time card"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHorizonAnnotationFollowsSiteWithoutInterceptingMapGestures() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 360, height: 250))
        let coordinator = AstroNightLightsMap.Coordinator(source: LightPollutionSources.current, onCenterChange: { _ in })
        let sites = [
            CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
            CLLocationCoordinate2D(latitude: 39.90, longitude: 116.41),
        ]
        let events = [AstroHorizonEvent(kind: .sunrise, date: Date(), azimuth: 100)]
        coordinator.updateHorizon(origin: sites[0], events: events, on: map)
        let annotation = try XCTUnwrap(map.annotations.compactMap { $0 as? AstroHorizonAnnotation }.first)
        let view = try XCTUnwrap(coordinator.mapView(map, viewFor: annotation) as? AstroHorizonAnnotationView)
        XCTAssertNotNil(view.image)
        XCTAssertFalse(view.isUserInteractionEnabled)
        let north = AstroHorizonAnnotationView.point(from: CGPoint(x: 50, y: 50), angle: 0, radius: 20)
        let east = AstroHorizonAnnotationView.point(from: CGPoint(x: 50, y: 50), angle: .pi / 2, radius: 20)
        XCTAssertEqual(north, CGPoint(x: 50, y: 30))
        XCTAssertEqual(east, CGPoint(x: 70, y: 50))
        for i in 0..<20 {
            let site = sites[i % sites.count]
            coordinator.updateHorizon(origin: site, events: events, on: map)
            XCTAssertEqual(map.annotations.filter { $0 is AstroHorizonAnnotation }.count, 1)
            XCTAssertEqual(annotation.coordinate.latitude, site.latitude)
            XCTAssertEqual(annotation.coordinate.longitude, site.longitude)
        }
        coordinator.updateHorizon(origin: sites[0], events: [], on: map)
        XCTAssertFalse(map.annotations.contains { $0 === annotation })
        coordinator.updateHorizon(origin: sites[1], events: events, on: map)
        XCTAssertTrue(map.annotations.contains { $0 === annotation })
        coordinator.updateHorizon(origin: nil, events: events, on: map)
        XCTAssertFalse(map.annotations.contains { $0 === annotation })
    }

    func testMapPanSwitchesFromSavedPinToNewForecastPoint() throws {
        var selection = AstroForecastSelection()
        let site = AstroPlannedSite(slot: 1, coordinate: .init(latitude: 31.23, longitude: 121.47))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 360, height: 250))
        let coordinator = AstroNightLightsMap.Coordinator(
            source: LightPollutionSources.current,
            onCenterChange: { selection.updateCenter($0) },
            onPan: { selection.updateCenter($0, afterPan: true) },
            onSelectSite: { selection.siteID = $0 }
        )
        let view = try XCTUnwrap(coordinator.mapView(map, viewFor: AstroSiteAnnotation(site: site)))
        let point = try XCTUnwrap(AstroForecastPoint(site.coordinate))
        map.setRegion(MKCoordinateRegion(center: .init(latitude: 30.10, longitude: 120.25),
                                         latitudinalMeters: 50_000, longitudinalMeters: 50_000), animated: false)
        let center = try XCTUnwrap(AstroForecastPoint(map.centerCoordinate))
        XCTAssertNotEqual(point, center)
        let start = CACurrentMediaTime()
        for _ in 0..<20 {
            coordinator.mapView(map, didSelect: view)
            selection.updateCenter(map.centerCoordinate)
            XCTAssertEqual(selection.point(sites: [site], location: nil), point)
            coordinator.finishMapPan(on: map)
            XCTAssertNil(selection.siteID)
            XCTAssertEqual(selection.point(sites: [site], location: nil), center)
        }
        XCTAssertEqual(site.coordinate.longitude, 121.47)
        print("ASTRO-FORECAST-PAN samples=20 selectThenPanTotalMS=\((CACurrentMediaTime() - start) * 1000)")
    }

    func testMapSurvivesDetentChangesAndReopensAtMedium() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = EnvironmentSheetState()
        let host = UIHostingController(rootView: EnvironmentSheetHarness(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        var times = [Int]()
        var bottomGaps = [CGFloat]()
        var layerTimings = [Double]()
        for angle in [0.0, 90, -90, 0.0] {
            state.angle = angle
            let start = CACurrentMediaTime()
            state.show = true
            try await wait { host.presentedViewController?.viewIfLoaded.flatMap(self.findMap)?.bounds.height ?? 0 > 0 }
            let panel = try XCTUnwrap(host.presentedViewController)
            let sheet = try XCTUnwrap(panel.sheetPresentationController)
            let map = try XCTUnwrap(findMap(panel.view))
            times.append(Int((CACurrentMediaTime() - start) * 1000))
            try await Task.sleep(for: .milliseconds(550))
            let mediumSize = map.bounds.size
            let collapsedHeight = panel.view.bounds.height
            XCTAssertEqual(mediumSize.height, 250, accuracy: 1)
            XCTAssertLessThan(mediumSize.height, collapsedHeight)
            XCTAssertEqual(scene.interfaceOrientation, .portrait)
            XCTAssertEqual(map.traitCollection.userInterfaceStyle, .dark)
            XCTAssertEqual(map.traitCollection.accessibilityContrast, .high)
            let scroll = try XCTUnwrap(findScrollView(panel.view))
            let viewport = scroll.convert(scroll.bounds, to: window)
            let panelFrame = panel.view.convert(panel.view.bounds, to: window)
            print("ASTRO-ENVIRONMENT viewportBottom=\(viewport.maxY) sheetBottom=\(panelFrame.maxY)")
            XCTAssertEqual(viewport.maxY, panelFrame.maxY, accuracy: 1)
            let expectedBottomGap = window.safeAreaInsets.bottom + 8
            XCTAssertEqual(scroll.adjustedContentInset.bottom, expectedBottomGap, accuracy: 1)
            let top = scroll.contentOffset
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            XCTAssertGreaterThan(bottom, top.y)
            scroll.setContentOffset(CGPoint(x: top.x, y: bottom), animated: false)
            let gap = scroll.contentOffset.y + scroll.bounds.height - scroll.contentSize.height
            XCTAssertEqual(gap, expectedBottomGap, accuracy: 1)
            bottomGaps.append(gap)
            scroll.setContentOffset(top, animated: false)

            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            try await wait { panel.view.bounds.height > collapsedHeight + 100 }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(findMap(panel.view) === map)
            XCTAssertGreaterThanOrEqual(map.bounds.height, mediumSize.height)
            XCTAssertEqual(map.bounds.width, mediumSize.width, accuracy: 1)
            if layerTimings.isEmpty {
                let picker = try XCTUnwrap(findLayerPicker(panel.view))
                let pollutionHeight = scroll.contentSize.height
                for _ in 0..<3 {
                    for index in [1, 2, 0] {
                        let start = CACurrentMediaTime()
                        picker.selectedSegmentIndex = index
                        picker.sendActions(for: .valueChanged)
                        try await wait {
                            switch index {
                            case 1: return scroll.contentSize.height < pollutionHeight - 6
                            case 2: return scroll.contentSize.height > pollutionHeight + 6
                            default: return abs(scroll.contentSize.height - pollutionHeight) < 1
                            }
                        }
                        XCTAssertTrue(findMap(panel.view) === map)
                        layerTimings.append((CACurrentMediaTime() - start) * 1000)
                    }
                }
            }
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
            try await wait { abs(panel.view.bounds.height - collapsedHeight) < 1 }
            XCTAssertEqual(map.bounds.height, mediumSize.height, accuracy: 1)

            state.show = false
            try await wait { host.presentedViewController == nil }
        }

        state.show = true
        try await wait { host.presentedViewController != nil }
        state.show = false
        try await wait { host.presentedViewController == nil }
        print("ASTRO-ENVIRONMENT samples=\(times.count) angles=0,90,-90,0 layoutReadyMilliseconds=\(times) (20ms polling; excludes network tiles)")
        print("ASTRO-ENVIRONMENT bottomInsetPoints=\(bottomGaps)")
        print("ASTRO-ENVIRONMENT-LEGEND layerSwitches=\(layerTimings.count) layoutMilliseconds=\(layerTimings)")
    }

    func testDeleteAndRefillRemovesOnlyMatchingPin() {
        let map = MKMapView()
        let coordinator = AstroNightLightsMap.Coordinator(source: LightPollutionSources.current, onCenterChange: { _ in })
        let coordinate = CLLocationCoordinate2D(latitude: 31, longitude: 121)
        let first = AstroPlannedSite(slot: 1, coordinate: coordinate)
        let second = AstroPlannedSite(slot: 2, coordinate: coordinate)
        let third = AstroPlannedSite(slot: 3, coordinate: coordinate)
        coordinator.syncSites([first, second, third], on: map)
        XCTAssertNil(AstroPlannedSite.availableSlot(in: [first, second, third]))
        let survivors = [first, third]
        let slot = AstroPlannedSite.availableSlot(in: survivors)
        XCTAssertEqual(slot, 2)
        var times = [Double]()
        for _ in 0..<20 {
            let start = CACurrentMediaTime()
            coordinator.syncSites(survivors, on: map)
            coordinator.syncSites(survivors, on: map)
            XCTAssertEqual(Set(map.annotations.compactMap { ($0 as? AstroSiteAnnotation)?.site.id }), Set(survivors.map(\.id)))
            let replacement = AstroPlannedSite(slot: slot ?? -1, coordinate: coordinate)
            let updated = survivors + [replacement]
            coordinator.syncSites(updated, on: map)
            XCTAssertEqual(Set(map.annotations.compactMap { ($0 as? AstroSiteAnnotation)?.site.id }), Set(updated.map(\.id)))
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        coordinator.syncSites([], on: map)
        XCTAssertTrue(map.annotations.isEmpty)
        print("ASTRO-SITES samples=\(times.count) mutationAndAssertionsMaxMS=\(times.max() ?? 0)")
    }

    func testSolidLocationMarkerTracksRegionAcrossResizeAndMissingHeading() {
        let viewport = AstroMapViewport(frame: CGRect(x: 0, y: 0, width: 360, height: 250))
        let map = viewport.map
        let coordinator = AstroNightLightsMap.Coordinator(source: LightPollutionSources.current, onCenterChange: { _ in })
        coordinator.viewport = viewport
        viewport.layoutIfNeeded()
        let marker = viewport.locationMarker
        let location = CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47)
        let near = CLLocationCoordinate2D(latitude: 31.24, longitude: 121.48)
        map.setRegion(.init(center: location, latitudinalMeters: 12_000, longitudinalMeters: 12_000), animated: false)
        viewport.setLocation(location)
        XCTAssertEqual(CaptureLocationService.usableHeading(trueNorth: 90, magneticNorth: 80, accuracy: 3), 90)
        XCTAssertEqual(CaptureLocationService.usableHeading(trueNorth: -1, magneticNorth: 80, accuracy: 3), 80)
        XCTAssertNil(CaptureLocationService.usableHeading(trueNorth: 90, magneticNorth: 80, accuracy: -1))
        XCTAssertNil(CaptureLocationService.usableHeading(trueNorth: .nan, magneticNorth: 360, accuracy: 3))

        let headings: [Double] = [0, 90, 180, 270, 359, 1]
        var times = [Double]()
        for sample in 0..<60 {
            viewport.frame.size.height = sample.isMultiple(of: 2) ? 360 : 250
            viewport.layoutIfNeeded()
            let center = sample.isMultiple(of: 2) ? location : near
            map.setRegion(.init(center: center, latitudinalMeters: 12_000, longitudinalMeters: 12_000), animated: false)
            let heading = headings[sample % headings.count]
            let start = CACurrentMediaTime()
            coordinator.mapViewDidChangeVisibleRegion(map)
            coordinator.setHeading(heading)
            coordinator.setHeading(nil)
            times.append((CACurrentMediaTime() - start) * 1000)
            XCTAssertFalse(marker.isHidden)
            XCTAssertFalse(marker.isUserInteractionEnabled)
            XCTAssertFalse(marker.arrow.isHidden)
            XCTAssertEqual(marker.arrow.image?.renderingMode, .alwaysTemplate)
            XCTAssertEqual(marker.arrow.transform.a, cos(heading * .pi / 180), accuracy: 0.0001)
            XCTAssertEqual(marker.arrow.transform.b, sin(heading * .pi / 180), accuracy: 0.0001)
            XCTAssertTrue(viewport.subviews.last === marker)
            XCTAssertTrue(map.annotations.isEmpty)
            XCTAssertEqual(marker.bounds.size, CGSize(width: 28, height: 28))
            let projected = map.convert(location, toPointTo: viewport)
            XCTAssertEqual(marker.center.x, projected.x, accuracy: 0.5)
            XCTAssertEqual(marker.center.y, projected.y, accuracy: 0.5)
        }

        map.setRegion(.init(center: .init(latitude: 40.71, longitude: -74.01),
                            latitudinalMeters: 12_000, longitudinalMeters: 12_000), animated: false)
        coordinator.mapViewDidChangeVisibleRegion(map)
        XCTAssertTrue(marker.isHidden)
        map.setRegion(.init(center: location, latitudinalMeters: 12_000, longitudinalMeters: 12_000), animated: false)
        coordinator.mapViewDidChangeVisibleRegion(map)
        XCTAssertFalse(marker.isHidden)
        viewport.setLocation(nil)
        XCTAssertTrue(marker.isHidden)
        viewport.setLocation(location)
        XCTAssertFalse(marker.isHidden)
        print("ASTRO-HEADING samples=\(times.count) projectionAndHeadingMaxMS=\(times.max() ?? 0)")
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 3
        while !condition() && CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    private func findMap(_ view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        for child in view.subviews {
            if let map = findMap(child) { return map }
        }
        return nil
    }

    private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = findScrollView(child) { return scrollView }
        }
        return nil
    }

    private func findLayerPicker(_ view: UIView) -> UISegmentedControl? {
        if let picker = view as? UISegmentedControl, picker.numberOfSegments == 3 { return picker }
        return view.subviews.lazy.compactMap { self.findLayerPicker($0) }.first
    }
}

@MainActor private final class EnvironmentSheetState: ObservableObject {
    @Published var angle = 0.0
    @Published var show = false
}

private struct EnvironmentSheetHarness: View {
    @ObservedObject var state: EnvironmentSheetState

    var body: some View {
        Color.black
            .sheet(isPresented: $state.show) {
                AstroEnvironmentSheet(recoveryCount: 0, onClose: { state.show = false }, onRecovery: {})
                    .environment(\.scenePhase, .inactive)
            }
            .environment(\.captureControlAngle, state.angle)
    }
}
