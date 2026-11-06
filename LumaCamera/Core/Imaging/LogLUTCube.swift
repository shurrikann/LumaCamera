import CoreImage
import Foundation
import UIKit

struct LogLUTPreset: Identifiable, Hashable, Sendable {
    static let originalID = "__original__"
    static let original = LogLUTPreset(id: originalID, equipment: nil, title: "原片")

    let id: String
    let equipment: String?
    let title: String
    var displayName: String { [equipment, title].compactMap { $0 }.joined(separator: " ") }

    init(id: String, equipment: String?, title: String) {
        self.id = id
        self.equipment = equipment
        self.title = title
    }

    init(filename: String) {
        let stem = (filename as NSString).deletingPathExtension
        // Keep the camera family and LUT name separate so the capture control
        // can render them on two lines while retaining a complete display name.
        if stem == "AppleLog_Rec709" {
            self.init(id: stem, equipment: "Log", title: "Rec709")
            return
        }
        if stem == "AppleLog2_Rec709" {
            self.init(id: stem, equipment: "Log2", title: "Rec709")
            return
        }
        let prefixes: [(String, String, String)] = [
            ("AppleLog2_", "Log2", ""), ("AppleLog_", "Log", ""),
            ("ARRI_", "ARRI", ""), ("Arri_", "ARRI", ""),
            ("Kim_", "Kim", ""), ("日系-", "日系", ""), ("日系_", "日系", ""),
            ("波西米亚_", "波西米亚", ""), ("顾屿_", "顾屿", ""), ("馆长_", "馆长", "")
        ]
        if let match = prefixes.first(where: { stem.hasPrefix($0.0) }) {
            self.init(id: stem, equipment: match.1,
                      title: String(stem.dropFirst(match.0.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            self.init(id: stem, equipment: nil,
                      title: stem.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A decoded immutable Core Image cube. Cube entries follow .cube red-fastest order.
final class LogLUTCube: NSObject {
    let dimension: Int
    let rgbaData: Data

    init?(dimension: Int, rgbaData: Data) {
        let expected = dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
        guard (2...65).contains(dimension), rgbaData.count == expected else { return nil }
        self.dimension = dimension
        self.rgbaData = rgbaData
    }

    convenience init?(compiledData: Data) {
        guard compiledData.count >= 8, compiledData.prefix(4) == Data("LCUB".utf8) else { return nil }
        let dimension = Int(UInt32(compiledData[4]) | UInt32(compiledData[5]) << 8
                            | UInt32(compiledData[6]) << 16 | UInt32(compiledData[7]) << 24)
        guard dimension == 33 || dimension == 65,
              compiledData.count == 8 + dimension * dimension * dimension * 6 else { return nil }
        var rgba = Data(capacity: dimension * dimension * dimension * 16)
        for offset in stride(from: 8, to: compiledData.count, by: 6) {
            for channel in 0..<3 {
                let position = offset + channel * 2
                let bits = UInt16(compiledData[position]) | UInt16(compiledData[position + 1]) << 8
                let value = Float(Float16(bitPattern: bits))
                guard value.isFinite else { return nil }
                var littleEndian = value.bitPattern.littleEndian
                withUnsafeBytes(of: &littleEndian) { rgba.append(contentsOf: $0) }
            }
            var alpha = Float(1).bitPattern.littleEndian
            withUnsafeBytes(of: &alpha) { rgba.append(contentsOf: $0) }
        }
        guard let parsed = LogLUTCube(dimension: dimension, rgbaData: rgba) else { return nil }
        self.init(dimension: parsed.dimension, rgbaData: parsed.rgbaData)
    }

    func apply(to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": rgbaData,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            "inputExtrapolate": true
        ]).cropped(to: image.extent)
    }
}

enum LogLUTCubeRepository {
    private static let cache = NSCache<NSString, LogLUTCube>()
    private static let resourceBundle = Bundle(for: CameraEngine.self)

    static func presets(bundle: Bundle = resourceBundle) -> [LogLUTPreset] {
        guard let folder = bundle.url(forResource: "LogLUTs", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "lutcube" }
            .map { LogLUTPreset(filename: $0.lastPathComponent) }
            .sorted {
                let firstRank = appleLogRank($0.id)
                let secondRank = appleLogRank($1.id)
                if firstRank != secondRank { return firstRank < secondRank }
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
    }

    private static func appleLogRank(_ id: String) -> Int {
        if id.hasPrefix("AppleLog_") { return 0 }
        if id.hasPrefix("AppleLog2_") { return 1 }
        return 2
    }

    static func load(_ preset: LogLUTPreset, bundle: Bundle = resourceBundle) throws -> LogLUTCube {
        if let cached = cache.object(forKey: preset.id as NSString) { return cached }
        guard let folder = bundle.url(forResource: "LogLUTs", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = folder.appendingPathComponent(preset.id).appendingPathExtension("lutcube")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let cube = LogLUTCube(compiledData: data) else { throw CocoaError(.fileReadCorruptFile) }
        cache.setObject(cube, forKey: preset.id as NSString, cost: cube.rgbaData.count)
        cache.countLimit = 4
        cache.totalCostLimit = 18 * 1024 * 1024
        return cube
    }

    static func thumbnail(for preset: LogLUTPreset, source: CIImage, context: CIContext,
                          bundle: Bundle = resourceBundle) -> UIImage? {
        guard let cube = try? load(preset, bundle: bundle) else { return nil }
        let output = cube.apply(to: source)
        guard let cgImage = context.createCGImage(output, from: output.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
