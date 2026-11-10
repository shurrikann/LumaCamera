import SwiftUI

struct DepthToolbarButtonAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension CameraView {
    var toolStrip: some View {
        VStack(spacing: 4) {
            if model.captureKind == .video {
                HStack(spacing: 0) {
                    // Open Gate 不显示分辨率，只在原位置显示当前帧率。
                    videoToolbarButton(model.videoOpenGateEnabled ? "\(model.videoFrameRateText) fps" : model.videoResolutionText,
                                       detail: model.videoOpenGateEnabled ? nil : "\(model.videoFrameRateText) fps",
                                       detailSize: 8, panel: .videoFormat, selected: model.toolbarPanel == .videoFormat,
                                       accessibility: model.videoOpenGateEnabled
                                           ? "视频帧率，\(model.videoFrameRateText) 帧"
                                           : "视频分辨率与帧率，\(model.videoResolutionText)，\(model.videoFrameRateText) 帧")
                    let ratioTitle = model.videoRatio.rawValue
                    let timeLapseSummary = model.timeLapseEnabled
                        ? "\(model.timeLapseInterval.title)·\(model.timeLapseFrameCount.title)张"
                        : nil
                    videoToolbarButton(ratioTitle, detail: timeLapseSummary,
                                       detailSize: 8, panel: .videoRatio,
                                       selected: model.toolbarPanel == .videoRatio,
                                       accessibility: "视频画面比例，\(model.videoRatio.rawValue)\(timeLapseSummary.map { "，延时 \($0)" } ?? "")\(model.videoOpenGateEnabled ? "，Open Gate 已开启" : "")")
                    videoToolbarButton(model.timeLapseEnabled ? videoColorSpaceTitle.replacingOccurrences(of: "\n", with: " ") : videoColorSpaceTitle,
                                       detail: model.timeLapseEnabled ? (model.selectedTimeLapsePreset?.title ?? "选择预设") : nil,
                                       panel: .videoColor, selected: model.toolbarPanel == .videoColor,
                                       accessibility: "视频色彩空间，\(model.videoColorSpace.rawValue)" + (model.timeLapseEnabled ? "，延时预设，\(model.selectedTimeLapsePreset?.title ?? "未选择")" : ""))
                        .accessibilityIdentifier("camera.toolbar.videoColor")
                        .captureControlGeometry("toolbar.videoColor", model: model)
                    videoToolbarButton(model.videoCodec.rawValue,
                                       detail: model.videoCodec == .proRes ? model.proResSpecification.rawValue : nil,
                                       detailSize: 8,
                                       panel: .videoCodec, selected: model.toolbarPanel == .videoCodec,
                                       accessibility: model.videoCodec == .proRes
                                           ? "视频格式，ProRes，\(model.proResSpecification.rawValue)"
                                           : "视频格式，\(model.videoCodec.rawValue)")
                    toolbarIcon("gearshape", label: "应用设置") { model.presentSettings() }
                        .contentShape(Rectangle())
                        .disabled(camera.videoBusy)
                }.frame(height: 32)
                // Photo mode reserves the page-indicator row below the toolbar.
                // Keep the same total height so video uses the identical layout.
                Color.clear.frame(height: 7)
            } else {
            TabView(selection: Binding(get: { model.toolPage }, set: { model.updateToolPageFromPager($0) })) {
                HStack(spacing: 0) {
                    Button { model.toggleToolbarPanel(.format) } label: {
                        VStack(spacing: 1) {
                            if model.photoFormat == .heifPro {
                                // HEIF Pro 在横竖屏都分两行，随工具栏内容一起旋转。
                                Text("HEIF\nPro")
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineSpacing(-2)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            } else {
                                Text(model.photoFormat.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            if model.photoFormat != .heifPro {
                                Text("\(model.photoResolution.rawValue)MP").font(.system(size: 8, weight: .medium)).opacity(0.7)
                            }
                        }.foregroundStyle(model.toolbarPanel == .format ? AppTheme.accent : .white)
                            .rotatingCaptureContent().frame(maxWidth: .infinity).frame(height: 32)
                    }.buttonStyle(.plain).accessibilityLabel(model.photoFormat == .heifPro ? "图片格式，HEIF Pro" : "图片格式与像素")
                        .accessibilityIdentifier("camera.toolbar.photoFormat")
                        .captureControlGeometry("toolbar.format", model: model)
                    Button { model.toggleToolbarPanel(.ratio) } label: {
                        Text(model.ratio.rawValue).rotatingCaptureContent().font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                            .foregroundStyle(model.toolbarPanel == .ratio ? AppTheme.accent : .white)
                    }.buttonStyle(.plain).accessibilityLabel("画面比例").accessibilityValue(model.ratio.rawValue)
                        .captureControlGeometry("toolbar.ratio", model: model)
                    toolbarIcon(model.flashMode.icon, label: "闪光灯，\(model.flashMode.rawValue)", active: model.flashMode != .off) { model.flashMode = model.flashMode.next }
                        .opacity(camera.supportsFlash || camera.demo ? 1 : AppTheme.disabledControlOpacity)
                        .captureControlGeometry("toolbar.flash", model: model)
                    if model.slowShutterEnabled {
                        Button {
                            guard model.canEditSlowShutterDuration else { return }
                            model.toggleToolbarPanel(.slowShutterDuration)
                        } label: {
                            VStack(spacing: 1) {
                                Text(model.mode == .auto ? (model.selectedSlowShutterPreset?.title.replacingOccurrences(of: "\n", with: "") ?? "选择预设") : "慢门")
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                Text(model.slowShutterDuration.title)
                                    .font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .foregroundStyle(model.selectedSlowShutterPreset != nil ? AppTheme.accent : .white)
                            .rotatingCaptureContent()
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        // 拍摄中只阻断点击，不进入系统禁用态，避免文字被压暗。
                        .allowsHitTesting(model.canEditSlowShutterDuration)
                        .accessibilityHint(model.canEditSlowShutterDuration ? "打开慢门预设与时长选择" : "拍摄中不可修改")
                        .accessibilityLabel("慢门预设与时长，\(model.selectedSlowShutterPreset?.title.replacingOccurrences(of: "\n", with: "") ?? "未选择预设")，\(model.slowShutterDuration.title)")
                        .accessibilityIdentifier("camera.toolbar.slowShutterPresetDuration")
                        .captureControlGeometry("toolbar.slowShutterPresetDuration", model: model)
                    } else if model.virtualApertureEnabled {
                        Button { model.toggleVirtualApertureSlider() } label: {
                            VStack(spacing: 0) {
                                Image(systemName: "camera.aperture")
                                    .font(.system(size: 15, weight: .regular))
                                Text(model.virtualApertureText.replacingOccurrences(of: "ƒ/", with: ""))
                                    .font(.system(size: 7, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                            }
                            .rotatingCaptureContent()
                            .foregroundStyle(model.virtualApertureSliderVisible ? AppTheme.accent : .white)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("虚拟光圈调节")
                        .accessibilityValue(model.virtualApertureText)
                        .accessibilityIdentifier("camera.toolbar.virtualAperture")
                        .captureControlGeometry("toolbar.depthControl", model: model)
                        .anchorPreference(key: DepthToolbarButtonAnchorKey.self, value: .bounds) { ["button": $0] }
                    } else if model.portraitModeEnabled {
                        Button { model.togglePortraitDepthSlider() } label: {
                            VStack(spacing: 0) {
                                Text("ƒ")
                                    .font(.system(size: 17, weight: .medium, design: .serif))
                                Text("\(Int((model.portraitBlurStrength * 100).rounded()))%")
                                    .font(.system(size: 7, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                            }
                            .rotatingCaptureContent()
                            .foregroundStyle(model.portraitDepthSliderVisible ? AppTheme.accent : .white)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("景深调节")
                        .accessibilityValue(model.portraitDepthSliderVisible ? "已显示" : "已收起")
                        .accessibilityIdentifier("camera.toolbar.portraitDepth")
                        .captureControlGeometry("toolbar.depthControl", model: model)
                        .anchorPreference(key: DepthToolbarButtonAnchorKey.self, value: .bounds) { ["button": $0] }
                    } else if model.burstModeEnabled {
                        VStack(spacing: 0) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 12, weight: .regular))
                            Text("\(model.burstCaptureCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .rotatingCaptureContent()
                        .foregroundStyle(model.burstCaptureActive ? AppTheme.accent : .white)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .accessibilityLabel("连拍张数")
                        .accessibilityValue("\(model.burstCaptureCount)")
                        .captureControlGeometry("toolbar.burstCount", model: model)
                    } else if model.proToneReplacesLiveButton {
                        Button { model.toggleToolbarPanel(.tone) } label: {
                            VStack(spacing: 1) {
                                ToneCurveSymbol().stroke(lineWidth: 1.4)
                                    .frame(width: 17, height: 14)
                                Text("PRO").font(.system(size: 6, weight: .semibold, design: .rounded))
                            }
                            .rotatingCaptureContent()
                            .foregroundStyle(model.toolbarPanel == .tone || model.tone != .natural ? AppTheme.accent : .white)
                            .frame(maxWidth: .infinity).frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .opacity(model.isPreparingSubmode ? AppTheme.disabledControlOpacity : 1)
                        .disabled(model.isPreparingSubmode)
                        .accessibilityLabel("Pro 影调")
                        .accessibilityValue(model.tone.rawValue)
                        .captureControlGeometry("toolbar.proTone", model: model)
                    } else {
                        toolbarIcon(model.livePhotoEnabled ? "livephoto" : "livephoto.slash", label: "Live 实况照片", active: model.capturesLivePhoto, feedback: false) { model.toggleLivePhoto() }
                            .accessibilityValue(model.livePhotoEnabled ? (model.capturesLivePhoto ? "已触发" : "已开启，当前不可用") : "已关闭")
                            .opacity(model.canToggleLivePhoto ? 1 : AppTheme.disabledControlOpacity)
                            .disabled(!model.canToggleLivePhoto)
                            .captureControlGeometry("toolbar.live", model: model)
                    }
                    toolbarIcon("gearshape", label: "应用设置") { model.presentSettings() }
                        .captureControlGeometry("toolbar.settings", model: model)
                }
                .tag(0)
                HStack(spacing: 0) {
                    readout("S", value: camera.readings.map { model.shutterText($0.seconds) } ?? "—")
                    readout("ISO", value: camera.readings.map { CameraNumericText.integer($0.iso) } ?? "—")
                    readout(model.usesGlobalMeteringReadout ? "总EV" : "EV", value: String(format: "%+.1f", model.displayedExposureBias))
                    readout("WB", value: camera.readings.map { CameraNumericText.integer($0.kelvin) == "—" ? "—" : CameraNumericText.integer($0.kelvin) + "K" } ?? "—")
                    readout("FOCUS", value: camera.readings.map { String(format: "%.2f", $0.focus) } ?? "—")
                }.tag(1)
            }.buttonStyle(.plain).tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 32)
                .accessibilityLabel("顶部工具与拍摄参数，可左右滑动")
            HStack(spacing: 4) {
                ForEach(0..<2) { index in
                    Capsule().fill(model.toolPage == index ? .white.opacity(0.7) : .white.opacity(0.2))
                        .frame(width: model.toolPage == index ? 12 : 5, height: 3)
                }
            }
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 5)
        .padding(.horizontal, 14)
        // Consume otherwise-empty toolbar taps so they can’t fall through to the
        // preview’s high-priority focus gesture. Keep the hit surface visually clear.
        .background {
            Rectangle().fill(Color.black.opacity(0.001)).contentShape(Rectangle())
                .onTapGesture { }
        }
        .transformAnchorPreference(key: DepthToolbarButtonAnchorKey.self, value: .bounds) { anchors, toolbar in
            anchors["toolbar"] = toolbar
        }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.toolbarFrameForTesting = $0 }
        #endif
    }

    /// 滑条打开后首次定位就冻结；旋转、画幅重排都沿用同一绝对位置。
    private func depthControlCenterY(bounds: CGRect, proxy: GeometryProxy) -> CGFloat {
        let overlayOriginY = proxy.frame(in: .global).minY
        let landscape = abs(sin(controlAngle * .pi / 180)) > 0.5
        // 横屏只读竖屏冻结位置；竖屏必须持续跟随直方图中线，
        // 不能在直方图尚未布局时用 fallback 位置把错误值冻结下来。
        if landscape, let frozenMidY = depthControlPortraitMidY {
            return frozenMidY - overlayOriginY
        }
        let hasHistogram = model.showHistogram
            && model.histogramFrame.width > 0 && model.histogramFrame.height > 0
        if hasHistogram { return model.histogramFrame.midY - overlayOriginY }
        if let frozenMidY = depthControlPortraitMidY { return frozenMidY - overlayOriginY }
        return bounds.maxY + 36
    }

    /// 浮层属于完整相机区域，保留工具栏外的绘制及触摸范围。
    func depthControlOverlay(anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ZStack {
                if model.depthControlPopupVisible,
                   let button = anchors["button"], let toolbar = anchors["toolbar"] {
                    let bounds = proxy[toolbar]
                    let center = min(max(proxy[button].midX, bounds.minX + 109), bounds.maxX - 109)
                    Group {
                        if model.virtualApertureEnabled { virtualApertureControl }
                        else { portraitDepthControl }
                    }
                    .frame(width: 190, height: 32)
                    .fixedSize()
                    .captureControlGeometry("depthControlPopup", model: model)
                    .position(x: center, y: depthControlCenterY(bounds: bounds, proxy: proxy))
                    .transition(.opacity)
                }
            }
            .onChange(of: model.depthControlPopupVisible) { _, visible in
                if !visible { depthControlPortraitMidY = nil }
                else if abs(sin(controlAngle * .pi / 180)) <= 0.5,
                        model.histogramFrame.width > 0 {
                    depthControlPortraitMidY = model.histogramFrame.midY
                }
            }
            // 只从竖屏直方图更新冻结值；横屏旋转时的几何回调不能覆盖它。
            .onChange(of: model.histogramFrame) { _, frame in
                guard model.depthControlPopupVisible,
                      abs(sin(controlAngle * .pi / 180)) <= 0.5,
                      frame.width > 0, frame.height > 0 else { return }
                depthControlPortraitMidY = frame.midY
            }
            .onChange(of: model.ratio) { _, _ in
                guard model.depthControlPopupVisible,
                      abs(sin(controlAngle * .pi / 180)) <= 0.5,
                      model.histogramFrame.width > 0 else { return }
                depthControlPortraitMidY = model.histogramFrame.midY
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.2), value: model.depthControlPopupVisible)
        }
    }

    func toolbarIcon(_ icon: String, label: String, active: Bool = false, feedback: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            if feedback { CameraHaptics.impact(.light) }
            action()
        } label: {
            Image(systemName: icon).rotatingCaptureContent().font(.system(size: 15, weight: .regular))
                .foregroundStyle(active ? AppTheme.accent : .white).frame(maxWidth: .infinity).frame(height: 32)
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(active ? "开启" : "关闭")
    }

    func readout(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 9, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
        }.rotatingCaptureContent().frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sliderSurface: some View {
        if #available(iOS 26.0, *) {
            PopupGlassBackground(shape: Capsule())
        } else {
            Capsule().fill(.black.opacity(0.28))
        }
    }

    var virtualApertureControl: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { model.virtualAperturePosition },
                                  set: { model.virtualAperturePosition = $0 }),
                   in: 0...1,
                   onEditingChanged: {
                       model.setFilterParameterEditing($0)
                       model.setDepthControlEditing($0)
                   })
                .tint(AppTheme.accent)
                .frame(height: 22)
                .accessibilityLabel("虚拟光圈")
                .accessibilityValue(model.virtualApertureText)
                .accessibilityIdentifier("camera.virtualAperture.slider")
            Button {
                CameraHaptics.impact(.light)
                model.virtualAperture = VirtualApertureRenderer.defaultValue
            } label: {
                Text(model.virtualApertureText)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 38, height: 32, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复默认虚拟光圈")
            .accessibilityValue(model.virtualApertureText)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background { sliderSurface }
        .onDisappear { model.setFilterParameterEditing(false); model.setDepthControlEditing(false) }
        .accessibilityElement(children: .contain)
    }

    var portraitDepthControl: some View {
        HStack(spacing: 8) {
            Slider(value: $model.portraitBlurStrength, in: 0...1,
                   onEditingChanged: { model.setDepthControlEditing($0) })
                .tint(AppTheme.accent)
                .frame(height: 22)
                .accessibilityLabel("背景虚化强度")
                .accessibilityValue("\(Int(model.portraitBlurStrength * 100))%")
                .accessibilityIdentifier("camera.portrait.depth.slider")
            Button {
                CameraHaptics.impact(.light)
                model.portraitBlurStrength = 0.5
            } label: {
                Text("\(Int((model.portraitBlurStrength * 100).rounded()))%")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 32, height: 32, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复默认人像虚化")
            .accessibilityValue("\(Int((model.portraitBlurStrength * 100).rounded()))%")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background { sliderSurface }
        .onDisappear { model.setDepthControlEditing(false) }
        .accessibilityElement(children: .contain)
    }

    private var videoColorSpaceTitle: String {
        switch model.videoColorSpace {
        case .appleLog: "Apple\nLog"
        case .appleLog2: "Apple\nLog 2"
        default: model.videoColorSpace.rawValue
        }
    }

    private func videoToolbarButton(_ value: String, detail: String? = nil, detailSize: CGFloat = 8,
                                    panel: CameraToolbarPanel, selected: Bool = false, accessibility: String) -> some View {
        Button { model.toggleToolbarPanel(panel) } label: {
            VStack(spacing: 1) {
                Text(value).font(.system(size: 9, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                if let detail {
                    Text(detail).font(.system(size: detailSize, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.75)
                }
            }
            .foregroundStyle(selected ? AppTheme.accent : .white)
            .rotatingCaptureContent()
            .frame(maxWidth: .infinity).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.videoBusy)
        .accessibilityLabel(accessibility)
    }
}

private struct ToneCurveSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.width * 0.16, y: rect.height * 0.84)
        let end = CGPoint(x: rect.width * 0.84, y: rect.height * 0.16)
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: rect.width * 0.72, y: rect.height * 0.85), control2: CGPoint(x: rect.width * 0.27, y: rect.height * 0.15))
        for point in [start, end] { path.addEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) }
        return path
    }
}
