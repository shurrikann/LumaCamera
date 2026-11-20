import AVFoundation
import Combine
import CoreImage
import CoreMedia
import SwiftUI
import UIKit

@MainActor
final class VideoEditorViewModel: FilterEditingControls {
    let asset: AVAsset
    let photo: LibraryPhoto
    let player: AVPlayer
    let playerItem: AVPlayerItem
    @Published private(set) var isLogVideo: Bool
    @Published private(set) var colorSpace: VideoColorSpace
    @Published private(set) var availableTools: [VideoEditorTool]
    private(set) var hasKnownColorSpace: Bool

    @Published var tool: VideoEditorTool = .trim
    @Published private(set) var isToolPanelPresented = false
    @Published private(set) var isSelectingLivePhoto = false
    private var trimBeforeLive: (start: Double, end: Double)?
    @Published private(set) var duration: Double = 0
    @Published private(set) var filmstripThumbnails: [UIImage] = []
    @Published private(set) var playheadTime: Double = 0
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published private(set) var message: String?
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var style: FilmStyle { didSet { if style != oldValue { rememberAndPreview(oldValue) } } }
    @Published var intensity: Double { didSet { if editingFilter { renderLiveFilterPreview() }; schedulePreview() } }
    @Published var adjustments: FilterAdjustments {
        didSet {
            if editingFilter {
                if adjustments[.grainSize] > 0 { startLivePreviewGrainAnimation() }
                else { stopLivePreviewGrainAnimation() }
                renderLiveFilterPreview()
            }
            schedulePreview()
        }
    }
    @Published var selectedLogLUTID: String { didSet { if selectedLogLUTID != oldValue { schedulePreview() } } }
    /// 与相机 Log 面板一致：关闭时只预览 LUT，导出保留原始 Log 色彩。
    @Published var burnLogLUT = true
    @Published private(set) var logLUTCategory: LogLUTCategory = .all
    @Published private(set) var logLUTFavorites: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "camera.favoriteLogLUTs") ?? [])
    @Published private(set) var logLUTThumbnails: [String: UIImage] = [:]
    @Published private(set) var logLUTThumbnailLoading: Set<String> = []
    @Published var filterEditorTab: FilterEditorTab = .color {
        didSet { if filterEditorTab != oldValue { invalidateFilterControls() } }
    }
    @Published private(set) var filterNumericParameter: FilterParameter?
    @Published var filterNumericDraft = ""
    /// 暂停拖动参数时覆盖在播放器上的小尺寸实时预览；不改变最终合成。
    @Published private(set) var liveFilterPreview: UIImage?
    #if DEBUG
    var filterDialPadFrameForTesting: CGRect = .zero
    var captureButtonFramesForTesting: [String: CGRect] = [:]
    private(set) var previewCompositionBuildCount = 0
    #endif
    private var filterControlRevision: UInt64 = 0
    private var editingFilter = false

    private(set) var trimPreviewSeekRequestCount = 0
    private(set) var isSeekingTrimPreview = false

    private let library: PhotoLibraryViewModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let logLUTThumbnailQueue = DispatchQueue(label: "videoEditor.logLUTThumbnails", qos: .userInitiated)
    private static let logLUTThumbnailContext = CIContext(options: [.cacheIntermediates: false])
    private static let logLUTThumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()
    private var recipes: [String: SavedFilterSettings] = [:]
    private var previewTask: Task<Void, Never>?
    private let previewState = VideoEditorPreviewState()
    private var previewComposition: AVMutableVideoComposition?
    private var videoFrameRate = 30.0
    private var livePreviewSource: CIImage?
    private var livePreviewSourceTime: Double = .nan
    private var livePreviewSourceTask: Task<Void, Never>?
    private var livePreviewRenderTask: Task<Void, Never>?
    private var livePreviewClearTask: Task<Void, Never>?
    private var livePreviewAnimationTask: Task<Void, Never>?
    private var livePreviewRevision: UInt64 = 0
    private var livePreviewGrainFrame: Int64 = 0
    private var filmstripTask: Task<Void, Never>?
    private var trimPreviewSeekTask: Task<Void, Never>?
    private var pendingTrimPreviewTime: Double?
    private var playbackObserver: Any?
    private var previewRevision: UInt64 = 0

    init(asset: AVAsset, photo: LibraryPhoto, library: PhotoLibraryViewModel) {
        self.asset = asset
        self.photo = photo
        self.library = library
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        let badges = photo.videoBadges
        let storedColorSpace = badges?.colorSpace
            ?? (photo.logLabel == "LOG2" ? .appleLog2 : photo.logLabel != nil ? .appleLog : nil)
        let resolvedColorSpace = storedColorSpace ?? .sdr
        let logVideo = photo.logLabel != nil || resolvedColorSpace.isLog
        colorSpace = resolvedColorSpace
        hasKnownColorSpace = storedColorSpace != nil
        isLogVideo = logVideo
        availableTools = storedColorSpace.map { VideoEditorTool.available(colorSpace: $0) } ?? [.trim]

        let hasSourceFilter = photo.hasFilter
        let storedStyle = badges?.filmStyleID.flatMap(FilmStyle.init(rawValue:))
        if !logVideo, hasSourceFilter, let storedStyle, FilmStyle.availableStyles.contains(storedStyle) {
            style = storedStyle
        } else {
            style = .original
        }
        intensity = badges?.filterIntensity.map { min(max($0, 0), 1) } ?? 0.8
        adjustments = badges?.filterAdjustments ?? FilterAdjustments()
        let storedLUT = badges?.logLUTID
        if logVideo, hasSourceFilter, let storedLUT { selectedLogLUTID = storedLUT }
        else { selectedLogLUTID = LogLUTPreset.originalID }
        playbackObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 12), queue: .main) { [weak self] time in
            guard time.seconds.isFinite else { return }
            Task { @MainActor [weak self] in self?.playheadTime = time.seconds }
        }
        Task { await loadDuration() }
    }

    var allLogLUTOptions: [LogLUTPreset] { [.original] + LogLUTCubeRepository.presets() }
    var logLUTOptions: [LogLUTPreset] {
        let compatible = LogLUTCubeRepository.presets().filter {
            $0.requiredColorSpace == nil || $0.requiredColorSpace == colorSpace
        }
        if logLUTCategory == .favorites {
            return compatible.filter { logLUTFavorites.contains($0.id) }
        }
        return [.original] + compatible.filter { logLUTCategory.includes($0) }
    }
    var selectedLogLUTPreset: LogLUTPreset? {
        allLogLUTOptions.first { $0.id == selectedLogLUTID }
    }
    func selectLogLUTCategory(_ category: LogLUTCategory) { logLUTCategory = category }
    func toggleLogLUTFavorite(_ id: String) {
        guard LogLUTCubeRepository.presets().contains(where: { $0.id == id }) else { return }
        if logLUTFavorites.contains(id) { logLUTFavorites.remove(id) }
        else { logLUTFavorites.insert(id) }
        UserDefaults.standard.set(
            LogLUTCubeRepository.presets().filter { logLUTFavorites.contains($0.id) }.map(\.id),
            forKey: "camera.favoriteLogLUTs")
    }
    func prepareLogLUTThumbnail(for preset: LogLUTPreset) {
        guard preset.id != LogLUTPreset.originalID,
              logLUTThumbnails[preset.id] == nil,
              !logLUTThumbnailLoading.contains(preset.id) else { return }
        if let cached = Self.logLUTThumbnailCache.object(forKey: preset.id as NSString) {
            logLUTThumbnails[preset.id] = cached
            return
        }
        logLUTThumbnailLoading.insert(preset.id)
        let thumbnailContext = Self.logLUTThumbnailContext
        Self.logLUTThumbnailQueue.async { [weak self] in
            let image: UIImage? = autoreleasepool {
                guard let photo = UIImage(named: "FilterLandscape"),
                      let sourceImage = CIImage(image: photo) else { return nil }
                let square = FrameRatio.square.crop(sourceImage)
                let size: CGFloat = 112
                let sample = square.transformed(by: CGAffineTransform(scaleX: size / square.extent.width,
                                                                       y: size / square.extent.width))
                return LogLUTCubeRepository.thumbnail(for: preset, source: sample, context: thumbnailContext)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.logLUTThumbnailLoading.remove(preset.id)
                guard let image else { return }
                let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                Self.logLUTThumbnailCache.setObject(image, forKey: preset.id as NSString, cost: cost)
                self.logLUTThumbnails[preset.id] = image
            }
        }
    }
    func selectLogLUT(_ id: String) {
        guard allLogLUTOptions.contains(where: { $0.id == id }) else { return }
        selectedLogLUTID = id
    }
    var minimumTrimDuration: Double { min(0.1, max(0, duration)) }
    var selectedLook: CaptureLook { CaptureLook(style: style, intensity: intensity, adjustments: adjustments) }
    var isSavingLibrary: Bool { library.videoSaving }
    var hasEdits: Bool {
        isLogVideo ? selectedLogLUTID != LogLUTPreset.originalID : style != .original || !adjustments.isNeutral
    }

    var selectedTrimDuration: Double { max(0, trimEnd - trimStart) }

    var livePhotoDurationLabel: String {
        let seconds = isSelectingLivePhoto ? selectedTrimDuration : min(3, duration)
        if abs(seconds.rounded() - seconds) < 0.05 { return "\(Int(seconds.rounded()))s" }
        return String(format: "%.1fs", seconds)
    }

    func selectTool(_ selected: VideoEditorTool) {
        guard availableTools.contains(selected), !saving else { return }
        invalidateFilterControls()
        isToolPanelPresented = tool != selected || !isToolPanelPresented
        tool = selected
        if selected == .filters, isToolPanelPresented {
            prepareLiveFilterPreviewSource()
        } else {
            clearLiveFilterPreviewImmediately()
        }
    }

    func closeToolPanel() {
        invalidateFilterControls()
        isToolPanelPresented = false
        clearLiveFilterPreviewImmediately()
    }

    func toggleLivePhotoSelection() {
        guard !loading, !saving, duration > 0 else { return }
        if isSelectingLivePhoto {
            isSelectingLivePhoto = false
            if let previous = trimBeforeLive { trimStart = previous.start; trimEnd = previous.end }
            trimBeforeLive = nil
        } else {
            trimBeforeLive = (trimStart, trimEnd)
            let range = VideoTrimSelection.livePhoto(start: 0, end: duration,
                                                     totalDuration: duration, playhead: playheadTime)
            trimStart = range.start
            trimEnd = range.end
            isSelectingLivePhoto = true
        }
        syncPreviewTrimRange(keepCurrentPreview: true)
        seekPreview(to: trimStart)
    }

    /// Move a fixed-length Live selection across the source, never resize it.
    func moveLivePhotoSelection(to start: Double) {
        guard isSelectingLivePhoto, !saving, start.isFinite else { return }
        let length = min(3, duration)
        let bounded = min(max(start, 0), max(0, duration - length))
        guard bounded != trimStart else { return }
        trimStart = bounded
        trimEnd = bounded + length
        scheduleTrimPointPreview(to: bounded)
    }

    func setTrimStart(_ value: Double) {
        if isSelectingLivePhoto { moveLivePhotoSelection(to: value); return }
        let bounded = boundedStart(value)
        guard bounded != trimStart else { return }
        trimStart = bounded
        scheduleTrimPointPreview(to: bounded)
    }

    func setTrimEnd(_ value: Double) {
        if isSelectingLivePhoto { moveLivePhotoSelection(to: value - min(3, duration)); return }
        let bounded = boundedEnd(value)
        guard bounded != trimEnd else { return }
        trimEnd = bounded
        scheduleTrimPointPreview(to: bounded)
    }

    func finishTrimDrag() {
        syncPreviewTrimRange(keepCurrentPreview: true)
    }

    func resetTrim() {
        guard duration > 0 else { return }
        isSelectingLivePhoto = false
        trimBeforeLive = nil
        trimStart = 0
        trimEnd = duration
        syncPreviewTrimRange(keepCurrentPreview: true)
        pendingTrimPreviewTime = nil
        seekPreview(to: 0)
    }

    func seekPreview(to value: Double) {
        scheduleTrimPointPreview(to: value)
    }

    /// Coalesce drag events into one serialized AVPlayer seek stream. Updating
    /// the item playback boundary on every pointer event forces unnecessary
    /// player work, so the selected range is committed when the drag ends.
    private func scheduleTrimPointPreview(to value: Double) {
        guard duration > 0, value.isFinite else { return }
        pendingTrimPreviewTime = min(max(value, 0), duration)
        player.pause()
        isSeekingTrimPreview = true
        guard trimPreviewSeekTask == nil else { return }

        trimPreviewSeekTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var nextSeekAllowedAt = clock.now
            while !Task.isCancelled, self.pendingTrimPreviewTime != nil {
                let now = clock.now
                if now < nextSeekAllowedAt {
                    do { try await Task.sleep(for: now.duration(to: nextSeekAllowedAt)) }
                    catch { break }
                }
                guard !Task.isCancelled, let latestTarget = self.pendingTrimPreviewTime else { continue }
                self.pendingTrimPreviewTime = nil
                let seekStart = clock.now
                let time = CMTime(seconds: latestTarget, preferredTimescale: 600)
                self.trimPreviewSeekRequestCount += 1
                let finished = await self.player.seek(to: time,
                                           toleranceBefore: CMTime(value: 1, timescale: 15),
                                           toleranceAfter: CMTime(value: 1, timescale: 15))
                if finished, !Task.isCancelled {
                    let actualTime = self.player.currentTime().seconds
                    if actualTime.isFinite { self.playheadTime = actualTime }
                }
                nextSeekAllowedAt = seekStart.advanced(by: .milliseconds(33))
            }
            self.isSeekingTrimPreview = false
            self.trimPreviewSeekTask = nil
        }
    }
    func dismissMessage() { message = nil }

    func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause(); return }
        clearLiveFilterPreviewImmediately()
        syncPreviewTrimRange(keepCurrentPreview: true)
        let current = player.currentTime().seconds
        if !current.isFinite || current < trimStart || current >= trimEnd {
            player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished else { return }
                Task { @MainActor [weak self] in self?.player.play() }
            }
        } else { player.play() }
    }

    func value(for parameter: FilterParameter) -> Double {
        parameter == .strength ? (style == .original ? 0 : intensity * 100) : adjustments[parameter]
    }

    func setValue(_ value: Double, for parameter: FilterParameter) {
        guard !saving, value.isFinite else { return }
        if parameter == .strength {
            guard style != .original else { return }
            let normalized = parameter.clamped(value) / 100
            guard normalized != intensity else { return }
            intensity = normalized
        } else {
            adjustments[parameter] = value
        }
    }

    var filterDialControlsEnabled: Bool {
        !loading && !saving && isToolPanelPresented
            && (tool == .filters || tool == .adjustments) && availableTools.contains(tool)
    }

    func filterParameterBinding(_ parameter: FilterParameter) -> Binding<Double> {
        let revision = filterControlRevision
        return Binding(get: { [self] in value(for: parameter) }, set: { [self] value in
            guard filterDialControlsEnabled, revision == filterControlRevision else { return }
            setValue(value, for: parameter)
        })
    }

    func filterParameterPairBinding(_ x: FilterParameter, _ y: FilterParameter) -> Binding<CGPoint> {
        let revision = filterControlRevision
        return Binding(get: { [self] in CGPoint(x: value(for: x), y: value(for: y)) }, set: { [self] point in
            guard filterDialControlsEnabled, revision == filterControlRevision,
                  x != .strength, y != .strength, point.x.isFinite, point.y.isFinite else { return }
            var next = adjustments
            next[x] = Double(point.x); next[y] = Double(point.y)
            if next != adjustments { adjustments = next }
        })
    }

    func filterParameterText(_ parameter: FilterParameter) -> String {
        parameter == .strength && style == .original ? "—" : parameter.text(value(for: parameter))
    }

    func setFilterParameterEditing(_ editing: Bool) {
        guard editingFilter != editing else { return }
        editingFilter = editing
        if editing {
            livePreviewGrainFrame = Int64(max(0, player.currentTime().seconds * videoFrameRate))
            if adjustments[.grainSize] > 0 { startLivePreviewGrainAnimation() }
            prepareLiveFilterPreviewSource()
            renderLiveFilterPreview()
        } else {
            stopLivePreviewGrainAnimation()
            schedulePreview(delay: .zero)
            clearLiveFilterPreviewAfterRefresh()
        }
    }

    func resetCurrentFilterTab() {
        guard filterDialControlsEnabled else { return }
        invalidateFilterControls()
        var next = adjustments
        for parameter in filterEditorTab.parameters {
            if parameter == .strength { if style != .original { intensity = parameter.defaultValue / 100 } }
            else { next[parameter] = parameter.defaultValue }
        }
        if next != adjustments { adjustments = next }
    }

    func presentFilterNumericInput(_ parameter: FilterParameter) {
        guard filterDialControlsEnabled, parameter != .strength || style != .original else { return }
        setFilterParameterEditing(false)
        filterNumericDraft = String(value(for: parameter))
        filterNumericParameter = parameter
    }

    var filterNumericValue: Double? { filterNumericParameter?.inputValue(from: filterNumericDraft) }

    func restoreFilterNumericDraft() {
        if let filterNumericParameter { filterNumericDraft = String(filterNumericParameter.defaultValue) }
    }

    func confirmFilterNumericInput() {
        guard filterDialControlsEnabled, let filterNumericParameter, let filterNumericValue else { return }
        setValue(filterNumericValue, for: filterNumericParameter)
        dismissFilterNumericInput()
    }

    func dismissFilterNumericInput() {
        filterNumericParameter = nil
        filterNumericDraft = ""
    }

    private func invalidateFilterControls() {
        filterControlRevision &+= 1
        dismissFilterNumericInput()
        setFilterParameterEditing(false)
    }

    func resetCurrentLook() {
        guard !saving else { return }
        invalidateFilterControls()
        if isLogVideo { selectedLogLUTID = LogLUTPreset.originalID }
        else {
            style = .original
            intensity = 0.8
            adjustments = FilterAdjustments()
        }
    }

    func save(completion: @escaping () -> Void) {
        guard !saving, duration > 0, library.beginEditing() else { return }
        let library = library
        saving = true
        Task { [self] in
            var outputURL: URL?
            do {
                let colorSpace = hasKnownColorSpace ? effectiveColorSpace : nil
                let lutID = selectedLogLUTID
                let cube: LogLUTCube?
                if isLogVideo, lutID != LogLUTPreset.originalID {
                    guard let preset = allLogLUTOptions.first(where: { $0.id == lutID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }

                let selection = VideoTrimSelection(start: trimStart, end: trimEnd, totalDuration: duration)
                let url = try await VideoEditExportService.export(
                    asset: asset,
                    selection: selection,
                    isLogVideo: isLogVideo,
                    look: selectedLook,
                    logLUTCube: cube,
                    frameRate: videoFrameRate
                )
                outputURL = url
                let badges = editedBadges(colorSpace: colorSpace)
                library.saveVideo(at: url, badges: badges, opensReview: false) { [weak self] result in
                    library.endEditing()
                    guard let self else { return }
                    self.saving = false
                    switch result {
                    case .success: completion()
                    case .failure(let error): self.message = error.localizedDescription
                    }
                }
            } catch {
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                library.endEditing()
                saving = false
                message = error.localizedDescription
            }
        }
    }

    func exportToFiles(completion: @escaping (URL?) -> Void) {
        guard !saving, duration > 0 else {
            completion(nil)
            return
        }
        guard library.beginEditing() else {
            message = "另一个编辑或保存操作正在进行，请稍后重试。"
            completion(nil)
            return
        }
        saving = true
        player.pause()
        Task { [self] in
            var outputURL: URL?
            do {
                let cube: LogLUTCube?
                if isLogVideo, burnLogLUT, selectedLogLUTID != LogLUTPreset.originalID {
                    guard let preset = allLogLUTOptions.first(where: { $0.id == selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }

                let selection = VideoTrimSelection(start: trimStart, end: trimEnd, totalDuration: duration)
                let url = try await VideoEditExportService.export(
                    asset: asset,
                    selection: selection,
                    isLogVideo: isLogVideo,
                    look: selectedLook,
                    logLUTCube: cube,
                    frameRate: videoFrameRate
                )
                outputURL = url
                let ext = url.pathExtension
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: ".", with: "-")
                let suffix = UUID().uuidString.prefix(8)
                let namedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumaCamera-Edited-\(timestamp)-\(suffix)")
                    .appendingPathExtension(ext)
                try FileManager.default.moveItem(at: url, to: namedURL)
                outputURL = namedURL
                library.endEditing()
                saving = false
                completion(namedURL)
            } catch {
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                library.endEditing()
                saving = false
                message = error.localizedDescription
                completion(nil)
            }
        }
    }

    func saveAsLivePhoto(completion: @escaping () -> Void) {
        guard !saving, duration > 0, library.beginEditing() else { return }
        let library = library
        saving = true
        player.pause()
        Task { [self] in
            var exportedURL: URL?
            var pairedURL: URL?
            do {
                let range = livePhotoSelection()
                let cube: LogLUTCube?
                if isLogVideo, burnLogLUT, selectedLogLUTID != LogLUTPreset.originalID {
                    guard let preset = allLogLUTOptions.first(where: { $0.id == selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }
                let url = try await VideoEditExportService.export(asset: asset, selection: range, isLogVideo: isLogVideo, look: selectedLook, logLUTCube: cube, frameRate: videoFrameRate)
                exportedURL = url
                let coverTime = min(max(playheadTime - range.start, 0), range.duration)
                let paired = try await VideoToLivePhotoService.makePair(from: url, coverTime: coverTime)
                pairedURL = paired.movieURL
                library.saveLivePhoto(
                    stillImage: paired.stillImage,
                    movieURL: paired.movieURL,
                    location: photo.location,
                    creationDate: photo.date
                ) { [weak self] result in
                    if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
                    if let pairedURL { try? FileManager.default.removeItem(at: pairedURL) }
                    library.endEditing()
                    guard let self else { return }
                    self.saving = false
                    switch result {
                    case .success: completion()
                    case .failure(let error): self.message = error.localizedDescription
                    }
                }
            } catch {
                if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
                if let pairedURL { try? FileManager.default.removeItem(at: pairedURL) }
                library.endEditing()
                saving = false
                message = error.localizedDescription
            }
        }
    }

    func cancel() {
        invalidateFilterControls()
        previewTask?.cancel()
        previewTask = nil
        livePreviewSourceTask?.cancel(); livePreviewSourceTask = nil
        livePreviewRenderTask?.cancel(); livePreviewRenderTask = nil
        livePreviewClearTask?.cancel(); livePreviewClearTask = nil
        stopLivePreviewGrainAnimation()
        clearLiveFilterPreviewImmediately()
        filmstripTask?.cancel()
        filmstripTask = nil
        trimPreviewSeekTask?.cancel()
        trimPreviewSeekTask = nil
        pendingTrimPreviewTime = nil
        isSeekingTrimPreview = false
        if let playbackObserver { player.removeTimeObserver(playbackObserver); self.playbackObserver = nil }
        player.pause()
    }

    private func livePhotoSelection() -> VideoTrimSelection {
        VideoTrimSelection.livePhoto(start: trimStart, end: trimEnd, totalDuration: duration, playhead: playheadTime)
    }

    private var effectiveColorSpace: VideoColorSpace { colorSpace }

    private func editedBadges(colorSpace: VideoColorSpace?) -> VideoCaptureBadges {
        if isLogVideo {
            let burnedLUT = burnLogLUT && selectedLogLUTID != LogLUTPreset.originalID
            return VideoCaptureBadges(
                logLabel: photo.logLabel ?? (effectiveColorSpace == .appleLog2 ? "LOG2" : "LOG"),
                hasFilter: photo.hasFilter || burnedLUT,
                colorSpace: colorSpace,
                logLUTID: burnedLUT ? selectedLogLUTID : nil
            )
        }
        let chosenStyle = style == .original ? nil : style.rawValue
        let selectedFilter = style != .original && intensity > 0 || !adjustments.isNeutral
        return VideoCaptureBadges(
            logLabel: nil,
            hasFilter: photo.hasFilter || selectedFilter,
            colorSpace: colorSpace,
            filmStyleID: chosenStyle,
            filterIntensity: chosenStyle == nil ? nil : intensity,
            filterAdjustments: adjustments.isNeutral ? nil : adjustments
        )
    }

    private func loadDuration() async {
        defer { loading = false }
        do {
            let value = try await asset.load(.duration).seconds
            guard value.isFinite, value > 0 else { throw VideoEditError.invalidDuration }
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
                if let rate = try? await track.load(.nominalFrameRate), rate.isFinite, rate > 0 {
                    videoFrameRate = Double(rate)
                }
                if !hasKnownColorSpace,
                   let descriptions = try? await track.load(.formatDescriptions),
                   let detected = descriptions.compactMap(VideoColorSpaceDetector.detect).first {
                    colorSpace = detected
                    hasKnownColorSpace = true
                    isLogVideo = detected.isLog
                    availableTools = VideoEditorTool.available(colorSpace: detected)
                }
            }
            duration = value
            livePreviewSource = nil
            livePreviewSourceTime = .nan
            trimEnd = value
            trimStart = 0
            playheadTime = 0
            syncPreviewTrimRange()
            schedulePreview()
            filmstripTask?.cancel()
            filmstripTask = Task { [weak self] in await self?.loadFilmstripThumbnails() }
        } catch { message = error.localizedDescription }
    }

    private func loadFilmstripThumbnails() async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 150, height: 100)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let count = min(12, max(6, Int(ceil(duration / 2))))
        var images: [UIImage] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            guard !Task.isCancelled else { return }
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                images.append(UIImage(cgImage: image))
            } catch {
                continue
            }
            filmstripThumbnails = images
        }
    }

    private func rememberAndPreview(_ previous: FilmStyle) {
        invalidateFilterControls()
        recipes[previous.rawValue] = SavedFilterSettings(intensity: intensity, adjustments: adjustments)
        let restored = recipes[style.rawValue] ?? SavedFilterSettings()
        intensity = restored.intensity
        adjustments = restored.adjustments
        schedulePreview()
    }

    /// 参数变化只更新一份共享状态并刷新当前暂停帧；CI 视频合成只创建一次。
    /// 这样拖调色盘/滑条时不需要为每个值重建 videoComposition。
    private func schedulePreview(delay: Duration = .milliseconds(8)) {
        previewRevision &+= 1
        let revision = previewRevision
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            do {
                let cube: LogLUTCube?
                if self.isLogVideo, self.selectedLogLUTID != LogLUTPreset.originalID {
                    guard let preset = self.allLogLUTOptions.first(where: { $0.id == self.selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else {
                    cube = nil
                }
                guard !Task.isCancelled, revision == self.previewRevision else { return }
                self.previewState.update(look: self.selectedLook, cube: cube)
                await self.ensurePreviewComposition()
                guard !Task.isCancelled, revision == self.previewRevision else { return }
                self.refreshPausedPreview()
            } catch {
                guard !Task.isCancelled, revision == self.previewRevision else { return }
                self.message = error.localizedDescription
            }
        }
    }

    /// 相机视频的颗粒每帧换相位；暂停编辑时也按 30fps 推进，避免颗粒像一张固定蒙版。
    private func startLivePreviewGrainAnimation() {
        guard livePreviewAnimationTask == nil else { return }
        livePreviewAnimationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.editingFilter else { break }
                self.livePreviewGrainFrame &+= 1
                self.renderLiveFilterPreview()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopLivePreviewGrainAnimation() {
        livePreviewAnimationTask?.cancel()
        livePreviewAnimationTask = nil
    }

    private func prepareLiveFilterPreviewSource() {
        guard !isLogVideo, !loading else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        if livePreviewSource != nil, abs(time - livePreviewSourceTime) < 0.2 { return }
        livePreviewSourceTask?.cancel()
        livePreviewSource = nil
        livePreviewSourceTime = time
        let sourceAsset = asset
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        let generation = Task.detached(priority: .userInitiated) { () -> CIImage? in
            let generator = AVAssetImageGenerator(asset: sourceAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 900)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: target) else { return nil }
            return CIImage(cgImage: image)
        }
        livePreviewSourceTask = Task { [weak self] in
            let image = await generation.value
            guard let self, !Task.isCancelled else { return }
            guard abs(self.player.currentTime().seconds - time) < 0.25 else { return }
            self.livePreviewSource = image
            if self.editingFilter { self.renderLiveFilterPreview() }
        }
    }

    private func renderLiveFilterPreview() {
        guard !isLogVideo, editingFilter,
              player.timeControlStatus != .playing,
              let source = livePreviewSource else { return }
        livePreviewRevision &+= 1
        let revision = livePreviewRevision
        var look = selectedLook
        look.grainPhase = VideoGrainPhase.phase(frame: livePreviewGrainFrame)
        let renderContext = context
        livePreviewRenderTask?.cancel()
        livePreviewRenderTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let output = Imaging.filtered(source, look: look)
                guard let cg = renderContext.createCGImage(output, from: output.extent,
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard let self, !Task.isCancelled, revision == self.livePreviewRevision,
                  self.editingFilter else { return }
            self.liveFilterPreview = image
        }
    }

    private func clearLiveFilterPreviewAfterRefresh() {
        livePreviewClearTask?.cancel()
        livePreviewClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !self.editingFilter else { return }
            self.liveFilterPreview = nil
            self.livePreviewSource = nil
        }
    }

    private func clearLiveFilterPreviewImmediately() {
        stopLivePreviewGrainAnimation()
        livePreviewRevision &+= 1
        livePreviewRenderTask?.cancel(); livePreviewRenderTask = nil
        livePreviewClearTask?.cancel(); livePreviewClearTask = nil
        liveFilterPreview = nil
    }

    private func ensurePreviewComposition() async {
        guard previewComposition == nil else { return }
        let snapshot = previewState.snapshot()
        guard snapshot.cube != nil || snapshot.look.requiresImageProcessing else { return }
        let state = previewState
        let sourceAsset = asset
        let renderContext = context
        let frameRate = videoFrameRate
        let composition: AVMutableVideoComposition
        do {
            composition = try await VideoFilterComposition.make(asset: sourceAsset) { request in
                let current = state.snapshot()
                if let cube = current.cube {
                    autoreleasepool { request.finish(with: cube.apply(to: request.sourceImage), context: renderContext) }
                } else if current.look.requiresImageProcessing {
                    autoreleasepool {
                        var look = current.look
                        look.grainPhase = VideoGrainPhase.phase(
                            seconds: request.compositionTime.seconds, frameRate: frameRate)
                        request.finish(with: Imaging.filtered(request.sourceImage, look: look), context: renderContext)
                    }
                } else {
                    request.finish(with: request.sourceImage, context: renderContext)
                }
            }
        } catch {
            message = error.localizedDescription
            return
        }
        previewComposition = composition
        playerItem.videoComposition = composition
        #if DEBUG
        previewCompositionBuildCount += 1
        #endif
        refreshPausedPreview()
    }

    /// paused 时 videoComposition 状态变化不会自动出帧，用零容差 seek 强制刷新当前帧。
    private func refreshPausedPreview() {
        guard player.timeControlStatus != .playing else { return }
        let current = player.currentTime()
        guard current.isValid, current.isNumeric else { return }
        if let previewComposition { playerItem.videoComposition = previewComposition }
        player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func syncPreviewTrimRange(keepCurrentPreview: Bool = false) {
        guard duration > 0, trimEnd > trimStart else { return }
        playerItem.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        guard !keepCurrentPreview else { return }
        let current = player.currentTime().seconds
        if current.isFinite, (current < trimStart || current >= trimEnd) {
            player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func boundedStart(_ value: Double) -> Double {
        guard duration > 0, value.isFinite else { return 0 }
        return min(max(value, 0), max(0, trimEnd - minimumTrimDuration))
    }

    private func boundedEnd(_ value: Double) -> Double {
        guard duration > 0, value.isFinite else { return duration }
        return min(max(value, min(duration, trimStart + minimumTrimDuration)), duration)
    }
}

/// 播放器和滤镜参数共用的一份可变预览状态；安装一次 CI 视频合成后，
/// 参数变化只更新状态并刷新当前帧，不再反复重建 videoComposition。
private final class VideoEditorPreviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var look = CaptureLook()
    private var cube: LogLUTCube?

    func update(look: CaptureLook, cube: LogLUTCube?) {
        lock.lock(); defer { lock.unlock() }
        self.look = look
        self.cube = cube
    }

    func snapshot() -> (look: CaptureLook, cube: LogLUTCube?) {
        lock.lock(); defer { lock.unlock() }
        return (look, cube)
    }
}

/// 与相机视频录制相同的逐帧颗粒相位，避免编辑预览使用连续秒数导致颗粒流动速度不同。
enum VideoGrainPhase {
    static func phase(seconds: Double, frameRate: Double) -> Double {
        guard seconds.isFinite, frameRate.isFinite, frameRate > 0 else { return 0 }
        return phase(frame: Int64(max(0, seconds * frameRate)))
    }

    static func phase(frame: Int64) -> Double {
        Double(((max(0, frame) &* 73) % 4093))
    }
}

enum VideoColorSpaceDetector {
    static func detect(_ description: CMFormatDescription) -> VideoColorSpace? {
        guard let values = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] else { return nil }
        return detect(
            transferFunction: values[kCMFormatDescriptionExtension_TransferFunction] as? String,
            logTransferFunction: values[kCMFormatDescriptionExtension_LogTransferFunction] as? String,
            colorPrimaries: values[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        )
    }

    static func detect(transferFunction: String?, logTransferFunction: String?, colorPrimaries: String?) -> VideoColorSpace? {
        if logTransferFunction == "com.apple.apple-wide-gamut.apple-log" { return .appleLog2 }
        if logTransferFunction == (kCMFormatDescriptionLogTransferFunction_AppleLog as String) { return .appleLog }
        if transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return .hdr }
        if colorPrimaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) { return .p3 }
        if transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
            || transferFunction == (kCMFormatDescriptionTransferFunction_sRGB as String) { return .sdr }
        return nil
    }
}

