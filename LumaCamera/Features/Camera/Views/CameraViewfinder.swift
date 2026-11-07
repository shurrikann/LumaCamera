import SwiftUI
import AVFoundation
import UIKit

extension CameraView {
    var glassBackground: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                // Keep the original translucent glow; only the opaque base is black.
                Circle().fill(Color(red: 0.36, green: 0.36, blue: 0.36).opacity(0.12))
                    .frame(width: 300).blur(radius: 80).offset(x: -140, y: -300)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false)
    }

    var viewfinder: some View {
        viewfinderContent(controlAngle: controlAngle, reducingMotion: reduceMotion)
    }

    func viewfinderContent(controlAngle: Double, reducingMotion: Bool = UIAccessibility.isReduceMotionEnabled) -> some View {
        GeometryReader { geometry in
            let previewRect = CameraPreviewLayout.frame(in: geometry.size, ratio: model.ratio,
                                                         openGatePortraitRatio: camera.openGatePortraitRatio,
                                                         landscape: model.effectiveCaptureLook.landscape)
            let previewTop = previewRect.minY
            let width = previewRect.width
            let height = previewRect.height
            let toolbarOverlap = max(0, CameraControlLayout.toolbarHeight + 2 - previewTop)
            let isRecording = model.captureKind == .video && camera.videoRecording
            // 录像时工具栏已隐藏，不再为它保留HUD空白；窄画幅让数据面板避开居中的计时。
            let hudTop = isRecording ? (width < 300 ? 34.0 : 5.0)
                : max(1, toolbarOverlap > 0 ? toolbarOverlap + 8 : 1)
            let controlLandscape = abs(sin(controlAngle * .pi / 180)) > 0.5
            let showsMeteringReadout = model.effectiveMetering == .global
            ZStack {
                Color.black
                if let image = camera.preview {
                    Image(uiImage: image).resizable().allowedDynamicRange(.high).scaledToFill()
                        .transaction { $0.animation = nil }
                        .frame(width: width, height: height).clipped()
                        .blur(radius: ratioTransitionActive ? 2.5 : 0)
                        .opacity(ratioTransitionActive ? 0.86 : 1)
                }
                ZStack {
                    if let accumulated = model.slowShutterAccumulationPreview {
                        SlowShutterAccumulationView(state:accumulated).id(accumulated.id).transition(.opacity)
                    }
                    if let reveal = camera.nightPreviewReveal {
                        NightCaptureRevealView(state:reveal).id(reveal.id).transition(.opacity)
                    }
                }.frame(width:width,height:height).allowsHitTesting(false)
                    .animation(reducingMotion ? .easeInOut(duration:0.1) : .easeInOut(duration:0.2),value:camera.nightPreviewReveal?.id)
                    .animation(reducingMotion ? .easeInOut(duration:0.1) : .easeInOut(duration:0.2),value:model.slowShutterAccumulationPreview?.id)
                if model.hdr, model.captureKind == .photo {
                    Text("HDR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.88), in: Capsule())
                        .frame(width: width, height: height, alignment: .topTrailing)
                        .padding(.top, 8).padding(.trailing, 10)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("preview.hdrBadge")
                }
                if let image = model.resumeTransitionImage {
                    Image(uiImage: image).resizable().allowedDynamicRange(.high).scaledToFill()
                        .frame(width: width, height: height).clipped()
                        .blur(radius: model.resumeTransitionOpacity < 1 ? 2.5 : 0)
                        .opacity(model.resumeTransitionOpacity).allowsHitTesting(false)
                }
                if let image = model.focalTransitionImage {
                    Image(uiImage: image).resizable().allowedDynamicRange(.high).scaledToFill()
                        .frame(width: width, height: height).clipped()
                        .blur(radius: model.focalTransitionBlur)
                        .opacity(model.focalTransitionOpacity)
                        .allowsHitTesting(false)
                }
                Group {
                    VStack(spacing: 0) {
                        CameraToolbarOverlapBackground(height: toolbarOverlap)
                            .opacity(isRecording ? 0 : 1)
                            .animation(AppTheme.popupAnimation, value: isRecording)
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.toolbarBackdropFrameForTesting = $0 }
                            #endif
                        Spacer(minLength: 0)
                    }.allowsHitTesting(false)
                }
                if model.panel == .film {
                    focusSurface(size: CGSize(width: width, height: height))
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded {
                            model.swipeFilter(translation: $0.translation)
                        })
                } else {
                    focusSurface(size: CGSize(width: width, height: height))
                }
                if model.smartCaptureEnabled,
                   let guide = model.smartDisplayedCompositionGuide,
                   !model.popupVisible, model.toolbarPanel == nil, model.panel != .film,
                   !camera.videoBusy {
                    smartCompositionGuideOverlay(guide)
                        .frame(width: width, height: height)
                        .transition(.opacity)
                        .zIndex(4)
                }
                if model.smartCaptureEnabled, let framing = model.smartFramingRecommendation,
                   !model.popupVisible, model.toolbarPanel == nil, model.panel != .film,
                   !camera.videoBusy {
                    smartFramingOverlay(framing)
                        .frame(width: width, height: height)
                        .transition(.opacity)
                        .zIndex(5)
                }
                if model.captureKind == .video, model.timeLapseEnabled, camera.videoRecording {
                    VStack {
                        Spacer(minLength: 0)
                        Text(timeLapsePreviewStatus)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.42), in: Capsule())
                            .padding(.bottom, 12)
                    }
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)
                    .zIndex(6)
                }
                if model.captureKind == .photo, model.preferences.focusAssist, camera.currentZoom >= 8, let image = camera.focusNavigatorImage {
                    let sourceRect = model.focusNavigatorLayoutRect
                    let rect = DualCaptureInsetLayout.displayRect(sourceRect, ratio: model.ratio.portraitRatio, turns: model.previewQuarterTurns)
                    let region = camera.focusNavigatorRegion
                    let windowWidth = width * rect.width, windowHeight = height * rect.height
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: windowWidth, height: windowHeight).clipped()
                        .overlay {
                            Rectangle().stroke(.white, lineWidth: 1.3)
                                .frame(width: windowWidth * region.width, height: windowHeight * region.height)
                                .position(x: windowWidth * region.midX, y: windowHeight * region.midY)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.5), lineWidth: 0.75))
                        .overlay {
                            DualCaptureInsetSurface(rect: sourceRect, previewSize: CGSize(width: width, height: height),
                                onMove: { model.moveFocusNavigator(from: $0, translation: $1) }, onSwap: {},
                                accessibilityTitle: "对焦辅助导航", accessibilityDescription: "拖动移动位置，白框表示估计的当前取景范围")
                        }
                        .captureControlGeometry("focusNavigator", model: model)
                        .position(x: width * rect.midX, y: height * rect.midY)
                        .zIndex(5.5)
                }
                if camera.dualCaptureEnabled {
                    // 热区随合成窗口和预览辅助旋转一起变换；位移以整个预览为坐标系，不受窗口自身移动影响。
                    let sourceRect = camera.dualCaptureInsetRect
                    let rect = DualCaptureInsetLayout.displayRect(sourceRect,
                        ratio: model.videoRatio.frameRatio.portraitRatio, turns: model.previewQuarterTurns)
                    DualCaptureInsetSurface(rect: sourceRect, previewSize: CGSize(width: width, height: height),
                        onMove: { model.moveDualCaptureInset(from: $0, translation: $1) },
                        onSwap: { model.swapDualCaptureCameras() })
                        .frame(width: width * rect.width, height: height * rect.height)
                        .overlay(alignment: .bottomTrailing) {
                            // 与拖动/双击热区并列命中；小按钮只在小窗内部显示，不写入视频像素。
                            if !camera.videoRecording {
                                dualInsetAspectButton(diameter: 28)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                                    .padding(3)
                            }
                        }
                        .captureControlGeometry("dualCaptureInset", model: model)
                        .position(x: width * rect.midX, y: height * rect.midY)
                        .allowsHitTesting(!camera.dualCapturePreparing && !camera.videoConfiguring && !model.dualInsetAspectChanging)
                        .zIndex(5.5)
                }
                if model.grid {
                    Path { path in
                        for index in 1...2 {
                            let x = width * CGFloat(index) / 3
                            let y = height * CGFloat(index) / 3
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y))
                        }
                    }.stroke(.white.opacity(0.42), lineWidth: 0.75)
                        .shadow(color: .black.opacity(0.35), radius: 0.5)
                        .allowsHitTesting(false)
                }
                if model.level {
                    CameraLevelIndicator(roll: camera.roll)
                    #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.levelFrameForTesting = $0 }
                    #endif
                }
                Group {
                    if isRecording {
                    Text(videoElapsedText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(.black.opacity(0.32), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
                        .captureControlGeometry("recordingTimer", model: model)
                        .padding(.top, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityLabel("录像时长 \(videoElapsedText)")
                        .zIndex(6)
                    }
                }.animation(AppTheme.popupAnimation, value: isRecording)
                if model.captureKind == .video && (model.showsRecordingCapacity || model.showsAudioMeter) {
                    VideoRecordingHUD(capacity: model.showsRecordingCapacity ? model.recordingCapacity : nil,
                                      showsAudio: model.showsAudioMeter, left: camera.audioLeftLevel, right: camera.audioRightLevel)
                    .captureControlGeometry("videoHUD", model: model)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.recordingHUDFrameForTesting = $0 }
                    #endif
                    .padding(.trailing, 5)
                    .padding(.top, hudTop)
                    .animation(AppTheme.popupAnimation, value: isRecording)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .zIndex(2)
                }

                if model.showHistogram || showsMeteringReadout {
                    HStack(alignment: .top, spacing: 6) {
                        if model.showHistogram {
                            // One persistent view so the 90/180/270 transitions animate
                            // instead of swapping between separate portrait/landscape copies.
                            CameraHistogram(bins: camera.histogram)
                                .rotatingCaptureContent()
                                .frame(width: controlLandscape ? CameraHistogram.size.height : CameraHistogram.size.width,
                                       height: controlLandscape ? CameraHistogram.size.width : CameraHistogram.size.height)
                                .captureControlGeometry("histogram", model: model)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    model.histogramFrame = $0
                                    #if DEBUG
                                    model.histogramFrameForTesting = $0
                                    #endif
                                }
                        }
                        if showsMeteringReadout {
                            meteringReadout
                                .rotatingCaptureContent()
                                .frame(width: controlLandscape ? CameraHistogram.size.height : CameraHistogram.size.width,
                                       height: controlLandscape ? CameraHistogram.size.width : CameraHistogram.size.height)
                                .captureControlGeometry("metering.compensation", model: model)
                                .transition(.opacity)
                        }
                    }
                    .animation(reducingMotion ? .easeInOut(duration: 0.1) : AppTheme.popupAnimation, value: showsMeteringReadout)
                    .padding(.leading, 5)
                    .padding(.top, max(5, hudTop))
                    .animation(AppTheme.popupAnimation, value: isRecording)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(5)
                    .animation(reducingMotion ? nil : .easeInOut(duration: 0.22), value: controlLandscape)
                }
                if let point = model.focusPoint {
                    CameraFocusControls(model: model, camera: camera, point: point, size: CGSize(width: width, height: height), topInset: hudTop, bottomInset: max(0, previewTop + height - (geometry.size.height - CameraControlLayout.compositionBottom - 32)))
                        .zIndex(4)
                }
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            if camera.demo {
                                Label("演示画面", systemImage: "sparkles")
                                    .font(.system(size: 9)).padding(.horizontal, 9).padding(.vertical, 6)
                                    .modifier(PreviewSurface(radius: 12))
                            }
                        }.opacity(model.focusPoint.map { $0.y < hudTop + (model.showHistogram ? (camera.demo ? 70 : 40) : 32) + 62 } == true ? 0 : 1)
                        Spacer()
                    }.padding(.horizontal, 5).padding(.top, hudTop)
                        .allowsHitTesting(false)
                    Spacer()
                }.zIndex(3)
                if let remaining = model.countdown {
                    Text("\(remaining)").font(.system(size: 64, weight: .light, design: .rounded))
                        .shadow(color: .black.opacity(0.4), radius: 10).allowsHitTesting(false)
                }
                if camera.denied {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(AppTheme.accent)
                        Text("开启相机，开始记录").font(.headline)
                        Text("请在系统设置中允许光屿访问摄像头。")
                            .font(.caption).foregroundStyle(.gray).multilineTextAlignment(.center)
                        Button("前往设置") { model.openSettings() }.buttonStyle(.borderedProminent).tint(AppTheme.accent).foregroundStyle(.black)
                    }.padding(22)
                } else if camera.preview == nil && model.focalTransitionImage == nil {
                    ProgressView("正在准备相机…").font(.caption)
                }
            }
            .frame(width: width, height: height)
            // 画幅与首张新帧同时切换，不对图像宽高做插值，以免人物暂时被压扁。
            .animation(nil, value: model.effectiveCaptureLook.landscape)
            .animation(AppTheme.popupAnimation, value: model.zoomDialVisible)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16), lineWidth: 0.5))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                model.reportDualInsetPreviewFrame($0)
                #if DEBUG
                model.previewFrameForTesting = $0
                #endif
            }
            .onChange(of: camera.videoRecording) { _, _ in model.scheduleDualInsetPlacementRepair() }
            .onChange(of: camera.dualCaptureEnabled) { _, _ in model.scheduleDualInsetPlacementRepair() }
            .onChange(of: camera.dualCaptureInsetRect.size) { _, _ in model.scheduleDualInsetPlacementRepair() }
            .onChange(of: camera.focusNavigatorActive) { _, _ in model.scheduleDualInsetPlacementRepair() }
            .onChange(of: model.ratio) { _, _ in model.scheduleDualInsetPlacementRepair() }
            .position(x: geometry.size.width / 2, y: previewRect.midY)
            .task(id: "\(width)-\(height)") {
                #if DEBUG && targetEnvironment(simulator)
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--preview-focus") {
                    for _ in 0..<50 {
                        if camera.ready && camera.preview != nil { break }
                        try? await Task.sleep(for: .milliseconds(100))
                        if Task.isCancelled { return }
                    }
                    let edge = arguments.contains("--preview-focus-edge")
                    let target = CGPoint(x: edge ? width - 27 : width * 0.62, y: edge ? 110 : height * 0.48)
                    model.focusPreview(at: target, size: CGSize(width: width, height: height), lockExposure: true)
                    model.adjustFocusEV(1.2)
                    if arguments.contains("--preview-focus-lock-menu") { model.toggleFocusLockPicker() }
                }
                #endif
            }
        }.padding(.horizontal, 8)
    }

    func nightIndicatorIcon(symbol: String, color: Color, unavailable: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 27, height: 27)
            // moon.slash 并非可用的系统符号，使用固定尺寸斜线表达不支持状态。
            .overlay {
                if unavailable {
                    Path { path in
                        path.move(to: CGPoint(x: 7, y: 7))
                        path.addLine(to: CGPoint(x: 20, y: 20))
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            .contentShape(Rectangle())
    }

    /// 全局测光独立显示读数，固定尺寸让实时数值更新时位置稳定。
    private var meteringReadout: some View {
        let readout = camera.globalMeteringReadout
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(format: "用户 %+.1f EV", model.ev))
            if let suggestion = readout.suggestion {
                Text(String(format: "建议 %+.1f EV", suggestion))
            } else {
                Text(String(format: "全局 %+.1f EV", readout.target ?? readout.correction))
            }
            Text(String(format: "设备 %+.1f EV", readout.actual))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(AppTheme.accent)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 4)
        .frame(width: CameraHistogram.size.width, height: CameraHistogram.size.height, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("metering.compensation")
        .accessibilityHint("全局是实时测光目标。设备是已生效的总补偿。手动曝光时显示建议。")
    }

    private func focusSurface(size: CGSize) -> some View {
        let surface = Color.clear.frame(width: size.width, height: size.height).contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("相机预览")
            .accessibilityHint(model.dockKitAccessoryConnected && model.dockKitTrackingEnabled
                ? "轻点对焦并选择追踪主体；按住并拖动可框选追踪区域；双指调整变焦。"
                : "双指张开或捏合调整变焦；轻点对焦，长按对焦并锁定曝光。")

        return Group {
            if model.dockKitAccessoryConnected && model.dockKitTrackingEnabled {
                surface.highPriorityGesture(dockKitHoldOrTapGesture(size: size))
            } else {
                surface.highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                        .onEnded { _ in
                            guard let point = previewPressLocation else { return }
                            guard !model.zoomDialVisible, !model.focusLockPickerVisible, model.toolbarPanel == nil, model.panel == nil,
                                  !model.functions, !model.tools, !model.shootingModes else { model.closePopups(); return }
                            model.focusPreview(at: point, size: size, lockExposure: true)
                        }
                        .exclusively(before: SpatialTapGesture().onEnded { tap in
                            if model.focusLockPickerVisible || model.zoomDialVisible || model.toolbarPanel != nil || model.panel != nil || model.functions || model.tools || model.shootingModes { model.closePopups(); return }
                            model.focusPreview(at: tap.location, size: size)
                        })
                )
            }
        }
        // Track the initial contact without waiting for movement, while tap/hold arbitrate exclusively.
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .updating($previewPressLocation) { drag, location, _ in location = drag.startLocation })
        .simultaneousGesture(MagnificationGesture()
            .onChanged { scale in model.updatePreviewPinchZoom(scale: scale) }
            .onEnded { _ in model.finishPreviewPinchZoom() })
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard !dockKitROISelecting, model.focusPoint != nil, !model.previewPinchActive, !model.focusLockPickerVisible, model.panel == nil, model.toolbarPanel == nil,
                      !model.zoomDialVisible, !model.tools, !model.functions else { return }
                guard previewEVOrigin != nil || abs(drag.translation.height) > abs(drag.translation.width) * 1.2 else { return }
                if previewEVOrigin == nil { previewEVOrigin = model.ev; model.beginFocusEVAdjustment() }
                model.adjustFocusEV(FocusTargetLayout.draggedEV(origin: previewEVOrigin ?? model.ev, translation: drag.translation.height))
            }
            .onEnded { _ in
                if previewEVOrigin != nil { previewEVOrigin = nil; model.finishFocusEVAdjustment() }
            })
        .overlay(alignment: .topLeading) {
            if let rect = dockKitROIFrame {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: model.dockKitTrackingEnabled) { _, enabled in
            if !enabled { clearDockKitSelectionOverlay() }
        }
        .onChange(of: model.dockKitAccessoryConnected) { _, connected in
            if !connected { clearDockKitSelectionOverlay() }
        }
    }

    /// 云台追踪开启时，短点仍用于对焦；长按后拖动则绘制搜索区域。
    private func dockKitHoldOrTapGesture(size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 18)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value,
                      !model.zoomDialVisible, !model.focusLockPickerVisible, model.toolbarPanel == nil, model.panel == nil,
                      !model.functions, !model.tools, !model.shootingModes else { return }
                dockKitROISelecting = true
                if dockKitROIStart == nil { dockKitROIStart = drag.startLocation }
                dockKitROIFrame = selectionRect(from: dockKitROIStart ?? drag.startLocation, to: drag.location)
            }
            .onEnded { value in
                defer { dockKitROISelecting = false; dockKitROIStart = nil }
                guard case .second(true, let drag?) = value else {
                    if case .second(true, nil) = value,
                       let point = previewPressLocation,
                       !model.zoomDialVisible, !model.focusLockPickerVisible, model.toolbarPanel == nil, model.panel == nil,
                       !model.functions, !model.tools, !model.shootingModes {
                        model.focusPreview(at: point, size: size, lockExposure: true)
                    }
                    dockKitROIFrame = nil
                    return
                }
                let start = dockKitROIStart ?? drag.startLocation
                let rect = selectionRect(from: start, to: drag.location)
                guard !model.zoomDialVisible, !model.focusLockPickerVisible, model.toolbarPanel == nil, model.panel == nil,
                      !model.functions, !model.tools, !model.shootingModes else { dockKitROIFrame = nil; return }
                if rect.width >= 24, rect.height >= 24 {
                    dockKitROIFrame = rect
                    model.setDockKitTrackingRegion(rect, surfaceSize: size)
                } else {
                    dockKitROIFrame = nil
                    model.focusPreview(at: start, size: size, lockExposure: true)
                }
            }
            .exclusively(before: SpatialTapGesture().onEnded { tap in
                if model.focusLockPickerVisible || model.zoomDialVisible || model.toolbarPanel != nil || model.panel != nil || model.functions || model.tools || model.shootingModes {
                    model.closePopups(); return
                }
                model.focusPreview(at: tap.location, size: size)
                model.selectDockKitSubject(at: tap.location, surfaceSize: size)
                dockKitROIFrame = nil
            })
    }

    private func selectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func clearDockKitSelectionOverlay() {
        dockKitROIFrame = nil
        dockKitROIStart = nil
        dockKitROISelecting = false
    }


    @ViewBuilder
    func lensBar(availableWidth: CGFloat) -> some View {
        let allLenses = camera.lenses.filter { $0.device.position == model.currentPosition }
        let lenses = model.displayedFocalLenses
        let frontWide: CameraLens? = lenses.first(where: { lens in
            lens.frontFraming == FrontCameraFraming.standard
        })
        let frontUltraWide: CameraLens? = lenses.first(where: { lens in
            lens.frontFraming == FrontCameraFraming.wide
        })
        let useFrontWideToggle = !camera.demo && model.displayedFocalPosition == .front && frontWide != nil && frontUltraWide != nil
        // 高像素隐藏裁切档位时沿用普通档的槽宽，不能把剩余三个按钮放大。
        let count = useFrontWideToggle ? 2 : allLenses.count
        let buttonWidth = CameraLensBarLayout.buttonWidth(availableWidth: availableWidth, count: camera.demo ? 1 : count)
        if camera.demo {
            CameraFocalButton(title: model.zoomText, selected: true,
                enabled: camera.ready && !camera.capturing, accessibilityLabel: "演示焦段",
                acceptsNewTouches: { !model.zoomDialVisible },
                onTap: { model.selectDemoFocalLength() },
                onLongPress: { model.openZoomDial() },
                onDrag: { model.dragZoomDial(translation: $0, width: $1) },
                onFinish: { model.finishZoomDrag() })
                .frame(width: buttonWidth, height: buttonWidth)
                .padding(2)
                .opacity(model.hidesFocalStripForZoomDial ? 0.001 : 1)
        } else if useFrontWideToggle, model.captureKind == .video, let wide = frontWide, let ultra = frontUltraWide {
            let isWide = camera.dualCaptureEnabled ? camera.dualCaptureFrontWide : camera.selectedLens == ultra.id
            CameraFocalButton(title: "", imageName: isWide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                selected: isWide,
                enabled: camera.ready && !camera.capturing && model.canSelectFocalLength(isWide ? wide : ultra),
                accessibilityLabel: isWide ? "切换回前置 1 倍" : "切换前置广角",
                usesEnclosingGlassBackground: true,
                acceptsNewTouches: { !model.zoomDialVisible },
                onTap: { model.selectFocalLength(isWide ? wide : ultra) },
                onLongPress: { model.openZoomDial() },
                onDrag: { model.dragZoomDial(translation: $0, width: $1) },
                onFinish: { model.finishZoomDrag() })
                .frame(width: buttonWidth, height: buttonWidth)
                .padding(2)
                .opacity(model.hidesFocalStripForZoomDial ? 0.001 : 1)
                .captureControlGeometry("frontVideoWide", model: model)
        } else if useFrontWideToggle, let wide = frontWide, let ultra = frontUltraWide {
            let isWide = camera.selectedLens == ultra.id
            let isLandscapePhoto = camera.frontPhotoLandscapeEnabled && model.photoFormat != .raw
            HStack(spacing: 6) {
                Button { model.selectFocalLength(isWide ? wide : ultra) } label: {
                    Image(systemName: isWide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: isWide ? 16 : 15, weight: .medium))
                        .foregroundStyle(isWide ? AppTheme.accent : Color.white.opacity(0.9))
                        .frame(width: buttonWidth, height: buttonWidth)
                        .background(isWide ? Color.white.opacity(0.06) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: buttonWidth, height: buttonWidth)
                .disabled(!camera.ready || camera.capturing || camera.videoBusy
                    || !model.canSelectFocalLength(isWide ? wide : ultra))
                .accessibilityLabel(isWide ? "切换回前置 1 倍" : "切换前置广角")
                .accessibilityIdentifier("camera.frontWide.toggle")
                .captureControlGeometry("frontPhotoWide", model: model)
                Button { model.toggleFrontPhotoAspectRatio() } label: {
                    Image(systemName: "rectangle.portrait")
                        .rotationEffect(isLandscapePhoto ? .degrees(90) : .zero)
                        .rotatingCaptureContent()
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isLandscapePhoto ? AppTheme.accent : .white)
                        .opacity(camera.frontPhotoAspectRatioSwitchAvailable ? 1 : AppTheme.disabledControlOpacity)
                        .frame(width: buttonWidth, height: buttonWidth)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!camera.ready || camera.capturing || camera.videoBusy
                    || !model.canToggleFrontPhotoAspectRatio)
                .accessibilityLabel(isLandscapePhoto ? "恢复之前的前置构图" : "切换为超广角横向照片")
                .accessibilityValue(isLandscapePhoto ? "横向构图" : "竖向构图")
                .accessibilityHint(model.photoFormat == .raw
                    ? "RAW 原始文件保留传感器画面，不能更改成片宽高比"
                    : model.ratio == .square ? "正方形照片无需切换方向" : "切为横向照片并使用超广角，再点击恢复之前的构图和倍率")
                .accessibilityIdentifier("camera.frontPhotoAspectRatio.toggle")
                .captureControlGeometry("frontPhotoAspectRatio", model: model)
            }
            .padding(2)
                .opacity(model.hidesFocalStripForZoomDial ? 0.001 : 1)
        } else {
            HStack(spacing: 2) {
                ForEach(lenses) { lens in
                    CameraFocalButton(title: model.focalButtonTitle(for: lens),
                        selected: model.isFocalSelected(lens),
                        enabled: camera.ready && !camera.capturing && model.canSelectFocalLength(lens),
                        accessibilityLabel: lens.accessibilityDescription,
                        usesEnclosingGlassBackground: true,
                        supportsContinuousZoom: !model.fixedHighResolutionFocalsOnly,
                        acceptsNewTouches: { !model.zoomDialVisible },
                        onTap: { model.selectFocalLength(lens) },
                        onLongPress: { model.openZoomDial() },
                        onDrag: { model.dragZoomDial(translation: $0, width: $1) },
                        onFinish: { model.finishZoomDrag() })
                        .frame(width: buttonWidth, height: buttonWidth)
                        .overlay(alignment:.bottom) {
                            if model.fixedHighResolutionFocalsOnly && camera.highResolutionPhotoConfiguring && camera.selectedLens == lens.id {
                                ProgressView().controlSize(.mini).scaleEffect(0.55)
                                    .frame(width:10,height:10).padding(.bottom,2).allowsHitTesting(false)
                            }
                        }
                        .captureControlGeometry("focal.\(lens.id)", model: model)
                }
            }
            .padding(2)
            // 记录焦段条本身的宽度；外层容器负责占满可用空间并居中。
            .captureControlGeometry("focalBarBackground", model: model)
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(reduceMotion ? .easeOut(duration:0.08) : .easeInOut(duration:0.18), value:model.fixedHighResolutionFocalsOnly)
            .animation(reduceMotion ? .easeOut(duration:0.08) : .easeInOut(duration:0.18), value:lenses.map(\.id))
                .opacity(model.hidesFocalStripForZoomDial ? 0.001 : 1)
        }
    }
}

/// The toolbar sits directly over the preview; no glass or tint is drawn.
struct CameraToolbarOverlapBackground: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: max(0, height))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

