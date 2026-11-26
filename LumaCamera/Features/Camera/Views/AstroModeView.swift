import AVFoundation
import QuartzCore
import SwiftUI

enum AstroCaptureMode: String, CaseIterable, Identifiable {
    case photo = "星空照片"
    case trails = "星轨"
    case timelapse = "星空延时"
    var id: String { rawValue }
}

#if DEBUG
/// Lets physical integration tests use the visible scene and its real lifecycle.
@MainActor enum AstroModeDiagnostics {
    static weak var photo: AstroPhotoEngine?
    static weak var trails: AstroTrailsEngine?
    static weak var timelapse: AstroTimelapseEngine?
    static weak var previewTransition: PreviewContentTransition?
    static var ratioSelection: Binding<String>?
    static var submode: Binding<AstroCaptureMode>?
    static var parameterSelection: Binding<AstroParameter?>?
    static var parameterBinding: ((AstroParameter) -> Binding<Double>)?
    static var parameterText: ((AstroParameter) -> String)?
    static var restoreParameterAuto: ((AstroParameter) -> Void)?
    static var parameterHeaderButtonFrame = CGRect.zero
    static var parameterBarFrame = CGRect.zero
    static var parameterButtonFrames: [AstroParameter: CGRect] = [:]
    static var shutterAction: (() -> Void)?
    static var shutterEnabled: (() -> Bool)?
    static var lensSelection: Binding<AVCaptureDevice.DeviceType>?
    static var lensTransitionActive = false
    static var toolbarClipFrame = CGRect.zero
    static var toolbarButtonsFrame = CGRect.zero
    static var focalButtonsFrame = CGRect.zero
    static var shutterFrame = CGRect.zero
    static var captureControlsHidden = false
    static var shutterActivityVisible = false
    static var timelapseControlsHidden = false
    static var recordingTimerSeconds: Int?
    static var recordingTimerFrame = CGRect.zero
    static var previewReady = false
    static var environmentSheet: Binding<Bool>?
    static var toolbarTap: ((Int) -> Void)?
    static var watermarkTap: ((PhotoWatermarkStyle) -> Void)?
    static var watermarkEnabled: (() -> Bool)?
    static var watermarkPanel: Binding<Bool>?
}
#endif

private enum AstroFileFormat: String, CaseIterable { case heif = "HEIF"; case jpg = "JPG" }
private enum AstroPhotoQuality: String, CaseIterable, Identifiable {
    case fast = "快速"; case standard = "标准"; case high = "高画质"
    var id: String { rawValue }
    var frames: Int { switch self { case .fast: 10; case .standard: 30; case .high: 60 } }
}
private enum AstroPhotoRatio: String, CaseIterable, Identifiable {
    case r4x3 = "4:3"; case r1x1 = "1:1"; case r16x9 = "16:9"
    var id: String { rawValue }
    var ratio: FrameRatio { switch self { case .r4x3: .standard; case .r1x1: .square; case .r16x9: .wide } }
    var aspect: Double { switch self { case .r4x3: 4.0 / 3.0; case .r1x1: 1; case .r16x9: 16.0 / 9.0 } }
}
private enum AstroToolbarPanel { case ratio, quality, duration, timelapseSettings }
private enum StarLens: Equatable {
    case ultraWide, wide, tele
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .tele: .builtInTelephotoCamera
        }
    }
    var title: String {
        switch self { case .ultraWide: "0.5x"; case .wide: "1x"; case .tele: "4x" }
    }
}
enum AstroParameter: String, CaseIterable, Identifiable {
    case shutter, iso, ev, wb, tint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shutter: "快门"; case .iso: "ISO"; case .ev: "曝光"; case .wb: "白平衡"; case .tint: "色调"
        }
    }
    var readoutLabel: String {
        switch self {
        case .shutter: CameraParameter.shutter.readoutLabel
        case .iso: CameraParameter.iso.readoutLabel
        case .ev: CameraParameter.ev.readoutLabel
        case .wb: CameraParameter.wb.readoutLabel
        case .tint: CameraParameter.tint.readoutLabel
        }
    }
}

struct AstroModeView: View {
    let onSelectMode: (CameraViewModel.TopLevelMode, UIImage?) -> Void
    let handoffImage: UIImage?
    let handoffOpacity: Double
    let handoffBridgeFrame: CGRect?
    let onPreviewing: () -> Void
    let onOpenSettings: () -> Void
    let albumImage: UIImage?
    let albumPendingCount: Int
    let onOpenLibrary: () -> Void
    let recordsLocation: Bool
    @State private var captureLocation = CaptureLocationService()
    let externalCoverPresented: Bool
    @ObservedObject private var recovery = AstroRecoveryStore.shared
    @State private var recoveryPresented = false
    let sharedSession: AstroSharedCaptureSession
    @Binding var watermarkSettings: PhotoWatermarkSettings
    @StateObject private var photo: AstroPhotoEngine
    @StateObject private var trails: AstroTrailsEngine
    @StateObject private var timelapse: AstroTimelapseEngine
    @State private var mode: AstroCaptureMode = .photo
    @State private var started = false
    @State private var ready = true
    @State private var previewShowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var previewContentTransition = PreviewContentTransition()
    @State private var lensHandoffImage: UIImage?
    @State private var lensHandoffOpacity = 1.0
    @State private var layerPreviewing = false
    @State private var environmentPresented = false
    @State private var fileFormat: AstroFileFormat = .heif
    @State private var quality: AstroPhotoQuality = .standard
    @State private var photoRatio: AstroPhotoRatio
    @State private var toolbarPanel: AstroToolbarPanel?
    @State private var manualSettings = AstroManualSettings()
    @State private var previewParameters: CameraReadings?
    @State private var activeParameter: AstroParameter?
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsApplyTask: Task<Void, Never>?
    @State private var selectedLens: StarLens = .wide
    @State private var zoomWheelVisible = false
    @State private var zoomDragOrigin: CGFloat = 1
    @State private var zoomHideTask: Task<Void, Never>?
    @State private var toolsVisible = false
    @State private var showWatermark = false
    @State private var watermarkPanelVisible = false
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var countdownSeconds = 0
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?
    @StateObject private var starLevel = StarLevelObserver()