enum VideoEditorTool: String, CaseIterable, Identifiable, Equatable {
    case trim, filters, adjustments
    static func available(colorSpace: VideoColorSpace) -> [VideoEditorTool] {
        if colorSpace.isLog { return [.trim, .filters] }
        if colorSpace == .sdr || colorSpace == .p3 { return [.trim, .filters, .adjustments] }
        return [.trim]
    }
    var id: String { rawValue }
    var title: String {
        switch self { case .trim: "裁切"; case .filters: "滤镜"; case .adjustments: "调整" }
    }
    var icon: String {
        switch self { case .trim: "scissors"; case .filters: "camera.filters"; case .adjustments: "slider.horizontal.3" }
    }
}

struct VideoTrimSelection: Equatable {
    private(set) var start: Double
    private(set) var end: Double
    let totalDuration: Double
    private let minimumDuration: Double

    init(start: Double, end: Double, totalDuration: Double) {
        let duration = totalDuration.isFinite ? max(0, totalDuration) : 0
        self.totalDuration = duration
        minimumDuration = min(0.1, duration)
        let safeStart = start.isFinite ? min(max(0, start), duration) : 0
        let safeEnd = end.isFinite ? min(max(0, end), duration) : duration
        self.start = min(safeStart, max(0, safeEnd - minimumDuration))
        self.end = min(duration, max(safeEnd, self.start + minimumDuration))
    }

