import Foundation

struct SavedFilterSettings: Codable, Equatable {
    var intensity = 0.8
    var adjustments = FilterAdjustments()
}
@MainActor
final class FilterSettingsStore {
    private let defaults: UserDefaults?
    private let key = "camera.filterParameters.v1"
    private(set) var selectedStyle = FilmStyle.original
    private var values: [String: SavedFilterSettings] = [:]
    private var writeTask: Task<Void, Never>?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let raw = defaults?.string(forKey: "camera.selectedFilmStyle"), let style = FilmStyle(rawValue: raw), FilmStyle.availableStyles.contains(style) { selectedStyle = style }
        if let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([String: SavedFilterSettings].self, from: data) {
            for (style, var settings) in saved where FilmStyle(rawValue: style) != nil {
                settings.intensity = settings.intensity.isFinite ? min(max(settings.intensity, 0), 1) : 0.8
                values[style] = settings
            }
        }
        // Upgrade only untouched legacy defaults, once. Explicit custom strengths and colour recipes remain intact.
        if defaults?.bool(forKey: "camera.filterDefault80Boosted.v1") != true {
            for (style, var settings) in values where settings.intensity == 1.0 && settings.adjustments.isNeutral {
                settings.intensity = 0.8
                values[style] = settings
            }
            if let defaults {
                if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
                defaults.set(true, forKey: "camera.filterDefault80Boosted.v1")
            }
        }
    }
    func select(_ style: FilmStyle) {
        guard FilmStyle.availableStyles.contains(style) else { return }
        selectedStyle = style; defaults?.set(style.rawValue, forKey: "camera.selectedFilmStyle")
    }
    func settings(for style: FilmStyle) -> SavedFilterSettings {
        values[style.rawValue] ?? SavedFilterSettings(intensity: style.defaultIntensity, adjustments: FilterAdjustments())
    }
    func set(_ settings: SavedFilterSettings, for style: FilmStyle) {
        var safe = settings
        safe.intensity = safe.intensity.isFinite ? min(max(safe.intensity, 0), 1) : 0.8
        values[style.rawValue] = safe
        writeTask?.cancel()
        guard defaults != nil else { return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }; self?.flush()
        }
    }
    func flush() {
        writeTask?.cancel(); writeTask = nil
        if let data = try? JSONEncoder().encode(values) { defaults?.set(data, forKey: key) }
    }
}
