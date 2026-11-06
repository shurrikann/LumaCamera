import Combine
import CoreImage
import SwiftUI
import UIKit

@MainActor
final class PhotoEditorViewModel: ObservableObject {
    #if DEBUG
    var editingRulerFrameForTesting: CGRect = .zero
    var photoViewportFrameForTesting: CGRect = .zero
    var parameterHintFrameForTesting: CGRect = .zero
    var fadeButtonFrameForTesting: CGRect = .zero
    #endif
    let session: PhotoEditSession
    private let library: PhotoLibraryViewModel
    @Published var adjustments: PhotoAdjustments {
        didSet {
            if tool == .crop { var old = oldValue; old.crop = adjustments.crop; if old == adjustments { return } }
            renderPreview(structural: oldValue.filterID != adjustments.filterID || oldValue.quarterTurns != adjustments.quarterTurns)
        }
    }
    @Published var tool = PhotoEditorTool.filters { didSet { setParameterEditing(false); renderPreview(structural: true) } }
    @Published var preservesLive = true
    @Published var selectedParameter = FilterParameter.temperature
    private var cropEntry: PhotoAdjustments?
    private var toolBeforeCrop = PhotoEditorTool.filters
    @Published var filterTab = FilterEditorTab.color {
        didSet { if !filterTab.parameters.contains(selectedParameter) { selectedParameter = filterTab.parameters.first(where: { $0 != .strength }) ?? .temperature } }
    }
    @Published private(set) var preview: UIImage?
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
    private struct Request { let adjustments: PhotoAdjustments; let revision: UInt64 }
    private lazy var renderer = LatestValueThrottle<Request>(queue: queue, interval: 1.0 / 60) { [weak self, source = session.source, raw = session.rawDevelopment, context, gate = previewGate] request in
        guard gate.canRender(request.revision) else { return }
        let image:UIImage?
        do {
            image = try raw.map { try $0.preview(request.adjustments) }
                ?? PhotoEditRenderer.preview(source:source,adjustments:request.adjustments,context:context)
        } catch {
            DispatchQueue.main.async {
                guard let self, !self.cancelled, gate.acceptsPublication(request.revision) else { return }
                self.message = "RAW 显影失败：\(error.localizedDescription)"
            }
            return
        }
        DispatchQueue.main.async {
            guard let self, !self.cancelled, gate.acceptsPublication(request.revision) else { return }
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
    }
    var style: FilmStyle { FilmStyle(rawValue: adjustments.filterID) ?? .original }
    func selectFilter(_ style: FilmStyle) {
        guard !saving, style != self.style, FilmStyle.availableStyles.contains(style) else { return }
        setParameterEditing(false); dismissReset(); resetRevision &+= 1
        recipes[adjustments.filterID] = SavedFilterSettings(intensity: adjustments.filterIntensity, adjustments: adjustments.filterAdjustments)
        let saved = recipes[style.rawValue] ?? SavedFilterSettings()
        var next = adjustments; next.filterID = style.rawValue; next.filterIntensity = saved.intensity; next.filterAdjustments = saved.adjustments
        adjustments = next
    }
    func parameterBinding(_ parameter: FilterParameter) -> Binding<Double> {
        let revision = resetRevision, filter = adjustments.filterID
        return Binding(get: { [self] in parameter == .strength ? (style == .original ? 0 : adjustments.filterIntensity * 100) : adjustments.filterAdjustments[parameter] }, set: { [self] value in
            guard !saving, !resetVisible, revision == resetRevision, filter == adjustments.filterID else { return }
            if parameter == .strength { if style != .original { adjustments.filterIntensity = parameter.clamped(value) / 100 } }
            else { adjustments.filterAdjustments[parameter] = value }
        })
    }
    func parameterText(_ parameter: FilterParameter) -> String { parameter == .strength && style == .original ? "—" : parameter.text(parameterBinding(parameter).wrappedValue) }
    func setParameterEditing(_ active: Bool) {
        guard editingParameter != active else { return }
        editingParameter = active; previewGate.setInteractive(active)
        if !active { renderPreview() }
    }
    func presentReset() { guard !saving else { return }; setParameterEditing(false); resetVisible = true }
    func dismissReset() { resetVisible = false }
    func resetCurrentFilter() {
        guard !saving else { return }
        setParameterEditing(false); dismissReset(); resetRevision &+= 1
        var next = adjustments; next.filterIntensity = 0.8; next.filterAdjustments = FilterAdjustments()
        adjustments = next
    }
    func enterCrop() {
        guard !saving, tool != .crop else { return }
        toolBeforeCrop = tool; cropEntry = adjustments; tool = .crop
    }
    func finishCrop(commit: Bool) {
        guard !saving else { return }
        if !commit, let cropEntry { adjustments = cropEntry }
        cropEntry = nil; tool = toolBeforeCrop
    }
    func resetGeometry() {
        var next = adjustments
        next.crop = .full; next.quarterTurns = 0; next.flipHorizontal = false; next.flipVertical = false; next.straightenAngle = 0
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
        if tool == .crop { rendered.crop = .full }
        renderer.submit(Request(adjustments: rendered, revision: revision))
    }
    func presentSaveOptions() { guard !saving else { return }; setParameterEditing(false); dismissReset(); saveOptionsVisible = true }
    func dismissSaveOptions() { saveOptionsVisible = false }
    func save(asCopy: Bool = false, completion: @escaping (PhotoEditResult) -> Void) {
        guard !saving, library.beginEditing() else { return }
        setParameterEditing(false); dismissReset(); dismissSaveOptions(); saving = true
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
        
    func cancelPreview() { cancelled = true; previewGate.setInteractive(false); _ = previewGate.advance(); renderer.cancel() }
}
