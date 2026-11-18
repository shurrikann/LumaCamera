import CoreLocation
import MapKit
import UIKit

struct SkyBrightness: Equatable {
    let mcdPerSquareMeter: Double
    let estimatedBortle: Int?
    let sourceName: String
    let dataYear: Int
    let measured: Bool
}

struct LightPollutionMetadata: Equatable {
    let name: String
    let year: Int
    let license: String
    let attribution: String
    let isMeasured: Bool
}

struct LightPollutionLegend: Equatable {
    let title: String
    let detail: String
}

protocol LightPollutionSource {
    var metadata: LightPollutionMetadata { get }
    var legend: LightPollutionLegend? { get }
    func overlays(in mapRect: MKMapRect) -> [MKOverlay]
    func brightness(at coordinate: CLLocationCoordinate2D) -> SkyBrightness?
}

enum LightPollutionSources {
    /// Swap this line to change the map source; the environment UI does not
    /// know about Falchi files, GeoTIFFs, or remote tiles.
    static let current: any LightPollutionSource = Falchi2016Source()
}

final class LightPollutionImageOverlay: NSObject, MKOverlay {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let attribution: String
    private let imageProvider: () -> UIImage?

    init(id: String, coordinate: CLLocationCoordinate2D, boundingMapRect: MKMapRect,
         attribution: String, imageProvider: @escaping () -> UIImage?) {
        self.id = id
        self.coordinate = coordinate
        self.boundingMapRect = boundingMapRect
        self.attribution = attribution
        self.imageProvider = imageProvider
    }

    func image() -> UIImage? { imageProvider() }
}

final class LightPollutionOverlayRenderer: MKOverlayRenderer {
    private let imageOverlay: LightPollutionImageOverlay
    private var cachedImage: UIImage?
    private var loaded = false
    init(_ overlay: LightPollutionImageOverlay) {
        imageOverlay = overlay
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if !loaded { cachedImage = imageOverlay.image(); loaded = true }
        guard let cgImage = cachedImage?.cgImage else { return }
        let target = rect(for: imageOverlay.boundingMapRect)
        context.saveGState()
        context.setAlpha(0.82)
        context.interpolationQuality = zoomScale > 0.08 ? .high : .low
        // MKOverlayRenderer may draw off the main thread; use CoreGraphics
        // instead of UIKit's UIImage.draw here.
        context.translateBy(x: 0, y: target.minY + target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: target)
        context.restoreGState()
    }
}
