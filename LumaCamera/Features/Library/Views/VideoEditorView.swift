import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct VideoEditorView: View {
    @StateObject private var model: VideoEditorViewModel
    @StateObject private var filters = FilterPickerViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var saveChoicePresented = false
    @State private var filesExport: VideoFileExport?
    @State private var dismissAfterFilesExport = false

    private let onClose: (() -> Void)?

    init(asset: AVAsset, photo: LibraryPhoto, library: PhotoLibraryViewModel, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        _model = StateObject(wrappedValue: VideoEditorViewModel(asset: asset, photo: photo, library: library))
    }

    init(model: VideoEditorViewModel, initialSaveChoicePresented: Bool = false) {
        onClose = nil
        _model = StateObject(wrappedValue: model)
        _saveChoicePresented = State(initialValue: initialSaveChoicePresented)
    }

    private var bottomPopupCornerRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }
    private var sdrFilterPopupVisible: Bool {
        model.tool == .filters && model.isToolPanelPresented && !model.isLogVideo
    }
    private var logFilterPopupVisible: Bool {
        model.tool == .filters && model.isToolPanelPresented && model.isLogVideo
    }

    var body: some View {
        preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
                .recordEditorFrame("preview", model: model)
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) {
            toolBar
                .frame(width: 216, height: 60)
                .background {
                    Color.clear.frame(height: 50)
                        .modifier(PreviewSurface(radius: 25, opacity: AppTheme.popupOpacity, interactive: false))
                }
                .recordEditorFrame("toolbar", model: model)
                .padding(.bottom, 12)
                .opacity(logFilterPopupVisible || sdrFilterPopupVisible || saveChoicePresented ? 0 : 1)
                .allowsHitTesting(!(logFilterPopupVisible || sdrFilterPopupVisible || saveChoicePresented))
                .accessibilityHidden(logFilterPopupVisible || sdrFilterPopupVisible || saveChoicePresented)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(model.saving)
        .allowsHitTesting(!model.saving)
        .overlayPreferenceValue(VideoPopupAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if model.isToolPanelPresented, !sdrFilterPopupVisible, !logFilterPopupVisible,
                          let anchor = anchors[.tool(model.tool)] {
                    let height = VideoEditorPanelMetrics.height(for: model.tool)
                    VideoAnchoredPopup(
                        anchor: geometry[anchor], container: geometry.size,
                        width: 420, height: height
                    ) {
                        editorPanel.frame(height: height).recordEditorFrame("panel", model: model)
                    }
                    .id(model.tool)
                    .transition(.opacity)
                }
            }
            .animation(popupAnimation, value: saveChoicePresented)
        }
        .overlay(alignment: .bottom) {
            if sdrFilterPopupVisible {
                VideoFilterPopup(model: model, filters: filters) {
                    filters.showStrength = false
                    model.closeToolPanel()
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
            }
        }
        .animation(popupAnimation, value: sdrFilterPopupVisible)
        .overlay(alignment: .bottom) {
            if logFilterPopupVisible {
                VideoLogFilterPopup(model: model) {
                    model.closeToolPanel()
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
            }
        }
        .animation(popupAnimation, value: logFilterPopupVisible)
        .overlay(alignment: .bottom) {
            if saveChoicePresented {
                saveChoiceCard
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                    .accessibilityIdentifier("video.save.popup")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        model.captureButtonFramesForTesting["video.save.popup"] = $0
                    }
                    #endif
            }
        }
        .animation(popupAnimation, value: saveChoicePresented)
        .overlay {
            if model.filterNumericParameter != nil {
                FilterNumericInputDialog(model: model).transition(.opacity)
            }
        }
        .environment(\.captureControlAngle, 0)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear { filters.prepareThumbnails() }
        .onChange(of: sdrFilterPopupVisible) { _, visible in
            if !visible { filters.showStrength = false }
        }
        .onDisappear { model.cancel() }
        .alert("视频编辑", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.dismissMessage() } })) {
            Button("好", role: .cancel) { model.dismissMessage() }
        } message: { Text(model.message ?? "") }
        .sheet(item: $filesExport, onDismiss: {
            if dismissAfterFilesExport {
                dismissAfterFilesExport = false
                closeEditor()
            }
        }) { session in
            VideoFileExportPicker(url: session.url) { didExport in
                try? FileManager.default.removeItem(at: session.url)
                dismissAfterFilesExport = didExport
                filesExport = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); closeEditor() } label: {
                Image(systemName: "arrow.left").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true))
            }.accessibilityLabel("取消视频编辑")
            Spacer()
            Text("编辑视频").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer()
            Menu {
                Button("重置滤镜", systemImage: "arrow.counterclockwise") { model.resetCurrentLook() }
                Button("重置裁切", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    model.resetTrim()
                }
                .disabled(model.duration <= 0 || (model.trimStart == 0 && model.trimEnd == model.duration && !model.isSelectingLivePhoto))
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true))
            }.accessibilityLabel("视频编辑选项")
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 5)
        .buttonStyle(.plain)
    }

    private var preview: some View {
        ZStack {
            VideoEditorPlayerLayer(player: model.player)
            if let live = model.liveFilterPreview {
                Image(uiImage: live).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if model.loading { ProgressView().tint(AppTheme.accent) }
            else if model.liveFilterPreview == nil, model.player.timeControlStatus != .playing {
                Image(systemName: "play.fill").font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white).padding(15).background(.black.opacity(0.52), in: Circle())
                    .allowsHitTesting(false)
            }
            if model.saving {
                ProgressView().controlSize(.large).tint(AppTheme.accent)
                    .padding(18).background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handlePreviewTap() }
        .accessibilityLabel("视频编辑预览，点按播放或暂停")
    }

    private var hasActivePopup: Bool {
        saveChoicePresented || model.isToolPanelPresented || model.filterNumericParameter != nil
    }

    private func handlePreviewTap() {
        guard hasActivePopup else {
            model.togglePlayback()
            return
        }
        if model.filterNumericParameter != nil {
            model.dismissFilterNumericInput()
        }
        if saveChoicePresented {
            saveChoicePresented = false
        }
        if model.isToolPanelPresented {
            filters.showStrength = false
            model.closeToolPanel()
        }
    }

    @ViewBuilder private var editorPanel: some View {
        switch model.tool {
        case .trim: trimPanel
        case .filters:
            if model.isLogVideo { logFilterPanel } else { standardFilterPanel }
        case .adjustments: adjustmentPanel
        }
    }

    private var trimPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                        model.toggleLivePhotoSelection()
                    }
                } label: {
                    Label(model.livePhotoDurationLabel, systemImage: "livephoto")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.isSelectingLivePhoto ? AppTheme.accent : .white)
                        .padding(.horizontal, 12)
                        .frame(height: VideoEditorPanelMetrics.liveButtonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.loading || model.duration <= 0)
                .accessibilityLabel("选择 Live 片段")
                .accessibilityValue(model.livePhotoDurationLabel)
                .accessibilityAddTraits(model.isSelectingLivePhoto ? .isSelected : [])
                Spacer()
            }
            .frame(height: VideoEditorPanelMetrics.liveButtonHeight)
            .padding(.top, VideoEditorPanelMetrics.liveSpacing)
            Color.clear.frame(height: VideoEditorPanelMetrics.liveSpacing)
            if model.loading || model.duration <= 0 {
                ProgressView().tint(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .padding(.bottom, 5)
            } else {
                HStack(spacing: 10) {
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 34, height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(model.player.timeControlStatus == .playing ? "暂停预览" : "播放预览")
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 32)
                    VideoFilmstripTimeline(
                        thumbnails: model.filmstripThumbnails,
                        duration: model.duration,
                        start: model.trimStart,
                        end: model.trimEnd,
                        movesSelection: model.isSelectingLivePhoto,
                        onSelectionMoved: model.moveLivePhotoSelection,
                        onStartChanged: model.setTrimStart,
                        onEndChanged: model.setTrimEnd,
                        onTrimDragEnded: model.finishTrimDrag,
                        onScrub: model.seekPreview(to:)
                    )
                    .frame(height: 48)
                }
                .padding(.bottom, 5)
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PopupSurface(radius: 22, glass: true))
    }

    private var standardFilterPanel: some View {
        VStack(spacing: 9) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(filters.styles) { style in
                            Button {
                                withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) { model.style = style }
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        Circle().fill(.white.opacity(0.05))
                                        if let image = filters.thumbnails[style] { Image(uiImage: image).resizable().scaledToFill() }
                                        else { ProgressView().controlSize(.mini).tint(.white.opacity(0.75)) }
                                    }
                                    .frame(width: 52, height: 52).clipShape(Circle())
                                    .overlay(Circle().stroke(model.style == style ? AppTheme.accent : .white.opacity(0.15), lineWidth: model.style == style ? 2 : 0.5))
                                    Text(style.title).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).frame(width: 62, height: 26)
                                }
                                .foregroundStyle(model.style == style ? AppTheme.accent : .white.opacity(0.85))
                            }
                            .id(style).buttonStyle(.plain)
                            .accessibilityLabel("视频滤镜" + style.title)
                            .accessibilityAddTraits(model.style == style ? .isSelected : [])
                        }
                    }.padding(.horizontal, 8)
                }
                .onAppear { proxy.scrollTo(model.style, anchor: .center) }
                .onChange(of: model.style) { _, style in withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(style, anchor: .center) } }
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PopupSurface(radius: 22, glass: true))
    }

    private var logFilterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log 拍摄格式滤镜").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.photo.logLabel ?? "LOG").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(AppTheme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.logLUTOptions) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) { model.selectedLogLUTID = preset.id }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.id == LogLUTPreset.originalID ? "circle.lefthalf.filled" : "camera.filters")
                                    .font(.system(size: 19)).foregroundStyle(model.selectedLogLUTID == preset.id ? .black : .white.opacity(0.85))
                                    .frame(width: 48, height: 48)
                                    .background(model.selectedLogLUTID == preset.id ? AppTheme.accent : .white.opacity(0.07), in: Circle())
                                Text(preset.title).font(.system(size: 9, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).frame(width: 58, height: 24)
                            }.foregroundStyle(model.selectedLogLUTID == preset.id ? AppTheme.accent : .white.opacity(0.82))
                        }
                        .buttonStyle(.plain).accessibilityLabel(preset.title + " Log LUT")
                        .accessibilityAddTraits(model.selectedLogLUTID == preset.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 8)
            }
            Text(model.logLUTOptions.first(where: { $0.id == model.selectedLogLUTID })?.displayName ?? "原片")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PopupSurface(radius: 22, glass: true))
    }

    private var popupAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.1 : 0.18)
    }

    private func closeEditor() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var adjustmentPanel: some View {
        VStack(spacing: 8) {
            FilterAdjustmentTabs(model: model, onClose: {
                withAnimation(popupAnimation) { model.closeToolPanel() }
            })
            FilterDialEditor(model: model, tab: model.filterEditorTab)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PopupSurface(radius: 22, glass: true))
        .accessibilityIdentifier("video.editor.sharedFilterControls")
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(model.availableTools.filter { $0 != .adjustments }) { tool in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if tool == .filters, !sdrFilterPopupVisible { filters.showStrength = false }
                    withAnimation(popupAnimation) { model.selectTool(tool) }
                } label: {
                    Image(systemName: tool.icon).font(.system(size: 20))
                        .foregroundStyle(model.tool == tool && model.isToolPanelPresented ? AppTheme.accent : .white.opacity(0.82))
                        .frame(width: 44, height: 44)
                        .videoPopupAnchor(.tool(tool))
                        .recordEditorFrame("tool." + tool.title, model: model)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("视频编辑" + tool.title)
                .accessibilityAddTraits(model.tool == tool && model.isToolPanelPresented ? .isSelected : [])
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                saveChoicePresented = true
            } label: {
                ZStack {
                    if model.saving || model.isSavingLibrary { ProgressView().tint(.white) }
                    else { Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(.white.opacity(0.82)) }
                }
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.loading || model.saving || model.isSavingLibrary)
            .accessibilityLabel("保存编辑结果")
        }
    }

    private var saveChoiceCard: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Text("保存编辑结果").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button { saveChoicePresented = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消保存")
            }
            Text("Live Photo 最长 3 秒，以当前预览位置作为封面。原视频会保留。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("另存为视频") {
                    saveChoicePresented = false
                    model.save { closeEditor() }
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(.white.opacity(0.08), in: Capsule())
                Button("另存为 Live") {
                    saveChoicePresented = false
                    model.saveAsLivePhoto { closeEditor() }
                }
                .buttonStyle(.plain).foregroundStyle(AppTheme.accentForeground)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(AppTheme.accent, in: Capsule())
            }
            Button {
                saveChoicePresented = false
                model.exportToFiles { url in
                    guard let url else { return }
                    filesExport = VideoFileExport(url: url)
                }
            } label: {
                Label("存储到文件…", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: bottomPopupCornerRadius, style: .continuous))
        .background {
            PopupGlassBackground(
                shape: RoundedRectangle(cornerRadius: bottomPopupCornerRadius, style: .continuous),
                materialOpacity: AppTheme.cameraPopupMaterialOpacity
            )
        }
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00.0" }
        let minutes = Int(value) / 60, seconds = Int(value) % 60, tenths = Int(value * 10) % 10
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

