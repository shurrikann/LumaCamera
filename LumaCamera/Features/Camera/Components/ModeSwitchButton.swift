import SwiftUI
import UIKit

/// A fixed glass button with an endlessly wrapping vertical icon reel.
struct ModeSwitchButton: View {
    let current: CameraViewModel.TopLevelMode
    var size: CGFloat = 52
    let onSelect: (CameraViewModel.TopLevelMode) -> Void
    var body: some View {
        CyclicModeSwitchButton(current: current, modes: ModeSwipeState.modes, size: size,
            label: "拍摄模式，"+title(current), hint: "上下滑动循环切换拍照、视频和星空",
            icon: { Image(systemName: symbol($0)).font(.system(size: 19)) }, onSelect: onSelect)
    }
    private func symbol(_ mode: CameraViewModel.TopLevelMode) -> String {
        switch mode { case .photo: "camera.fill"; case .video: "video.fill"; case .astro: "moon.stars.fill" }
    }
    private func title(_ mode: CameraViewModel.TopLevelMode) -> String {
        switch mode { case .photo: "拍照"; case .video: "视频"; case .astro: "星空" }
    }
}

struct CyclicModeSwitchButton<Mode: Hashable, Icon: View>: View {
    let current: Mode
    let modes: [Mode]
    let size: CGFloat
    let label: String
    let hint: String
    let icon: (Mode) -> Icon
    let onSelect: (Mode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var swipe: CyclicModeSwipeState<Mode>
    init(current: Mode, modes: [Mode], size: CGFloat, label: String, hint: String,
         @ViewBuilder icon: @escaping (Mode) -> Icon, onSelect: @escaping (Mode) -> Void) {
        self.current = current; self.modes = modes; self.size = size
        self.label = label; self.hint = hint; self.icon = icon; self.onSelect = onSelect
        _swipe = StateObject(wrappedValue: CyclicModeSwipeState(modes: modes))
    }
    var body: some View {
        ZStack {
            if reduceMotion {
                icon(swipe.mode(current, offset: swipe.detent))
                    .id(swipe.mode(current, offset: swipe.detent))
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.08), value: swipe.detent)
                    .rotatingCaptureContent()
            } else {
                let base = Int(floor(swipe.position))
                ZStack {
                    ForEach((base-1)...(base+2), id: \.self) { offset in
                        icon(swipe.mode(current, offset: offset))
                            .rotatingCaptureContent()
                            .offset(y: (CGFloat(offset)-swipe.position)*CyclicModeSwipeState<Mode>.step)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: size-12, height: size-12).clipped()
        .frame(width: size, height: size)
        .modifier(GlassSurface(radius: size/2))
        .overlay {
            ModeSwipeTouchSurface(enabled: isEnabled && !swipe.settling,
                onBegin: { swipe.begin(current) }, onMove: { swipe.move($0) },
                onEnd: { swipe.end($0, reduceMotion: reduceMotion, onSelect: onSelect) })
                .frame(width: size+16, height: size+16)
        }
        .onChange(of: current) { _, _ in swipe.reset() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { swipe.reset() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { swipe.reset() } }
        .onDisappear { swipe.reset() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            CameraHaptics.selectionChanged()
            onSelect(CyclicModeSwipeState<Mode>.wrapped(current, offset: step, choices: modes))
        }
    }
}

@MainActor final class CyclicModeSwipeState<Mode: Hashable>: ObservableObject {
    static var step: CGFloat { 44 }
    private let choices: [Mode]
    @Published private(set) var anchor: Mode?
    @Published private(set) var position: CGFloat = 0
    @Published private(set) var settling = false
    private var tracking = false
    @Published private(set) var detent = 0
    private var finishTask: Task<Void, Never>?
    private let feedback: @MainActor () -> Void
    private let prepare: @MainActor () -> Void
    init(modes: [Mode], feedback: (@MainActor () -> Void)? = nil,
         prepare: (@MainActor () -> Void)? = nil) {
        precondition(!modes.isEmpty)
        self.choices = modes
        self.feedback = feedback ?? { CameraHaptics.selectionChanged() }
        self.prepare = prepare ?? { CameraHaptics.prepare() }
    }
    static func wrapped(_ current: Mode, offset: Int, choices: [Mode]) -> Mode {
        let index = choices.firstIndex(of: current) ?? 0
        return choices[((index+offset)%choices.count+choices.count)%choices.count]
    }
    func mode(_ current: Mode, offset: Int) -> Mode {
        Self.wrapped(anchor ?? current, offset: offset, choices: choices)
    }
    func begin(_ current: Mode) {
        reset(); anchor = current; tracking = true; prepare()
    }
    func move(_ translation: CGPoint) {
        guard tracking, translation.y.isFinite else { return }
        position = min(3000, max(-3000, -translation.y/Self.step))
        if abs(position-CGFloat(detent)) >= 0.6 {
            detent = Int(position.rounded())
            feedback()
        }
    }
    func end(_ translation: CGPoint?, reduceMotion: Bool, onSelect: @escaping (Mode) -> Void) {
        guard tracking, let start = anchor else { return }
        if let translation { move(translation) }
        tracking = false; settling = true
        let offset = translation == nil ? 0 : detent
        let target = Self.wrapped(start, offset: offset, choices: choices)
        let duration = reduceMotion ? 0.08 : 0.16
        withAnimation(.easeOut(duration: duration)) { position = CGFloat(offset) }
        finishTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // Rebase without moving the centered icon while the capture route changes.
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { anchor = target; position = 0; detent = 0 }
            if target != start { onSelect(target) }
            else { reset(); return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            reset() // Rejected/busy capture routes must not leave a stale icon.
        }
    }
    func reset() {
        finishTask?.cancel(); finishTask = nil
        tracking = false; settling = false; anchor = nil; position = 0; detent = 0
    }
}

struct ModeSwipeTouchSurface: UIViewRepresentable {
    let enabled: Bool
    let onBegin: () -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: (CGPoint?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.cancel() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ModeSwipeTouchSurface
        private var tracking = false
        init(_ parent: ModeSwipeTouchSurface) { self.parent = parent }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.enabled, !tracking, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return abs(speed.y) > abs(speed.x)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) { handle(gesture.state, translation: gesture.translation(in: gesture.view)) }
        func handle(_ state: UIGestureRecognizer.State, translation: CGPoint) {
            switch state {
            case .began:
                guard parent.enabled else { return }
                tracking = true; parent.onBegin(); parent.onMove(translation)
            case .changed: if tracking { parent.onMove(translation) }
            case .ended:
                guard tracking else { return }; tracking = false; parent.onEnd(translation)
            case .cancelled, .failed: cancel()
            default: break
            }
        }
        func cancel() { guard tracking else { return }; tracking = false; parent.onEnd(nil) }
    }
}

typealias ModeSwipeState = CyclicModeSwipeState<CameraViewModel.TopLevelMode>

extension CyclicModeSwipeState where Mode == CameraViewModel.TopLevelMode {
    static var modes: [Mode] { [.photo, .video, .astro] }
    convenience init(feedback: (@MainActor () -> Void)? = nil, prepare: (@MainActor () -> Void)? = nil) {
        self.init(modes: Self.modes, feedback: feedback, prepare: prepare)
    }
    static func wrapped(_ current: Mode, offset: Int) -> Mode {
        wrapped(current, offset: offset, choices: modes)
    }
}

