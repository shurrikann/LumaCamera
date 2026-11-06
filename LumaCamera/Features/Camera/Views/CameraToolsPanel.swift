import SwiftUI
import AVFoundation

enum ShootingModePanelLayout {
    static let optionHeight: CGFloat = 54 + 7 + 13
    static let rowSpacing: CGFloat = 10
    static func panelHeight(for optionCount: Int) -> CGFloat {
        optionCount > 3 ? optionHeight * 2 + rowSpacing : optionHeight
    }
}

extension CameraView {
    var shootingModesPanel: some View {
        let options: [ShootingModeOption] = model.captureKind == .photo
            ? [
                ShootingModeOption(title: "慢门", icon: PhotoSubmode.slowShutter.symbol),
                ShootingModeOption(title: "夜景", icon: PhotoSubmode.night.symbol),
                ShootingModeOption(title: "人像", icon: PhotoSubmode.portrait.symbol),
                ShootingModeOption(title: "连拍", icon: PhotoSubmode.burst.symbol),
                // 虚拟光圈仅模拟高亮星芒，真实镜头光圈与曝光不变。
                ShootingModeOption(title: "虚拟光圈", icon: "camera.aperture"),
                // 智拍入口可点击；场景识别和参数联动仍待实现。
                ShootingModeOption(title: "智拍", icon: "sparkles")
            ]
            : [
                ShootingModeOption(title: "延时", icon: VideoSubmode.timeLapse.symbol),
                ShootingModeOption(title: "慢动作", icon: VideoSubmode.slowMotion.symbol),
                ShootingModeOption(title: "电影", icon: VideoSubmode.cinematic.symbol),
                ShootingModeOption(title: "同步双拍", icon: "rectangle.on.rectangle"),
                ShootingModeOption(title: "虚拟光圈", icon: "camera.aperture")
            ]
        let visibleOptions = options.filter {
            !($0.title == "虚拟光圈" && model.currentPosition == .front)
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 10) {
            ForEach(visibleOptions) { option in
                let isSlowShutter = option.title == "慢门" && model.captureKind == .photo
                let isBurst = option.title == "连拍" && model.captureKind == .photo
                let isNight = option.title == "夜景" && model.captureKind == .photo
                let isPortrait = option.title == "人像" && model.captureKind == .photo
                let isSmartCapture = option.title == "智拍" && model.captureKind == .photo
                let isVirtualAperture = option.title == "虚拟光圈"
                let isTimeLapse = option.title == "延时" && model.captureKind == .video
                let isSlowMotion = option.title == "慢动作" && model.captureKind == .video
                let isCinematic = option.title == "电影" && model.captureKind == .video
                let isDualCapture = option.title == "同步双拍" && model.captureKind == .video
                let selected = isSlowShutter ? model.slowShutterEnabled
                    : isBurst ? model.burstModeEnabled
                    : isPortrait ? model.portraitModeEnabled
                    : isSmartCapture ? model.smartCaptureEnabled
                    : isTimeLapse ? model.timeLapseEnabled
                    : isSlowMotion ? model.slowMotionEnabled
                    : isCinematic ? model.cinematicVideoEnabled
                    : isDualCapture ? camera.dualCaptureEnabled : false
                let nightSelected = isNight && model.nightModeEnabled
                // 规格不匹配只用于说明和自动适配，不再让子模块入口失去点击能力。
                let enabled = camera.ready && !camera.capturing && !camera.videoBusy
                    && model.photoSubmodePreparing == nil && model.videoSubmodePreparing == nil
                Group {
                    if isPortrait {
                        Button { model.togglePortraitMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("人像模式")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("为人物场景请求系统深度遮罩并生成背景虚化。仅支持 12MP JPG 或 HEIF，不支持 HDR、Live、夜景、慢门或连拍；A/M 曝光仍可用。")
                    } else if isSlowShutter {
                        Button { model.toggleSlowShutterMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("慢门模式")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("开启后选择光轨、流水、动态模糊、摇拍追焦或星轨。自动曝光按环境计算单帧参数并多帧合成，M挡手动设置会保留。再次点快门可提前结束。")
                    } else if isNight {
                        Button { model.toggleNightMode() } label: {
                            shootingModeOption(option, selected: nightSelected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("夜景模式")
                        .accessibilityValue(nightSelected
                            ? (model.nightIndicatorIsTriggered
                                ? "夜景已触发"
                                : model.nightIndicatorIsSupported ? "已开启，等待低照度" : "已开启，当前参数不支持")
                            : model.nightUnavailableReason ?? "关闭")
                        .accessibilityHint("低照度环境满足条件时使用三帧曝光包围合成；已触发后可点按取景框月亮关闭。")
                    } else if isBurst {
                        Button { model.toggleBurstMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("连拍模式")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("开启后按住快门连续拍摄，松开即可停止。仅支持 12MP JPG 或 HEIF，不支持 HDR 和 Live。")
                    } else if isTimeLapse {
                        Button { model.toggleTimeLapseMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled || camera.videoBusy)
                        .accessibilityLabel("延时摄影")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("选择采样间隔后按当前分辨率和帧率连续编码；当前规格不兼容时会切换到可用规格。延时视频不录制声音，ProRes RAW 会自动切换为普通视频格式。")
                    } else if isSlowMotion {
                        Button { model.toggleSlowMotionMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled || camera.videoBusy)
                        .accessibilityLabel("慢动作")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("按当前镜头支持的 120 或 240 fps 采集，再按顶部选择的帧率慢速播放；当前规格不兼容时会自动切换到可用规格。慢动作不录制声音。")
                    } else if isCinematic {
                        Button { model.toggleCinematicVideoMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled || camera.videoBusy)
                        .accessibilityLabel("电影模式")
                        .accessibilityValue(selected ? "已开启，景深效果已合成" : "关闭")
                        .accessibilityHint("使用相机和当前格式声明的系统电影视频处理；规格不兼容时会自动切换。取景画面点按主体可让系统跟踪对焦。效果直接合成到视频画面。")
                    } else if isDualCapture {
                        Button { model.toggleDualCapture() } label: {
                            ZStack {
                                shootingModeOption(option, selected: selected, enabled: enabled || camera.dualCaptureEnabled)
                                if camera.dualCapturePreparing { ProgressView().tint(AppTheme.accent) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!camera.ready || camera.videoBusy || camera.dualCapturePreparing || !model.dualCaptureAvailable)
                        .accessibilityLabel(camera.dualCaptureEnabled ? "关闭同步双拍" : "开启同步双拍")
                        .accessibilityValue(camera.dualCaptureEnabled ? "已开启，小窗为前置镜头" : "关闭")
                        .accessibilityHint("前置镜头显示在可拖动小窗，后置主画面同步录制。")
                        .accessibilityIdentifier("camera.shooting-mode.dual-capture")
                        .captureControlGeometry("shootingMode.dualCapture", model: model)
                    } else if isVirtualAperture {
                        Button { model.toggleVirtualAperture() } label: {
                            shootingModeOption(option, selected: model.virtualApertureEnabled, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("虚拟光圈")
                        .accessibilityValue(model.virtualApertureEnabled ? model.virtualApertureText : "关闭")
                        .accessibilityHint(model.captureKind == .video
                            ? "仅主摄和长焦、SDR或P3视频；不兼容规格自动适配。星芒写入成片，不改变实际曝光或景深。"
                            : "仅主摄和长焦，连续调整光源星芒；不改变实际曝光或景深。")
                        .accessibilityIdentifier("camera.shooting-mode.virtual-aperture")
                    } else if isSmartCapture {
                        Button { model.toggleSmartCaptureMode() } label: {
                            shootingModeOption(option, selected: selected, enabled: enabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("智拍模式")
                        .accessibilityValue(selected ? "已开启" : "关闭")
                        .accessibilityHint("识别逆光、夜景、人像和文档，给出一条拍摄建议；A 挡可应用，M 挡只作参考。")
                        .accessibilityIdentifier("camera.shooting-mode.smart-capture")
                    } else {
                        shootingModeOption(option, selected: false, enabled: false)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(height: ShootingModePanelLayout.panelHeight(for: visibleOptions.count))
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .modifier(PopupSurface(radius: 32, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
        .accessibilityLabel(model.captureKind == .photo ? "照片拍摄模式选项" : "视频拍摄模式选项")
    }

    private func shootingModeOption(_ option: ShootingModeOption, selected: Bool, enabled: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: option.icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(selected ? AppTheme.accent : .white.opacity(enabled ? 0.88 : 0.55))
                .frame(width: 54, height: 54)
                .background(selected ? AppTheme.accent.opacity(0.2) : .white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(selected ? AppTheme.accent.opacity(0.8) : .white.opacity(0.12), lineWidth: 0.5))
            Text(option.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? AppTheme.accent : .white.opacity(enabled ? 0.8 : 0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    var shootingFunctionsPanel: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 16) {
                ForEach(model.shootingFeatures, id: \.title) { feature in
                    let selectable = feature.title == "照片" || feature.title == "视频"
                    let active = (feature.title == "照片" && model.captureKind == .photo) || (feature.title == "视频" && model.captureKind == .video)
                    Button {
                        if feature.title == "视频" { model.setCaptureKind(.video) }
                        else if feature.title == "照片" { model.setCaptureKind(.photo) }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: feature.icon).font(.system(size: 18, weight: .light)).frame(height: 36)
                            Text(feature.title).font(.system(size: 13, weight: .medium))
                            Text(feature.title == "视频" ? "" : active ? "当前模式" : selectable ? "点击切换" : "即将支持")
                                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                                .opacity(active || feature.title == "视频" ? 0 : 1)
                                .accessibilityHidden(active || feature.title == "视频")
                        }.rotatingCaptureContent().foregroundStyle(active ? AppTheme.accent : .white.opacity(0.62))
                            .frame(maxWidth: .infinity).frame(height: 93)
                    }.disabled(!selectable || model.isPreparingSubmode)
                }
            }
        }.padding(16).modifier(PopupSurface(radius: 32, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
    }

    var captureToolsPanel: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                if model.captureKind == .photo {
                    captureTool("水印", icon: "square.bottomthird.inset.filled", active: model.border) { model.border.toggle() }
                    captureTool(model.timerSeconds == 0 ? "倒计时" : "\(model.timerSeconds) 秒", icon: "timer", active: model.timerSeconds > 0,
                                enabled: !model.burstModeEnabled && !model.nightModeEnabled, status: "当前子模块不可用") {
                        model.timerSeconds = model.timerSeconds == 0 ? 3 : model.timerSeconds == 3 ? 10 : 0
                    }
                }
                captureTool("参考线", icon: "grid", active: model.grid) { model.grid.toggle() }
                captureTool("直方图", icon: "chart.bar", active: model.showHistogram) { model.showHistogram.toggle() }
                captureTool("峰值", icon: "viewfinder", active: model.focusPeaking) { model.focusPeaking.toggle() }
                captureTool("水平仪", icon: "level", active: model.level) { model.level.toggle() }
                captureTool("翻转", icon: "rotate.right", active: model.previewQuarterTurns != 0) { model.rotatePreview() }
                if model.captureKind == .video {
                    captureTool("剩余时间", icon: "hourglass", active: model.showsRecordingCapacity) { model.showsRecordingCapacity.toggle() }
                    captureTool("声音电平", icon: "waveform", active: model.showsAudioMeter) { model.showsAudioMeter.toggle() }
                }
            }
        }.padding(16).modifier(PopupSurface(radius: 32, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
    }

    func captureTool(_ title: String, icon: String, active: Bool = false, enabled: Bool = true, status: String = "暂不可用", action: @escaping () -> Void) -> some View {
        Button {
                        withAnimation(AppTheme.popupAnimation) { action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 24, weight: .regular))
                    .foregroundStyle(active ? AppTheme.accent : .white.opacity(enabled ? 0.85 : 0.45))
                    .frame(width: 52, height: 52)
                    .background(active ? AppTheme.accent.opacity(0.22) : Color.white.opacity(enabled ? 0.12 : 0.09), in: Circle())
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(enabled ? 0.8 : 0.5))
                if !enabled { Text(status).font(.system(size: 7)).foregroundStyle(.white.opacity(0.45)) }
            }.rotatingCaptureContent().frame(maxWidth: .infinity).frame(height: 76, alignment: .top)
        }.disabled(!enabled).accessibilityLabel(title).accessibilityValue(active ? "开启" : "关闭")
    }
}

private struct ShootingModeOption: Identifiable {
    let title: String
    let icon: String
    var id: String { title }
}