    init(onSelectMode: @escaping (CameraViewModel.TopLevelMode, UIImage?) -> Void,
         handoffImage: UIImage?, handoffOpacity: Double, handoffBridgeFrame: CGRect?, onPreviewing: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void, albumImage: UIImage?, albumPendingCount: Int,
         onOpenLibrary: @escaping () -> Void, recordsLocation: Bool = false,
         externalCoverPresented: Bool, inheritedRatio: FrameRatio,
         sharedSession: AstroSharedCaptureSession, watermarkSettings: Binding<PhotoWatermarkSettings>) {
        self.onSelectMode = onSelectMode; self.handoffImage = handoffImage
        self.handoffOpacity = handoffOpacity; self.onPreviewing = onPreviewing
        self.handoffBridgeFrame = handoffBridgeFrame
        self.onOpenSettings = onOpenSettings; self.albumImage = albumImage
        self.albumPendingCount = albumPendingCount; self.onOpenLibrary = onOpenLibrary
        self.recordsLocation = recordsLocation
        self.externalCoverPresented = externalCoverPresented
        let initialPhotoRatio: AstroPhotoRatio = switch inheritedRatio {
        case .square: .r1x1
        case .wide: .r16x9
        default: .r4x3
        }
        _photoRatio = State(initialValue: initialPhotoRatio)
        self.sharedSession = sharedSession
        _watermarkSettings = watermarkSettings
        _photo = StateObject(wrappedValue: AstroPhotoEngine(sharedSession: sharedSession))
        _trails = StateObject(wrappedValue: AstroTrailsEngine(sharedSession: sharedSession))
        _timelapse = StateObject(wrappedValue: AstroTimelapseEngine(sharedSession: sharedSession))
    }

    private var previewRatio: FrameRatio {
        mode == .timelapse ? .wide : mode == .trails ? .standard : photoRatio.ratio
    }

