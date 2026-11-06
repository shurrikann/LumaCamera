import Foundation

struct VideoCaptureBadges: Codable, Hashable {
    var logLabel: String?
    var hasFilter: Bool
    var colorSpace: VideoColorSpace? = nil
    var filmStyleID: String? = nil
    var filterIntensity: Double? = nil
    var filterAdjustments: FilterAdjustments? = nil
    var logLUTID: String? = nil

    var hasBadge: Bool { logLabel != nil || hasFilter }
    var hasPersistenceData: Bool { hasBadge || colorSpace != nil || filmStyleID != nil || logLUTID != nil }

    func hash(into hasher: inout Hasher) {
        hasher.combine(logLabel)
        hasher.combine(hasFilter)
        hasher.combine(colorSpace)
        hasher.combine(filmStyleID)
        hasher.combine(filterIntensity)
        hasher.combine(filterAdjustments?.summary)
        hasher.combine(logLUTID)
    }

    static func forRecording(colorSpace: VideoColorSpace, burnedLogLUT: Bool, look: CaptureLook = CaptureLook(), logLUTID: String? = nil) -> Self {
        VideoCaptureBadges(logLabel: colorSpace == .appleLog ? "LOG" : colorSpace == .appleLog2 ? "LOG2" : nil,
                           hasFilter: colorSpace.isLog ? burnedLogLUT : look.requiresImageProcessing,
                           colorSpace: colorSpace,
                           filmStyleID: colorSpace.isLog ? nil : look.style.rawValue,
                           filterIntensity: colorSpace.isLog ? nil : look.intensity,
                           filterAdjustments: colorSpace.isLog ? nil : look.adjustments,
                           logLUTID: colorSpace.isLog && burnedLogLUT ? logLUTID : nil)
    }
}

final class VideoCaptureBadgeStore {
    static let shared = VideoCaptureBadgeStore(defaults: .standard)
    private let defaults: UserDefaults
    private let key = "camera.videoCaptureBadges"
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

    func badges(assetID: String) -> VideoCaptureBadges? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: VideoCaptureBadges].self, from: data) else { return nil }
        return values[assetID]
    }

    func save(_ badges: VideoCaptureBadges, assetID: String) {
        lock.lock(); defer { lock.unlock() }
        var values = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: VideoCaptureBadges].self, from: $0) } ?? [:]
        if badges.hasPersistenceData { values[assetID] = badges } else { values.removeValue(forKey: assetID) }
        if values.count > 3000 {
            values = Dictionary(values.sorted { $0.key < $1.key }.suffix(2500), uniquingKeysWith: { _, latest in latest })
        }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }
}
