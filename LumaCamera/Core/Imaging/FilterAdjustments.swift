import Foundation

enum FilterEditorTab: String, CaseIterable, Identifiable {
    case color = "色彩", light = "明暗", effects = "质感"
    var id: String { rawValue }
    var parameters: [FilterParameter] {
        switch self {
        case .color: return [.strength, .temperature, .tint, .saturation, .fade]
        // 原版编辑入口保留曝光与亮度的独立调节，沿用各自的渲染参数。
        case .light: return [.exposure, .brightness, .contrast, .highlights, .shadows]
        case .effects: return [.detail, .aberration, .softness, .halation, .grainSize, .grainSaturation, .vignette]
        }
    }
}
enum FilterParameter: String, CaseIterable, Codable, Identifiable {
    case strength, temperature, tint, saturation, fade, exposure, brightness, contrast, highlights, shadows
    case detail, aberration, softness, halation, grainSize, grainSaturation, vignette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .strength: return "浓度"
        case .temperature: return "色温"
        case .tint: return "色调"
        case .saturation: return "饱和度"
        case .fade: return "褪色"
        case .exposure: return "曝光补偿"
        case .brightness: return "亮度"
        case .contrast: return "对比度"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .detail: return "模糊／锐化"
        case .aberration: return "色差"
        case .softness: return "柔光"
        case .halation: return "光晕"
        case .grainSize: return "颗粒大小"
        case .grainSaturation: return "颗粒饱和度"
        case .vignette: return "暗角"
        }
    }
    var icon: String {
        switch self {
        case .strength: return "dial.medium.fill"
        case .temperature: return "thermometer.medium"
        case .tint: return "drop.halffull"
        case .saturation: return "circle.lefthalf.filled"
        case .fade: return "circle.dotted"
        case .exposure: return "plusminus.circle"
        case .brightness: return "sun.max"
        case .contrast: return "circle.righthalf.filled"
        case .highlights: return "sun.max.fill"
        case .shadows: return "moon.fill"
        case .detail: return "triangle"
        case .aberration: return "circle.hexagongrid"
        case .softness: return "drop"
        case .halation: return "sparkles"
        case .grainSize: return "circle.grid.3x3"
        case .grainSaturation: return "paintpalette"
        case .vignette: return "viewfinder"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .strength, .fade, .aberration, .softness, .halation, .grainSize, .grainSaturation, .vignette: return 0...100
        case .exposure: return -5...5
        default: return -100...100
        }
    }
    func clamped(_ value: Double) -> Double { value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0 }
    func text(_ value: Double) -> String { self == .exposure ? String(format: "%+.1f", value) : String(format: "%.0f", value) }
    /// 单项默认值与整组重置一致；浓度沿用80%，其它调色参数为零。
    var defaultValue: Double { self == .strength ? 80 : 0 }
    /// 新版数值行保留小数，避免手动输入32.5后仍显示成33；旧版滑条格式不变。
    func numericDisplayText(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US_POSIX")))
    }
    func inputValue(from text: String) -> Double? {
        let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

/// Sparse numeric recipe shared by preview, processed output and capture metadata.
struct FilterAdjustments: Codable, Equatable {
    private var values: [String: Double] = [:]
    init() {}
    subscript(_ parameter: FilterParameter) -> Double {
        get { parameter.clamped(values[parameter.rawValue] ?? 0) }
        set {
            guard parameter != .strength else { return }
            let value = parameter.clamped(newValue)
            if value == 0 { values.removeValue(forKey: parameter.rawValue) }
            else { values[parameter.rawValue] = value }
        }
    }
    var isNeutral: Bool { FilterParameter.allCases.allSatisfy { self[$0] == 0 } }
    var hasSpatialEffects: Bool { [.detail, .aberration, .softness, .halation, .grainSize, .vignette].contains { self[$0] != 0 } }
    var summary: String {
        FilterParameter.allCases.filter { $0 != .strength && self[$0] != 0 }.map { $0.title + " " + $0.text(self[$0]) }.joined(separator: " · ")
    }
    init(from decoder: Decoder) throws {
        let input = try decoder.singleValueContainer().decode([String: Double].self)
        for (key, value) in input { if let parameter = FilterParameter(rawValue: key) { self[parameter] = value } }
    }
    func encode(to encoder: Encoder) throws { var output = encoder.singleValueContainer(); try output.encode(values) }
}
