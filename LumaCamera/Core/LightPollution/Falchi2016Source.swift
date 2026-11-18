import CoreLocation
import MapKit
import UIKit

private struct FalchiCell: Decodable {
    let file: String
    let north: Double
    let south: Double
    let east: Double
    let west: Double
}

final class Falchi2016Source: LightPollutionSource {
    let metadata = LightPollutionMetadata(
        name: "New World Atlas of Artificial Night Sky Brightness",
        year: 2016,
        license: "CC BY-NC 4.0",
        attribution: "Falchi et al. 2016 · GFZ Data Services",
        isMeasured: false)
    var legend: LightPollutionLegend? {
        LightPollutionLegend(title: "人工天顶亮度",
                             detail: "蓝色较低，绿/黄/红色逐渐升高；分类着色，不直接等于 Bortle")
    }

    private static let bundle = LightPollutionResourceLocator.bundle(named: "FalchiAtlas")
    private static let cells: [FalchiCell] = loadCells()
    private static let images = NSCache<NSString, UIImage>()

    func overlays(in mapRect: MKMapRect) -> [MKOverlay] {
        Self.cells.compactMap { cell in
            let overlay = Self.makeOverlay(cell)
            return mapRect.intersects(overlay.boundingMapRect) ? overlay : nil
        }
    }

    func brightness(at coordinate: CLLocationCoordinate2D) -> SkyBrightness? {
        // The KMZ is a classified color raster without per-pixel radiance values.
        // Do not invent a mcd/m² or Bortle number from the color alone.
        nil
    }

    static func image(named file: String) -> UIImage? {
        if let cached = images.object(forKey: file as NSString) { return cached }
        let url = bundle?.url(forResource: file, withExtension: nil)
            ?? Bundle.main.url(forResource: file, withExtension: nil)
            ?? Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "FalchiAtlas.bundle")
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: file as NSString)
        return image
    }

    private static func makeOverlay(_ cell: FalchiCell) -> LightPollutionImageOverlay {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: cell.north, longitude: cell.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: cell.south, longitude: cell.east))
        let rect = MKMapRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                             width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y))
        return LightPollutionImageOverlay(
            id: cell.file,
            coordinate: CLLocationCoordinate2D(latitude: (cell.north + cell.south) / 2,
                                               longitude: (cell.east + cell.west) / 2),
            boundingMapRect: rect,
            attribution: "Falchi et al. 2016 · CC BY-NC 4.0",
            imageProvider: { image(named: cell.file) })
    }

    private static func loadCells() -> [FalchiCell] {
        let url = bundle?.url(forResource: "index", withExtension: "json")
            ?? Bundle.main.url(forResource: "index", withExtension: "json")
            ?? Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "FalchiAtlas.bundle")
        guard let url, let data = try? Data(contentsOf: url),
              let cells = try? JSONDecoder().decode([FalchiCell].self, from: data) else { return [] }
        return cells
    }
}

private enum LightPollutionResourceLocator {
    static func bundle(named name: String) -> Bundle? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LightPollution", isDirectory: true)
            .appendingPathComponent("\(name).bundle")
        if let appSupport, let bundle = Bundle(url: appSupport) { return bundle }
        if let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.main
    }
}
