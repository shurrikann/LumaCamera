import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Numeric values and stable identifiers for future border rendering, independent of UI text.
struct PhotoCaptureParameters: Codable, Equatable {
    var capturedAt: Date = Date()
    var mode: String?
    var shootingType: String?
    var displayedZoom: Double?
    var lensType: String?
    var lensName: String?
    var cameraModel: String?
    var lensModel: String?
    // Final photo EXIF values. Absent EXIF remains nil rather than implying a measured value.
    var iso: Double?
    var exposureSeconds: Double?
    var aperture: Double?
    var virtualAperture: Double?
    var adaptiveHighDynamic: Bool?
    var focalLengthMM: Double?
    var equivalentFocalLengthMM: Double?
    var exifExposureBiasEV: Double?
    // Device state at the shutter, kept separately from final photo EXIF.
    var sampledISO: Double?
    var sampledExposureSeconds: Double?
    var requestedExposureBiasEV: Double?
    // 全局测光单独记录用户/应用/设备三种值；实际成片EXIF仍由系统提供。
    var globalMeteringBiasEV: Double?
    var deviceExposureBiasEV: Double?
    var whiteBalanceKelvin: Double?
    var whiteBalanceTint: Double?
    var whiteBalanceMode: String?
    var focusPosition: Double?
    var flashMode: String?
    var flashFired: Bool?
    var requestedFormat: String?
    var requestedMegapixels: Int?
    var ratio: String?
    var filterID: String?
    var filterName: String?
    var filterIntensity: Double?
    var filterAdjustments: FilterAdjustments?
    var toneID: String?
    var location: PhotoLocation?
    var borderEnabled: Bool?

    mutating func updateEXIF(_ properties: [CFString: Any], overwrite: Bool = true) {
        let rawProperties = Dictionary(uniqueKeysWithValues: properties.map { ($0.key as String,$0.value) })
        if let recipe = RAWDevelopmentRecipe.read(rawProperties) { adaptiveHighDynamic = recipe.rawDevelopment?.adaptive }
        if let value = VirtualApertureRenderer.recordedValue(properties) { virtualAperture = value }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func positive(_ key: CFString) -> Double? {
            guard let v = exif[key] as? NSNumber, v.doubleValue.isFinite, v.doubleValue > 0 else { return nil }
            return v.doubleValue
        }
        if let value = tiff[kCGImagePropertyTIFFModel] as? String, overwrite || cameraModel == nil { cameraModel = value }
        if let value = exif[kCGImagePropertyExifLensModel] as? String, overwrite || lensModel == nil { lensModel = value }
        if let value = positive(kCGImagePropertyExifFocalLength), overwrite || focalLengthMM == nil { focalLengthMM = value }
        if let value = positive(kCGImagePropertyExifFocalLenIn35mmFilm), overwrite || equivalentFocalLengthMM == nil { equivalentFocalLengthMM = value }
        if let value = positive(kCGImagePropertyExifExposureTime), overwrite || exposureSeconds == nil { exposureSeconds = value }
        if let value = positive(kCGImagePropertyExifFNumber), overwrite || aperture == nil { aperture = value }
        if let value = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue, value.isFinite, value > 0, overwrite || iso == nil { iso = value }
        if let value = exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber, value.doubleValue.isFinite, overwrite || exifExposureBiasEV == nil { exifExposureBiasEV = value.doubleValue }
        if let value = exif[kCGImagePropertyExifFlash] as? NSNumber, overwrite || flashFired == nil { flashFired = (value.intValue & 1) != 0 }
    }