    var body: some View {
        GeometryReader { geometry in
            let ratio = previewRatio
            let previewContainer = CGSize(width: max(1, geometry.size.width - 16), height: geometry.size.height)
            let preview = CameraPreviewLayout.frame(in: previewContainer, ratio: ratio)
            ZStack {
                Color.black.ignoresSafeArea()
                if ready {
                    AstroSessionPreview(session: currentSession, onPreviewingChanged: { layerPreviewing = $0 })
                        .overlay {
                            if let handoffImage {
                                Image(uiImage: handoffImage).resizable().allowedDynamicRange(.high).scaledToFill()
                                    .opacity(handoffOpacity).allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            if let lensHandoffImage {
                                Image(uiImage:lensHandoffImage).resizable().scaledToFill()
                                    .blur(radius:reduceMotion ? 0 : 2)
                                    .opacity(lensHandoffOpacity).allowsHitTesting(false)
                            }
                        }
                        .overlay { PreviewContentTransitionOverlay(transition: previewContentTransition) }
                        .frame(width: preview.width, height: preview.height)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16), lineWidth: 0.5))
                        .previewControlContrastFrame()
                        .position(x: preview.midX + 8, y: preview.midY)
                    if showGrid, !captureControlsHidden {
                        StarGridOverlay()
                            .frame(width: preview.width, height: preview.height)
                            .position(x: preview.midX + 8, y: preview.midY)
                            .allowsHitTesting(false)
                    }
                    if showLevel, !captureControlsHidden {
                        CameraLevelIndicator(roll: starLevel.roll)
                            .position(x: preview.midX + 8, y: preview.midY)
                            .allowsHitTesting(false)
                    }
                    if showWatermark, !captureControlsHidden {
                        Text("LUMA · 星空")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.28), in: Capsule())
                            .position(x: preview.minX + 8 + 52, y: preview.maxY - 22)
                            .allowsHitTesting(false)
                    }
                    if let countdownRemaining {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white).padding(22)
                            .background(.black.opacity(0.28), in: Circle())
                            .position(x: preview.midX + 8, y: preview.midY)
                            .allowsHitTesting(false)
                    }
                }
                // Hold the outgoing crop during the first display transaction, below the controls.
                if let handoffImage, handoffBridgeFrame != nil || !ready {
                    let origin = geometry.frame(in: .global).origin
                    let frame = handoffBridgeFrame?.offsetBy(dx: -origin.x, dy: -origin.y)
                        ?? preview.offsetBy(dx: 8, dy: 0)
                    Image(uiImage: handoffImage).resizable().allowedDynamicRange(.high).scaledToFill()
                        .frame(width: max(1, frame.width), height: max(1, frame.height))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .position(x: frame.midX, y: frame.midY)
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    topBar
                        .mask(alignment: .top) {
                            // Match the preview's sides without reflowing its buttons.
                            if preview.minY == 0 {
                                RoundedRectangle(cornerRadius: 16)
                                    .frame(width: preview.width, height: preview.height)
                            } else {
                                Rectangle().frame(width: preview.width)
                            }
                        }
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { proxy in
                            let frame = proxy.frame(in: .global)
                            return CGRect(x: frame.midX - preview.width / 2, y: frame.minY,
                                width: preview.width, height: frame.height)
                        } action: { AstroModeDiagnostics.toolbarClipFrame = $0 }
                        #endif
                        .recordingHidden(captureControlsHidden)
                        .animation(recordingControlsAnimation, value: captureControlsHidden)
                    Spacer()
                }
                if timelapseControlsHidden {
                    recordingTimer
                        .padding(.top, preview.minY + CameraControlLayout.recordingTimerTopInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
                bottomBar
            }
        }
        .previewControlContrastSource(active: ready && !externalCoverPresented && !environmentPresented && !captureControlsHidden) {
            currentPreviewSnapshot ?? currentImage
        }
        .allowsHitTesting(activeParameter == nil || captureControlsHidden)
        .accessibilityHidden(activeParameter != nil && !captureControlsHidden)
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                if let toolbarPanel, !captureControlsHidden {
                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(Rectangle())
                            .padding(.top, CameraControlLayout.toolbarHeight)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { self.toolbarPanel = nil } }
                        astroToolbarPanel(toolbarPanel, width: max(1, proxy.size.width - 16))
                            .padding(.horizontal, 8)
                            .padding(.top, CameraControlLayout.toolbarHeight)
                            .transition(.opacity)
                    }
                }
            }
            .allowsHitTesting(toolbarPanel != nil && activeParameter == nil && !captureControlsHidden)
            .accessibilityHidden(activeParameter != nil)
            .animation(AppTheme.popupAnimation, value: toolbarPanel)
        }
        .overlay(alignment: .bottom) {
            Group {
                if toolsVisible, !captureControlsHidden {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(AppTheme.popupAnimation) { toolsVisible = false } }
                        starToolsPanel
                            .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                }
                if watermarkPanelVisible, !captureControlsHidden {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(AppTheme.popupAnimation) { watermarkPanelVisible = false } }
                        starWatermarkPanel
                            .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                }
            }.animation(AppTheme.popupAnimation, value: toolsVisible)
                .animation(AppTheme.popupAnimation, value: watermarkPanelVisible)
        }
        .overlay(alignment: .bottom) {
            Group {
                if let activeParameter, !captureControlsHidden {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                            .onTapGesture { self.activeParameter = nil }
                        manualParameterPanel(activeParameter)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                }
            }
            .animation(AppTheme.popupAnimation, value: activeParameter)
        }
        .overlay {
            if recoveryPresented, !captureControlsHidden {
                AstroRecoveryPanel(store: recovery) {
                    withAnimation(AppTheme.popupAnimation) { recoveryPresented = false }
                }.transition(.opacity)
            }
        }
        .onReceive(recovery.$items) { items in
            guard scenePhase == .active, !isBusy else { return }
            if !items.isEmpty { withAnimation(AppTheme.popupAnimation) { recoveryPresented = true } }
            else if recoveryPresented { withAnimation(AppTheme.popupAnimation) { recoveryPresented = false } }
        }
        .onChange(of: mode) { previous, _ in
            let source: UIImage?
            switch previous {
            case .photo: source = photo.result ?? photo.previewFrames.snapshot
            case .trails: source = trails.result ?? trails.previewFrames.snapshot
            case .timelapse: source = timelapse.previewFrames.snapshot
            }
            previewContentTransition.begin(source, reducingMotion: reduceMotion)
            clearLensHandoff()
            previewShowing = false
            stopAll()
            toolbarPanel = nil
            activeParameter = nil
            syncOutputOptions()
            zoomWheelVisible = false
            zoomHideTask?.cancel()
            countdownTask?.cancel()
            countdownRemaining = nil
            toolsVisible = false
        }
        .onChange(of: manualSettings) { _, _ in
            if mode == .timelapse, timelapse.intervalSeconds < manualSettings.clampedFusionExposure {
                timelapse.intervalSeconds = timelapse.intervalOptions.first { $0 >= manualSettings.clampedFusionExposure } ?? 30
            }
            applyManualSettings()
        }
        .onChange(of: fileFormat) { _, _ in syncOutputOptions() }
        .onChange(of: photoRatio) { _, _ in
            if mode == .photo { previewContentTransition.begin(currentPreviewSnapshot ?? currentImage, waitsForFrame: false, reducingMotion: reduceMotion) }
            syncOutputOptions()
        }
        .onChange(of: showWatermark) { _, _ in syncOutputOptions() }
        .onChange(of: watermarkSettings) { _, _ in syncOutputOptions() }
        .onChange(of: recordsLocation && scenePhase == .active && !externalCoverPresented, initial: true) { _, active in
            captureLocation.setActive(active)
        }
        .onChange(of: showLevel) { _, enabled in
            if enabled { starLevel.start() } else { starLevel.stop() }
        }
        .onChange(of: previewCovered) { _, covered in
            if covered {
                countdownTask?.cancel()
                countdownRemaining = nil
            }
            updatePreviewPause()
        }
        .onChange(of: isBusy) { _, busy in
            if !busy, previewCovered { updatePreviewPause() }
        }
        .onChange(of: captureControlsHidden) { _, hidden in
            #if DEBUG
            AstroModeDiagnostics.captureControlsHidden = hidden
            AstroModeDiagnostics.timelapseControlsHidden = timelapseControlsHidden
            if !timelapseControlsHidden { AstroModeDiagnostics.recordingTimerSeconds = nil }
            #endif
            if hidden {
                environmentPresented = false
                toolbarPanel = nil
                activeParameter = nil
                toolsVisible = false
                watermarkPanelVisible = false
                zoomWheelVisible = false
                zoomHideTask?.cancel()
                recoveryPresented = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { previewContentTransition.cancel() }
            if phase == .active {
                guard started else { return }
                ready = true
                if showLevel { starLevel.start() }
                updatePreviewPause()
                recovery.reload()
            } else if phase == .background {
                environmentPresented = false
                clearLensHandoff()
                previewShowing = false
                layerPreviewing = false
                recoveryPresented = false
                interruptCaptureForBackground()
                sharedSession.pause()
                ready = false
                activeParameter = nil
                toolbarPanel = nil
            }
        }
        .onChange(of: previewShowing) { _, shown in
            #if DEBUG
            AstroModeDiagnostics.previewReady = shown
            #endif
        }
        .task(id: "\(mode.rawValue)-\(selectedLens.title)-\(currentLensSwitching)-\(started)-\(ready)-\(scenePhase == .active)-\(previewCovered)") {
            await Task.yield()
            guard !Task.isCancelled, started, ready, scenePhase == .active, !previewCovered else { return }
            // The main suspension and this graph's preparation share one queue.
            start(mode)
            let deadline = CACurrentMediaTime() + 3
            while !Task.isCancelled, started {
                let framesReady = layerPreviewing && !currentLensSwitching
                    && currentLensType == selectedLens.deviceType && currentPreviewFrames.metrics.count >= 2
                let exposureReady = lensHandoffImage == nil || currentPreviewExposureSettled
                if framesReady && exposureReady {
                    previewShowing = true
                    previewContentTransition.finish()
                    onPreviewing()
                    if lensHandoffImage != nil {
                        withAnimation(.easeOut(duration:reduceMotion ? 0.08 : 0.10)) { lensHandoffOpacity = 0 }
                        try? await Task.sleep(for:.milliseconds(reduceMotion ? 90 : 110))
                        guard !Task.isCancelled else { return }
                        clearLensHandoff()
                    }
                    break
                }
                if !currentLensSwitching, currentError != nil, let actual = currentLensType,
                   let restored = [StarLens.ultraWide,.wide,.tele].first(where: { $0.deviceType == actual }), restored != selectedLens {
                    selectedLens = restored
                    clearLensHandoff()
                    break
                }
                // A failed route cannot leave a frozen old image covering the view.
                if lensHandoffImage != nil, CACurrentMediaTime() >= deadline { clearLensHandoff() }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        .task(id: previewShowing && scenePhase == .active && !previewCovered) {
            guard previewShowing, scenePhase == .active, !previewCovered else {
                previewParameters = nil
                return
            }
            while !Task.isCancelled {
                let newReadings = await sharedSession.readPreviewParameters()
                guard !Task.isCancelled else { return }
                previewParameters = newReadings
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onAppear {
            #if DEBUG
            AstroModeDiagnostics.photo = photo; AstroModeDiagnostics.trails = trails
            AstroModeDiagnostics.timelapse = timelapse; AstroModeDiagnostics.submode = $mode
            AstroModeDiagnostics.previewTransition = previewContentTransition
            AstroModeDiagnostics.ratioSelection = Binding(get: { photoRatio.rawValue }, set: { if let value = AstroPhotoRatio(rawValue: $0) { photoRatio = value } })
            AstroModeDiagnostics.parameterSelection = $activeParameter
            AstroModeDiagnostics.parameterBinding = parameterBinding
            AstroModeDiagnostics.parameterText = parameterReadout
            AstroModeDiagnostics.restoreParameterAuto = restoreAuto
            AstroModeDiagnostics.shutterAction = primaryAction
            AstroModeDiagnostics.shutterEnabled = { !primaryDisabled }
            AstroModeDiagnostics.toolbarTap = handleToolbarTap
            AstroModeDiagnostics.watermarkTap = toggleWatermarkStyle
            AstroModeDiagnostics.watermarkEnabled = { showWatermark }
            AstroModeDiagnostics.watermarkPanel = $watermarkPanelVisible
            AstroModeDiagnostics.lensSelection = Binding(get: { selectedLens.deviceType }, set: { type in
                if let lens = [StarLens.ultraWide,.wide,.tele].first(where: { $0.deviceType == type }) { selectLens(lens) }
            })
            AstroModeDiagnostics.previewReady = previewShowing
            AstroModeDiagnostics.environmentSheet = $environmentPresented
            #endif
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                guard !started else { return }
                started = true
                ready = true
                recovery.reload()
                photo.frameCount = quality.frames
                applyManualSettings()
                syncOutputOptions()
            }
        }
        .onDisappear {
            previewContentTransition.cancel()
            clearLensHandoff()
            started = false
            settingsApplyTask?.cancel(); settingsApplyTask = nil
            #if DEBUG
            AstroModeDiagnostics.photo = nil; AstroModeDiagnostics.trails = nil
            AstroModeDiagnostics.timelapse = nil; AstroModeDiagnostics.submode = nil
            AstroModeDiagnostics.previewTransition = nil; AstroModeDiagnostics.ratioSelection = nil
            AstroModeDiagnostics.previewReady = false
            AstroModeDiagnostics.environmentSheet = nil
            AstroModeDiagnostics.toolbarTap = nil
            AstroModeDiagnostics.toolbarButtonsFrame = .zero
            AstroModeDiagnostics.focalButtonsFrame = .zero
            AstroModeDiagnostics.shutterFrame = .zero
            AstroModeDiagnostics.captureControlsHidden = false
            AstroModeDiagnostics.shutterActivityVisible = false
            AstroModeDiagnostics.timelapseControlsHidden = false
            AstroModeDiagnostics.recordingTimerSeconds = nil
            AstroModeDiagnostics.recordingTimerFrame = .zero
            AstroModeDiagnostics.parameterSelection = nil
            AstroModeDiagnostics.parameterBinding = nil
            AstroModeDiagnostics.parameterText = nil
            AstroModeDiagnostics.restoreParameterAuto = nil
            AstroModeDiagnostics.shutterAction = nil
            AstroModeDiagnostics.shutterEnabled = nil
            AstroModeDiagnostics.parameterHeaderButtonFrame = .zero
            AstroModeDiagnostics.parameterBarFrame = .zero
            AstroModeDiagnostics.parameterButtonFrames.removeAll()
            AstroModeDiagnostics.watermarkTap = nil; AstroModeDiagnostics.watermarkEnabled = nil
            AstroModeDiagnostics.watermarkPanel = nil
            AstroModeDiagnostics.lensSelection = nil
            AstroModeDiagnostics.lensTransitionActive = false
            #endif
            recoveryPresented = false
            captureLocation.setActive(false)
            interruptCaptureForBackground()
            countdownTask?.cancel()
            starLevel.stop()
            stopAll()
            sharedSession.pauseWhenHidden()
        }
    }

    private var currentSession: AVCaptureSession {
        switch mode {
        case .photo: return photo.session
        case .trails: return trails.session
        case .timelapse: return timelapse.session
        }
    }

    private var currentPreviewFrames: AstroPreviewFrameStore {
        switch mode {
        case .photo: photo.previewFrames
        case .trails: trails.previewFrames
        case .timelapse: timelapse.previewFrames
        }
    }
    private var currentPreviewSnapshot: UIImage? { currentPreviewFrames.snapshot }
    private var currentLensSwitching: Bool {
        switch mode { case .photo: photo.switchingLens; case .trails: trails.switchingLens; case .timelapse: timelapse.switchingLens }
    }
    private var currentLensType: AVCaptureDevice.DeviceType? {
        switch mode { case .photo: photo.activeDeviceType; case .trails: trails.activeDeviceType; case .timelapse: timelapse.activeDeviceType }
    }
    private var currentPreviewExposureSettled: Bool {
        guard let device = currentSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first?.device else { return false }
        return abs(CMTimeGetSeconds(device.exposureDuration)-1.0/15) < 0.003
    }
    private func clearLensHandoff() {
        lensHandoffImage = nil; lensHandoffOpacity = 1
        #if DEBUG
        AstroModeDiagnostics.lensTransitionActive = false
        #endif
    }


    private var currentImage: UIImage? {
        switch mode {
        case .photo: return photo.result
        case .trails: return trails.result
        case .timelapse: return nil
        }
    }

    private var isBusy: Bool {
        switch mode {
        case .photo: return photo.isCapturing || photo.isSaving
        case .trails: return trails.isCapturing || trails.isSaving
        case .timelapse: return timelapse.isRecording || timelapse.isFinishing
        }
    }

    private var captureControlsHidden: Bool { isBusy || countdownRemaining != nil }
    private var timelapseControlsHidden: Bool { mode == .timelapse && isBusy }

    private var recordingControlsAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : AppTheme.popupAnimation
    }

    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = timelapse.samplingStartedAt.map {
                max(0, Int((timelapse.samplingEndedAt ?? CACurrentMediaTime()) - $0))
            } ?? 0
            let elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            Text(elapsed)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(.black.opacity(0.32), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
                .accessibilityLabel("录制时长 \(elapsed)")
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    AstroModeDiagnostics.recordingTimerFrame = $0
                }
                .onChange(of: seconds, initial: true) { _, value in
                    if timelapse.isRecording || timelapse.isFinishing {
                        AstroModeDiagnostics.recordingTimerSeconds = value
                    }
                }
                #endif
        }
    }

    private var currentError: String? {
        switch mode {
        case .photo: return photo.error
        case .trails: return trails.error
        case .timelapse: return timelapse.error
        }
    }

    private var thirdSlotTitle: String {
        switch mode {
        case .photo: return quality.rawValue
        case .trails: return durationText(trails.captureDurationSeconds)
        case .timelapse: return "\(timelapse.effectiveIntervalSeconds) 秒"
        }
    }

    private var thirdSlotSubtitle: String? {
        switch mode {
        case .photo: return "RAW"
        case .trails: return nil
        case .timelapse: return durationText(timelapse.durationMinutes.map { Double($0) * 60 })
        }
    }

    private func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "∞" }
        return "\(Int((seconds / 60).rounded())) 分钟"
    }

    private func durationText(_ minutes: Int?) -> String {
        guard let minutes else { return "∞" }
        return "\(minutes) 分钟"
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { handleToolbarTap(0) } label: {
                    VStack(spacing: 1) {
                        Text(mode == .timelapse ? "HEVC" : fileFormat.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode == .timelapse ? "4K" : "12MP")
                            .font(.system(size: 8))
                    }.previewControlContrast().frame(maxWidth: .infinity).frame(height: 32)
                }.buttonStyle(CameraToolbarButtonStyle()).disabled(mode == .timelapse)
                Button { handleToolbarTap(1) } label: {
                    Text(mode == .timelapse ? "16:9" : mode == .trails ? "4:3" : photoRatio.rawValue)
                        .font(.system(size: 10, weight: .semibold)).previewControlContrast().frame(maxWidth: .infinity).frame(height: 32)
                }.buttonStyle(CameraToolbarButtonStyle()).disabled(mode != .photo)
                Button { handleToolbarTap(2) } label: {
                    VStack(spacing: 1) {
                        Text(thirdSlotTitle).font(.system(size: 10, weight: .semibold))
                        if let subtitle = thirdSlotSubtitle {
                            Text(subtitle).font(.system(size: 8))
                        }
                    }.previewControlContrast().frame(maxWidth: .infinity).frame(height: 32)
                }.buttonStyle(CameraToolbarButtonStyle())
                Button { handleToolbarTap(3) } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).previewControlContrast(icon: true).frame(maxWidth: .infinity).frame(height: 32)
                }.buttonStyle(CameraToolbarButtonStyle())
            }
            .frame(height: 32)
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                AstroModeDiagnostics.toolbarButtonsFrame = $0
            }
            #endif
            .overlay {
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { item in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { handleToolbarTap(item) }
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 48)
            }
            .foregroundStyle(.white)
            .padding(.top, CameraControlLayout.toolbarTopInset + CameraControlLayout.toolbarContentInset)
            Color.clear.frame(height: 7)
        }.background {
            Color.black.opacity(previewRatio == .wide ? 0 : 1)
                .animation(AppTheme.popupAnimation, value: previewRatio)
        }
    }

    private func handleToolbarTap(_ item: Int) {
        guard !captureControlsHidden, (0...3).contains(item), item != 0 || mode != .timelapse,
              item != 1 || mode == .photo else { return }
        CameraHaptics.impact(.light)
        switch item {
        case 0: cycleFormat()
        case 1: toolbarPanel = toolbarPanel == .ratio ? nil : .ratio
        case 2:
            let panel: AstroToolbarPanel = mode == .photo ? .quality
                : mode == .trails ? .duration : .timelapseSettings
            toolbarPanel = toolbarPanel == panel ? nil : panel
        default: onOpenSettings()
        }
    }

    private func cycleFormat() {
        guard mode != .timelapse else { return }
        fileFormat = fileFormat == .heif ? .jpg : .heif
    }

    @ViewBuilder private func astroToolbarPanel(_ panel: AstroToolbarPanel, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if panel == .ratio {
                Text("画面比例")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            } else if panel == .quality {
                Text("画质")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            if panel == .duration || panel == .timelapseSettings {
                if panel == .timelapseSettings {
                    Text("采样间隔").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), alignment: .leading, spacing: 10) {
                        ForEach([5, 10, 15, 20, 30], id: \.self) { seconds in
                            choicePill("\(seconds) 秒", selected: timelapse.intervalSeconds == seconds) {
                                manualSettings.fusionExposureSeconds = min(manualSettings.clampedFusionExposure, seconds)
                                timelapse.manualSettings = manualSettings
                                timelapse.intervalSeconds = seconds
                                toolbarPanel = nil
                            }
                        }
                    }
                    Text("录制时长").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text("星轨时长").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), alignment: .leading, spacing: 10) {
                    if panel == .duration {
                        ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                            choicePill(durationText(minutes), selected: Int((trails.captureDurationSeconds ?? 0) / 60) == minutes) {
                                trails.captureDurationSeconds = Double(minutes) * 60
                                toolbarPanel = nil
                            }
                        }
                        choicePill("∞", selected: trails.captureDurationSeconds == nil) {
                            trails.captureDurationSeconds = nil
                            toolbarPanel = nil
                        }
                    } else {
                        ForEach([15, 30, 60, 120], id: \.self) { minutes in
                            choicePill(durationText(minutes), selected: timelapse.durationMinutes == minutes) {
                                timelapse.durationMinutes = minutes
                                toolbarPanel = nil
                            }
                        }
                        choicePill("∞", selected: timelapse.durationMinutes == nil) {
                            timelapse.durationMinutes = nil
                            toolbarPanel = nil
                        }
                    }
                }
            } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), alignment: .leading, spacing: 10) {
                if panel == .ratio {
                    ForEach(AstroPhotoRatio.allCases) { value in
                        choicePill(value.rawValue, selected: photoRatio == value) {
                            photoRatio = value; toolbarPanel = nil
                        }
                    }
                } else {
                    ForEach(AstroPhotoQuality.allCases) { value in
                        choicePill(value.rawValue, selected: quality == value) {
                            quality = value; photo.frameCount = value.frames; toolbarPanel = nil
                        }
                    }
                }
            }
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .modifier(PopupSurface(radius: 28, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
        .environment(\.colorScheme, .dark)
    }

    private func choicePill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if !selected { CameraHaptics.impact(.light) }
            action()
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(selected ? AppTheme.accentForeground : .white.opacity(0.95))
                .frame(maxWidth: .infinity).frame(minHeight: 32)
                .background(selected ? AppTheme.accent : Color.white.opacity(0.18), in: Capsule())
        }.buttonStyle(.plain)
    }



    private var zoomBar: some View {
        HStack(spacing: 2) {
            ForEach([StarLens.ultraWide, StarLens.wide, StarLens.tele], id: \.self) { lens in
                CameraFocalButton(
                    title: lens.title,
                    selected: selectedLens == lens,
                    enabled: !isBusy && ready && lensAvailable(lens),
                    accessibilityLabel: lens == .ultraWide ? "0.5 倍超广角" : lens == .wide ? "1 倍主摄" : "4 倍长焦",
                    usesEnclosingGlassBackground: true,
                    supportsContinuousZoom: false,
                    acceptsNewTouches: { !isBusy },
                    onTap: { selectLens(lens) },
                    onLongPress: {},
                    onDrag: { _, _ in },
                    onFinish: {})
                    .frame(width: 42, height: 42)
                    .previewFocalContrast(title: lens.title, selected: selectedLens == lens)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func lensAvailable(_ lens: StarLens) -> Bool {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
    }

    private func selectLens(_ lens: StarLens) {
        guard selectedLens != lens, !isBusy else { return }
        CameraHaptics.impact(.light)
        var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            lensHandoffImage = currentPreviewSnapshot ?? lensHandoffImage
            lensHandoffOpacity = 1
            previewShowing = false
            selectedLens = lens
        }
        #if DEBUG
        AstroModeDiagnostics.lensTransitionActive = lensHandoffImage != nil
        #endif
        zoomWheelVisible = false; zoomHideTask?.cancel()
        switch mode {
        case .photo: photo.switchLens(to: lens.deviceType)
        case .trails: trails.switchLens(to: lens.deviceType)
        case .timelapse: timelapse.switchLens(to: lens.deviceType)
        }
    }

    private func applyPreferredLens() {
        switch mode {
        case .photo: photo.setPreferredLens(selectedLens.deviceType)
        case .trails: trails.setPreferredLens(selectedLens.deviceType)
        case .timelapse: timelapse.setPreferredLens(selectedLens.deviceType)
        }
    }

    private func syncOutputOptions() {
        var options = AstroImageOptions()
        options.format = fileFormat == .heif ? .heif : .jpg
        options.aspect = mode == .photo ? photoRatio.aspect : nil
        options.watermark = showWatermark
        options.watermarkSettings = watermarkSettings
        photo.outputOptions = options
        trails.outputOptions = options
        timelapse.outputOptions = options
    }

    private func interruptCaptureForBackground() {
        if photo.isCapturing { photo.interruptAndSave() }
        if trails.isCapturing { trails.stopAndSave() }
        if timelapse.isRecording { timelapse.stopAndSave(manual: true) }
        photo.keepResultForRecovery(); trails.keepResultForRecovery()
        stopAll()
        starLevel.stop()
    }

    private var previewCovered: Bool { environmentPresented || externalCoverPresented }

    private func updatePreviewPause() {
        guard !isBusy else { return }
        let paused = previewCovered || scenePhase != .active
        switch mode {
        case .photo: photo.setPreviewPaused(paused)
        case .trails: trails.setPreviewPaused(paused)
        case .timelapse: timelapse.setPreviewPaused(paused)
        }
    }

    private func applyManualSettings() {
        photo.manualSettings = manualSettings
        trails.manualSettings = manualSettings
        timelapse.manualSettings = manualSettings
        settingsApplyTask?.cancel()
        settingsApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            photo.refreshPreviewSettings()
            trails.refreshPreviewSettings()
            timelapse.refreshPreviewSettings()
        }
    }

    private func restoreAuto(_ item: AstroParameter) {
        guard item != .shutter else { return }
        switch item {
        case .iso: manualSettings.isoAutomatic = true
        case .ev: manualSettings.exposureBias = 0; manualSettings.exposureBiasAutomatic = true
        case .wb:
            manualSettings.whiteBalanceAutomatic = true
            manualSettings.tintAutomatic = true
        case .tint:
            manualSettings.whiteBalanceTint = 0
            manualSettings.tintAutomatic = true
            manualSettings.whiteBalanceAutomatic = true
        case .shutter: break
        }
    }

    private func parameterRange(_ item: AstroParameter) -> ClosedRange<Double> {
        switch item {
        case .iso:
            switch mode {
            case .photo: return photo.isoRange
            case .trails: return trails.isoRange
            case .timelapse: return timelapse.isoRange
            }
        case .ev: return -5...5
        case .shutter: return mode == .photo ? (1.0 / 15.0)...1.0 : 1...30
        case .wb: return 2000...10000
        case .tint: return -150...150
        }
    }

    private func isAutomatic(_ item: AstroParameter) -> Bool {
        switch item {
        case .shutter: false
        case .iso: manualSettings.isoAutomatic
        case .ev: manualSettings.exposureBiasAutomatic
        case .wb: manualSettings.whiteBalanceAutomatic
        case .tint: manualSettings.tintAutomatic
        }
    }

    private func parameterValue(_ item: AstroParameter) -> Double {
        let value: Double
        switch item {
        case .shutter:
            value = mode == .photo ? manualSettings.clampedPhotoShutter : Double(manualSettings.clampedFusionExposure)
        case .iso:
            value = (isAutomatic(item) ? previewParameters?.iso : nil) ?? manualSettings.iso
        case .ev:
            value = isAutomatic(item) ? 0 : manualSettings.exposureBias
        case .wb:
            let liveKelvin = previewParameters?.kelvin ?? 0
            value = isAutomatic(item) && liveKelvin > 0 ? liveKelvin : manualSettings.whiteBalanceKelvin
        case .tint:
            value = (isAutomatic(item) ? previewParameters?.tint : nil) ?? manualSettings.whiteBalanceTint
        }
        let range = parameterRange(item)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func parameterBinding(_ item: AstroParameter) -> Binding<Double> {
        Binding(get: { parameterValue(item) }, set: { value in
            guard value.isFinite else { return }
            let range = parameterRange(item)
            let bounded = min(max(value, range.lowerBound), range.upperBound)
            switch item {
            case .shutter:
                if mode == .photo { manualSettings.photoShutterSeconds = bounded }
                else { manualSettings.fusionExposureSeconds = Int(bounded.rounded()) }
            case .iso:
                manualSettings.iso = bounded
                manualSettings.isoAutomatic = false
            case .ev:
                manualSettings.exposureBias = bounded
                manualSettings.exposureBiasAutomatic = false
            case .wb, .tint:
                let kelvin = item == .wb ? bounded : parameterValue(.wb)
                let tint = item == .tint ? bounded : parameterValue(.tint)
                manualSettings.whiteBalanceKelvin = kelvin
                manualSettings.whiteBalanceTint = tint
                manualSettings.whiteBalanceAutomatic = false
                manualSettings.tintAutomatic = false
            }
        })
    }

    private func parameterReadout(_ item: AstroParameter) -> String {
        if item == .iso, isAutomatic(item), previewParameters == nil { return "—" }
        let value = parameterValue(item)
        guard value.isFinite else { return "—" }
        switch item {
        case .shutter:
            // The idle sensor is kept at 1/15s. Show the selected shot exposure.
            return mode == .photo ? CameraNumericText.shutter(value) : "\(Int(value))s"
        case .iso: return CameraNumericText.integer(value)
        case .ev: return String(format: "%+.1f", value)
        case .wb: return CameraNumericText.integer(value) + "K"
        case .tint: return String(format: "%+.0f", value)
        }
    }

    private var starPopupBottomRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }

    private func manualParameterPanel(_ item: AstroParameter) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.16)) { activeParameter = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .light)).frame(width: 36, height: 36)
                }.accessibilityLabel("关闭参数面板")
                Spacer()
                Text(item == .shutter && mode != .photo ? "融合曝光" : item.title)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                if item != .shutter {
                    Button { restoreAuto(item) } label: {
                        Text("Auto").font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(isAutomatic(item) ? .white : AppTheme.accent)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("恢复自动\(item.title)")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        AstroModeDiagnostics.parameterHeaderButtonFrame = $0
                    }
                    #endif
                } else {
                    Color.clear.frame(width: 36, height: 36).accessibilityHidden(true)
                }
            }
            Text(parameterReadout(item))
                .foregroundStyle(isAutomatic(item) ? .white : AppTheme.accent)
                .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.45)
                .frame(height: 42)
            CameraRuler(value: parameterBinding(item), range: parameterRange(item), tint: AppTheme.accent,
                        temperature: item == .wb, tintAdjustment: item == .tint,
                        reversedScale: mode == .photo && item == .shutter,
                        quantizedValues: item == .shutter
                            ? (mode == .photo ? AstroManualSettings.photoShutterOptions : Array(stride(from: 1.0, through: 30.0, by: 1.0)))
                            : nil)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 42)
        .modifier(PopupSurface(radius: starPopupBottomRadius, glass: true,
                               materialOpacity: AppTheme.cameraPopupMaterialOpacity))
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture {}
        }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var bottomBar: some View {
        ZStack(alignment: .bottom) {
            Group {
                zoomBar
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        AstroModeDiagnostics.focalButtonsFrame = $0
                    }
                    #endif
                    .padding(.horizontal, 20)
                    .padding(.bottom, CameraControlLayout.compositionBottom)
                Button {
                    CameraHaptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.16)) { toolsVisible.toggle() }
                } label: {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(toolsVisible ? AppTheme.accent : .white)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("星空拍摄辅助")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 20)
                .padding(.bottom, CameraControlLayout.compositionBottom)
                HStack(spacing: 0) {
                    ForEach(AstroParameter.allCases) { item in
                        let value = parameterReadout(item)
                        Button {
                            CameraHaptics.impact(.light)
                            withAnimation(AppTheme.popupAnimation) { activeParameter = item }
                        } label: {
                            CaptureParameterReadout(label: item.readoutLabel, value: value, isAutomatic: isAutomatic(item))
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            AstroModeDiagnostics.parameterButtonFrames[item] = $0
                        }
                        #endif
                        .accessibilityLabel(item == .shutter && mode != .photo ? "融合曝光" : item.title)
                        .accessibilityValue(value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .background {
                    Color.clear.frame(height: CameraControlLayout.parameterGlassHeight)
                        .modifier(GlassSurface.parameterBar)
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            AstroModeDiagnostics.parameterBarFrame = $0
                        }
                        #endif
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, CameraControlLayout.parameterSideInset)
                .padding(.bottom, CameraControlLayout.parameterBottom)
            }
            .recordingHidden(captureControlsHidden)
            .animation(recordingControlsAnimation, value: captureControlsHidden)
            HStack(spacing: 0) {
                Button { onOpenLibrary() } label: {
                    Group {
                        if let albumImage {
                            CaptureAlbumThumbnail(image: albumImage)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.gray)
                                .rotatingCaptureContent()
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .modifier(CaptureAlbumGlassSurface())
                    .overlay {
                        if albumPendingCount > 0 {
                            ProgressView().controlSize(.small).tint(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.48), in: Circle())
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if albumPendingCount > 0 {
                            Text("\(albumPendingCount)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(AppTheme.accentForeground)
                                .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 18)
                                .background(AppTheme.accent, in: Capsule())
                                .padding(.top, -3).padding(.trailing, -3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开相册")
                .recordingHidden(captureControlsHidden)
                .animation(recordingControlsAnimation, value: captureControlsHidden)
                Spacer(minLength: 0)
                ModeSwitchButton(current: .astro, size: 52) { target in
                    onSelectMode(target, currentPreviewSnapshot ?? currentImage)
                }
                .recordingHidden(captureControlsHidden)
                .animation(recordingControlsAnimation, value: captureControlsHidden)
                Spacer(minLength: 0)
                shutterButton
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        AstroModeDiagnostics.shutterFrame = $0
                    }
                    #endif
                    .overlay {
                        if !previewShowing && !isBusy { ProgressView().tint(.white).allowsHitTesting(false) }
                    }
                    .allowsHitTesting(previewShowing || isBusy || countdownRemaining != nil)
                Spacer(minLength: 0)
                AstroSubmodeSwitchButton(current: mode, size: 52) { next in
                    guard !isBusy else { return }
                    mode = next
                }
                .disabled(isBusy)
                .recordingHidden(captureControlsHidden)
                .animation(recordingControlsAnimation, value: captureControlsHidden)
                Spacer(minLength: 0)
                Button {
                    guard !captureControlsHidden else { return }
                    CameraHaptics.impact(.light)
                    environmentPresented = true
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .rotatingCaptureContent()
                        .frame(width: 52, height: 52)
                        .modifier(GlassSurface(radius: 26))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("星空环境信息")
                .accessibilityIdentifier("astro.environment.open")
                .recordingHidden(captureControlsHidden)
                .animation(recordingControlsAnimation, value: captureControlsHidden)
            }
            .frame(height: 78)
            .padding(.horizontal, 20)
            .padding(.bottom, max(0, CameraControlLayout.shutterBottom - 10))
            if let error = currentError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.bottom, 280)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .sheet(isPresented: $environmentPresented) {
            AstroEnvironmentSheet(
                recoveryCount: recovery.items.count,
                onClose: { environmentPresented = false },
                onRecovery: {
                    environmentPresented = false
                    withAnimation(AppTheme.popupAnimation) { recoveryPresented = true }
                }
            )
        }
    }


    private func toggleWatermarkStyle(_ style: PhotoWatermarkStyle) {
        CameraHaptics.impact(.light)
        if showWatermark && watermarkSettings.style == style {
            showWatermark = false
        } else {
            watermarkSettings.style = style
            showWatermark = true
        }
    }

    private var starWatermarkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("水印").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { withAnimation(AppTheme.popupAnimation) { watermarkPanelVisible = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30).background(.white.opacity(0.10), in: Circle())
                }
            }
            HStack(spacing: 8) {
                ForEach(PhotoWatermarkStyle.allCases) { style in
                    Button {
                        toggleWatermarkStyle(style)
                    } label: {
                        WatermarkStyleThumbnail(style:style,selected:showWatermark && watermarkSettings.style == style)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                        .accessibilityAddTraits(showWatermark && watermarkSettings.style == style ? .isSelected : [])
                }
            }
            WatermarkInfoToggles(
                showsLocation: $watermarkSettings.showsLocation,
                showsParameters: $watermarkSettings.showsParameters
            )
        }
        .padding(16)
        .modifier(PopupSurface(radius: starPopupBottomRadius, glass: true,
                               materialOpacity: AppTheme.cameraPopupMaterialOpacity))
    }

    private var starToolsPanel: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
            starTool("水印", icon: "square.bottomthird.inset.filled", active: showWatermark) {
                toolsVisible = false
                withAnimation(.easeInOut(duration: 0.16)) { watermarkPanelVisible = true }
            }
            starTool(countdownSeconds == 0 ? "倒计时" : "\(countdownSeconds) 秒", icon: "timer", active: countdownSeconds > 0) {
                countdownSeconds = countdownSeconds == 0 ? 3 : countdownSeconds == 3 ? 10 : 0
            }
            starTool("参考线", icon: "grid", active: showGrid) { showGrid.toggle() }
            starTool("水平仪", icon: "level", active: showLevel) { showLevel.toggle() }
        }
        .padding(16)
        .modifier(PopupSurface(radius: starPopupBottomRadius, glass: true,
                               materialOpacity: AppTheme.cameraPopupMaterialOpacity))
    }

    private func starTool(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            CameraHaptics.impact(.light)
            withAnimation(AppTheme.popupAnimation) { action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 24, weight: .regular))
                    .foregroundStyle(active ? AppTheme.accent : .white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .background(active ? AppTheme.accent.opacity(0.22) : Color.white.opacity(0.12), in: Circle())
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity).frame(height: 76, alignment: .top)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(active ? "开启" : "关闭")
    }

    private var shutterButton: some View {
        let center: CaptureShutterFace.Center = if captureInProgress || primaryDisabled {
            .loading
        } else if countdownRemaining != nil {
            .countdown
        } else {
            .none
        }
        return Button { primaryAction() } label: {
            CaptureShutterFace(kind: mode == .timelapse ? .video : .photo, center: center)
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
        .accessibilityLabel(primaryDisabled ? "正在保存" : primaryLabel)
        #if DEBUG
        .onAppear { AstroModeDiagnostics.shutterActivityVisible = center == .loading }
        .onChange(of: center) { _, value in AstroModeDiagnostics.shutterActivityVisible = value == .loading }
        .onDisappear { AstroModeDiagnostics.shutterActivityVisible = false }
        #endif
    }

    private var submodeButton: some View {
        Menu {
            ForEach(AstroCaptureMode.allCases) { value in
                Button(value.rawValue) { mode = value }
            }
        } label: {
            Text(submodeTitle)
                .font(.system(size: 8, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(width: 52, height: 52)
                .modifier(GlassSurface(radius: 26))
        }
        .disabled(isBusy)
        .accessibilityLabel("切换星空照片、星轨或星空延时")
    }

    private var submodeTitle: String {
        switch mode {
        case .photo: return "照片"
        case .trails: return "星轨"
        case .timelapse: return "延时"
        }
    }

    private var captureInProgress: Bool {
        switch mode {
        case .photo: return photo.isCapturing
        case .trails: return trails.isCapturing
        case .timelapse: return timelapse.isRecording
        }
    }

    private var primaryDisabled: Bool {
        switch mode {
        case .photo: return photo.isSaving
        case .trails: return trails.isSaving
        case .timelapse: return timelapse.isFinishing
        }
    }

    private var primaryLabel: String {
        if countdownRemaining != nil { return "取消倒计时" }
        switch mode {
        case .photo: return photo.isCapturing ? "取消星空照片" : "开始星空照片"
        case .trails: return trails.isCapturing ? "停止并保存星轨" : "开始星轨"
        case .timelapse: return timelapse.isRecording ? "停止并保存星空延时" : "开始星空延时"
        }
    }

    private func primaryAction() {
        guard !primaryDisabled else { return }
        if countdownRemaining != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdownRemaining = nil
            return
        }
        if captureInProgress { performPrimaryAction(); return }
        if countdownSeconds > 0 {
            startCountdown()
            return
        }
        performPrimaryAction()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for value in stride(from: countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                countdownRemaining = value
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            countdownRemaining = nil
            countdownTask = nil
            performPrimaryAction()
        }
    }

    private func performPrimaryAction() {
        switch mode {
        case .photo:
            if photo.isCapturing { photo.cancel() } else { photo.begin(location: recordsLocation ? captureLocation.snapshot() : nil) }
        case .trails:
            if trails.isCapturing { trails.stopAndSave() } else { trails.begin(location: recordsLocation ? captureLocation.snapshot() : nil) }
        case .timelapse:
            if timelapse.isRecording { timelapse.stopAndSave() } else { timelapse.begin() }
        }
    }

    private func start(_ target: AstroCaptureMode) {
        applyPreferredLens()
        switch target {
        case .photo: photo.start()
        case .trails: trails.start()
        case .timelapse: timelapse.start()
        }
    }

    private func stopAll() {
        photo.stop()
        trails.stop()
        timelapse.stop()
    }
}

private struct AstroSessionPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onPreviewingChanged: (Bool) -> Void
    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
    final class Coordinator {
        var observation: NSKeyValueObservation?
        var active = true
        let onPreviewingChanged: (Bool) -> Void
        init(onPreviewingChanged: @escaping (Bool) -> Void) { self.onPreviewingChanged = onPreviewingChanged }
        func observe(_ layer: AVCaptureVideoPreviewLayer) {
            observation = layer.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] layer, _ in
                let previewing = layer.isPreviewing
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    self.onPreviewingChanged(previewing)
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPreviewingChanged: onPreviewingChanged) }
    func makeUIView(context: Context) -> View {
        let view = View()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.observe(view.previewLayer)
        view.previewLayer.session = session
        return view
    }
    func updateUIView(_ uiView: View, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        uiView.setNeedsLayout()
    }
    static func dismantleUIView(_ uiView: View, coordinator: Coordinator) {
        coordinator.active = false; coordinator.observation?.invalidate(); coordinator.observation = nil
        uiView.previewLayer.session = nil
    }
}


private struct StarGridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            Path { path in
                for i in 1..<3 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}


@MainActor
private final class StarLevelObserver: ObservableObject {
    @Published private(set) var roll: Double = 0
    private let monitor = DeviceLevelMonitor()
    private var hapticGate = LevelHapticGate()

    func start() {
        hapticGate = LevelHapticGate()
        monitor.start { [weak self] sample in
            guard let self else { return }
            let value = sample.roll
            self.roll = value
            let tilt = CameraLevelReading(roll: value).tilt
            if self.hapticGate.update(roll: tilt, time: CACurrentMediaTime(), enabled: true) {
                CameraHaptics.impact(.light)
            }
        }
    }

    func stop() {
        monitor.stop()
        hapticGate = LevelHapticGate()
    }
}
