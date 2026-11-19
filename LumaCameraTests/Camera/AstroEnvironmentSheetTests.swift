import MapKit
import SwiftUI
import XCTest
@testable import LumaCamera

@MainActor
final class AstroEnvironmentSheetTests: XCTestCase {
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

    func testSolidHeadingPresentationSurvivesMissingUpdatesAndRecreation() throws {
        let map = MKMapView()
        let coordinator = AstroNightLightsMap.Coordinator(source: LightPollutionSources.current, onCenterChange: { _ in })
        let marker = coordinator.marker
        marker.coordinate = CLLocationCoordinate2D(latitude: 31, longitude: 121)
        XCTAssertEqual(CaptureLocationService.usableHeading(trueNorth: 90, magneticNorth: 80, accuracy: 3), 90)
        XCTAssertEqual(CaptureLocationService.usableHeading(trueNorth: -1, magneticNorth: 80, accuracy: 3), 80)
        XCTAssertNil(CaptureLocationService.usableHeading(trueNorth: 90, magneticNorth: 80, accuracy: -1))
        XCTAssertNil(CaptureLocationService.usableHeading(trueNorth: .nan, magneticNorth: 360, accuracy: 3))
        let view = try XCTUnwrap(coordinator.mapView(map, viewFor: marker) as? AstroLocationAnnotationView)
        XCTAssertEqual(view.arrow.image?.renderingMode, .alwaysTemplate)
        XCTAssertFalse(view.arrow.isHidden)
        XCTAssertEqual(view.arrow.transform, .identity)
        let values: [Double] = [0, 90, 180, 270, 359, 1]
        var times = [Double]()
        for value in Array(repeating: values, count: 10).flatMap({ $0 }) {
            let start = CACurrentMediaTime()
            view.setHeading(value, animated: true)
            times.append((CACurrentMediaTime() - start) * 1000)
            XCTAssertFalse(view.arrow.isHidden)
            XCTAssertEqual(view.arrow.transform.a, cos(value * .pi / 180), accuracy: 0.0001)
            XCTAssertEqual(view.arrow.transform.b, sin(value * .pi / 180), accuracy: 0.0001)
        }
        // A new annotation view keeps the last valid bearing, even if the compass
        // briefly reports no usable value while the map changes size.
        for height in [250.0, 360.0, 250.0, 360.0, 250.0] {
            map.frame.size.height = height
            coordinator.setHeading(90, on: map)
            coordinator.setHeading(nil, on: map)
            let recreated = try XCTUnwrap(coordinator.mapView(map, viewFor: marker) as? AstroLocationAnnotationView)
            XCTAssertFalse(recreated.arrow.isHidden)
            XCTAssertEqual(recreated.arrow.image?.renderingMode, .alwaysTemplate)
            XCTAssertEqual(recreated.arrow.transform.b, 1, accuracy: 0.0001)
        }
        view.setHeading(nil, animated: false)
        XCTAssertFalse(view.arrow.isHidden)
        XCTAssertEqual(view.arrow.transform, .identity)
        XCTAssertEqual(marker.coordinate.latitude, 31)
        XCTAssertEqual(marker.coordinate.longitude, 121)
        print("ASTRO-HEADING samples=\(times.count) transformUpdateMaxMS=\(times.max() ?? 0)")
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
