import SwiftUI
import AVFoundation

/// 图标只在固定区域内淡入淡出，切换子模块不移动按钮或改变玻璃背景尺寸。
struct ShootingModeButtonSymbol: View {
    let symbol: String
    var body: some View {
        ZStack {
            Image(systemName: symbol).id(symbol).transition(.opacity)
        }
        .frame(width: 22, height: 22)
        .animation(AppTheme.popupAnimation, value: symbol)
    }
}

extension CameraView {
    /// 独立小窗画幅按钮保留固定热区，不占用拖动或双击交换手势。
    func dualInsetAspectButton(diameter: CGFloat) -> some View {
        Button { model.toggleDualCaptureInsetAspect() } label: {
            ZStack {
                Image(systemName: camera.dualCaptureInsetLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .opacity(model.dualInsetAspectChanging ? 0 : 1)
                if model.dualInsetAspectChanging { ProgressView().tint(.white) }
            }
            .font(.system(size: camera.dualCaptureInsetLandscape ? 16 : 15, weight: .medium))
            .foregroundStyle(camera.dualCaptureInsetLandscape ? AppTheme.accent : Color.white.opacity(0.9))
            .rotatingCaptureContent()
            .frame(width: diameter, height: diameter)
            .background(camera.dualCaptureInsetLandscape ? Color.white.opacity(0.06) : .clear, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.ready || camera.videoBusy || camera.dualCapturePreparing || camera.videoConfiguring || model.dualInsetAspectChanging)
        .accessibilityLabel(camera.dualCaptureInsetLandscape ? "恢复竖向小窗" : "横向小窗并开启前置超广角")
        .accessibilityIdentifier("camera.dualCapture.aspect")
        .captureControlGeometry("dualCaptureAspect", model: model)
    }

    /// 与前置广角/双拍并排，组整体居中；仅旋转图标，不改变布局。
    private func frontVideoCenteringButton(diameter: CGFloat) -> some View {
        Button { model.toggleFrontVideoCentering() } label: {
            ZStack {
                Image(systemName: "person.crop.rectangle").font(.system(size: 17))
                    .opacity(camera.frontVideoCenteringPreparing ? 0 : 1)
                if camera.frontVideoCenteringPreparing { ProgressView().tint(.white) }
            }
            .foregroundStyle(model.frontVideoCenteringRequested ? AppTheme.accent : .white)
            .rotatingCaptureContent().frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }.buttonStyle(.plain)
            .disabled(!camera.ready || camera.videoBusy || camera.dualCapturePreparing || camera.frontVideoCenteringPreparing)
            .accessibilityLabel("视频人物居中")
            .accessibilityValue(model.frontVideoCenteringRequested ? "开启" : "关闭")
            .accessibilityIdentifier("camera.frontVideoCentering")
            .captureControlGeometry("frontVideoCentering", model: model)
    }

    var videoElapsedText: String {
        let seconds = max(0, Int(model.videoElapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var timeLapsePreviewStatus: String {
        if let target = model.timeLapseFrameCount.target {
            return "剩余 \(max(0, target - camera.timeLapseCapturedFrames)) 张"
        }
        return "已拍 \(videoElapsedText)"
    }

    var modeControls: some View {
        Group {
            if model.mode == .auto {
                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Text(model.usesGlobalMeteringReadout ? "总曝光" : "曝光").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                        Text(String(format: "%+.1f", model.displayedExposureBias)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(AppTheme.accent)
                    }.rotatingCaptureContent().frame(width: 38)
                    ZStack {
                        HStack(alignment: .center, spacing: 0) {
                            ForEach(0..<25) { tick in
                                Rectangle().fill(.white.opacity(tick % 6 == 0 ? 0.5 : 0.2))
                                    .frame(width: 1, height: tick % 6 == 0 ? 18 : 9)
                                    .frame(maxWidth: .infinity)
                            }
                        }.allowsHitTesting(false)
                        Slider(value: Binding(get: { model.ev }, set: { model.updateAutomaticEVFromSlider($0) }), in: model.exposureCompensationRange)
                            .tint(AppTheme.accent).disabled(!camera.ready || camera.demo).accessibilityLabel("自动曝光补偿")
                    }
                    Button { CameraHaptics.impact(.light); model.ev = 0; model.applyExposure() } label: {
                        Text("A").rotatingCaptureContent().font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                            .frame(width: 30, height: 30).background(AppTheme.accent.opacity(0.08), in: Circle())
                    }.accessibilityLabel("重置曝光补偿")
                }.padding(.horizontal, 14).frame(height: 46).modifier(GlassSurface(radius: 29, previewOverlay: true))
            } else {
                HStack(spacing: 4) {
                    ForEach(model.displayedManualParameters, id: \.self) { item in
                        Button {
                            CameraHaptics.impact(.light)
                            model.openParameter(item)
                        } label: {
                            Image(systemName: model.parameterIcon(item)).rotatingCaptureContent().font(.system(size: 17, weight: .regular))
                                .foregroundStyle(model.parameterIsManual(item) ? Color(red: 0.24, green: 0.12, blue: 0.04) : .white)
                                .frame(width: 42, height: 42)
                                .background(model.parameterIsManual(item) ? AppTheme.manualParameterColor.opacity(0.78) : .clear, in: Circle())
                                .modifier(GlassSurface(radius: 21, previewOverlay: true))
                                .frame(maxWidth: model.cinematicAutomaticControls ? 62 : .infinity)
                        }.captureControlGeometry("parameter." + item.rawValue, model: model).accessibilityLabel(model.parameterTitle(item))
                            .accessibilityValue(model.parameterIsManual(item) ? "手动" : "自动")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.2), value: model.displayedManualParameters)
            }
        }.padding(.horizontal, CameraControlLayout.parameterSideInset(automatic: model.mode == .auto))
            .captureControlGeometry("parameters", model: model)
    }

    func fixedCameraControls(width: CGFloat) -> some View {
        let hidesSlowShutterControls = model.slowShutterCaptureHidesControls
        let positionLenses = camera.lenses.filter { $0.device.position == model.currentPosition }
        let hasFrontWideToggle = model.currentPosition == .front
            && positionLenses.contains { $0.frontFraming == .wide }
            && positionLenses.contains { $0.frontFraming == .standard }
        let count = camera.demo ? 1 : (hasFrontWideToggle ? 1 : positionLenses.count)
        let diameter = CameraLensBarLayout.controlDiameter(containerWidth: width, count: count)
        let lensWidth = max(1, width - 56 - 2 * diameter)
        return ZStack(alignment: .bottom) {
            if model.zoomDialVisible {
                GeometryReader { geometry in
                    zoomDialLayer(size: CGSize(width: width, height: geometry.size.height))
                }.allowsHitTesting(false).transition(.opacity).zIndex(0)
                GeometryReader { geometry in
                    let size = CGSize(width: width, height: geometry.size.height)
                    let layout = CameraZoomDialLayout(size: size, ratio: model.ratio,
                                                       openGatePortraitRatio: camera.openGatePortraitRatio)
                    let bottom = model.panel == .manual && !controlsLandscape ? max(CameraControlLayout.compositionBottom, parameterPopupHeight + 16) : CameraControlLayout.compositionBottom
                    let controlsY = size.height - bottom - 44
                    CameraZoomPanSurface(region: layout.visible, excluded: [
                        CGRect(x: 16, y: controlsY - 4, width: diameter + 8, height: 52),
                        CGRect(x: width - 24 - diameter, y: controlsY - 4, width: diameter + 8, height: 52),
                        CGRect(x: width - 24 - diameter,
                               y: controlsY - diameter - CameraControlLayout.upperButtonGap - 4,
                               width: diameter + 8,
                               height: 52 + diameter + CameraControlLayout.upperButtonGap),
                        CGRect(x: 0, y: size.height - CameraControlLayout.parameterBottom - 42, width: width, height: 42),
                        CGRect(x: 0, y: size.height - CameraControlLayout.shutterBottom - 78, width: width, height: 78)
                    ], dialWidth: layout.dialWidth,
                        onBegin: { model.beginZoomDial(at: camera.currentZoom) },
                        onDrag: { model.dragZoomDial(translation: $0, width: $1) },
                        onFinish: { model.finishZoomDrag() })
                }.zIndex(4)
            }
            HStack(spacing: 8) {
                Group {
                    // 仅视频录制中隐藏 A/M；视频状态残留不得影响照片模式按钮。
                    if model.captureKind == .video && camera.videoRecording {
                        Color.clear.accessibilityHidden(true)
                    } else {
                        Button { model.setMode(model.mode == .auto ? .manual : .auto) } label: {
                            Text(model.mode.rawValue).rotatingCaptureContent().font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(model.mode == .manual ? AppTheme.accent : .white)
                                .frame(width: diameter, height: diameter)
                                .contentShape(Rectangle().inset(by: -CameraControlLayout.buttonHitExpansion))
                        }
                            .captureControlGeometry("shootingModeToggle", model: model)
                            .disabled(camera.capturing || camera.videoBusy || model.isPreparingSubmode)
                            .accessibilityLabel(model.mode == .auto ? "自动模式，点击切换手动模式" : "手动模式，点击切换自动模式")
                            .accessibilityIdentifier("camera.shootingModeToggle")
                            .transition(.opacity)
                    }
                }
                .frame(width: diameter, height: diameter)
                .overlay(alignment: .bottom) {
                    let macroIndicatorVisible = model.mode == .auto && camera.macroActive
                    if macroIndicatorVisible {
                        Image(systemName: "camera.macro")
                            .rotatingCaptureContent()
                            .frame(width: diameter, height: diameter)
                            .contentShape(Circle())
                            .captureControlGeometry("macro", model: model)
                            .accessibilityLabel("微距镜头启用")
                            .accessibilityIdentifier("camera.macro.indicator")
                            .transition(.opacity)
                            .offset(y: -diameter - CameraControlLayout.upperButtonGap)
                    }
                }.animation(AppTheme.popupAnimation, value: camera.macroActive)
                    .onChange(of: camera.macroActive) { _, isActive in
                        if isActive { model.dismissPortraitDepthSliderForMacro() }
                    }
                .captureControlGeometry("mode", model: model)
                    .opacity(hidesSlowShutterControls ? 0 : 1)
                    .allowsHitTesting(!hidesSlowShutterControls)
                Group {
                    if model.captureKind == .video && model.displayedFocalPosition == .front {
                        // 视频前置固定超广角：不渲染任何焦段控件；追踪可用时只显示居中的追踪按钮。
                        if model.frontVideoCenteringVisible {
                            frontVideoCenteringButton(diameter: diameter).padding(2)
                                .recordingHidden(camera.videoRecording)
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    } else if model.captureKind == .video && (model.dualCaptureAvailable || camera.dualCaptureEnabled) {
                        lensBar(availableWidth: lensWidth).fixedSize().frame(maxWidth: .infinity)
                    } else {
                        lensBar(availableWidth: lensWidth).frame(maxWidth: .infinity)
                    }
                }
                    #if DEBUG
                    .onChange(of: model.dualCaptureAvailable || camera.dualCaptureEnabled) { _, visible in
                        if !visible { model.captureButtonFramesForTesting.removeValue(forKey: "dualCaptureToggle") }
                    }
                    #endif
                    .animation(AppTheme.popupAnimation, value: model.virtualApertureEnabled)
                    .animation(AppTheme.popupAnimation, value: model.slowShutterEnabled)
                    .animation(AppTheme.popupAnimation, value: model.timeLapseEnabled)
                    .allowsHitTesting(!camera.videoBusy || camera.videoRecording)
                    .accessibilityHidden(model.zoomDialVisible)
                    .captureControlGeometry("lenses", model: model)
                    .opacity(hidesSlowShutterControls ? 0 : 1)
                    .allowsHitTesting(!hidesSlowShutterControls)
                Button { model.openTools() } label: {
                    Image(systemName: "square.grid.3x3.fill").rotatingCaptureContent().font(.system(size: 13))
                        .frame(width: diameter, height: diameter)
                        .contentShape(Rectangle().inset(by: -CameraControlLayout.buttonHitExpansion))
                }
                .overlay(alignment: .top) {
                    shootingModeButton(diameter: diameter)
                        .offset(y: CameraControlLayout.upperButtonOffset(diameter: diameter))
                        .captureControlGeometry("shootingMode", model: model)
                }
                .captureControlGeometry("tools", model: model).accessibilityLabel("拍摄辅助工具").disabled(camera.videoBusy)
                    .recordingHidden(model.captureKind == .video && camera.videoRecording)
                    .opacity(hidesSlowShutterControls ? 0 : 1)
                    .allowsHitTesting(!hidesSlowShutterControls)
            }.frame(height: 44).padding(.horizontal, CameraControlLayout.buttonRowSideInset)
                .padding(.bottom, CameraControlLayout.compositionBottom)
                .opacity(model.panel == .film || model.tools || model.functions || model.shootingModes ? 0 : 1)
                .allowsHitTesting(model.panel != .film && !model.tools && !model.functions && !model.shootingModes).zIndex(3)
            modeControls.frame(height: 42).padding(.bottom, CameraControlLayout.parameterBottom)
                .opacity(model.panel == .film || model.popupVisible ? 0 : 1)
                .allowsHitTesting(model.panel != .film && !model.popupVisible).zIndex(1)
                .opacity(camera.videoRecording && model.mode == .manual ? 0 : 1)
                .allowsHitTesting(!(camera.videoRecording && model.mode == .manual))
                .accessibilityHidden(camera.videoRecording && model.mode == .manual)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(AppTheme.popupAnimation, value: camera.videoRecording)
            .animation(AppTheme.popupAnimation, value: model.zoomDialVisible)
    }

    private func shootingModeButton(diameter: CGFloat) -> some View {
        Button {
            CameraHaptics.impact(.light)
            model.openShootingModes()
        } label: {
            ShootingModeButtonSymbol(symbol: model.shootingModeButtonSymbol)
                .rotatingCaptureContent().font(.system(size: 15, weight: .regular))
                .foregroundStyle(model.shootingModes || model.shootingSubmodeEnabled ? AppTheme.accent : .white)
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle().inset(by: -CameraControlLayout.buttonHitExpansion))
        }
        .accessibilityLabel("拍摄模式选项")
        .accessibilityValue(model.captureKind == .video ? (camera.dualCaptureEnabled ? "同步双拍已开启" : model.timeLapseEnabled ? "延时摄影已开启" : model.slowMotionEnabled ? "慢动作已开启" : model.cinematicVideoEnabled ? "电影模式已开启" : model.virtualApertureEnabled ? "虚拟光圈已开启" : "视频模式") : model.portraitModeEnabled ? "人像已开启" : model.burstModeEnabled ? "连拍已开启" : model.slowShutterEnabled ? "慢门已开启" : "照片模式")
        .disabled(camera.videoBusy)
        .recordingHidden(model.captureKind == .video && camera.videoRecording)
    }

    /// 视频滑块固定在入口正上方；拖动时暂停自动收起，松手后重新计时。
    private var videoVirtualApertureVerticalControl: some View {
        Slider(value: Binding(get: { model.virtualAperturePosition },
                              set: { model.virtualAperturePosition = $0 }),
               in: 0...1,
               onEditingChanged: {
                   model.setDepthControlEditing($0)
                   model.setFilterParameterEditing($0)
               })
            .tint(AppTheme.accent)
            .frame(width: 120, height: 28)
            .rotationEffect(.degrees(-90))
            .frame(width: 22, height: 120)
            .accessibilityLabel("虚拟光圈")
            .accessibilityValue(model.virtualApertureText)
            .accessibilityIdentifier("camera.video.virtualAperture.slider")
            .captureControlGeometry("videoVirtualApertureSlider", model: model)
            .onDisappear { model.setDepthControlEditing(false); model.setFilterParameterEditing(false) }
    }

    func videoApertureOverlay(diameter: CGFloat) -> some View {
        let button = Button { model.toggleVirtualApertureSlider() } label: {
            HStack(spacing: 1) {
                Text("ƒ")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                Text(model.virtualApertureText.replacingOccurrences(of: "ƒ/", with: ""))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .rotatingCaptureContent()
            .foregroundStyle(model.virtualApertureSliderVisible ? AppTheme.accent : .white)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("虚拟光圈调节")
        .accessibilityValue(model.virtualApertureText)
        .accessibilityIdentifier("camera.video.virtualAperture.control")
        .captureControlGeometry("videoVirtualApertureButton", model: model)

        return ZStack(alignment: .bottom) {
            if model.virtualApertureSliderVisible {
                Color.clear
                    .frame(width: 40, height: 120 + 16 + diameter + CameraControlLayout.upperButtonGap / 4)
                    .modifier(PreviewSurface(radius: 20, opacity: 0.16, curve: .circular, interactive: false))
                videoVirtualApertureVerticalControl
                    .padding(.bottom, diameter + CameraControlLayout.upperButtonGap / 4)
            }
            button
        }
        .frame(width: 40,
               height: model.virtualApertureSliderVisible
                   ? 120 + 16 + diameter + CameraControlLayout.upperButtonGap / 4
                   : 40,
               alignment: .bottom)
    }

    private func zoomDialLayer(size: CGSize) -> some View {
        let layout = CameraZoomDialLayout(size: size, ratio: model.ratio,
                                           openGatePortraitRatio: camera.openGatePortraitRatio)
        let preview = layout.preview, dialWidth = layout.dialWidth, top = layout.top
        return CameraZoomDial(value: camera.currentZoom, range: model.zoomRange)
            .frame(width: dialWidth, height: dialWidth + 12)
            .position(x: size.width / 2, y: top + (dialWidth + 12) / 2)
            .frame(width: size.width, height: size.height)
            .mask {
                RoundedRectangle(cornerRadius: 16).frame(width: preview.width, height: preview.height)
                    .position(x: preview.midX, y: preview.midY)
            }
    }

    private var albumPendingCount: Int {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-processing-badge") { return 3 }
        #endif
        return camera.pendingPhotoCount + library.pendingSaveCount + (library.videoSaving ? 1 : 0)
    }

    var shutterBar: some View {
        GeometryReader { geometry in
            captureButtonRow(size: min(52, max(44, (geometry.size.width - 40 - 76 - 24) / 4)))
        }.frame(height: 78)
    }

    private func captureButtonRow(size: CGFloat) -> some View {
        let recording = model.captureKind == .video && camera.videoRecording
        return HStack(spacing: 0) {
            Button { CameraHaptics.impact(.light); model.openLibrary() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                    // Only media rotates; the circular hit target and progress stay fixed.
                    Group {
                        if let image = gallery.albumButtonImage {
                            CaptureAlbumThumbnail(image: image)
                        } else { Image(systemName: "photo").foregroundStyle(.gray).rotatingCaptureContent() }
                    }
                    .frame(width: size, height: size)
                }.frame(width: size, height: size).clipShape(Circle()).modifier(GlassSurface(radius: size / 2))
                .overlay {
                    if albumPendingCount > 0 {
                        ProgressView().controlSize(.small).tint(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.48), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    let pending = albumPendingCount
                    if pending > 0 {
                        Text(String(pending)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(AppTheme.accentForeground).padding(.horizontal, 5).frame(minWidth: 19, minHeight: 19)
                            .background(AppTheme.accent, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
                            .offset(x: 4, y: -4).allowsHitTesting(false)
                    }
                }
            }.captureControlGeometry("album", model: model).disabled(camera.capturing || camera.pendingPhotoCount > 0 || camera.videoBusy || library.videoSaving)
                .accessibilityLabel(library.captureAwaitingReview ? "查看刚拍摄的照片" : "打开系统相册")
                .accessibilityValue("\(albumPendingCount) 张照片正在处理或保存")
                .recordingHidden(recording)
            Spacer(minLength: 0)
            bottomButton(model.captureKind == .video ? "video.fill" : "camera.fill",
                         label: model.captureKind == .video ? "切换到照片模式" : "切换到视频模式",
                         size: size, iconSize: 20) {
                model.requestCaptureKind(model.captureKind == .video ? .photo : .video)
            }.captureControlGeometry("functions", model: model)
                // 配置/子模式准备/快速切换期间点击也要立即反馈，必要时由模型排队执行。
                .disabled(camera.capturing || library.videoSaving)
                .recordingHidden(recording)
            Spacer(minLength: 0)
            Group {
                if model.captureKind == .photo && model.burstModeEnabled {
                    captureShutterFace
                        .frame(width: 76, height: 76)
                        .contentShape(Circle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in model.startBurstCapture() }
                            .onEnded { _ in model.stopBurstCapture() })
                        .accessibilityLabel("连拍快门")
                        .accessibilityHint("按住连续拍摄，松开停止")
                        .accessibilityAction { model.takePhoto() }
                } else {
                    Button {
                        CameraHaptics.impact(.medium)
                        if model.captureKind == .video { model.toggleVideoRecording() } else { model.takePhoto() }
                    } label: { captureShutterFace }
                        // 序列进行中再次点按是提前结束，不应被单帧原生捕获的忙碌状态阻挡。
                        .disabled(model.captureKind == .video ? !model.videoShutterEnabled :
                            (model.captureKindSwitching || model.slowShutterComposing || (model.slowShutterSequenceProgress == nil &&
                                (!camera.ready || camera.highResolutionPhotoConfiguring || camera.shutterBusy || !camera.hasCaptureCapacity(for: model.photoOptions) || !library.canAcceptNewCapture))))
                        .accessibilityLabel(model.captureKind == .video ? (camera.videoRecording ? "停止录像" : "开始录像")
                                            : model.slowShutterComposing ? "正在合成慢门"
                                            : model.slowShutterSequenceProgress == nil ? "拍照" : "结束慢门合成")
                }
            }
            .captureControlGeometry("shutter", model: model)
            Spacer(minLength: 0)
            let showsStyle = model.filtersEnabled || model.hdr || model.captureKind == .video
            Button { CameraHaptics.impact(.light); model.togglePanel(.film) } label: {
                let isLog = model.logVideoLUTControlsEnabled
                CameraFilterButtonLabel(
                    title: isLog ? (model.selectedLogLUTPreset?.title ?? "Log LUT")
                        : showsStyle ? model.style.filterButtonName : "RAW",
                    equipment: isLog ? model.selectedLogLUTPreset?.equipment
                        : showsStyle ? model.style.filterButtonEquipment : nil,
                    active: isLog ? model.selectedLogLUTPreset != nil : model.effectiveCaptureLook.style != .original,
                    size: size, dimmed: !model.filterControlsEnabled)
            }.captureControlGeometry("filter", model: model).disabled(!model.filterControlsEnabled || camera.videoBusy)
                .accessibilityLabel(model.logVideoLUTControlsEnabled ? "选择 Log 视频 LUT" : "选择滤镜")
                .accessibilityValue(model.logVideoLUTControlsEnabled ? (model.selectedLogLUTPreset?.displayName ?? "未选择 Log 滤镜")
                    : showsStyle ? model.style.title : model.captureKind == .video ? "当前视频色彩空间不支持滤镜" : "RAW，滤镜已禁用")
                .accessibilityHint(model.logVideoLUTControlsEnabled ? "Log/Log 2 LUT 始终作用于预览；打开烧录开关后写入成片并保留 Log 色彩标记"
                    : model.filterControlsEnabled ? "打开滤镜列表；SDR/P3 视频的滤镜会应用到预览和录制结果"
                    : model.captureKind == .video ? "视频滤镜仅支持 SDR 和 P3；HDR 与 RAW 保持原始输出" : "RAW 原始文件不应用滤镜")
                .recordingHidden(recording)
            Spacer(minLength: 0)
            Button {
                CameraHaptics.impact(.light)
                if !UIAccessibility.isReduceMotionEnabled {
                    withAnimation(.easeInOut(duration: 0.32)) { flipButtonRotation += 180 }
                } else {
                    flipButtonRotation += 180
                }
                model.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(flipButtonRotation))
                    .rotatingCaptureContent()
                    .opacity(model.oppositeLens == nil ? AppTheme.disabledControlOpacity : 1)
                    .frame(width: size, height: size)
                    .modifier(GlassSurface(radius: size / 2))
                    .contentShape(Circle())
            }.captureControlGeometry("flip", model: model)
                .disabled(!camera.ready || camera.capturing || camera.videoBusy || model.virtualApertureEnabled || model.oppositeLens == nil)
                .accessibilityLabel(model.currentPosition == .front ? "切换到后置镜头" : "切换到前置镜头")
                .recordingHidden(recording)
        }
        .padding(.horizontal, 20).padding(.top, 2)
        .animation(AppTheme.popupAnimation, value: recording)
    }

    private var captureShutterFace: some View {
        ZStack {
            Circle().stroke(model.burstCaptureActive ? AppTheme.accent : .white.opacity(0.85), lineWidth: model.burstCaptureActive ? 3 : 2).frame(width: 76, height: 76)
            Circle().fill(.ultraThinMaterial).frame(width: 70, height: 70)
            if model.captureKind == .video {
                RoundedRectangle(cornerRadius: camera.videoRecording ? 8 : 31)
                    .fill(.red).frame(width: camera.videoRecording ? 30 : 62, height: camera.videoRecording ? 30 : 62)
                if model.timeLapseEnabled, camera.videoRecording {
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(Double(camera.timeLapseCapturedFrames) * 360))
                        .animation(.linear(duration: max(0.12, model.timeLapseInterval.seconds)),
                                   value: camera.timeLapseCapturedFrames)
                        .allowsHitTesting(false)
                }
            } else {
                Circle().fill(camera.ready ? Color(white: 0.95) : Color.gray).frame(width: 62, height: 62)
                if model.slowShutterComposing {
                    ProgressView().tint(.black).frame(width: 30, height: 30).allowsHitTesting(false)
                } else if let progress = model.slowShutterSequenceProgress {
                    Text(progress.countdownText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.black).allowsHitTesting(false)
                }
            }
            if model.captureKind == .video && model.videoOpenGateEnabled && !camera.videoRecording {
                Text("Open\nGate").font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.black).multilineTextAlignment(.center)
                    .lineLimit(2).lineSpacing(-1).fixedSize()
                    .frame(width: 62, height: 62, alignment: .center)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            let hdrDirectBusy = model.captureKind == .photo && model.hdr && model.photoFormat == .heif
            if camera.recoveringSession || camera.highResolutionPhotoConfiguring || (model.captureKind == .video && model.videoShutterBusy)
                || (camera.shutterBusy && !hdrDirectBusy && !model.burstModeEnabled
                    && model.slowShutterSequenceProgress == nil && !model.slowShutterComposing) {
                ProgressView().tint(model.captureKind == .video ? .white : .black)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: camera.videoRecording)
        .animation(.easeInOut(duration: 0.15), value: model.burstCaptureActive)
    }

    func bottomButton(_ icon: String, label: String, active: Bool = false, size: CGFloat = 52, dimmed: Bool = false, iconSize: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button {
            CameraHaptics.impact(.light)
            action()
        } label: {
            Image(systemName: icon).rotatingCaptureContent().font(.system(size: iconSize ?? (size >= 50 ? 23 : 21)))
                .foregroundStyle(active ? AppTheme.accent : .white)
                .opacity(dimmed ? AppTheme.disabledControlOpacity : 1)
                .frame(width: size, height: size).modifier(GlassSurface(radius: size / 2))
                .contentShape(Circle())
        }.accessibilityLabel(label)
    }
}

extension View {
    func recordingHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

/// 独立所有权避免旧视图的onDisappear删除新视图位置，生产避让与测试几何共用。
private struct CaptureControlGeometryModifier: ViewModifier {
    let key: String
    let model: CameraViewModel
    @State private var owner = UUID()
    @State private var lastFrame: CGRect?
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            lastFrame = rect
            model.updateCaptureControlGeometry(key, owner: owner, rect: rect)
        }.onAppear {
            model.claimCaptureControlGeometry(key, owner: owner)
            if let lastFrame { model.updateCaptureControlGeometry(key, owner: owner, rect: lastFrame) }
        }.onDisappear { model.updateCaptureControlGeometry(key, owner: owner, rect: nil) }
    }
}

extension View {
    func captureControlGeometry(_ key: String, model: CameraViewModel) -> some View {
        modifier(CaptureControlGeometryModifier(key: key, model: model))
    }
}
