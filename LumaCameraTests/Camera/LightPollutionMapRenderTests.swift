import MapKit
import UIKit
import XCTest
@testable import LumaCamera

@MainActor final class LightPollutionMapRenderTests: XCTestCase {
    func testFalchiOverlayProducesColorOnMap() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let delegate = RendererDelegate()
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        map.delegate = delegate
        map.overrideUserInterfaceStyle = .dark
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
                                         latitudinalMeters: 200_000, longitudinalMeters: 200_000), animated: false)
        map.addOverlays(Falchi2016Source().overlays(in: .world), level: .aboveRoads)
        let vc = UIViewController(); vc.view = map
        let window = UIWindow(windowScene: scene); window.rootViewController = vc; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(800))
        let image = UIGraphicsImageRenderer(bounds: map.bounds).image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
        }
        if let data = image.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("falchi_map.png")
            try? data.write(to: url)
            print("FALCHI-MAP file=\(url.path)")
        }
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colored = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            let maxv = max(r, g, b), minv = min(r, g, b)
            if maxv > 35, maxv - minv > 20 { colored += 1 }
        }
        let ratio = Double(colored) / Double(width * height)
        print("FALCHI-MAP coloredRatio=\(ratio)")
        XCTAssertGreaterThan(ratio, 0.05, "Falchi overlay did not paint the map")
    }
}

private final class RendererDelegate: NSObject, MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let cell = overlay as? LightPollutionImageOverlay else { return MKOverlayRenderer(overlay: overlay) }
        return LightPollutionOverlayRenderer(cell)
    }
}
