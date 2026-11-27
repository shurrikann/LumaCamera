import SwiftUI

private enum CropRulerControl: String {
    case straighten
    case verticalPerspective
    case horizontalPerspective
}

struct PhotoEditorView: View {
    @StateObject private var model: PhotoEditorViewModel
    @StateObject private var filters = FilterPickerViewModel()
    let onSaved: (PhotoEditResult) -> Void
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.captureControlAngle) private var controlAngle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cropRulerControl: CropRulerControl = .straighten
    @State private var presentationVisible = false
    @State private var closing = false
    static func present(_ session: PhotoEditSession, selection: Binding<PhotoEditSession?>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection.wrappedValue = session }
    }
    init(session: PhotoEditSession, library: PhotoLibraryViewModel, onSaved: @escaping (PhotoEditResult) -> Void) {
        _model = StateObject(wrappedValue: PhotoEditorViewModel(session: session, library: library)); self.onSaved = onSaved
    }
    init(model: PhotoEditorViewModel, onSaved: @escaping (PhotoEditResult) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: model); self.onSaved = onSaved
    }
    var body: some View {
        NavigationStack {
            editorContent
                .overlay {
                    if controlsPopupVisible {
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(AppTheme.popupAnimation) {
                                    filters.showStrength = false
                                    model.closeEditorControls()
                                }
                            }
                            .accessibilityLabel("收起编辑面板")
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.tool != .crop {
                        toolBar
                            .frame(width: 264, height: 60)
                            .background {
                                Color.clear.frame(height: 50)
                                    .modifier(PreviewSurface(radius: 25, opacity: AppTheme.popupOpacity, interactive: false))
                            }
                            .padding(.bottom, 12)
                            .opacity(bottomPopupVisible ? 0 : 1)
                            .allowsHitTesting(!bottomPopupVisible).accessibilityHidden(bottomPopupVisible)
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                model.captureButtonFramesForTesting["photo.editor.toolbar"] = $0
                            }
                            #endif
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.editorControlsVisible, model.tool == .adjustments {
                        adjustmentPanel
                            .padding(10)
                            .frame(height: model.editorControlsHeight)
                            .modifier(PopupSurface(radius: 24, glass: true))
                            .background { Color.black.opacity(0.001).onTapGesture {} }
                            .padding(.horizontal, 10).padding(.bottom, 84)
                            .transition(.opacity)
                    }
                }
                .animation(AppTheme.popupAnimation, value: model.editorControlsVisible)
                .animation(AppTheme.popupAnimation, value: model.tool)
                .overlay(alignment: .top) { if model.tool != .crop { editorHeader.transition(.opacity) } }
                .overlay(alignment: .bottom) {
                    if model.filterPopupVisible {
                        PhotoFilterPopup(model: model, filters: filters) {
                            filters.showStrength = false
                            model.closeEditorControls()
                        }
                        .background { Color.black.opacity(0.001).onTapGesture {} }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                .animation(AppTheme.popupAnimation, value: model.filterPopupVisible)
                .overlay(alignment: .bottom) {
                    if watermarkPopupVisible {
                        watermarkPanel
                            .background { Color.black.opacity(0.001).onTapGesture {} }
                            .padding(.horizontal, 10).padding(.bottom, 10)
                            .ignoresSafeArea(edges: .bottom)
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .animation(AppTheme.popupAnimation, value: watermarkPopupVisible)
                .overlay { if model.resetVisible { resetDialog.transition(.opacity) }; if model.saveOptionsVisible { saveDialog.transition(.opacity) } }
                .overlay {
                    if model.filterNumericParameter != nil {
                        FilterNumericInputDialog(model: model).environment(\.captureControlAngle, 0).transition(.opacity)
                    }
                }
                .animation(AppTheme.popupAnimation, value: model.filterNumericParameter)
                .toolbar(.hidden, for: .navigationBar)
                .animation(AppTheme.popupAnimation, value: model.resetVisible)
                .animation(AppTheme.popupAnimation, value: model.saveOptionsVisible)
                .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18), value: model.tool == .crop)
                .onChange(of: controlAngle) { _, _ in model.setParameterEditing(false) }
                .onChange(of: model.filterPopupVisible) { _, visible in
                    if !visible { filters.showStrength = false }
                }
                .task { model.renderPreview(); filters.prepareThumbnails() }.onDisappear { model.cancelPreview() }
                .interactiveDismissDisabled(model.saving)
                .allowsHitTesting(!model.saving)
                .alert("图片编辑", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("好", role: .cancel) { model.message = nil }
                } message: { Text(model.message ?? "") }
            .animation(AppTheme.popupAnimation, value: model.tool == .crop)
        }
        .background {
            Group {
                if model.tool == .crop {
                    Color.black
                } else {
                    AppTheme.popupColor
                }
            }
            .ignoresSafeArea()
        }
        .environment(\.captureControlAngle, 0)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(AppTheme.accent).preferredColorScheme(.dark)
            // The crop preview paints its own transformed overflow over a dark canvas.
            .presentationBackground(Color.clear)
            .presentationCornerRadius(0)
            .opacity(presentationVisible ? 1 : 0)
            .allowsHitTesting(!closing)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.18)) { presentationVisible = true }
            }
    }
    private func closeEditor() {
        guard !closing else { return }
        closing = true
        let duration = reduceMotion ? 0.08 : 0.18
        withAnimation(.easeOut(duration: duration)) { presentationVisible = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
    @ViewBuilder private var editorContent: some View {
        if model.tool == .crop {
            VStack(spacing: 10) {
                cropHeader
                photoPreview
                cropFooter
            }.padding(.bottom, 10)
        } else {
            photoPreview.ignoresSafeArea()
        }
    }

    private var controlsPopupVisible: Bool {
        bottomPopupVisible || (model.tool == .adjustments && model.editorControlsVisible)
    }

    private var editorHeader: some View {
        HStack {
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); closeEditor() } label: { Image(systemName: "arrow.left").rotatingCaptureContent().frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true)) }.accessibilityLabel("取消编辑")
            Spacer()
            Menu {
                if model.session.rawDevelopment != nil {
                    Toggle("高动态",isOn:Binding(get:{ model.adjustments.rawDevelopment?.adaptive == true },set:{ model.adjustments.rawDevelopment?.adaptive = $0 }))
                    Toggle("HDR 输出",isOn:Binding(get:{ model.adjustments.rawDevelopment?.hdr == true },set:{ model.adjustments.rawDevelopment?.hdr = $0 }))
                    Picker("Pro 影调",selection:Binding(get:{ model.adjustments.rawDevelopment?.tone ?? PhotoTone.natural.rawValue },set:{ model.adjustments.rawDevelopment?.tone = $0 })) {
                        ForEach(PhotoTone.allCases) { tone in Text(tone.rawValue).tag(tone.rawValue) }
                    }
                }
                Button("重置当前滤镜", systemImage: "arrow.counterclockwise") { model.presentReset() }
                Button("还原构图", systemImage: "crop.rotate") { model.resetGeometry() }
            } label: { Image(systemName: "ellipsis").rotatingCaptureContent().frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true)) }
        }.padding(.horizontal, 12).padding(.top, 8).buttonStyle(.plain)
    }
    private var photoPreview: some View {
        GeometryReader { geometry in
            if let image = model.preview {
                if model.tool == .crop {
                    let scale = min(geometry.size.width/max(1,image.size.width), geometry.size.height/max(1,image.size.height))
                    let size = CGSize(width: image.size.width*scale, height: image.size.height*scale)
                    ZStack(alignment: .topLeading) {
                        if let outside = model.cropOverflowPreview {
                            let extent = model.cropOverflowExtent
                            Image(uiImage: outside).resizable()
                                .frame(width: extent.width * scale, height: extent.height * scale)
                                .position(x: extent.midX * scale,
                                          y: size.height - extent.midY * scale)
                                .opacity(0.45)
                                .allowsHitTesting(false)
                        }
                        Image(uiImage: image).resizable()
                            .frame(width: size.width, height: size.height)
                        PhotoCropOverlay(crop: $model.adjustments.crop)
                    }
                    .frame(width: size.width, height: size.height)
                    .position(x: geometry.size.width/2, y: geometry.size.height/2)
                } else {
                    ZoomablePhotoView(image: image, preservesViewportOnImageUpdates: true)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityLabel("编辑预览，可双指缩放并拖动查看")
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.photoViewportFrameForTesting = $0
        }
        #endif
    }
    private var watermarkPopupVisible: Bool {
        model.tool == .watermark && model.editorControlsVisible
    }
    private var bottomPopupVisible: Bool {
        model.filterPopupVisible || watermarkPopupVisible
    }
    private var bottomPopupCornerRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }
    private var toolBar: some View {
        HStack(spacing: 0) {
            toolButton(.crop, icon: "crop") { cropRulerControl = .straighten; model.enterCrop() }
            toolButton(.filters, icon: "camera.filters") {
                if !model.filterPopupVisible { filters.showStrength = false }
                model.toggleEditorControls(.filters)
            }
            toolButton(.watermark, icon: "photo.artframe") { model.toggleEditorControls(.watermark) }
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.presentSaveOptions() } label: {
                ZStack {
                    if model.saving { ProgressView().tint(.white) }
                    else { Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8)) }
                }.frame(width: 44, height: 44).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.disabled(model.preview == nil || model.saving).accessibilityLabel("保存编辑")
        }.frame(maxWidth: .infinity).buttonStyle(.plain)
    }
    private func toolButton(_ tool: PhotoEditorTool, icon: String, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            let active = tool == .filters ? model.filterPopupVisible : (model.tool == tool && model.editorControlsVisible)
            Image(systemName: icon).rotatingCaptureContent().font(.system(size: 20)).foregroundStyle(active ? AppTheme.accent : .white.opacity(0.8))
                .frame(width: 44, height: 44).frame(maxWidth: .infinity)
                .contentShape(Circle())
                .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18), value: model.tool)
        }.accessibilityLabel("照片编辑" + tool.rawValue).accessibilityAddTraits(
            (tool == .filters ? model.filterPopupVisible : (model.tool == tool && model.editorControlsVisible)) ? .isSelected : [])
    }
    private var watermarkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("水印").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { model.closeEditorControls() } label: {
                    Image(systemName: "xmark").frame(width: 30, height: 30)
                        .background(.white.opacity(0.1), in: Circle())
                }.accessibilityLabel("收起水印面板")
            }
            HStack(spacing: 8) {
                ForEach(PhotoWatermarkStyle.allCases) { style in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.selectWatermarkStyle(style)
                    } label: {
                        WatermarkStyleThumbnail(style: style, selected: model.adjustments.watermark?.settings.style == style)
                    }.accessibilityLabel(style.title)
                        .accessibilityAddTraits(model.adjustments.watermark?.settings.style == style ? .isSelected : [])
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            model.captureButtonFramesForTesting["photo.editor.watermark." + style.rawValue] = $0
                        }
                        #endif
                }
            }
            WatermarkInfoToggles(
                showsLocation: Binding(
                    get: { model.watermarkSettings.showsLocation },
                    set: { model.setWatermarkInformation(location: $0) }),
                showsParameters: Binding(
                    get: { model.watermarkSettings.showsParameters },
                    set: { model.setWatermarkInformation(parameters: $0) })
            )
        }.padding(16).buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: bottomPopupCornerRadius, style: .continuous))
            .background {
                PopupGlassBackground(
                    shape: RoundedRectangle(cornerRadius: bottomPopupCornerRadius, style: .continuous),
                    materialOpacity: AppTheme.cameraPopupMaterialOpacity
                )
            }
            .environment(\.captureControlAngle, 0)
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                model.captureButtonFramesForTesting["photo.editor.watermark.panel"] = $0
            }
            #endif
    }
    private var adjustmentPanel: some View {
        VStack(spacing: 12) {
            FilterAdjustmentTabs(model: model, onClose: { model.closeEditorControls() })
            FilterDialEditor(model: model, tab: model.filterEditorTab)
        }
        .padding(.horizontal, 6)
        .environment(\.captureControlAngle, 0)
        .accessibilityIdentifier("photo.editor.sharedFilterControls")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.captureButtonFramesForTesting["photo.editor.controls"] = $0
        }
        #endif
    }
    private var cropHeader: some View {
        HStack(spacing: 22) {
            Button { model.flip(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right").rotatingCaptureContent() }.accessibilityLabel("水平翻转")
            Menu {
                Button("旋转90°") { model.rotate() }
                Button("垂直翻转") { model.flip(horizontal: false) }
            } label: { Image(systemName: "ellipsis").rotatingCaptureContent() }
            Spacer()
            Menu {
                Button("原始比例") { model.setCropAspect(nil) }
                ForEach(FrameRatio.allCases.filter { $0 != .openGate }, id: \.self) { ratio in Button(ratio.rawValue) { model.setCropAspect(ratio) } }
            } label: { Image(systemName: "aspectratio").rotatingCaptureContent() }.accessibilityLabel("裁剪比例")
        }.font(.system(size: 21)).buttonStyle(.plain).padding(.horizontal, 22).frame(height: 56)
    }
    private func cropActionButton(_ icon: String, label: String, active: Bool = false,
                                  rotation: Angle = .zero,
                                  action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: icon).rotatingCaptureContent()
                .rotationEffect(rotation)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(active ? AppTheme.accentForeground : .white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background {
                    if active { Circle().fill(AppTheme.accent.opacity(0.36)) }
                }
                .modifier(GlassSurface(radius: 22))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var resetCropButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            cropRulerControl = .straighten
            model.resetGeometry()
        } label: {
            Image(systemName: "arrow.counterclockwise").rotatingCaptureContent()
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .modifier(GlassSurface(radius: 22))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("还原构图")
    }
    private var cropFooter: some View {
        VStack(spacing: 14) {
            Text(cropRulerText).rotatingCaptureContent()
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(AppTheme.accent)
            CameraRuler(value: cropRulerValue, range: cropRulerRange, tint: AppTheme.accent)
                .id("\(cropRulerControl.rawValue)-\(landscape)")
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.editingRulerFrameForTesting = $0 }
                #endif
                .padding(.horizontal, 18)
                .accessibilityLabel(cropRulerAccessibilityLabel)
            HStack {
                Button { model.finishCrop(commit: false) } label: {
                    Text("取消").rotatingCaptureContent()
                }
                Spacer()
                HStack(spacing: 12) {
                    cropActionButton("rotate.right", label: "校正角度",
                                     active: cropRulerControl == .straighten) {
                        cropRulerControl = .straighten
                    }
                    cropActionButton("perspective", label: "上下透视拉伸",
                                     active: cropRulerControl == .verticalPerspective,
                                     rotation: .degrees(90)) {
                        cropRulerControl = .verticalPerspective
                    }
                    cropActionButton("perspective", label: "左右透视拉伸",
                                     active: cropRulerControl == .horizontalPerspective) {
                        cropRulerControl = .horizontalPerspective
                    }
                    resetCropButton
                }
                Spacer()
                Button { model.finishCrop(commit: true) } label: {
                    Text("完成").rotatingCaptureContent()
                }.foregroundStyle(AppTheme.accent)
            }.font(.system(size: 16)).buttonStyle(.plain).padding(.horizontal, 24).frame(height: 48)
        }.padding(.top, 10)
    }

    private var cropRulerRange: ClosedRange<Double> {
        cropRulerControl == .straighten ? -45...45 : -50...50
    }

    private var cropRulerValue: Binding<Double> {
        switch cropRulerControl {
        case .straighten:
            return $model.adjustments.straightenAngle
        case .verticalPerspective:
            // Top/bottom convergence is driven by the horizontal-edge inset.
            return Binding(
                get: { model.adjustments.stretch.horizontal * 100 },
                set: { model.adjustments.stretch.horizontal = min(max($0 / 100, -0.5), 0.5) }
            )
        case .horizontalPerspective:
            // Left/right convergence is driven by the vertical-edge inset.
            return Binding(
                get: { model.adjustments.stretch.vertical * 100 },
                set: { model.adjustments.stretch.vertical = min(max($0 / 100, -0.5), 0.5) }
            )
        }
    }

    private var cropRulerText: String {
        switch cropRulerControl {
        case .straighten:
            return String(format: "%.1f°", model.adjustments.straightenAngle)
        case .verticalPerspective:
            return String(format: "%+.0f%%", model.adjustments.stretch.horizontal * 100)
        case .horizontalPerspective:
            return String(format: "%+.0f%%", model.adjustments.stretch.vertical * 100)
        }
    }

    private var cropRulerAccessibilityLabel: String {
        switch cropRulerControl {
        case .straighten: return "照片校正角度"
        case .verticalPerspective: return "上下透视拉伸"
        case .horizontalPerspective: return "左右透视拉伸"
        }
    }
    private var saveDialog: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.3).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { model.dismissSaveOptions() }
            VStack(spacing: 16) {
                HStack {
                    Text("保存编辑后的照片").font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button { model.dismissSaveOptions() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                            .contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("关闭保存选项")
                }
                if model.session.supportsLiveEditing {
                    HStack(spacing: 8) {
                        liveSaveMode("保留 Live", icon: "livephoto", live: true)
                        liveSaveMode("静态照片", icon: "photo", live: false)
                    }
                }
                if model.session.supportsLiveEditing && !model.preservesLive {
                    saveChoice("另存静态照片", subtitle: "仅保存编辑后的照片，原 Live 保留", asCopy: true)
                } else {
                    HStack(spacing: 10) {
                        if model.session.supportsSaveCopy {
                            saveChoice("另存一张", subtitle: model.session.supportsLiveEditing ? "照片与动态片段同步编辑，保留声音" : "保留原照片，保存编辑副本", asCopy: true)
                        }
                        saveChoice(model.session.supportsSaveCopy ? "覆盖原图" : "保存照片", subtitle: model.session.supportsLiveEditing ? "更新完整 Live，可在系统照片中还原" : (model.session.supportsSaveCopy ? "更新当前照片，可在系统照片中还原" : "保存当前编辑结果"), asCopy: false)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity)
            .modifier(PopupSurface(radius: 28, glass: true))
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                model.captureButtonFramesForTesting["photo.save.popup"] = $0
            }
            #endif
            .padding(.horizontal, 10).padding(.bottom, 10)
        }.ignoresSafeArea(edges: .bottom)
    }
    private func liveSaveMode(_ title: String, icon: String, live: Bool) -> some View {
        Button {
            withAnimation(AppTheme.popupAnimation) { model.preservesLive = live }
        } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 36)
                .foregroundStyle(model.preservesLive == live ? AppTheme.accent : .white.opacity(0.65))
                .background(.white.opacity(model.preservesLive == live ? 0.12 : 0.04), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(model.preservesLive == live ? .isSelected : [])
    }
    private func saveChoice(_ title: String, subtitle: String, asCopy: Bool) -> some View {
        Button { model.save(asCopy: asCopy) { result in onSaved(result); closeEditor() } } label: {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.85)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 90).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private var resetDialog: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { model.dismissReset() }
            VStack(spacing: 18) {
                Text("重置" + model.style.title + "？").font(.system(size: 17, weight: .semibold))
                Text("恢复本次编辑中当前滤镜的默认参数。").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 12) {
                    Button { model.dismissReset() } label: { Text("取消").frame(maxWidth: .infinity).frame(height: 44).background(.white.opacity(0.07), in: Capsule()) }
                    Button { model.resetCurrentFilter() } label: {
                        Text("重置").fontWeight(.semibold).foregroundStyle(AppTheme.accentForeground)
                            .frame(maxWidth: .infinity).frame(height: 44).background(AppTheme.accent, in: Capsule())
                    }
                }.font(.system(size: 14)).buttonStyle(.plain)
            }.padding(22).frame(maxWidth: 310).modifier(PopupSurface(radius: 28, glass: true)).orientedPopup(maximumWidth: 310)
        }
    }
}
