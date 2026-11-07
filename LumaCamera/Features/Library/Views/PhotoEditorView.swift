import SwiftUI

struct PhotoEditorView: View {
    @StateObject private var model: PhotoEditorViewModel
    @StateObject private var filters = FilterPickerViewModel()
    let onSaved: (PhotoEditResult) -> Void
    @Environment(\.captureControlsLandscape) private var landscape
    @Environment(\.captureControlAngle) private var controlAngle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(session: PhotoEditSession, library: PhotoLibraryViewModel, onSaved: @escaping (PhotoEditResult) -> Void) {
        _model = StateObject(wrappedValue: PhotoEditorViewModel(session: session, library: library)); self.onSaved = onSaved
    }
    init(model: PhotoEditorViewModel, onSaved: @escaping (PhotoEditResult) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: model); self.onSaved = onSaved
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if model.tool == .crop { cropHeader.transition(.opacity) }
                photoPreview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.photoViewportFrameForTesting = $0 }
                    #endif
                    .animation(AppTheme.frameAnimation, value: landscape)
                if model.tool == .crop { cropFooter.transition(.opacity) }
                else {
                    ZStack {
                        if model.editorControlsVisible {
                            Group {
                                if model.tool == .filters { filterPanel } else { adjustmentPanel }
                            }.transition(.opacity)
                        }
                    }
                    .frame(height: model.editorControlsHeight).padding(.horizontal, 10)
                    .animation(AppTheme.popupAnimation, value: model.editorControlsVisible)
                    .animation(AppTheme.popupAnimation, value: model.tool)
                    toolBar.padding(.horizontal, 12).transition(.opacity)
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            model.captureButtonFramesForTesting["photo.editor.toolbar"] = $0
                        }
                        #endif
                }
            }.padding(.bottom, 10).background(AppTheme.popupColor)
                .overlay(alignment: .top) { if model.tool != .crop { editorHeader.transition(.opacity) } }
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
                .task { model.renderPreview(); filters.prepareThumbnails() }.onDisappear { model.cancelPreview() }
                .interactiveDismissDisabled(model.saving)
                .allowsHitTesting(!model.saving)
                .alert("图片编辑", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("好", role: .cancel) { model.message = nil }
                } message: { Text(model.message ?? "") }
        }.ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(AppTheme.accent).preferredColorScheme(.dark)
            .presentationCornerRadius(0)
    }
    private var editorHeader: some View {
        HStack {
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); dismiss() } label: { Image(systemName: "arrow.left").rotatingCaptureContent().frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true)) }.accessibilityLabel("取消编辑")
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
                    ZStack {
                        Image(uiImage: image).resizable().scaledToFit()
                        PhotoCropOverlay(crop: $model.adjustments.crop)
                    }.frame(width: size.width, height: size.height).position(x: geometry.size.width/2, y: geometry.size.height/2)
                } else {
                    ZoomablePhotoView(image: image, preservesViewportOnImageUpdates: true)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityLabel("编辑预览，可双指缩放并拖动查看")
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    private var toolBar: some View {
        HStack(spacing: 24) {
            toolButton(.crop, icon: "crop") { model.enterCrop() }
            toolButton(.filters, icon: "camera.filters") { model.toggleEditorControls(.filters) }
            toolButton(.adjustments, icon: "slider.horizontal.3") { model.toggleEditorControls(.adjustments) }
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.presentSaveOptions() } label: {
                ZStack {
                    Circle().fill(AppTheme.accent)
                    if model.saving { ProgressView().tint(.black) }
                    else { Text("保存").rotatingCaptureContent().font(.system(size: 12, weight: .semibold)).foregroundStyle(.black) }
                }.frame(width: 44, height: 44)
            }.disabled(model.preview == nil || model.saving).accessibilityLabel("保存编辑")
        }.frame(maxWidth: .infinity).buttonStyle(.plain)
    }
    private func toolButton(_ tool: PhotoEditorTool, icon: String, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() } label: {
            Image(systemName: icon).rotatingCaptureContent().font(.system(size: 20)).foregroundStyle(model.tool == tool && model.editorControlsVisible ? AppTheme.accent : .white.opacity(0.8))
                .frame(width: 44, height: 44).modifier(PopupSurface(radius: 22, glass: true))
                .overlay(Circle().stroke(model.tool == tool && model.editorControlsVisible ? AppTheme.accent.opacity(0.65) : .clear, lineWidth: 1))
                .contentShape(Circle())
                .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18), value: model.tool)
        }.accessibilityLabel("照片编辑" + tool.rawValue).accessibilityAddTraits(model.tool == tool && model.editorControlsVisible ? .isSelected : [])
    }
    private var filterPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                ForEach(FilterCategory.allCases) { category in
                    Button { filters.category = category } label: {
                        Text(category.rawValue).rotatingCaptureContent().font(.system(size: 12)).foregroundStyle(filters.category == category ? AppTheme.accent : .white.opacity(0.55))
                    }
                }
                Spacer(minLength: 0)
                Button { model.closeEditorControls() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32)
                }.accessibilityLabel("收起滤镜列表")
            }.padding(.horizontal, 10)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(filters.styles) { style in
                            Button { model.selectFilter(style) } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle().fill(.white.opacity(0.05))
                                        if let image = filters.thumbnails[style] { Image(uiImage: image).resizable().scaledToFill() }
                                        else { ProgressView().controlSize(.small) }
                                    }.frame(width: 60, height: 60).clipShape(Circle())
                                        .overlay(Circle().stroke(model.style == style ? AppTheme.accent : .white.opacity(0.2), lineWidth: model.style == style ? 2 : 0.5))
                                    Text(style.title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(width: 72, height: 27)
                                }.foregroundStyle(model.style == style ? AppTheme.accent : .white)
                            }.id(style).accessibilityLabel("编辑滤镜" + style.title).accessibilityAddTraits(model.style == style ? .isSelected : [])
                        }
                    }.padding(.horizontal, 10)
                }.scrollIndicators(.hidden).onAppear { proxy.scrollTo(model.style, anchor: .center) }
            }
        }.buttonStyle(.plain)
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
            Button { model.rotate() } label: { Image(systemName: "rotate.right").rotatingCaptureContent() }.accessibilityLabel("旋转90度")
            Menu { Button("垂直翻转") { model.flip(horizontal: false) }; Button("还原构图") { model.resetGeometry() } } label: { Image(systemName: "ellipsis").rotatingCaptureContent() }
            Spacer()
            Menu {
                Button("原始比例") { model.setCropAspect(nil) }
                ForEach(FrameRatio.allCases.filter { $0 != .openGate }, id: \.self) { ratio in Button(ratio.rawValue) { model.setCropAspect(ratio) } }
            } label: { Image(systemName: "aspectratio").rotatingCaptureContent() }.accessibilityLabel("裁剪比例")
        }.font(.system(size: 21)).buttonStyle(.plain).padding(.horizontal, 22).frame(height: 56)
    }
    private var cropFooter: some View {
        VStack(spacing: 14) {
            Text(String(format: "%.1f°", model.adjustments.straightenAngle)).rotatingCaptureContent().font(.system(size: 13, design: .monospaced)).foregroundStyle(AppTheme.accent)
            CameraRuler(value: $model.adjustments.straightenAngle, range: -45...45, tint: AppTheme.accent)
                .id(landscape)
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.editingRulerFrameForTesting = $0 }
                #endif
                .padding(.horizontal, 18).accessibilityLabel("照片校正角度")
            HStack {
                Button { model.finishCrop(commit: false) } label: { Text("取消").rotatingCaptureContent() }
                Spacer()
                Button { model.finishCrop(commit: true) } label: { Text("完成").rotatingCaptureContent() }.foregroundStyle(AppTheme.accent)
            }.font(.system(size: 16)).buttonStyle(.plain).padding(.horizontal, 24).frame(height: 48)
        }.padding(.top, 10)
    }
    private var saveDialog: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { model.dismissSaveOptions() }
            VStack(spacing: 16) {
                Text("保存编辑后的照片").font(.system(size: 17, weight: .semibold))
                if model.session.supportsLiveEditing {
                    HStack(spacing: 8) {
                        liveSaveMode("保留 Live", icon: "livephoto", live: true)
                        liveSaveMode("静态照片", icon: "photo", live: false)
                    }
                }
                if model.session.supportsLiveEditing && !model.preservesLive {
                    saveChoice("另存静态照片", subtitle: "仅保存编辑后的照片，原 Live 保留", asCopy: true)
                } else {
                    if model.session.supportsSaveCopy {
                        saveChoice("另存一张", subtitle: model.session.supportsLiveEditing ? "照片与动态片段同步编辑，保留声音" : "保留原照片，保存一张编辑后的副本", asCopy: true)
                    }
                    saveChoice(model.session.supportsSaveCopy ? "覆盖原片" : "保存照片", subtitle: model.session.supportsLiveEditing ? "更新完整 Live，可在系统照片中还原" : (model.session.supportsSaveCopy ? "更新当前照片，可在系统照片中还原" : "保存当前编辑结果"), asCopy: false)
                }
                Button("取消") { model.dismissSaveOptions() }.font(.system(size: 14)).frame(height: 36)
            }.padding(22).frame(maxWidth: 320).modifier(PopupSurface(radius: 28, glass: true)).orientedPopup(maximumWidth: 320)
        }
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
        Button { model.save(asCopy: asCopy) { result in onSaved(result); dismiss() } } label: {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }.frame(maxWidth: .infinity).padding(.vertical, 14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
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
