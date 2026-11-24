import CoreGraphics
import Foundation
import MapKit
import Observation

struct AstroCloudRegion: Hashable, Sendable {
    // 11x11 balances regional cloud detail against the multi-location URL
    // size and cellular response time. The raster is still bicubically
    // interpolated, so the display remains continuous.
    static let sampleWidth = 11
    static let sampleCount = sampleWidth * sampleWidth
    private let x: Int
    private let y: Int
    private let size: Int

    init?(_ visible: MKMapRect) {
        let world = MKMapRect.world
        guard !visible.isNull, visible.midX.isFinite, visible.midY.isFinite, visible.width > 0, visible.height > 0,
              max(visible.width, visible.height) < world.width * 0.15 else { return nil }
        let span = max(visible.width, visible.height, world.width / 512)
        // Half-octave zoom buckets leave modest pan margins without sampling
        // most of the coordinates outside the viewport.
        size = Int(pow(2, ceil(log2(span * 1.35) * 2) / 2).rounded(.up))
        let stride = size / 16
        let centerX = (visible.midX.truncatingRemainder(dividingBy: world.width) + world.width)
            .truncatingRemainder(dividingBy: world.width)
        let limit = Int(world.width) - size
        x = min(limit, max(0, Int((centerX / Double(stride)).rounded()) * stride - size / 2))
        y = min(limit, max(0, Int((visible.midY / Double(stride)).rounded()) * stride - size / 2))
    }

    var mapRect: MKMapRect {
        MKMapRect(x: Double(x), y: Double(y), width: Double(size), height: Double(size))
    }

    var samples: [CLLocationCoordinate2D] {
        let step = Double(size) / Double(Self.sampleWidth - 1)
        return (0..<Self.sampleCount).map { index in
            let row = Double(index / Self.sampleWidth)
            let column = Double(index % Self.sampleWidth)
            return MKMapPoint(x: Double(x) + column * step, y: Double(y) + row * step).coordinate
        }
    }
}

struct AstroCloudFrame: Sendable {
    let gridID: UUID
    let date: Date
    let region: AstroCloudRegion
    let values: [Double?]

    var coverageSummary: (mean: Double, isPartial: Bool)? {
        let available = values.compactMap { $0 }
        guard !available.isEmpty else { return nil }
        return (available.reduce(0, +) / Double(available.count), available.count < values.count)
    }