enum VideoEditorPanelMetrics {
    static let liveSpacing: CGFloat = 7
    static let liveButtonHeight: CGFloat = 32
    static let trimHeight: CGFloat = liveSpacing + liveButtonHeight + liveSpacing + 48 + 5
    static let standardHeight: CGFloat = 186

    static func height(for tool: VideoEditorTool) -> CGFloat {
        switch tool {
        case .trim: trimHeight
        case .filters: standardHeight
        case .adjustments: 308
        }
    }
}

enum VideoPopupAnchor: Hashable {
    case info, save, tool(VideoEditorTool)
}

struct VideoPopupAnchorKey: PreferenceKey {
    static let defaultValue: [VideoPopupAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [VideoPopupAnchor: Anchor<CGRect>], nextValue: () -> [VideoPopupAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct VideoAnchoredPopup<Content: View>: View {
    let anchor: CGRect
    let container: CGSize
    let width: CGFloat
    let height: CGFloat
    var scrollsWhenCompact = true
    @ViewBuilder let content: () -> Content

    static func placement(anchor: CGRect, container: CGSize, width: CGFloat, height: CGFloat) -> CGRect {
        let margin: CGFloat = 8
        let width = min(width, max(0, container.width - 2 * margin))
        let bottom = min(container.height, max(0, anchor.minY - margin))
        let height = min(height, max(0, bottom - margin))
        let left = min(max(margin, anchor.midX - width / 2), max(margin, container.width - margin - width))
        return CGRect(x: left, y: bottom - height, width: width, height: height)
    }

    var body: some View {
        let frame = Self.placement(anchor: anchor, container: container, width: width, height: height)
        Group {
            if scrollsWhenCompact && frame.height < height {
                ScrollView { content() }.scrollIndicators(.hidden)
            } else {
                content()
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .bottom)
        .position(x: frame.midX, y: frame.midY)
    }
}

extension View {
    func videoPopupAnchor(_ anchor: VideoPopupAnchor) -> some View {
        anchorPreference(key: VideoPopupAnchorKey.self, value: .bounds) { [anchor: $0] }
    }

    @ViewBuilder fileprivate func recordEditorFrame(_ key: String, model: VideoEditorViewModel) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.captureButtonFramesForTesting[key] = $0
        }
        #else
        self
        #endif
    }
}

private struct VideoFileExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct VideoFileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Bool) -> Void
        private var finished = false
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
        private func finish(_ success: Bool) {
            guard !finished else { return }
            finished = true
            completion(success)
        }
    }
}

