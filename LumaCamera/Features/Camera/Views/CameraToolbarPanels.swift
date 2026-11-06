import SwiftUI
import CoreImage

extension CameraView {
    var toolbarOptionsPanel: some View {
        toolbarOptionsPanel(availableWidth: 374)
    }
    func toolbarOptionsPanel(availableWidth: CGFloat, reducingMotion: Bool = UIAccessibility.isReduceMotionEnabled) -> some View {
        let contentWidth = max(1, availableWidth - 32)
        // 顶部弹窗共用可用宽度；选项数量变化时只留下空白，不改变弹窗宽度。
        let panelWidth = max(1, availableWidth)
        @ViewBuilder func content() -> some View {
            VStack(alignment: .leading, spacing: 24) {
                switch model.toolbarPanel {
                case .format: formatOptions(contentWidth: contentWidth)
                case .ratio: ratioOptions
                case .tone: toneOptions
                case .videoFormat: videoFormatOptions(contentWidth: contentWidth)
                case .videoRatio: videoRatioOptions(contentWidth: contentWidth)
                case .videoColor: videoColorOptions(contentWidth: contentWidth)
                case .videoCodec: videoCodecOptions(contentWidth: contentWidth)
                case .slowShutterDuration: slowShutterDurationOptions(contentWidth: contentWidth)
                case nil: EmptyView()
                }
            }
            // 即使只有一个选项，内容也从弹窗左侧内边距开始排列。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        return Group {
            if model.toolbarPanel == .format {
                // 照片文件格式随说明文字和 HEIF Pro 状态变化；高度由内容决定，
                // 上下保留 16pt，不用固定 maxHeight/ScrollView 拉伸或裁切。
                content()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(width: panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    content().padding(16).padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: panelWidth)
                .frame(maxHeight: toolbarPanelMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(PopupSurface(radius: 28, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
        .captureControlGeometry("videoOptionsPanel", model: model)
    }

    private var toolbarPanelMaxHeight: CGFloat {
        switch model.toolbarPanel {
        case .format: return 360
        case .tone, .videoFormat, .videoCodec: return 390
        case .videoColor: return 300
        case .videoRatio: return model.timeLapseEnabled ? 380 : 190
        case .slowShutterDuration: return 220
        default: return 190
        }
    }

    private func formatOptions(contentWidth: CGFloat) -> some View {
        // 第一行五个格式按钮等分宽度；HEIF Pro 使用同一列宽，不能固定成更宽的按钮。
        let formatColumnWidth = max(1, (contentWidth - 32) / 5)
        return VStack(alignment: .leading, spacing: 12) {
            panelHeading("分辨率")
            HStack(spacing: 10) {
                ForEach(PhotoResolution.allCases) { resolution in
                    choicePill(resolution.title, selected: model.photoResolution == resolution, enabled: model.canSelectPhotoResolution(resolution)) { model.photoResolution = resolution }
                        .frame(width: 70)
                        .accessibilityIdentifier("format.resolution.\(resolution.rawValue)")
                        .captureControlGeometry("format.resolution.\(resolution.rawValue)", model: model)
                }
                Spacer()
            }
            panelHeading("文件格式")
            HStack(spacing: 8) {
                ForEach(PhotoFileFormat.allCases.filter { $0 != .heifPro }) { format in
                    choicePill(format.rawValue, selected: model.photoFormat == format, enabled: model.canSelectPhotoFormat(format)) {
                        model.photoFormat = format; if format != .heifPro && format != .heif { model.hdr = false }
                    }
                    .captureControlGeometry("format.option." + format.rawValue, model: model)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                choicePill("HEIF Pro", selected: model.photoFormat == .heifPro, enabled: model.canSelectPhotoFormat(.heifPro)) {
                    model.photoFormat = .heifPro
                }
                .frame(width: formatColumnWidth)
                .captureControlGeometry("format.heifPro", model: model)
                Text("通过 RAW 格式转换 HEIF，保留更多细节并降低锐化，支持 Pro 影调。")
                    .font(.system(size: 9))
                    .lineSpacing(1)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("camera.format.heifPro.explanation")
                if model.photoFormat == .heifPro {
                    choicePill("Pro 影调", selected: false, enabled: !model.isPreparingSubmode) {
                        // choicePill 已提供触感和淡入淡出；格式浮层已完成其他弹窗收起。
                        model.toolbarPanel = .tone
                    }
                    .frame(width: formatColumnWidth)
                    .accessibilityIdentifier("camera.format.proTone")
                    .captureControlGeometry("format.proTone", model: model)
                }
            }
            if model.photoFormat != .heifPro, let formatExplanation {
                Text(formatExplanation).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ZStack(alignment: .trailing) {
                        Text("HDR").font(.system(size: 12))
                        if camera.hdrPreviewConfiguring {
                            ProgressView().controlSize(.mini).tint(AppTheme.accent)
                                .offset(x: 20).transition(.opacity)
                        }
                    }
                    Toggle("HDR", isOn: $model.hdr).labelsHidden().tint(AppTheme.accent)
                        .disabled(camera.hdrPreviewConfiguring || model.isPreparingSubmode || model.burstModeEnabled || model.nightModeEnabled || model.portraitModeEnabled || (model.photoFormat != .heifPro && model.photoFormat != .heif) || model.border || (model.photoFormat == .heif && !model.hdr && !camera.supportsHEIFHDR))
                        .captureControlGeometry("format.hdr",model:model)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("10-bit HEIF").font(.system(size: 9))
                        Text("HDR不支持滤镜").font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("camera.hdr.previewNotice")
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                HStack(spacing: 6) {
                    Text("高动态").font(.system(size: 12))
                    Toggle("高动态",isOn:Binding(get:{ model.adaptiveHighDynamic },set:{ model.setAdaptiveHighDynamic($0) }))
                        .labelsHidden().tint(AppTheme.accent)
                        .disabled(!model.adaptiveHighDynamicAvailable)
                        .accessibilityIdentifier("camera.format.adaptiveHighDynamic")
                        .captureControlGeometry("format.highDynamic",model:model)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 12) {
                Text("普通 HEIF Pro 下自适应平衡亮暗，保留 DNG 底片供重新显影；与 HDR 独立，效果在成片中呈现。")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("camera.format.adaptiveHighDynamic.explanation")
                    .captureControlGeometry("format.highDynamic.explanation",model:model)
            }
        }
    }
    private var formatExplanation: String? {
        switch model.photoFormat {
        case .heifPro: return "通过 RAW 格式转换 HEIF，保留更多细节和降低锐化，并支持 Pro 影调。"
        case .heif: return nil
        case .raw: return "保留原始 DNG，禁用滤镜；影调、画幅和边框仅用于预览，DNG 保留完整传感器画面。"
        case .rawJPEG: return "同时保存 DNG 和 JPG；滤镜应用于 JPG 及其预览，DNG 原始数据保持不变。"
        default: return "滤镜、影调、画幅和边框直接写入所选格式。HEIF 和 JPG 为压缩格式，TIFF 为 16-bit 输出。"
        }
    }
    private var ratioOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeading("画面比例")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), alignment: .leading, spacing: 10) {
                ForEach(FrameRatio.photoOptions, id: \.self) { ratio in
                    choicePill(ratio.rawValue, selected: model.ratio == ratio) { model.selectRatio(ratio) }
                }
            }
        }.padding(.bottom, 8)
    }
    private var toneOptions: some View {
        VStack(spacing: 12) {
            panelHeading("Pro 影调")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                ForEach(PhotoTone.allCases) { tone in
                    Button { model.tone = tone } label: {
                        VStack(spacing: 7) {
                            Group {
                                if let image = TonePreviewCache.images[tone] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else { Color.white.opacity(0.08) }
                            }.frame(height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(tone.rawValue).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(model.tone == tone ? AppTheme.accent : .white)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.padding(6).frame(maxWidth: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.tone == tone ? AppTheme.accent : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }
            Divider().overlay(.white.opacity(0.15))
            panelHeading("测光")
            HStack(spacing: 16) {
                ForEach(CameraMetering.allCases) { metering in
                    Button { model.metering = metering } label: {
                        VStack(spacing: 8) {
                            Image(systemName: metering.icon).font(.system(size: 20, weight: .light))
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .background(model.metering == metering ? AppTheme.accent.opacity(0.7) : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            Text(metering.rawValue).font(.system(size: 12, weight: .medium))
                        }
                    }.buttonStyle(.plain)
                }
            }

        }
    }

    private func videoFormatOptions(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.videoOpenGateEnabled {
                panelHeading(model.slowMotionEnabled ? "采集分辨率" : "分辨率")
                HStack(spacing: 10) {
                    ForEach(model.videoResolutionOptions) { resolution in
                        choicePill(resolution.title, selected: model.videoResolution == resolution) { model.selectVideoResolution(resolution) }
                            .frame(width: 70, height: 32)
                            .captureControlGeometry("videoResolution.\(resolution.rawValue)", model: model)
                            .disabled(model.camera.videoBusy || !model.supportsVideoResolution(resolution))
                    }
                    Spacer()
                }
            }
            panelHeading(model.slowMotionEnabled ? "采集帧率" : "帧率")
            HStack(spacing: model.slowMotionEnabled ? 10 : 8) {
                // 慢动作采集能力仍按最高帧率优先供策略选择；界面先显示更高的 240 fps，再显示 120 fps。
                ForEach(model.videoFrameRateOptions) { rate in
                    let selectedRate = model.slowMotionEnabled ? model.slowMotionCaptureFrameRateForSelection : model.videoFrameRate
                    choicePill("\(rate.rawValue) fps", selected: selectedRate == rate) { model.selectVideoFrameRate(rate) }
                        // 慢动作采集帧率按钮与上方分辨率按钮同为 70×32 pt，禁止横向拉伸。
                        .frame(width: model.slowMotionEnabled ? 70 : (contentWidth - 40) / 6, height: 32)
                        .captureControlGeometry("videoRate.\(rate.rawValue)", model: model)
                        .disabled(model.camera.videoBusy || !model.supportsVideoFrameRate(rate))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func videoRatioOptions(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeading("画面比例")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed((contentWidth - 32) / 5), spacing: 8), count: 5), alignment: .leading, spacing: 10) {
                ForEach(VideoRatio.aspectOptions) { ratio in
                    if model.videoRatioOptions.contains(ratio) {
                        choicePill(ratio.rawValue, selected: model.videoRatio == ratio) {
                            model.selectVideoRatio(ratio)
                        }
                        .disabled(!model.supportsVideoRatio(ratio))
                    } else {
                        // Open Gate hides unsupported ratios, but keeps the five-column
                        // grid and popup geometry unchanged.
                        Color.clear
                            .frame(height: 32)
                            .accessibilityHidden(true)
                    }
                }
            }
            if model.timeLapseEnabled {
                Divider().overlay(.white.opacity(0.15))
                panelHeading("拍摄间隔")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                          alignment: .leading, spacing: 10) {
                    ForEach(TimeLapseInterval.allCases) { interval in
                        choicePill(interval.title, selected: model.timeLapseInterval == interval,
                                   enabled: !camera.videoBusy) { model.selectTimeLapseInterval(interval) }
                    }
                }
                panelHeading("拍摄张数")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                          alignment: .leading, spacing: 10) {
                    ForEach(TimeLapseFrameCount.allCases) { count in
                        choicePill(count.title, selected: model.timeLapseFrameCount == count,
                                   enabled: !camera.videoBusy) { model.selectTimeLapseFrameCount(count) }
                    }
                }
            }
            if model.videoOpenGateAvailable || model.videoOpenGateEnabled {
            HStack(spacing: 8) {
                Text("Open Gate").font(.system(size: 11, weight: .medium))
                Toggle("Open Gate", isOn: Binding(
                    get: { model.videoOpenGateEnabled },
                    set: { model.setVideoOpenGateEnabled($0) }
                ))
                .labelsHidden()
                .tint(AppTheme.accent)
                .disabled(camera.videoBusy || (!model.videoOpenGateEnabled
                    && (!model.supportsVideoOpenGate || !model.videoOpenGateRatioSupported)))
                .accessibilityLabel("Open Gate")
                .accessibilityValue(model.videoOpenGateEnabled ? "已开启" : "已关闭")
                .accessibilityIdentifier("camera.video.openGate")
                Button {
                                        withAnimation(AppTheme.popupAnimation) { openGateInfoVisible = true }
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Gate 说明")
                .accessibilityIdentifier("camera.video.openGate.info")
            }
            }
        }.padding(.bottom, 8)
    }

    private func videoColorOptions(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeading("色彩空间")
            HStack(spacing: 8) {
                ForEach(model.videoColorSpaceOptions) { space in
                    let title = space == .appleLog ? "Apple\nLog" : space == .appleLog2 ? "Apple\nLog 2" : space.rawValue
                    choicePill(title, selected: model.videoColorSpace == space, lines: 2) { model.videoColorSpace = space }
                        .frame(width: (contentWidth - 32) / 5)
                        .disabled(camera.videoBusy || !model.supportsVideoColorSpace(space))
                        .accessibilityLabel(space.rawValue)
                        .captureControlGeometry("videoColor.\(space.rawValue)", model: model)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.timeLapseEnabled {
                panelHeading("延时预设")
                HStack(spacing: 8) {
                    ForEach(TimeLapsePreset.allCases) { preset in
                        choicePill(preset.title, selected: model.selectedTimeLapsePreset == preset,
                                   enabled: !camera.videoBusy, feedback: false) { model.selectTimeLapsePreset(preset) }
                            .frame(width: (contentWidth - 32) / 5)
                            .accessibilityLabel("\(preset.title)，\(preset.intervalDescription)取一帧")
                            .accessibilityIdentifier("camera.timeLapse.preset.\(preset.rawValue)")
                            .captureControlGeometry("timeLapsePreset.\(preset.rawValue)", model: model)
                    }
                }
                .captureControlGeometry("timeLapsePresetRow", model: model)
            }
        }.padding(.bottom, 8)
    }

    private func videoCodecOptions(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeading("视频格式")
            HStack(spacing: 8) {
                ForEach(model.videoCodecOptions) { codec in
                    choicePill(codec.rawValue, selected: model.videoCodec == codec) { model.videoCodec = codec }
                        .frame(width: (contentWidth - 16) / 3)
                        .disabled(!model.supportsVideoCodec(codec))
                        .captureControlGeometry("videoCodec.\(codec.rawValue)", model: model)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !model.proResSpecificationOptions.isEmpty {
            panelHeading("ProRes 规格")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed((contentWidth - 16) / 3), spacing: 8), count: min(3, model.proResSpecificationOptions.count)), alignment: .leading, spacing: 10) {
                ForEach(model.proResSpecificationOptions) { spec in
                    choicePill(spec.rawValue, selected: model.proResSpecification == spec) {
                        model.selectProResSpecification(spec)
                    }
                    .disabled(!model.canSelectProRes(spec))
                    .accessibilityHint(!spec.isSelectable ? "需要已授权的合规外接存储及支持 RAW 的镜头" : model.videoCodec == .proRes ? "" : "先选择 ProRes 视频格式")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.bottom, 8)
    }
    private func slowShutterDurationOptions(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.mode == .auto {
                panelHeading("慢门预设")
                HStack(spacing: 8) {
                    ForEach(SlowShutterPreset.allCases) { preset in
                        choicePill(preset.title, selected: model.selectedSlowShutterPreset == preset,
                                   enabled: model.canEditSlowShutterDuration && model.isSlowShutterPresetSupported(preset),
                                   lines: 2, feedback: false) { model.selectSlowShutterPreset(preset) }
                            .frame(width: (contentWidth - 32) / 5)
                            .accessibilityLabel(preset.title.replacingOccurrences(of: "\n", with: ""))
                            .accessibilityHint(slowPresetHint(preset))
                            .accessibilityIdentifier("camera.slowShutter.preset.\(preset.rawValue)")
                            .captureControlGeometry("slowShutterPreset.\(preset.rawValue)", model: model)
                    }
                }
                .captureControlGeometry("slowShutterPresetRow", model: model)
            }
            panelHeading("拍摄时长")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed((contentWidth - 32) / 5), spacing: 8), count: 5), spacing: 10) {
                ForEach(model.availableSlowShutterDurations) { duration in
                    choicePill(duration.title, selected: model.slowShutterDuration == duration,
                               enabled: model.canEditSlowShutterDuration, feedback: false) {
                        model.selectSlowShutterDuration(duration)
                    }
                    .frame(maxWidth: .infinity)
                    .captureControlGeometry("slowShutterDuration.\(duration.rawValue)", model: model)
                }
            }
        }
    }

    private func slowPresetHint(_ preset: SlowShutterPreset) -> String {
        guard model.isSlowShutterPresetSupported(preset) else { return "当前镜头或格式不支持该慢门预设" }
        switch preset {
        case .lightTrails: return "按环境自适应曝光，亮部叠加；再次点快门可提前结束"
        case .silkyWater: return "手持帧间对齐平均，融合流水轨迹"
        case .motionBlur: return "多帧平均融合运动轨迹"
        case .panning: return "跟随移动主体并保持在画面中央，对齐融合"
        case .starTrails: return "对准夜空积累星轨，再次点快门可提前结束"
        }
    }

    private func panelHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
    }
    private func choicePill(_ title: String, selected: Bool, enabled: Bool = true, lines: Int = 1, feedback: Bool = true, action: @escaping () -> Void) -> some View {
        Button {

            withAnimation(AppTheme.popupAnimation) { action() }
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.center).lineLimit(lines)
                .minimumScaleFactor(0.7).frame(maxWidth: .infinity).frame(minHeight: 32)
                .foregroundStyle(selected ? .black.opacity(enabled ? 1 : 0.55) : .white.opacity(enabled ? 0.95 : 0.55))
                .background(selected ? AppTheme.accent.opacity(enabled ? 1 : 0.7) : Color.white.opacity(enabled ? 0.18 : 0.10), in: Capsule())
        }.buttonStyle(.plain).disabled(!enabled || camera.capturing).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OpenGateInformationDialog: View {
    let specsSummary: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Open Gate").font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8)).frame(width: 30, height: 30)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭说明")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("支持比例：4:3、1:1")
                    Text("格式：HEVC")
                    Text("输出当前镜头的完整采集尺寸；1:1 裁切为正方形。")
                    Text(specsSummary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("camera.video.openGate.supportedSpecs")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(22)
            .frame(maxWidth: 460, alignment: .leading)
            .background { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
            .padding(24)
            .accessibilityIdentifier("camera.video.openGate.infoDialog")
        }
    }
}

private enum TonePreviewCache {
    static let images: [PhotoTone: UIImage] = {
        let context = CIContext()
        guard let photo = UIImage(named: "FilterLandscape"), let source = CIImage(image: photo) else { return [:] }
        let crop = source.transformed(by: CGAffineTransform(scaleX: 270 / source.extent.width, y: 270 / source.extent.height))
        return Dictionary(uniqueKeysWithValues: PhotoTone.allCases.compactMap { tone in
            let image = tone.apply(to: crop)
            guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
            return (tone, UIImage(cgImage: cg))
        })
    }()
}
