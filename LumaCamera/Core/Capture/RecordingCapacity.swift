import Foundation

/// Estimates remaining recording time from the volume's available capacity
/// and reports the storage occupancy shown in the video HUD.
enum RecordingCapacity {
    struct Info {
        let timeText: String
        let usedPercent: Int
        let freeText: String
        let usedFraction: CGFloat
        let isExternal: Bool
        let isEstimated: Bool
    }

    static let videoBitsPerSecond: Double = 12_000_000
    static let audioBitsPerSecond: Double = 128_000

    static func info(videoBitsPerSecond: Double = videoBitsPerSecond,
                     externalCapacity: ExternalVideoStorage.CapacitySnapshot? = nil) -> Info? {
        let available: Int64
        let total: Int64
        if let externalCapacity {
            available = externalCapacity.freeBytes
            total = externalCapacity.totalBytes
        } else {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey
            ])
            available = values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(values?.volumeAvailableCapacity ?? 0)
            total = Int64(values?.volumeTotalCapacity ?? 0)
        }
        guard available > 0 else { return nil }
        let usedFraction: CGFloat
        if total > 0 {
            usedFraction = min(1, max(0, CGFloat(total - available) / CGFloat(total)))
        } else {
            usedFraction = 0
        }

        let bitsPerSecond = (videoBitsPerSecond + audioBitsPerSecond) * 1.05
        let seconds = max(0, Int(Double(available) * 8 / bitsPerSecond))
        let timeText = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)

        let freeText: String
        if externalCapacity != nil {
            freeText = "\(capacityText(available)) / \(capacityText(total))"
        } else { freeText = capacityText(available) }
        return Info(timeText: timeText,
                    usedPercent: Int((usedFraction * 100).rounded()),
                    freeText: freeText,
                    usedFraction: usedFraction,
                    isExternal: externalCapacity != nil,
                    isEstimated: externalCapacity != nil)
    }

    private static func capacityText(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000_000 { return String(format: "%.1fTB", Double(bytes) / 1_000_000_000_000) }
        if bytes >= 1_000_000_000 { return "\(Int(Double(bytes) / 1_000_000_000))GB" }
        return "\(max(1, Int(Double(bytes) / 1_000_000)))MB"
    }
}
