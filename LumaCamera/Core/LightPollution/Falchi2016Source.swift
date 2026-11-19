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
    var legend: LightPollutionLegend? { Self.atlasLegend }

    // Falchi et al. (2016), Fig. 2. Use the bundled KMZ's JPEG palette,
    // which differs from the display swatches in the paper's Table 1.
    private static let atlasLegend = LightPollutionLegend(title: "人工天光 / 自然天光", bands: [
        .init(minimumRatio: 0, range: "<0.01×", rgb: 0x000000),
        .init(minimumRatio: 0.01, range: "0.01–0.02×", rgb: 0x4D4D4D),
        .init(minimumRatio: 0.02, range: "0.02–0.04×", rgb: 0x808080),
        .init(minimumRatio: 0.04, range: "0.04–0.08×", rgb: 0x002573),
        .init(minimumRatio: 0.08, range: "0.08–0.16×", rgb: 0x004EB3),
        .init(minimumRatio: 0.16, range: "0.16–0.32×", rgb: 0x0092CE),
        .init(minimumRatio: 0.32, range: "0.32–0.64×", rgb: 0x2E8A01),
        .init(minimumRatio: 0.64, range: "0.64–1.28×", rgb: 0xA9A800),
        .init(minimumRatio: 1.28, range: "1.28–2.56×", rgb: 0xFFFF00),
        .init(minimumRatio: 2.56, range: "2.56–5.12×", rgb: 0xFF5500),
        .init(minimumRatio: 5.12, range: "5.12–10.24×", rgb: 0xE60000),
        .init(minimumRatio: 10.24, range: "10.24–20.5×", rgb: 0xDF72FF),
        .init(minimumRatio: 20.5, range: "20.5–41×", rgb: 0xE0BDFF),
        .init(minimumRatio: 41, range: ">41×", rgb: 0xFFFFFF)
    ])

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

    func band(at point: LightPollutionPoint) -> LightPollutionLegend.Band? {
        guard let cell = Self.cells.first(where: {
            ($0.south...$0.north).contains(point.latitude) && ($0.west...$0.east).contains(point.longitude)
        }), let image = Self.image(named: cell.file)?.cgImage,
            image.width >= 3, image.height >= 3 else { return nil }
        let x = Int((point.longitude - cell.west) / (cell.east - cell.west) * Double(image.width - 1))
        let y = Int((cell.north - point.latitude) / (cell.north - cell.south) * Double(image.height - 1))
        let sample = CGRect(x: min(max(0, x - 1), image.width - 3),
            y: min(max(0, y - 1), image.height - 3), width: 3, height: 3)
        guard let pixels = image.cropping(to: sample),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 36)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8,
                bytesPerRow: 12, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            let rgb = buffer.bindMemory(to: UInt8.self)
            var counts: [Int: Int] = [:]
            for pixel in stride(from: 0, to: rgb.count, by: 4) {
                let r = Int(rgb[pixel]), g = Int(rgb[pixel + 1]), b = Int(rgb[pixel + 2])
                var closest = 0
                var distance = 32 * 32
                for (index, band) in Self.atlasLegend.bands.enumerated() {
                    let dr = r - band.red, dg = g - band.green, db = b - band.blue
                    let error = dr * dr + dg * dg + db * db
                    if error < distance { closest = index; distance = error }
                }
                if distance < 32 * 32 { counts[closest, default: 0] += 1 }
            }
            // Require a majority; JPEG blending at color boundaries can be ambiguous.
            return counts.first(where: { $0.value >= 5 }).map { Self.atlasLegend.bands[$0.key] }
        }
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