    var rows: [PhotoInfoRow] {
        var result = [PhotoInfoRow(title: "拍摄时间", value: capturedAt.formatted(date: .numeric, time: .standard))]
        if let shootingType, !shootingType.isEmpty { result.append(.init(title: "拍摄类型", value: shootingType)) }
        if let mode { result.append(.init(title: "拍摄模式", value: mode)) }
        if let virtualAperture { result.append(.init(title: "虚拟光圈", value: VirtualApertureRenderer.label(virtualAperture))) }
        if let adaptiveHighDynamic { result.append(.init(title:"高动态显影",value:adaptiveHighDynamic ? "开启" : "关闭")) }
        if let ev = exifExposureBiasEV { result.append(.init(title: "成片曝光补偿", value: String(format: "%+.1f EV", ev))) }
        if let ev = globalMeteringBiasEV { result.append(.init(title: "全局测光补偿", value: String(format: "%+.1f EV", ev))) }
        if let ev = deviceExposureBiasEV { result.append(.init(title: "设备曝光补偿", value: String(format: "%+.1f EV", ev))) }
        if let ev = requestedExposureBiasEV { result.append(.init(title: "设置曝光补偿", value: String(format: "%+.1f EV", ev))) }
        if let kelvin = whiteBalanceKelvin { result.append(.init(title: "快门时白平衡", value: String(format: "%.0f K", kelvin))) }
        if let whiteBalanceTint { result.append(.init(title: "快门时色调", value: String(format: "%+.0f", whiteBalanceTint))) }
        if let whiteBalanceMode { result.append(.init(title: "白平衡模式", value: whiteBalanceMode)) }
        if let flashMode { result.append(.init(title: "闪光灯设置", value: flashMode)) }
        if let flashFired { result.append(.init(title: "成片闪光灯", value: flashFired ? "已闪光" : "未闪光")) }
        if let filterName { result.append(.init(title: "滤镜", value: filterName)) }
        if let filterIntensity { result.append(.init(title: "滤镜强度", value: String(format: "%.0f%%", filterIntensity * 100))) }
        if let filterAdjustments, !filterAdjustments.isNeutral { result.append(.init(title: "滤镜调整", value: filterAdjustments.summary)) }
        if let ratio { result.append(.init(title: "拍摄画面比例", value: ratio)) }
        if let requestedFormat { result.append(.init(title: "拍摄格式设置", value: requestedFormat)) }
        return result
    }
}

/// The filter already present in the pixels or applied by a reversible edit.
struct PhotoFilterRecord: Codable, Equatable {
    var id: String
    var name: String
    var intensity: Double
    var adjustments: FilterAdjustments = FilterAdjustments()
    var applied: Bool { id != FilmStyle.original.rawValue && intensity > 0 }
    var rows: [PhotoInfoRow] {
        var result = [PhotoInfoRow(title: "滤镜", value: name), .init(title: "滤镜强度", value: applied ? String(format: "%.0f%%", intensity * 100) : "—")]
        if !adjustments.isNeutral { result.append(.init(title: "滤镜调整", value: adjustments.summary)) }
        return result
    }
}

/// Capture-time observations; these do not prove which cameras contributed to a fused image.
struct PhotoCaptureDiagnostics: Codable, Equatable {
    var rows: [PhotoInfoRow] = []
    var parameters: PhotoCaptureParameters? = nil
    var bakedFilter: PhotoFilterRecord? = nil
    var editedFilter: PhotoFilterRecord? = nil
    var captureFilter: PhotoFilterRecord? {
        guard let p = parameters, let id = p.filterID else { return nil }
        return PhotoFilterRecord(id: id, name: p.filterName ?? FilmStyle(rawValue: id)?.title ?? id, intensity: p.filterIntensity ?? 1, adjustments: p.filterAdjustments ?? FilterAdjustments())
    }
    // Older copies stored the selected name only as a detail row.
    var legacyEditedFilter: PhotoFilterRecord? {
        guard let name = rows.first(where: { $0.title == "编辑滤镜" })?.value,
              let style = FilmStyle.allCases.first(where: { $0.title == name }), style != .original else { return nil }
        let amount = rows.first(where: { $0.title == "编辑滤镜浓度" })?.value.replacingOccurrences(of: "%", with: "")
        return PhotoFilterRecord(id: style.rawValue, name: name, intensity: amount.flatMap(Double.init).map { $0 / 100 } ?? 1)
    }
    var currentFilter: PhotoFilterRecord? { editedFilter ?? bakedFilter ?? legacyEditedFilter ?? captureFilter }
    var isNightComposite: Bool {
        rows.contains {
            guard $0.title == "夜景曝光合成", let count = Int($0.value.split(separator: " ").first ?? "") else { return false }
            return (2...NightAdaptiveCapturePolicy.maximumFrameCount).contains(count) && $0.value == "\(count) 帧对齐融合"
        }
    }
    var currentParameters: PhotoCaptureParameters? {
        guard var p = parameters else { return nil }
        if let filter = currentFilter { p.filterID = filter.id; p.filterName = filter.name; p.filterIntensity = filter.intensity; p.filterAdjustments = filter.adjustments }
        return p
    }
    var detailRows: [PhotoInfoRow] {
        // 照片信息沿用“夜景曝光合成：N 帧对齐融合”，内部预算与采集数量不重复展示。
        let internalNightRows: Set<String> = ["夜景计划帧数", "夜景实际采集", "夜景曝光需求", "夜景运动评估", "夜景自适应", "夜景自动曝光", "夜景曝光路线"]
        let hidden = internalNightRows.union(["滤镜", "滤镜强度", "滤镜调整", "编辑滤镜", "编辑滤镜浓度"])
        var values = Self.merged(rows, with: parameters?.rows ?? []).filter { !hidden.contains($0.title) }
        if let currentFilter {
            if let captureFilter, captureFilter != currentFilter { values.append(.init(title: "拍摄时滤镜", value: captureFilter.name + (captureFilter.applied ? String(format: " · %.0f%%", captureFilter.intensity * 100) : ""))) }
            return currentFilter.rows + values
        }
        return Self.merged(rows, with: parameters?.rows ?? []).filter { !internalNightRows.contains($0.title) }
    }

