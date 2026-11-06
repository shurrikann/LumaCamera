import AVFoundation
import Combine
import CoreImage
import CoreMedia
import SwiftUI
import UIKit

@MainActor
final class VideoEditorViewModel: ObservableObject {
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
    @Published var intensity: Double { didSet { schedulePreview() } }
    @Published var adjustments: FilterAdjustments { didSet { schedulePreview() } }
    @Published var selectedLogLUTID: String { didSet { if selectedLogLUTID != oldValue { schedulePreview() } } }
    @Published var filterTab: FilterEditorTab = .color
    @Published var selectedParameter: FilterParameter = .strength

    private(set) var trimPreviewSeekRequestCount = 0
    private(set) var isSeekingTrimPreview = false

    private let library: PhotoLibraryViewModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var recipes: [String: SavedFilterSettings] = [:]
    private var previewTask: Task<Void, Never>?
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

    var logLUTOptions: [LogLUTPreset] { [.original] + LogLUTCubeRepository.presets() }
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
        isToolPanelPresented = tool != selected || !isToolPanelPresented
        tool = selected
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
        guard !saving else { return }
        if parameter == .strength {
            guard style != .original else { return }
            let normalized = parameter.clamped(value) / 100
            guard normalized != intensity else { return }
            intensity = normalized
        } else {
            adjustments[parameter] = value
        }
    }

    func resetCurrentLook() {
        guard !saving else { return }
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
                    guard let preset = logLUTOptions.first(where: { $0.id == lutID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }

                let selection = VideoTrimSelection(start: trimStart, end: trimEnd, totalDuration: duration)
                let url = try await VideoEditExportService.export(
                    asset: asset,
                    selection: selection,
                    isLogVideo: isLogVideo,
                    look: selectedLook,
                    logLUTCube: cube
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
                if isLogVideo, selectedLogLUTID != LogLUTPreset.originalID {
                    guard let preset = logLUTOptions.first(where: { $0.id == selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }

                let selection = VideoTrimSelection(start: trimStart, end: trimEnd, totalDuration: duration)
                let url = try await VideoEditExportService.export(
                    asset: asset,
                    selection: selection,
                    isLogVideo: isLogVideo,
                    look: selectedLook,
                    logLUTCube: cube
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
                if isLogVideo, selectedLogLUTID != LogLUTPreset.originalID {
                    guard let preset = logLUTOptions.first(where: { $0.id == selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }
                let url = try await VideoEditExportService.export(asset: asset, selection: range, isLogVideo: isLogVideo, look: selectedLook, logLUTCube: cube)
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
        previewTask?.cancel()
        previewTask = nil
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
            let selectedFilter = selectedLogLUTID != LogLUTPreset.originalID
            return VideoCaptureBadges(
                logLabel: photo.logLabel ?? (effectiveColorSpace == .appleLog2 ? "LOG2" : "LOG"),
                hasFilter: photo.hasFilter || selectedFilter,
                colorSpace: colorSpace,
                logLUTID: selectedFilter ? selectedLogLUTID : nil
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
            if !hasKnownColorSpace,
               let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let descriptions = try? await track.load(.formatDescriptions),
               let detected = descriptions.compactMap(VideoColorSpaceDetector.detect).first {
                colorSpace = detected
                hasKnownColorSpace = true
                isLogVideo = detected.isLog
                availableTools = VideoEditorTool.available(colorSpace: detected)
            }
            duration = value
            trimEnd = value
            trimStart = 0
            playheadTime = 0
            syncPreviewTrimRange()
            selectedParameter = .strength
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
        recipes[previous.rawValue] = SavedFilterSettings(intensity: intensity, adjustments: adjustments)
        let restored = recipes[style.rawValue] ?? SavedFilterSettings()
        intensity = restored.intensity
        adjustments = restored.adjustments
        schedulePreview()
    }

    private func schedulePreview() {
        guard !isLogVideo || selectedLogLUTID != LogLUTPreset.originalID else {
            previewTask?.cancel()
            playerItem.videoComposition = nil
            return
        }
        previewRevision &+= 1
        let revision = previewRevision
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled, let self else { return }
            do {
                let cube: LogLUTCube?
                if self.isLogVideo {
                    guard let preset = self.logLUTOptions.first(where: { $0.id == self.selectedLogLUTID }) else { throw VideoEditError.filterUnavailable }
                    cube = try await Task.detached(priority: .userInitiated) { try LogLUTCubeRepository.load(preset) }.value
                } else { cube = nil }
                let look = self.selectedLook
                let composition: AVMutableVideoComposition?
                let sourceAsset = self.asset
                let renderContext = self.context
                if let cube {
                    composition = try await VideoFilterComposition.make(asset: sourceAsset) { request in
                        autoreleasepool { request.finish(with: cube.apply(to: request.sourceImage), context: renderContext) }
                    }
                } else if look.requiresImageProcessing {
                    composition = try await VideoFilterComposition.make(asset: sourceAsset) { request in
                        autoreleasepool {
                            var frameLook = look
                            frameLook.grainPhase += request.compositionTime.seconds * 127.7
                            request.finish(with: Imaging.filtered(request.sourceImage, look: frameLook), context: renderContext)
                        }
                    }
                } else { composition = nil }
                guard !Task.isCancelled, revision == self.previewRevision else { return }
                self.playerItem.videoComposition = composition
            } catch {
                guard !Task.isCancelled, revision == self.previewRevision else { return }
                self.message = error.localizedDescription
            }
        }
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
                       look: CaptureLook, logLUTCube: LogLUTCube?) async throws -> URL {
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
                        frameLook.grainPhase += request.compositionTime.seconds * 127.7
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
