import SwiftUI

struct CameraView: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject var camera: CameraEngine
    @ObservedObject var library: PhotoLibraryViewModel
    @ObservedObject var filters: FilterPickerViewModel
    @ObservedObject var gallery: GalleryViewModel
    @State var ratioTransitionActive = false
    @State private var ratioTransitionRequest = UUID()
    @State private var cameraVisible = false
    @State var openGateInfoVisible = false
    @State var parameterPopupHeight: CGFloat = 0
    @State var flipButtonRotation = 0.0
    @State var previewEVOrigin: Double?
    @State var dockKitROIStart: CGPoint?
    @State var dockKitROIFrame: CGRect?
    @State var dockKitROISelecting = false
    @GestureState var previewPressLocation: CGPoint?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.captureControlAngle) var controlAngle
    @Environment(\.captureControlsLandscape) var controlsLandscape

    init(model: CameraViewModel) {
        self.model = model
        self.camera = model.camera
        self.library = model.library
        self.filters = model.filters
        self.gallery = model.gallery
    }

    private var cameraMessagePresented: Binding<Bool> {
        Binding(
            get: { camera.message != nil && !model.review },
            set: { isPresented in
                guard !isPresented, !model.review, let dismissedMessage = camera.message else { return }
                // SwiftUI 可能在 alert 更新视图树时写回 Binding；延后清空发布属性，避免在更新事务内发布变化。
                DispatchQueue.main.async {
                    guard !model.review, camera.message == dismissedMessage else { return }
                    camera.message = nil
                }
            }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                glassBackground
                viewfinder.animation(AppTheme.frameAnimation, value: model.ratio)
                VStack {
                    Spacer(minLength: 0)
                    shutterBar.padding(.bottom, CameraControlLayout.shutterBottom)
                        .opacity(model.popupVisible || model.panel == .film ? 0 : 1)
                        .allowsHitTesting(!model.popupVisible && model.panel != .film)
                }
                fixedCameraControls(width: geometry.size.width)
                VStack(spacing: 0) {
                    toolStrip.padding(.top, 2)
                        .captureControlGeometry("topToolbar", model: model)
                        .opacity(model.captureKind == .video && camera.videoRecording ? 0 : 1)
                        .allowsHitTesting(!(model.captureKind == .video && camera.videoRecording))
                        .accessibilityHidden(model.captureKind == .video && camera.videoRecording)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .top) {
                    if model.toolbarPanel != nil {
                        // The popup hangs from the toolbar at a fixed position so the
                        // video HUD cannot push it down; it may cover the HUD.
                        toolbarOptionsPanel(availableWidth: geometry.size.width - 16)
                            .environment(\.captureControlAngle, 0)
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.popupFrameForTesting = $0 }
                            #endif
                            .padding(.horizontal, 8)
                            .padding(.top, CameraControlLayout.toolbarHeight)
                            .transition(topPopupTransition)
                            .zIndex(1)
                    }
                }
                .overlayPreferenceValue(DepthToolbarButtonAnchorKey.self) { anchors in
                    depthControlOverlay(anchors: anchors)
                }
                .animation(AppTheme.popupAnimation, value: model.toolbarPanel)
                .animation(AppTheme.popupAnimation, value: camera.videoRecording)
                .task(id: model.captureKind) {
                    guard model.captureKind == .video else { return }
                    while !Task.isCancelled {
                        model.refreshRecordingCapacity()
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
                if model.zoomDialVisible {
                    Button { model.openShootingModes() } label: {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, CameraControlLayout.buttonRowSideInset)
                    .padding(.bottom, CameraControlLayout.compositionBottom + 44 + CameraControlLayout.upperButtonGap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(40)
                    .accessibilityHidden(true)
                }
                if model.captureKind == .video, model.virtualApertureEnabled {
                    videoApertureOverlay(diameter: 40)
                        .padding(.trailing, CameraControlLayout.buttonRowSideInset)
                        .padding(.bottom, CameraControlLayout.compositionBottom + 44 + 40 + 2 * CameraControlLayout.upperButtonGap)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .zIndex(30)

                }
            }
            .overlay(alignment: .top) {
                Color.black
                    .frame(height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                cameraPopupLayer
            }
            .overlay {
                if model.filterResetVisible && model.panel == .film && filters.showStrength { filterResetDialog }
            }
            .animation(AppTheme.popupAnimation, value: model.filterResetVisible)
            .overlay {
                if openGateInfoVisible {
                    OpenGateInformationDialog(
                        specsSummary: OpenGateCapability.supportedSpecsSummary(from: camera.openGateVideoSettings),
                        onDismiss: dismissOpenGateInformation
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .animation(AppTheme.popupAnimation, value: openGateInfoVisible)
            .overlay(alignment: .bottom) {
                if model.captureKind == .photo, model.photoSubmodeActive,
                   !model.popupVisible, model.panel == nil, !model.shootingModes {
                    photoSubmodeFocalHitOverlay(width: geometry.size.width)
                }
            }
        }
        .modifier(CameraHardwareCaptureModifier(
            enabled: cameraVisible && scenePhase == .active && !model.review && !model.settings && camera.ready,
            silent: model.preferences.silentShutter,
            action: { model.handleHardwareCapture(phase: $0.phase) }
        ))
        .tint(AppTheme.accent)
        .onAppear {
            cameraVisible = true
            model.setCameraActive(scenePhase == .active && !model.review && !model.settings)
            model.updateFrontFramingForOrientation(isLandscape: controlsLandscape)
        }
        .task {
            if scenePhase == .active { gallery.refreshAfterForeground() }
            #if DEBUG && targetEnvironment(simulator)
            // Wait for startup so its inactive-scene cleanup does not dismiss the QA dial.
            if ProcessInfo.processInfo.arguments.contains("--preview-zoom") {
                for _ in 0..<50 {
                    if camera.ready { model.zoomDialVisible = true; break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
            }
            // Explicit QA launch option: one demo capture through the real save pipeline.
            if ProcessInfo.processInfo.arguments.contains("--preview-auto-capture") {
                for _ in 0..<50 {
                    if camera.ready { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
                guard camera.demo, camera.ready, !Task.isCancelled else { return }
                model.takePhoto()
                for _ in 0..<100 {
                    if !camera.capturing && !library.saving { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
                if library.photoSaved { model.openLibrary() }
            }
            #endif
        }
        .onChange(of: model.ratio) { _, _ in
            let token = UUID(); ratioTransitionRequest = token
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.easeOut(duration: 0.08)) { ratioTransitionActive = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard ratioTransitionRequest == token else { return }
                withAnimation(.easeInOut(duration: 0.22)) { ratioTransitionActive = false }
            }
        }
        .onChange(of: camera.frontPhotoLandscapeEnabled) { _, _ in
            // 只淡化用户主动切换的取景内容，不插值画幅尺寸，也不移动按钮。
            let token = UUID(); ratioTransitionRequest = token
            ratioTransitionActive = true
            Task { @MainActor in
                await Task.yield()
                guard ratioTransitionRequest == token else { return }
                withAnimation(.easeOut(duration: UIAccessibility.isReduceMotionEnabled ? 0.08 : 0.18)) {
                    ratioTransitionActive = false
                }
            }
        }
        .onDisappear { ratioTransitionRequest = UUID(); ratioTransitionActive = false; openGateInfoVisible = false; cameraVisible = false; model.setCameraActive(false) }
        .onChange(of: model.toolbarPanel) { _, panel in
            if panel != .videoRatio { dismissOpenGateInformation() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setCameraActive(cameraVisible && phase == .active && !model.review && !model.settings)
            if phase != .active { dismissOpenGateInformation() }
            if phase == .active { gallery.refreshAfterForeground() }
        }
        .onChange(of: model.review) { _, _ in
            model.setCameraActive(cameraVisible && scenePhase == .active && !model.review && !model.settings)
            if model.review { dismissOpenGateInformation() }
            if !model.review { gallery.refreshThumbnail() }
        }
        .onChange(of: model.settings) { _, isPresented in
            model.setCameraActive(cameraVisible && scenePhase == .active && !model.review && !model.settings)
            if isPresented { dismissOpenGateInformation() }
        }
        .onChange(of: controlsLandscape) { _, isLandscape in
            model.updateFrontFramingForOrientation(isLandscape: isLandscape)
        }
        .onChange(of: camera.ready) { _, ready in
            if ready { model.updateFrontFramingForOrientation(isLandscape: controlsLandscape) }
        }
        .onChange(of: model.captureKind) { _, _ in
            model.updateFrontFramingForOrientation(isLandscape: controlsLandscape)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--qa-shooting-modes") {
                model.setCaptureKind(.video)
                model.openShootingModes()
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--qa-portrait-depth") {
                model.setCaptureKind(.photo)
                model.setVirtualApertureControlsForTesting(enabled: false, sliderVisible: false)
                model.setPortraitDepthControlsForTesting(enabled: true, sliderVisible: true)
            } else if ProcessInfo.processInfo.arguments.contains("--qa-virtual-aperture") {
                model.setCaptureKind(.photo)
                model.setVirtualApertureControlsForTesting(enabled: true, sliderVisible: true)
            }
            #endif
        }
        .onChange(of: model.currentPosition) { _, _ in
            model.updateFrontFramingForOrientation(isLandscape: controlsLandscape)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--qa-shooting-modes") {
                model.setCaptureKind(.video)
                model.openShootingModes()
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--qa-portrait-depth") {
                model.setCaptureKind(.photo)
                model.setVirtualApertureControlsForTesting(enabled: false, sliderVisible: false)
                model.setPortraitDepthControlsForTesting(enabled: true, sliderVisible: true)
            } else if ProcessInfo.processInfo.arguments.contains("--qa-virtual-aperture") {
                model.setCaptureKind(.photo)
                model.setVirtualApertureControlsForTesting(enabled: true, sliderVisible: true)
            }
            #endif
        }
        .onChange(of: camera.videoBusy) { _, busy in
            if !busy { model.updateFrontFramingForOrientation(isLandscape: controlsLandscape) }
        }
        .fullScreenCover(isPresented: $model.review) {
            GalleryView(model: model.gallery, library: library, isDemo: camera.demo, openLatestCapture: model.reviewCapture,
                        openVideoID: model.reviewVideoID, onCamera: { model.review = false })
        }
        .sheet(isPresented: $model.settings) { settingsView }
        .alert("光屿相机", isPresented: cameraMessagePresented) {
            if camera.recoveryFailed { Button("重试相机") { camera.retrySessionRecovery() } }
            if library.failedSaveCount > 0 || !library.failedVideos.isEmpty {
                Button("重试保存") { camera.message = nil; library.retryFailedSaves(); library.retryFailedVideo() }
            }
            Button("好", role: .cancel) { camera.message = nil; library.message = nil }
        } message: { Text(camera.message ?? "") }
    }

    private var cameraPopupLayer: some View {
        // Keep the transition host alive, so insertion and removal both animate.
        ZStack(alignment: .bottom) {
            if model.shootingModes {
                Color.black.opacity(0.08).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { model.closePopups() }
                    .transition(.opacity).zIndex(1)
                shootingModesPanel
                    .environment(\.captureControlAngle, 0)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(bottomPopupTransition).zIndex(2)
            } else if model.popupVisible {
                Color.black.opacity(0.08)
                    .ignoresSafeArea().allowsHitTesting(false)
                    .transition(.opacity).zIndex(0)
            }
            if model.panel == .film {
                filmPanel
                    .environment(\.captureControlAngle, 0)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.popupFrameForTesting = $0 }
                    #endif
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(bottomPopupTransition).zIndex(1)
            }
            if model.popupVisible {
                if model.functions || model.tools {
                    Group {
                        if model.functions { shootingFunctionsPanel }
                        else { captureToolsPanel }
                    }
                    .environment(\.captureControlAngle, 0)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.popupFrameForTesting = $0 }
                    #endif
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(bottomPopupTransition).zIndex(2)
                } else if !model.shootingModes {
                    // The parameter sheet keeps its portrait layout in every control
                    // orientation; only its close/title/automatic labels rotate.
                    manualPanel
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.popupFrameForTesting = $0 }
                        #endif
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { parameterPopupHeight = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(bottomPopupTransition).zIndex(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(AppTheme.popupAnimation, value: model.panel)
        .animation(AppTheme.popupAnimation, value: model.functions)
        .animation(AppTheme.popupAnimation, value: model.tools)
        .animation(AppTheme.popupAnimation, value: model.shootingModes)
    }

    /// The 1×/2× buttons sit under a transparent center overlay in night/portrait/burst.
    /// Keep their native appearance but give those two taps a top-level hit path.
    private func photoSubmodeFocalHitOverlay(width: CGFloat) -> some View {
        let positionLenses = camera.lenses.filter { $0.device.position == model.currentPosition }
        let diameter = CameraLensBarLayout.controlDiameter(containerWidth: width, count: positionLenses.count)
        let available = max(1, width - 56 - 2 * diameter)
        let buttonWidth = CameraLensBarLayout.buttonWidth(availableWidth: available, count: positionLenses.count)
        return HStack(spacing: 2) {
            ForEach(model.displayedFocalLenses) { lens in
                if abs(lens.displayZoom - 1) < 0.001 || abs(lens.displayZoom - 2) < 0.001 {
                    PhotoSubmodeFocalHitControl(
                        onTap: { model.selectFocalLength(lens) },
                        onLongPress: { model.openZoomDial() },
                        onDrag: { model.dragZoomDial(translation: $0, width: $1) },
                        onFinish: { model.finishZoomDrag() })
                        .frame(width: buttonWidth, height: buttonWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                        .frame(width: buttonWidth, height: buttonWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 44)
        .padding(.bottom, CameraControlLayout.compositionBottom)
        .zIndex(60)
    }

    private func dismissOpenGateInformation() {
        guard openGateInfoVisible else { return }
        withAnimation(AppTheme.popupAnimation) { openGateInfoVisible = false }
    }

    var parameterBottomCornerRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }

    private var topPopupTransition: AnyTransition {
        .opacity
    }
    private var bottomPopupTransition: AnyTransition {
        .opacity
    }
}





/// UIKit long-press path for the 1×/2× hit overlay. Unlike a SwiftUI long-press
/// gesture, it keeps the same contact after opening the wheel and forwards the
/// subsequent translation, matching the native focal button.
private struct PhotoSubmodeFocalHitControl: UIViewRepresentable {
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDrag: (CGFloat, CGFloat) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 10_000
        press.cancelsTouchesInView = true
        tap.require(toFail: press)
        view.addGestureRecognizer(press)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PhotoSubmodeFocalHitControl
        private var origin: CGFloat?
        init(parent: PhotoSubmodeFocalHitControl) { self.parent = parent }

        @objc func tap() {
            guard origin == nil else { return }
            parent.onTap()
        }

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard let window = gesture.view?.window else { return }
            let x = gesture.location(in: window).x
            switch gesture.state {
            case .began:
                origin = x
                parent.onLongPress()
            case .changed:
                guard let origin else { return }
                parent.onDrag(x - origin, window.bounds.width)
            case .ended, .cancelled, .failed:
                guard origin != nil else { return }
                origin = nil
                parent.onFinish()
            default:
                break
            }
        }
    }
}
