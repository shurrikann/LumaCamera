import Combine
import CoreImage
import SwiftUI
import UIKit

@MainActor
final class PhotoEditorViewModel: ObservableObject, FilterEditingControls {
    #if DEBUG
    var editingRulerFrameForTesting: CGRect = .zero
    var photoViewportFrameForTesting: CGRect = .zero
    var filterDialPadFrameForTesting: CGRect = .zero
    var captureButtonFramesForTesting: [String: CGRect] = [:]
    #endif
    let session: PhotoEditSession
    private let library: PhotoLibraryViewModel
    @Published private(set) var filterNumericParameter: FilterParameter?
    @Published var filterNumericDraft = ""
    private var filterNumericBinding: Binding<Double>?
    var filterDialControlsEnabled: Bool { !saving && !resetVisible && !cancelled }
    @Published var adjustments: PhotoAdjustments {
        didSet {
            if tool == .crop { var old = oldValue; old.crop = adjustments.crop; if old == adjustments { return } }
            renderPreview(structural: oldValue.filterID != adjustments.filterID || oldValue.quarterTurns != adjustments.quarterTurns)
        }
    }
    @Published var watermarkSettings = PhotoWatermarkSettings()
    @Published var tool = PhotoEditorTool.filters {
        didSet {
            if tool != .filters { filterPopupVisible = false }
            dismissFilterNumericInput(); setParameterEditing(false); renderPreview(structural: true)
        }
    }
    @Published private(set) var editorControlsVisible = true
    /// 照片详情进入时工具栏可见，但滤镜底部弹窗必须等待用户点击。
    @Published private(set) var filterPopupVisible = false
    @Published var preservesLive = true
    private var cropEntry: PhotoAdjustments?
    private var toolBeforeCrop = PhotoEditorTool.filters
    @Published var filterEditorTab = FilterEditorTab.color {
        didSet { if filterEditorTab != oldValue { dismissFilterNumericInput() } }
    }
    @Published private(set) var preview: UIImage?
    @Published private(set) var cropOverflowPreview: UIImage?
    private(set) var cropOverflowExtent: CGRect = .zero
    private var cropGeometryBase: UIImage?
    private var cropBaseRevision: UInt64 = 0
    @Published private(set) var saving = false
    @Published var message: String?
    @Published private(set) var saveOptionsVisible = false
    @Published private(set) var resetVisible = false
    private var resetRevision: UInt64 = 0
    private var recipes: [String: SavedFilterSettings] = [:]
    private var editingParameter = false
    private var cancelled = false
    private let queue = DispatchQueue(label: "photos.edit-preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let previewGate = PreviewRevision()
    private struct Request {
        let adjustments: PhotoAdjustments
        let revision: UInt64
        var cropBase: UIImage? = nil
    }
    private lazy var renderer = LatestValueThrottle<Request>(queue: queue, interval: 1.0 / 60) { [weak self, source = session.source, raw = session.rawDevelopment, context, gate = previewGate] request in
        guard gate.canRender(request.revision) else { return }
        let image:UIImage?
        var overflow: UIImage?
        var overflowExtent = CGRect.zero
        do {
            if let base = request.cropBase, let baseImage = CIImage(image: base) {
                let outside = request.adjustments.applyGeometry(to: baseImage, preservesOutside: true)
                overflowExtent = outside.extent
                overflow = Imaging.ownedCGImage(outside, from: outside.extent, context: context,
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    .map(UIImage.init(cgImage:))
                let geometry = request.adjustments.applyGeometry(to: baseImage)
                image = Imaging.ownedCGImage(geometry, from: geometry.extent, context: context,
                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    .map(UIImage.init(cgImage:))
            } else {
                image = try raw.map { try $0.preview(request.adjustments) }
                    ?? PhotoEditRenderer.preview(source:source,adjustments:request.adjustments,context:context)
            }
        } catch {
            DispatchQueue.main.async {
                guard let self, !self.cancelled, gate.acceptsPublication(request.revision) else { return }
                self.message = "RAW 显影失败：\(error.localizedDescription)"
            }
            return
        }
        DispatchQueue.main.async {
            guard let self, !self.cancelled, gate.acceptsPublication(request.revision) else { return }
            self.cropOverflowExtent = overflowExtent
            self.cropOverflowPreview = overflow
            self.preview = image
        }
    }
    init(session: PhotoEditSession, library: PhotoLibraryViewModel) {
        self.session = session; self.library = library
        var initial = session.initialAdjustments
        // Migrate the old editor's three controls into the shared filter recipe.
        initial.filterAdjustments[.exposure] += initial.exposure
        initial.filterAdjustments[.contrast] += log2(max(initial.contrast, 0.001)) * 100
        initial.filterAdjustments[.saturation] = (1 + initial.filterAdjustments[.saturation] / 100) * initial.saturation * 100 - 100
        initial.exposure = 0; initial.contrast = 1; initial.saturation = 1
        if !FilmStyle.availableStyles.contains(where: { $0.rawValue == initial.filterID }) { initial.filterID = FilmStyle.original.rawValue }
        adjustments = initial
        watermarkSettings = initial.watermark?.settings ?? CapturePreferencesStore().load().watermark
    }
    var style: FilmStyle { FilmStyle(rawValue: adjustments.filterID) ?? .original }
    func selectFilter(_ style: FilmStyle) {
        guard !saving, style != self.style, FilmStyle.availableStyles.contains(style) else { return }
        dismissFilterNumericInput(); setParameterEditing(false); dismissReset(); resetRevision &+= 1
        recipes[adjustments.filterID] = SavedFilterSettings(intensity: adjustments.filterIntensity, adjustments: adjustments.filterAdjustments)
        let saved = recipes[style.rawValue] ?? SavedFilterSettings(intensity: style.defaultIntensity, adjustments: FilterAdjustments())
        var next = adjustments; next.filterID = style.rawValue; next.filterIntensity = saved.intensity; next.filterAdjustments = saved.adjustments
        adjustments = next
    }
    func parameterBinding(_ parameter: FilterParameter) -> Binding<Double> {
        let revision = resetRevision, filter = adjustments.filterID
        return Binding(get: { [self] in parameter == .strength ? (style == .original ? 0 : adjustments.filterIntensity * 100) : adjustments.filterAdjustments[parameter] }, set: { [self] value in
            guard !saving, !cancelled, !resetVisible, revision == resetRevision, filter == adjustments.filterID else { return }
            if parameter == .strength { if style != .original { adjustments.filterIntensity = parameter.clamped(value) / 100 } }
            else { adjustments.filterAdjustments[parameter] = value }
        })
    }
    // 以下适配只操作本次编辑配方，不写CameraViewModel或相机FilterSettingsStore。
    func filterParameterBinding(_ parameter: FilterParameter) -> Binding<Double> { parameterBinding(parameter) }
    func filterParameterText(_ parameter: FilterParameter) -> String { parameterText(parameter) }
    func setFilterParameterEditing(_ editing: Bool) { setParameterEditing(editing) }
    func filterParameterPairBinding(_ x: FilterParameter, _ y: FilterParameter) -> Binding<CGPoint> {
        let revision = resetRevision, filter = adjustments.filterID, tab = filterEditorTab
        return Binding(get: { [self] in CGPoint(x: adjustments.filterAdjustments[x], y: adjustments.filterAdjustments[y]) },
                       set: { [self] point in
            guard filterDialControlsEnabled, revision == resetRevision, filter == adjustments.filterID, tab == filterEditorTab,
                  x != .strength, y != .strength, point.x.isFinite, point.y.isFinite else { return }
            var next = adjustments
            next.filterAdjustments[x] = Double(point.x); next.filterAdjustments[y] = Double(point.y)
            if next != adjustments { adjustments = next }
        })
    }
    func resetCurrentFilterTab() {
        guard filterDialControlsEnabled else { return }
        dismissFilterNumericInput(); setParameterEditing(false); resetRevision &+= 1
        var next = adjustments
        for parameter in filterEditorTab.parameters {
            if parameter == .strength { next.filterIntensity = parameter.defaultValue / 100 }
            else { next.filterAdjustments[parameter] = parameter.defaultValue }
        }
        adjustments = next
    }
    func presentFilterNumericInput(_ parameter: FilterParameter) {
        guard filterDialControlsEnabled, tool == .adjustments || tool == .filters,
              !(parameter == .strength && style == .original) else { return }
        setParameterEditing(false)
        let binding = parameterBinding(parameter)
        filterNumericBinding = binding; filterNumericDraft = String(binding.wrappedValue)
        filterNumericParameter = parameter
    }
    var filterNumericValue: Double? { filterNumericParameter?.inputValue(from: filterNumericDraft) }
    func restoreFilterNumericDraft() {
        guard let parameter = filterNumericParameter else { return }
        filterNumericDraft = String(parameter.defaultValue)
    }
    func confirmFilterNumericInput() {
        guard let value = filterNumericValue, let binding = filterNumericBinding else { return }
        binding.wrappedValue = value; dismissFilterNumericInput()
    }
    func dismissFilterNumericInput() {
        filterNumericParameter = nil; filterNumericBinding = nil; filterNumericDraft = ""
    }
    func parameterText(_ parameter: FilterParameter) -> String { parameter == .strength && style == .original ? "—" : parameter.text(parameterBinding(parameter).wrappedValue) }
    func setParameterEditing(_ active: Bool) {
        guard editingParameter != active else { return }
        editingParameter = active; previewGate.setInteractive(active)
        if !active { renderPreview() }
    }
    func presentReset() { guard !saving else { return }; dismissFilterNumericInput(); setParameterEditing(false); resetVisible = true }
    func dismissReset() { resetVisible = false }
    func resetCurrentFilter() {
        guard !saving else { return }
        dismissFilterNumericInput(); setParameterEditing(false); dismissReset(); resetRevision &+= 1
        var next = adjustments; next.filterIntensity = 0.8; next.filterAdjustments = FilterAdjustments()
        adjustments = next
    }
    /// 底部工具再次点击即可收起；只隐藏控件，不丢弃当前照片配方。
    func toggleEditorControls(_ requested: PhotoEditorTool) {
        guard !saving, requested != .crop else { return }
        dismissFilterNumericInput(); setParameterEditing(false)
        if requested == .filters {
            if filterPopupVisible {
                closeEditorControls()
            } else {
                tool = .filters
                editorControlsVisible = true
                filterPopupVisible = true
            }
            return
        }
        filterPopupVisible = false
        if tool == requested { editorControlsVisible.toggle() }
        else { tool = requested; editorControlsVisible = true }
    }
    func closeEditorControls() {
        guard !saving else { return }
        dismissFilterNumericInput(); setParameterEditing(false)
        filterPopupVisible = false
        editorControlsVisible = false
    }
    var editorControlsHeight: CGFloat {
        guard editorControlsVisible else { return 0 }
        return (tool == .filters || tool == .watermark) ? 0 : 290
    }
    func selectWatermarkStyle(_ style: PhotoWatermarkStyle) {
        guard !saving, !cancelled else { return }
        let selected = adjustments.watermark?.settings.style == style
        watermarkSettings.style = style
        if selected { adjustments.watermark = nil }
        else {
            var content = adjustments.watermark?.content ?? session.watermarkContent
            if content.signature.isEmpty { content.signature = CapturePreferencesStore().load().copyright }
            adjustments.watermark = PhotoEditWatermark(settings: watermarkSettings, content: content)
        }
    }
    func setWatermarkInformation(location: Bool? = nil, parameters: Bool? = nil) {
        guard !saving, !cancelled else { return }
        if let location { watermarkSettings.showsLocation = location }
        if let parameters { watermarkSettings.showsParameters = parameters }
        if adjustments.watermark != nil { adjustments.watermark?.settings = watermarkSettings }
    }
    func enterCrop() {
        guard !saving, tool != .crop else { return }
        // 裁剪与滤镜调节互斥；完成或取消裁剪后也不自动重新展开旧面板。
        closeEditorControls()
        toolBeforeCrop = tool; cropEntry = adjustments; tool = .crop
        prepareCropGeometryBase()
    }
    func finishCrop(commit: Bool) {
        guard !saving else { return }
        if !commit, let cropEntry { adjustments = cropEntry }
        cropEntry = nil; tool = toolBeforeCrop
        clearCropGeometryBase()
    }
    /// One color/filter render per crop entry. RAW decode is expensive, so
    /// rotation/perspective ticks then apply geometry to this cached image.
    private func prepareCropGeometryBase() {
        cropBaseRevision &+= 1
        let revision = cropBaseRevision
        var base = adjustments
        base.crop = .full
        base.quarterTurns = 0
        base.flipHorizontal = false
        base.flipVertical = false
        base.straightenAngle = 0
        base.stretch = PhotoStretch()
        base.watermark = nil
        let source = session.source
        let raw = session.rawDevelopment
        let context = context
        queue.async { [weak self] in
            let image: UIImage?
            if let raw { image = try? raw.preview(base) }
            else { image = PhotoEditRenderer.preview(source: source, adjustments: base, context: context) }
            DispatchQueue.main.async {
                guard let self, self.tool == .crop, revision == self.cropBaseRevision else { return }
                self.cropGeometryBase = image
                if image != nil { self.renderPreview() }
            }
        }
    }

    private func clearCropGeometryBase() {
        cropBaseRevision &+= 1
        cropGeometryBase = nil
        cropOverflowPreview = nil
        cropOverflowExtent = .zero
    }

    func resetGeometry() {
        var next = adjustments
        next.crop = .full; next.quarterTurns = 0; next.flipHorizontal = false; next.flipVertical = false
        next.straightenAngle = 0; next.stretch = PhotoStretch()
        adjustments = next
    }
    func rotate() {
        guard !saving else { return }; setParameterEditing(false)
        var next = adjustments; next.quarterTurns = (next.quarterTurns + 1) % 4
        let crop = next.crop.clamped
        next.crop = PhotoCropRectangle(x: 1-crop.y-crop.height, y: crop.x, width: crop.height, height: crop.width)
        adjustments = next
    }
    func flip(horizontal: Bool) {
        guard !saving else { return }
        var next = adjustments
        if horizontal { next.flipHorizontal.toggle(); next.crop.x = 1-next.crop.x-next.crop.width }
        else { next.flipVertical.toggle(); next.crop.y = 1-next.crop.y-next.crop.height }
        adjustments = next
    }
    func setCropAspect(_ ratio: FrameRatio?) {
        guard !saving else { return }
        guard let ratio else { adjustments.crop = .full; return }
        let rotated = adjustments.quarterTurns % 2 != 0
        let imageAspect = rotated ? session.source.extent.height/session.source.extent.width : session.source.extent.width/session.source.extent.height
        let aspect = imageAspect > 1 ? 1/ratio.portraitRatio : ratio.portraitRatio
        let fraction = aspect/imageAspect
        let width = min(1, fraction), height = min(1, 1/fraction)
        adjustments.crop = PhotoCropRectangle(x: (1-width)/2, y: (1-height)/2, width: width, height: height)
    }
    func renderPreview(structural: Bool = false) {
        cancelled = false
        let revision = previewGate.advance(resetInteractiveFloor: structural)
        var rendered = adjustments
        if tool == .crop { rendered.crop = .full; rendered.watermark = nil }
        let base = tool == .crop ? cropGeometryBase : nil
        renderer.submit(Request(adjustments: rendered, revision: revision, cropBase: base))
    }
    func presentSaveOptions() { guard !saving else { return }; dismissFilterNumericInput(); setParameterEditing(false); dismissReset(); saveOptionsVisible = true }
    func dismissSaveOptions() { saveOptionsVisible = false }
    func save(asCopy: Bool = false, completion: @escaping (PhotoEditResult) -> Void) {
        guard !saving, library.beginEditing() else { return }
        dismissFilterNumericInput(); setParameterEditing(false); dismissReset(); dismissSaveOptions(); saving = true
        let library = library
        let finish: (Result<PhotoEditResult, Error>) -> Void = { [weak self] result in
            library.endEditing()
            guard let self else { return }
            self.saving = false
            switch result { case .success(let result): completion(result); case .failure(let error): self.message = error.localizedDescription }
        }
        if session.supportsLiveEditing && preservesLive { session.saveLive(adjustments, asCopy: asCopy, completion: finish) }
        else if session.supportsLiveEditing || asCopy { session.saveCopy(adjustments, completion: finish) }
        else { session.save(adjustments, completion: finish) }
    }
        
    func cancelPreview() {
        clearCropGeometryBase()
        dismissFilterNumericInput(); editingParameter = false; cancelled = true; previewGate.setInteractive(false); _ = previewGate.advance(); renderer.cancel()
    }
}
