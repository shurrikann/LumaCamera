import SwiftUI
import AVFoundation

extension CameraView {
    var settingsView: some View { CameraSettingsPanel(model: model) }
}

private struct CameraSettingsPanel: View {
    @ObservedObject var model: CameraViewModel
    @State private var editingCopyright = false
    @State private var copyrightDraft = ""
    @State private var settingExplanation: SettingExplanation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Menu {
                            Picker("", selection: $model.preferences.videoBitratePreset) {
                                ForEach(VideoBitratePreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .labelsHidden()
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.preferences.videoBitratePreset.rawValue)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(model.preferences.videoBitratePreset == .systemDefault ? .white : AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.videoBitrate")
                        .captureControlGeometry("settings.videoBitrate", model: model)
                    } label: { settingTitleWithInfo("视频码率", message: videoBitrateHelpText) }
                    LabeledContent {
                        Menu {
                            ForEach(VideoStabilizationPreference.allCases) { option in
                                Button {
                                    model.preferences.videoStabilization = option
                                } label: {
                                    if model.preferences.videoStabilization == option {
                                        Label(option.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(option.rawValue)
                                    }
                                }
                                .disabled(!model.isVideoStabilizationAvailable(option))
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.preferences.videoStabilization.rawValue)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(model.preferences.videoStabilization == .off ? .white : AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.videoStabilization")
                    } label: { settingTitleWithInfo("视频防抖", message: videoStabilizationHelpText) }
                    Toggle(isOn: $model.preferences.focusAssist) {
                        settingTitleWithInfo("对焦辅助", message: "仅拍照：后置8倍及以上显示可拖动的广角导航小窗，白框按视场角估计当前取景范围，近距离可能有视差。小窗不写入照片；按快门时回到原拍照管线，保留实际格式和拍摄参数。视频、人像、慢门及HDR实时取景暂不启用，资源不足时保留原取景。")
                    }
                    .accessibilityIdentifier("settings.focusAssist")
                    Toggle(isOn: $model.smoothPreview) {
                        settingTitleWithInfo("流畅预览", message: "开启后，仅优化 M 挡手动曝光时的实时取景流畅度；实际照片仍按已设置的 ISO 和快门拍摄。视频拍摄不受影响。")
                    }
                    .accessibilityIdentifier("settings.smoothPreview")
                    Toggle(isOn: Binding(
                        get: { model.preferences.dockKitTrackingEnabled },
                        set: { model.setDockKitTrackingEnabled($0) }
                    )) {
                        settingTitleWithInfo("云台追踪", message: dockKitTrackingHelpText)
                    }
                    .disabled(model.dockKitTrackingUpdating)
                    .accessibilityIdentifier("settings.dockKitTracking")
                    Toggle(isOn: $model.preferences.saveUnfilteredOriginal) {
                        settingTitleWithInfo("保存原图", message: "JPG／HEIF 套用滤镜或色彩调整时，额外保存一张未套效果的静态原片。RAW、RAW+JPG、HEIF Pro 与 TIFF 不重复保存。")
                    }
                    Toggle(isOn: $model.preferences.recordLocation) {
                        settingTitleWithInfo("记录位置", message: "开启后，在系统授权且快门时有可用位置时，将坐标写入新拍照片的元数据。关闭后新拍照片不写位置，不修改已有照片。")
                    }
                    HStack(spacing: 8) {
                        settingTitleWithInfo("版权署名", message: "保存后，署名会写入新拍照片支持的 TIFF Artist／Copyright 和 IPTC 字段；不会覆盖现有照片元数据。")
                        Spacer(minLength: 8)
                        Button {
                            copyrightDraft = model.preferences.copyright
                            withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2)) { editingCopyright = true }
                        } label: {
                            HStack(spacing: 6) {
                                Text(model.preferences.copyright.isEmpty ? "未设置" : model.preferences.copyright)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: $model.preferences.lockVideoWhiteBalance) {
                        settingTitleWithInfo("白平衡锁定", message: "开启后，录像开始前锁定当前白平衡，录制中不随场景变化；停止、取消或失败后恢复录制前状态。适用于当前镜头支持的 HEVC、H.264 和常规 ProRes 规格；SDR/P3、HDR、Apple Log/Log 2 及分辨率、帧率按设备能力开放。ProRes RAW/RAW HQ 按录制要求自动锁定，不受此开关控制。默认关闭。")
                    }
                    .accessibilityIdentifier("settings.lockVideoWhiteBalance")
                    Button("恢复自动参数") { model.setMode(.auto); model.resetParameters() }
                } header: { Text("拍摄设置") }
                Section {
                    Toggle(isOn: $model.preferences.saveCaptureSettings) {
                        settingTitleWithInfo("保存拍摄设置", message: "开启后，下次启动恢复上次的模式、格式、参数、滤镜与焦段。关闭后，照片默认 JPG、4:3、A 挡、闪光灯与 Live 关闭；视频默认 1080p30、16:9、SDR、HEVC、A 挡，均不套滤镜。辅助开关独立保存。")
                    }
                    .accessibilityIdentifier("settings.saveCaptureSettings")
                    Toggle(isOn: $model.preferences.silentShutter) {
                        settingTitleWithInfo("快门静音", message: "开启后在系统相机接口允许时抑制拍照声；关闭后跟随系统静音状态。部分地区或设备可能限制静音。")
                    }
                    .accessibilityIdentifier("settings.silentShutter")
                    Button("打开系统权限设置") { model.openSettings() }
                    NavigationLink("关于光屿") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("光屿相机").font(.title2.weight(.semibold))
                                Text("专业拍摄，轻松直出。支持多种照片格式、实时滤镜、影调与手动拍摄。拍摄后自动保存到系统相册，可浏览、分享与编辑。")
                                Text("支持照片与视频拍摄。光绘和慢动作仍在规划中；不同设备和镜头的手动参数能力有所不同。")
                                    .foregroundStyle(.secondary)
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }.navigationTitle("关于光屿").navigationBarTitleDisplayMode(.inline)
                    }.foregroundStyle(.primary)
                } header: { Text("偏好设置") }
            }.scrollContentBackground(.hidden)
                .tint(AppTheme.accent).navigationTitle("应用设置").navigationBarTitleDisplayMode(.inline)
                .disabled(editingCopyright)
                .overlay {
                    if editingCopyright {
                        ZStack {
                            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { dismissCopyright() }
                            VStack(alignment: .leading, spacing: 20) {
                                Text("版权署名").font(.headline)
                                TextField("输入署名", text: $copyrightDraft)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .submitLabel(.done).onSubmit { saveCopyright() }
                                    .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityIdentifier("settings.copyright.input")
                                HStack {
                                    Button("取消") { dismissCopyright() }
                                        .accessibilityIdentifier("settings.copyright.cancel")
                                    Spacer()
                                    Button("保存") { saveCopyright() }.fontWeight(.semibold)
                                        .accessibilityIdentifier("settings.copyright.save")
                                }.buttonStyle(.bordered)
                            }.padding(24).background {
                                PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            }.padding(24)
                        }.transition(.opacity)
                    } else if let explanation = settingExplanation {
                        ZStack {
                            Color.black.opacity(0.25).ignoresSafeArea()
                                .onTapGesture { dismissSettingExplanation() }
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text(explanation.title).font(.headline)
                                    Spacer()
                                    Button { dismissSettingExplanation() } label: {
                                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.8)).frame(width: 30, height: 30)
                                            .background(.white.opacity(0.1), in: Circle())
                                    }.buttonStyle(.plain).accessibilityLabel("关闭说明")
                                }
                                Text(explanation.message).font(.system(size: 14)).foregroundStyle(.white.opacity(0.78))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(22)
                            .background { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
                            .padding(24)
                        }.transition(.opacity)
                    }
                }
        }.presentationDetents([.medium, .large])
            .interactiveDismissDisabled(editingCopyright)
            .presentationBackground { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
    }

    private var videoBitrateHelpText: String {
        func estimate(codec: VideoCodec, preset: VideoBitratePreset) -> String {
            let colorSpace: VideoColorSpace = codec == .h264 && (model.videoColorSpace.usesTenBit || model.videoColorSpace.isLog)
                ? .sdr : model.videoColorSpace
            let settings = VideoCaptureSettings(
                resolution: model.videoResolution,
                frameRate: model.videoFrameRate,
                colorSpace: colorSpace,
                codec: codec,
                bitratePreset: preset
            )
            return String(format: "%.0f", Double(settings.bitRate) / 1_000_000)
        }
        let hevc = [VideoBitratePreset.low, .medium, .high].map { estimate(codec: .hevc, preset: $0) }.joined(separator: "/")
        let h264 = [VideoBitratePreset.low, .medium, .high].map { estimate(codec: .h264, preset: $0) }.joined(separator: "/")
        return "低/中/高只对 HEVC 和 H.264 生效；ProRes/RAW 使用自身编码规格，不受此选项影响，所选档位会保留。当前 \(model.videoResolution.title) \(model.videoFrameRate.rawValue)fps 估算：HEVC \(hevc) Mbps，H.264 \(h264) Mbps。默认由编码器决定；实际码率随画面和设备变化。"
    }
    private var videoStabilizationHelpText: String {
        let details = VideoStabilizationPreference.allCases.map { "\($0.rawValue)：\($0.explanation)" }.joined(separator: "\n")
        return "普通录像的预览和成片使用同一种防抖模式，避免取景范围和成片不一致。\n\(details)\n当前格式不支持的档位直接置灰；旧存档中不支持的档位会自动回退，默认标准防抖。设置在下一次开始录像或重新配置时生效。"
    }


    private var dockKitTrackingHelpText: String {
        "需要 iPhone 12 或更新机型（iPhone SE 系列和 iPhone 16e 不支持）、iOS 17 或更高版本，以及支持 Apple DockKit 的电动云台（例如 Insta360 Flow Pro、Flow 2 Pro）。先按云台说明通过 NFC 完成配对；打开本开关后，在相机拍照或录像时，云台会跟随画面中的主体转动。轻点主体可指定追踪对象；按住并拖动可框选追踪区域。Flow Pro 系列也可单按云台扳机键启停追踪。实际可用性取决于云台型号、系统版本和连接状态。"
    }

    private func settingInfoButton(title: String, message: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2)) {
                settingExplanation = SettingExplanation(title: title, message: message)
            }
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)说明")
    }

    private func settingTitleWithInfo(_ title: String, message: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            settingInfoButton(title: title, message: message)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dismissSettingExplanation() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2)) { settingExplanation = nil }
    }

    private func dismissCopyright() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2)) { editingCopyright = false }
    }

    private func saveCopyright() {
        model.preferences.copyright = String(copyrightDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        dismissCopyright()
    }
}

private struct SettingExplanation: Identifiable {
    let title: String
    let message: String
    var id: String { title }
}