    mutating func add(_ title: String, _ value: String) {
        rows.removeAll { $0.title == title }
        rows.append(PhotoInfoRow(title: title, value: value))
    }

    static func exposureRows(properties: [CFString: Any]) -> [PhotoInfoRow] {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var rows: [PhotoInfoRow] = []
        if let aperture = VirtualApertureRenderer.recordedValue(properties) { rows.append(.init(title: "虚拟光圈", value: VirtualApertureRenderer.label(aperture))) }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { rows.append(.init(title: "相机", value: model)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(.init(title: "镜头型号", value: lens)) }
        func positive(_ key: CFString) -> Double? {
            guard let value = exif[key] as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return value.doubleValue
        }
        if let focal = positive(kCGImagePropertyExifFocalLength) { rows.append(.init(title: "实际焦距", value: String(format: "%.2f mm", focal))) }
        if let focal = positive(kCGImagePropertyExifFocalLenIn35mmFilm) { rows.append(.init(title: "35mm 等效焦距", value: String(format: "%.0f mm", focal))) }
        if let zoom = positive(kCGImagePropertyExifDigitalZoomRatio) { rows.append(.init(title: "EXIF 数码变焦比", value: String(format: "%.2f×", zoom))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first, iso.doubleValue.isFinite, iso.doubleValue > 0 { rows.append(.init(title: "ISO", value: iso.stringValue)) }
        if let seconds = positive(kCGImagePropertyExifExposureTime) {
            let value = seconds >= 1 ? String(format: "%.2f s", seconds) : (1 / seconds < Double(Int.max) ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.6g s", seconds))
            rows.append(.init(title: "快门", value: value))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber, bias.doubleValue.isFinite {
            rows.append(.init(title: "成片曝光补偿", value: String(format: "%+.1f EV", bias.doubleValue)))
        }
        if let aperture = positive(kCGImagePropertyExifFNumber) { rows.append(.init(title: "光圈", value: String(format: "f/%.1f", aperture))) }
        return rows
    }

    static func resourceRows(_ resources: [PhotoResource]) -> [PhotoInfoRow] {
        var rows: [PhotoInfoRow] = []
        for (index, resource) in resources.enumerated() {
            let prefix = index == 0 ? "" : "附加资源 \(index) · "
            rows.append(.init(title: prefix + "文件名称", value: resource.filename))
            rows.append(.init(title: prefix + "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(resource.data.count), countStyle: .file)))
            guard let source = CGImageSourceCreateWithData(resource.data as CFData, nil) else { continue }
            if let type = CGImageSourceGetType(source) {
                rows.append(.init(title: prefix + "输出格式", value: UTType(type as String)?.preferredFilenameExtension?.uppercased() ?? (type as String)))
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            rows += dimensionRows(properties: properties, prefix: prefix)
            if index == 0 { rows += exposureRows(properties: properties) }
        }
        return rows
    }

    static func dimensionRows(properties: [CFString: Any], prefix: String = "") -> [PhotoInfoRow] {
        guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue.isFinite, height.doubleValue.isFinite else { return [] }
        return [.init(title: prefix + "输出尺寸", value: "\(width.stringValue) × \(height.stringValue)"),
                .init(title: prefix + "输出像素", value: String(format: "%.1f MP", width.doubleValue * height.doubleValue / 1_000_000))]
    }

    static func merged(_ primary: [PhotoInfoRow], with fallback: [PhotoInfoRow]) -> [PhotoInfoRow] {
        var seen = Set(primary.map(\.title))
        return primary + fallback.filter { seen.insert($0.title).inserted }
    }
}

/// App-local records survive process restarts; original image resources remain unchanged.
final class PhotoCaptureDiagnosticsStore {
    static let shared = PhotoCaptureDiagnosticsStore()
    private let directory: URL
    private let lock = NSLock()
    private var filterCache: [String: Bool] = [:]
    private var nightCache: [String: Bool] = [:]
    private var filterOverrides: [String: Bool]?
    func filterApplied(assetID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if filterOverrides == nil { filterOverrides = (try? Data(contentsOf: directory.appendingPathComponent("FilterStatus.plist"))).flatMap { try? PropertyListDecoder().decode([String: Bool].self, from: $0) } ?? [:] }
        if let value = filterOverrides?[assetID] ?? filterCache[assetID] { return value }
        let diagnostics = (try? Data(contentsOf: url(assetID))).flatMap { try? JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: $0) }
        let value = diagnostics?.currentFilter?.applied ?? false
        if filterCache.count >= 5000 { filterCache.removeAll(keepingCapacity: true) }
        filterCache[assetID] = value
        return value
    }
    func isNightComposite(assetID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let value = nightCache[assetID] { return value }
        let diagnostics = (try? Data(contentsOf: url(assetID))).flatMap { try? JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: $0) }
        let value = diagnostics?.isNightComposite ?? false
        if nightCache.count >= 5000 { nightCache.removeAll(keepingCapacity: true) }
        nightCache[assetID] = value
        return value
    }
    @discardableResult func setFilterApplied(_ value: Bool, assetID: String) -> Bool {
        _ = filterApplied(assetID: assetID)
        lock.lock(); defer { lock.unlock() }
        filterOverrides?[assetID] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListEncoder().encode(filterOverrides ?? [:]).write(to: directory.appendingPathComponent("FilterStatus.plist"), options: .atomic)
            return true
        } catch { return false }
    }
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureDiagnostics", isDirectory: true)) { self.directory = directory }
    private func url(_ assetID: String) -> URL {
        directory.appendingPathComponent(Data(assetID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
    }
    @discardableResult func save(_ diagnostics: PhotoCaptureDiagnostics, assetID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(diagnostics).write(to: url(assetID), options: .atomic)
            filterCache.removeValue(forKey: assetID)
            nightCache.removeValue(forKey: assetID)
            return true
        } catch { return false }
    }
    /// A copy bakes its current look; an overwrite retains the input's reversible base.
    @discardableResult func copyRecord(from sourceID: String, to destinationID: String, adjustments: PhotoAdjustments, sourceIsOriginal: Bool = false) -> Bool {
        var record = load(assetID: sourceID) ?? PhotoCaptureDiagnostics()
        let base = sourceIsOriginal ? (record.bakedFilter ?? record.legacyEditedFilter ?? record.captureFilter) : record.currentFilter
        let style = FilmStyle(rawValue: adjustments.filterID) ?? .original
        let selected = PhotoFilterRecord(id: style.rawValue, name: style.title, intensity: min(max(adjustments.filterIntensity, 0), 1), adjustments: adjustments.filterAdjustments)
        // RAW重新显影的原片选择确实移除了拍摄时滤镜，不能继续沿用旧成片的已烘焙标记。
        let rawEdit = adjustments.rawDevelopment != nil
        let effective = rawEdit || adjustments.usesFilter ? selected : (base ?? PhotoFilterRecord(id: FilmStyle.original.rawValue, name: FilmStyle.original.title, intensity: 0))
        let reversibleBase = rawEdit ? PhotoFilterRecord(id:FilmStyle.original.rawValue,name:FilmStyle.original.title,intensity:0) : base
        record.bakedFilter = sourceID == destinationID ? reversibleBase : effective
        record.editedFilter = sourceID == destinationID ? effective : nil
        if let adaptive = adjustments.rawDevelopment?.adaptive { record.parameters?.adaptiveHighDynamic = adaptive }
        record.rows.removeAll { ["编辑滤镜", "编辑滤镜浓度", "编辑色彩调整"].contains($0.title) }
        if !adjustments.filterAdjustments.isNeutral { record.add("后期色彩调整", adjustments.filterAdjustments.summary) }
        else { record.rows.removeAll { $0.title == "后期色彩调整" } }
        return save(record, assetID: destinationID)
    }
    func load(assetID: String) -> PhotoCaptureDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(assetID)) else { return nil }
        return try? JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: data)
    }
}