private struct VideoFilmstripTimeline: View {
    let thumbnails: [UIImage]
    let duration: Double
    let start: Double
    let end: Double
    let movesSelection: Bool
    let onSelectionMoved: (Double) -> Void
    let onStartChanged: (Double) -> Void
    let onEndChanged: (Double) -> Void
    let onTrimDragEnded: () -> Void
    let onScrub: (Double) -> Void

    @State private var startDragOrigin: Double?
    @State private var endDragOrigin: Double?
    @State private var scrubOrigin: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let left = x(for: start, width: width)
            let right = x(for: end, width: width)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Rectangle().fill(.white.opacity(0.06))
                    } else {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill().frame(width: width / CGFloat(thumbnails.count), height: geometry.size.height).clipped()
                        }
                    }
                }
                .frame(width: width, height: geometry.size.height).clipShape(RoundedRectangle(cornerRadius: 9))
                if left > 0 {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: left)
                }
                if right < width {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: width - right).offset(x: right)
                }
                RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2)
                    .frame(width: max(2, right - left), height: geometry.size.height)
                    .offset(x: left)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if scrubOrigin == nil { scrubOrigin = movesSelection ? start : start + (end - start) / 2 }
                            let target = (scrubOrigin ?? 0) + value.translation.width / width * duration
                            if movesSelection { onSelectionMoved(target) }
                            else { onScrub(target) }
                        }
                        .onEnded { _ in
                            if movesSelection { onTrimDragEnded() }
                            scrubOrigin = nil
                        })
                handle(at: left, width: width, height: geometry.size.height, isStart: true)
                handle(at: right, width: width, height: geometry.size.height, isStart: false)
            }
            .frame(width: width, height: geometry.size.height)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("视频胶片裁切范围")
            .accessibilityValue("\(time(start)) 到 \(time(end))")
        }
    }

    private func handle(at x: CGFloat, width: CGFloat, height: CGFloat, isStart: Bool) -> some View {
        Capsule().fill(.white).frame(width: 5, height: height)
            .overlay(Capsule().stroke(.black.opacity(0.22), lineWidth: 0.5))
            .frame(width: 22, height: height + 10)
            .contentShape(Rectangle())
            .position(x: min(max(x, 0), width), y: height / 2)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if isStart {
                        if startDragOrigin == nil { startDragOrigin = start }
                        onStartChanged((startDragOrigin ?? start) + value.translation.width / max(1, width) * duration)
                    } else {
                        if endDragOrigin == nil { endDragOrigin = end }
                        onEndChanged((endDragOrigin ?? end) + value.translation.width / max(1, width) * duration)
                    }
                }
                .onEnded { _ in
                    onScrub(isStart ? start : end)
                    onTrimDragEnded()
                    if isStart { startDragOrigin = nil } else { endDragOrigin = nil }
                })
            .accessibilityLabel(isStart ? "拖动视频起始位置" : "拖动视频结束位置")
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    private func time(_ value: Double) -> String { String(format: "%.1f 秒", value) }
}

private struct VideoEditorPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView { let view = PlayerView(); view.playerLayer.player = player; return view }
    func updateUIView(_ view: PlayerView, context: Context) { if view.playerLayer.player !== player { view.playerLayer.player = player } }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