    var duration: Double { max(0, end - start) }
    var timeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    static func livePhoto(start: Double, end: Double, totalDuration: Double, playhead: Double,
                          maximumDuration: Double = 3) -> VideoTrimSelection {
        let selected = VideoTrimSelection(start: start, end: end, totalDuration: totalDuration)
        let safeMaximum = maximumDuration.isFinite ? max(0, maximumDuration) : 3
        guard selected.duration > safeMaximum, safeMaximum > 0 else { return selected }
        let safePlayhead = playhead.isFinite ? playhead : selected.start + selected.duration / 2
        let boundedStart = min(max(safePlayhead - safeMaximum / 2, selected.start), selected.end - safeMaximum)
        return VideoTrimSelection(start: boundedStart, end: boundedStart + safeMaximum, totalDuration: selected.totalDuration)
    }
}

enum VideoEditError: LocalizedError {
    case invalidDuration, filterUnavailable, exportUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidDuration: "无法读取有效的视频时长。"
        case .filterUnavailable: "无法读取所选滤镜，请重新选择后再试。"
        case .exportUnavailable: "无法导出编辑后的视频，请检查视频是否可用并重试。"
        }
    }
}

enum VideoEditExportService {
    static func export(asset: AVAsset, selection: VideoTrimSelection, isLogVideo: Bool,
                       look: CaptureLook, logLUTCube: LogLUTCube?, frameRate: Double = 30) async throws -> URL {
        guard selection.duration > 0 else { throw VideoEditError.invalidDuration }
        var url: URL?
        do {
            let appliesLook = !isLogVideo && look.requiresImageProcessing
            let appliesLUT = isLogVideo && logLUTCube != nil
            let preset = appliesLook || appliesLUT ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else { throw VideoEditError.exportUnavailable }
            let fileTypes = await exporter.compatibleFileTypes
            let outputType: AVFileType
            let fileExtension: String
            if fileTypes.contains(.mov) { outputType = .mov; fileExtension = "mov" }
            else if fileTypes.contains(.mp4) { outputType = .mp4; fileExtension = "mp4" }
            else { throw VideoEditError.exportUnavailable }
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-VideoEdit-" + UUID().uuidString).appendingPathExtension(fileExtension)
            url = outputURL
            if let logLUTCube {
                let context = CIContext(options: [.cacheIntermediates: false])
                exporter.videoComposition = try await VideoFilterComposition.make(asset: asset) { request in
                    autoreleasepool { request.finish(with: logLUTCube.apply(to: request.sourceImage), context: context) }
                }
            } else if !isLogVideo && look.requiresImageProcessing {
                let context = CIContext(options: [.cacheIntermediates: false])
                exporter.videoComposition = try await VideoFilterComposition.make(asset: asset) { request in
                    autoreleasepool {
                        var frameLook = look
                        frameLook.grainPhase = VideoGrainPhase.phase(
                            seconds: request.compositionTime.seconds, frameRate: frameRate)
                        request.finish(with: Imaging.filtered(request.sourceImage, look: frameLook), context: context)
                    }
                }
            }
            exporter.timeRange = selection.timeRange
            exporter.metadata = try await asset.load(.metadata)
            try await exporter.export(to: outputURL, as: outputType)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let outputSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard FileManager.default.fileExists(atPath: outputURL.path), outputSize > 0 else { throw VideoEditError.exportUnavailable }
            return outputURL
        } catch {
            if let url { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