    func makeImage() -> CGImage? {
        let samples = AstroCloudRegion.sampleWidth
        guard values.count == AstroCloudRegion.sampleCount else { return nil }
        let steps = 16
        let width = (samples - 1) * steps + 1
        let coverage = values.map { min(100, max(0, $0 ?? 0)) }
        let positions = (0..<width).map { position in
            (index: position / steps, fraction: Double(position % steps) / Double(steps))
        }
        var horizontal = [Double](repeating: 0, count: samples * width)
        for row in 0..<samples {
            for column in 0..<width {
                let (index, fraction) = positions[column]
                let offset = row * samples
                horizontal[row * width + column] = Self.interpolate(coverage, offset: offset, stride: 1,
                    index: index, fraction: fraction, count: samples)
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        for row in 0..<width {
            let (index, fraction) = positions[row]
            for column in 0..<width {
                let amount = Self.interpolate(horizontal, offset: column, stride: width,
                    index: index, fraction: fraction, count: samples)
                let alpha = UInt8((Self.displayOpacity(for: amount) * 255).rounded())
                let pixel = (row * width + column) * 4
                pixels[pixel] = alpha - alpha / 4
                pixels[pixel + 1] = alpha - alpha / 12
                pixels[pixel + 2] = alpha
                pixels[pixel + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func displayOpacity(for coverage: Double) -> Double {
        let fraction = min(100, max(0, coverage)) / 100
        // Fade into clear sky continuously, then give the edge of denser cloud
        // more contrast without drawing a fixed outline.
        let progress = min(1, max(0, (fraction - 0.08) / 0.40))
        let contrast = progress * progress * (3 - 2 * progress)
        return sqrt(fraction) * (0.22 + 0.78 * contrast)
    }

    // Bound each cubic segment to its two reported values to prevent ringing
    // and invented peaks between weather samples.
    private static func interpolate(_ values: [Double], offset: Int, stride: Int,
                                    index: Int, fraction: Double, count: Int) -> Double {
        let start = values[offset + index * stride]
        guard fraction > 0 else { return start }
        let end = values[offset + (index + 1) * stride]
        let previous = values[offset + max(0, index - 1) * stride]
        let following = values[offset + min(count - 1, index + 2) * stride]
        let startSlope = (end - previous) / 2
        let endSlope = (following - start) / 2
        let change = end - start
        let result = start + fraction * (startSlope + fraction * (
            3 * change - 2 * startSlope - endSlope + fraction * (startSlope + endSlope - 2 * change)))
        return min(max(start, end), max(min(start, end), result))
    }
}

struct AstroCloudGrid: Sendable {
    let id = UUID()
    let region: AstroCloudRegion
    let hours: [Date: [Double?]]

    var firstForecastHour: Date? { hours.keys.min()?.addingTimeInterval(3600) }

    func frame(at date: Date) -> AstroCloudFrame? {
        guard let nearest = hours.keys.min(by: {
            let first = abs($0.timeIntervalSince(date))
            let second = abs($1.timeIntervalSince(date))
            return first == second ? $0 < $1 : first < second
        }), abs(nearest.timeIntervalSince(date)) <= 1800,
              let values = hours[nearest], values.contains(where: { $0 != nil }) else { return nil }
        return AstroCloudFrame(gridID: id, date: nearest, region: region, values: values)
    }
}

protocol AstroCloudProvider: Sendable {
    func grid(for region: AstroCloudRegion) async throws -> AstroCloudGrid
}

struct OpenMeteoAstroCloudProvider: AstroCloudProvider {
    private struct Sample: Decodable {
        struct Hourly: Decodable {
            let time: [TimeInterval]
            let cloudCover: [Double?]
        }

        let hourly: Hourly
    }

    func grid(for region: AstroCloudRegion) async throws -> AstroCloudGrid {
        #if DEBUG
        let coordinates = region.samples
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        func coordinateList(_ keyPath: KeyPath<CLLocationCoordinate2D, Double>) -> String {
            coordinates.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0[keyPath: keyPath]) }
                .joined(separator: ",")
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinateList(\.latitude)),
            URLQueryItem(name: "longitude", value: coordinateList(\.longitude)),
            URLQueryItem(name: "hourly", value: "cloud_cover"),
            URLQueryItem(name: "forecast_hours", value: "48"),
            URLQueryItem(name: "past_hours", value: "1"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "cell_selection", value: "nearest")
        ]
        guard let url = components.url else { throw AstroForecastError.serviceUnavailable }
        return try await Self.decode(AstroWeatherRequest.data(from: url, timeout: 25), for: region)
        #else
        throw AstroForecastError.providerUnconfigured
        #endif
    }

    static func decode(_ data: Data, for region: AstroCloudRegion) throws -> AstroCloudGrid {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let samples = try decoder.decode([Sample].self, from: data)
        let count = AstroCloudRegion.sampleCount
        guard samples.count == count else { throw AstroForecastError.invalidForecast }

        var hours: [Date: [Double?]] = [:]
        for (index, sample) in samples.enumerated() {
            for (timestamp, cloud) in zip(sample.hourly.time, sample.hourly.cloudCover).prefix(49) {
                guard (946_684_800...4_102_444_800).contains(timestamp), let cloud, (0...100).contains(cloud) else { continue }
                let date = Date(timeIntervalSince1970: timestamp)
                hours[date, default: [Double?](repeating: nil, count: count)][index] = cloud
            }
        }
        guard !hours.isEmpty else { throw AstroForecastError.invalidForecast }
        return AstroCloudGrid(region: region, hours: hours)
    }
}

@MainActor @Observable
final class AstroCloudForecastStore {
    static let shared = AstroCloudForecastStore()

    private struct Entry {
        let grid: AstroCloudGrid
        let loadedAt: Date
        var validUntil: Date { grid.hours.keys.max()?.addingTimeInterval(3600) ?? .distantPast }
    }

    private let provider: any AstroCloudProvider
    private let refreshInterval = AstroWeatherRequest.cacheLifetime
    private var entries: [AstroCloudRegion: Entry] = [:]
    private(set) var failedRegion: AstroCloudRegion?
    private(set) var isUnconfigured = false

    init(provider: any AstroCloudProvider = OpenMeteoAstroCloudProvider()) {
        self.provider = provider
    }

    func grid(for region: AstroCloudRegion?, now: Date = Date()) -> AstroCloudGrid? {
        guard let region, let entry = entries[region], entry.validUntil > now else { return nil }
        return entry.grid
    }

    func load(_ region: AstroCloudRegion, now: Date = Date()) async {
        guard !Task.isCancelled else { return }
        if let entry = entries[region], entry.validUntil > now,
           now.timeIntervalSince(entry.loadedAt) < refreshInterval {
            if failedRegion == region { failedRegion = nil }
            return
        }
        failedRegion = nil
        isUnconfigured = false
        do {
            let grid = try await AstroWeatherRequest.retryTransientFailure {
                try await provider.grid(for: region)
            }
            try Task.checkCancellation()
            entries[region] = Entry(grid: grid, loadedAt: now)
            if entries.count > 5, let oldest = entries.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failedRegion = region
            if case AstroForecastError.providerUnconfigured = error { isUnconfigured = true }
        }
    }

    func refresh(_ region: AstroCloudRegion) async {
        do {
            if grid(for: region) == nil { try await Task.sleep(for: .milliseconds(300)) }
            var failureDelay = 5.0
            while !Task.isCancelled {
                await load(region)
                if failedRegion == region {
                    // Automatic backoff keeps a transient network or server
                    // failure from requiring a manual retry, without polling.
                    try await Task.sleep(for: .seconds(failureDelay))
                    failureDelay = min(300, failureDelay * 2)
                } else {
                    failureDelay = 5
                    let elapsed = entries[region].map { Date().timeIntervalSince($0.loadedAt) } ?? 0
                    try await Task.sleep(for: .seconds(max(1, refreshInterval - elapsed)))
                }
            }
        } catch {
            // Viewport, layer or visibility changed.
        }
    }
}

final class AstroCloudOverlay: NSObject, MKOverlay {
    let region: AstroCloudRegion
    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }
    var boundingMapRect: MKMapRect { region.mapRect }

    private let lock = NSLock()
    private var raster: CGImage

    init(region: AstroCloudRegion, image: CGImage) {
        self.region = region
        raster = image
    }

    var image: CGImage { lock.withLock { raster } }
    func setImage(_ image: CGImage) { lock.withLock { raster = image } }
}

final class AstroCloudOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let clouds = overlay as? AstroCloudOverlay else { return }
        let target = rect(for: clouds.boundingMapRect)
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: target.minY + target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(clouds.image, in: target)
        context.restoreGState()
    }
}
