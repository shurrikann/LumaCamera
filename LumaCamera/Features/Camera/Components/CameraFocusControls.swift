import SwiftUI

struct FocusTargetLayout {
    static func sunCenter(target: CGPoint, viewport: CGSize, topInset: CGFloat = 0, bottomInset: CGFloat = 0) -> CGPoint {
        let x = target.x + 48 <= viewport.width - 22 ? target.x + 48 : target.x - 48
        return CGPoint(x: min(max(x, 22), max(22, viewport.width - 22)),
                       y: min(max(target.y, topInset + 72), max(topInset + 72, viewport.height - bottomInset - 72)))
    }
    static func lockLabel(target: CGPoint, viewport: CGSize, topInset: CGFloat = 0) -> CGPoint {
        CGPoint(x: min(max(target.x, 42), max(42, viewport.width - 42)),
                y: min(max(target.y < topInset + 55 ? target.y + 43 : target.y - 43, 20), max(20, viewport.height - 20)))
    }
    static func lockPicker(target: CGPoint, viewport: CGSize, topInset: CGFloat = 0) -> CGRect {
        let width = max(1, min(210, viewport.width - 12)), height: CGFloat = 42
        let label = lockLabel(target: target, viewport: viewport, topInset: topInset)
        let y = label.y < target.y ? label.y - 43 : label.y + 43
        let center = CGPoint(x: min(max(label.x, width / 2 + 6), max(width / 2 + 6, viewport.width - width / 2 - 6)),
                             y: min(max(y, height / 2 + 6), max(height / 2 + 6, viewport.height - height / 2 - 6)))
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    static func draggedEV(origin: Double, translation: CGFloat) -> Double {
        guard origin.isFinite, translation.isFinite else { return origin.isFinite ? origin : 0 }
        return min(max(origin - Double(translation) / 24, -5), 5)
    }
}

struct CameraFocusControls: View {
    @Environment(\.captureControlsLandscape) private var landscape
    @ObservedObject var model: CameraViewModel
    @ObservedObject var camera: CameraEngine
    let point: CGPoint
    let size: CGSize
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var showsTargetBox = true
    var showsEV = true
    @State private var evOrigin: Double?
    var body: some View {
        ZStack {
            if showsTargetBox {
            RoundedRectangle(cornerRadius: 3).stroke(camera.targetLocked ? AppTheme.accent : Color.white, lineWidth: camera.targetLockActive ? 1.8 : 1.2)
                .frame(width: 50, height: 50).contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in model.lockFocusExposure() }
                    .exclusively(before: TapGesture(count: 2).onEnded { model.unlockFocusExposure() }))
                .accessibilityLabel(camera.targetLockActive ? model.focusLockSummary + "对焦框" : "对焦框")
                .accessibilityHint("长按按所选模式锁定，双击解除锁定")
                .accessibilityAction(named: "锁定曝光") { model.lockFocusExposure() }
                .accessibilityAction(named: "解除曝光锁定") { model.unlockFocusExposure() }
                .position(point)
            }
            if camera.targetLockActive || model.focusLockPickerVisible || model.subjectTrackingActive {
                let label = FocusTargetLayout.lockLabel(target: point, viewport: size, topInset: topInset)
                let applied = camera.targetExposureLocked || camera.targetFocusLocked || model.subjectTrackingActive
                Button { model.toggleFocusLockPicker() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: applied ? "lock.fill" : "hourglass")
                        Text(model.focusLockSummary).lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .modifier(PreviewSurface(radius: 8))
                    .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(applied ? AppTheme.accent : Color.white)
                        .frame(minWidth: 72, minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("锁定模式 " + model.focusLockSummary)
                    .accessibilityHint("独立开关 AE 与 AF；AF 再点切换 AF* 连续追踪")
                    .position(label)
                if model.focusLockPickerVisible {
                    let rect = FocusTargetLayout.lockPicker(target: point, viewport: size, topInset: topInset)
                    HStack(spacing: 5) {
                        Button { model.toggleExposureLockPreference() } label: {
                            Text("AE").font(.system(size: 8, weight: .semibold))
                                .frame(width: 44, height: 18)
                                .foregroundStyle(model.exposureLockEnabled ? Color.black : Color.white)
                                .background(model.exposureLockEnabled ? AppTheme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("锁定曝光")
                            .accessibilityAddTraits(model.exposureLockEnabled ? .isSelected : [])
                        Button { model.cycleFocusTrackingPreference() } label: {
                            Text(model.effectiveFocusTrackingState.label ?? "AF").font(.system(size: 8, weight: .semibold))
                                .frame(width: 44, height: 18)
                                .foregroundStyle(model.effectiveFocusTrackingState != .off ? Color.black : Color.white)
                                .background(model.effectiveFocusTrackingState != .off ? AppTheme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .disabled(!camera.demo && !camera.supportsTargetFocusLock)
                            .accessibilityLabel(model.effectiveFocusTrackingState == .continuous ? "AF 连续追踪" : "锁定对焦")
                            .accessibilityAddTraits(model.effectiveFocusTrackingState != .off ? .isSelected : [])
                    }.padding(3).frame(width: 100, height: 28)
                        .background(PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 12), materialOpacity: AppTheme.cameraPopupMaterialOpacity))
                        .position(x: rect.midX, y: rect.midY).transition(.opacity).zIndex(2)
                }
            }
            if showsEV {
            let center = FocusTargetLayout.sunCenter(target: point, viewport: size, topInset: topInset, bottomInset: bottomInset)
            VStack(spacing: 5) {
                ZStack {
                    Capsule().fill(.white.opacity(0.28)).frame(width: 1, height: 96)
                    Image(systemName: "sun.max.fill").font(.system(size: 17)).foregroundStyle(AppTheme.accent)
                        .frame(width: 26, height: 26).modifier(PreviewSurface(radius: 13))
                        .offset(y: -CGFloat(model.ev / 5) * 48)
                }.frame(width: 40, height: 110)
                Text(String(format: "%+.1f", model.ev)).font(.system(size: 9, design: .monospaced)).foregroundStyle(AppTheme.accent)
            }.frame(width: 44, height: 138).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if evOrigin == nil { evOrigin = model.ev; model.beginFocusEVAdjustment() }
                        model.adjustFocusEV(FocusTargetLayout.draggedEV(origin: evOrigin ?? model.ev, translation: drag.translation.height))
                    }.onEnded { _ in evOrigin = nil; model.finishFocusEVAdjustment() })
                .accessibilityElement(children: .ignore).accessibilityLabel("小太阳曝光补偿")
                .accessibilityValue(String(format: "%+.1f EV", model.ev))
                .accessibilityAdjustableAction { direction in
                    model.beginFocusEVAdjustment()
                    model.adjustFocusEV(model.ev + (direction == .increment ? 0.1 : -0.1))
                    model.finishFocusEVAdjustment()
                }
                .position(center)
            }
        }.frame(width: size.width, height: size.height).animation(AppTheme.popupAnimation, value: model.focusLockPickerVisible).disabled(camera.capturing)
    }
}


/// Orange while the subject is tracked; white/gray during the 5s reacquire window.
struct SubjectTrackingOverlay: View {
    let box: CGRect
    let lost: Bool

    var body: some View {
        GeometryReader { proxy in
            let color = lost ? Color.white.opacity(0.72) : AppTheme.accent
            // A tracking box is a focus indicator, not a segmentation mask.
            // Keep it fixed-size and move only its center so locking a larger
            // subject does not make the frame grow around it.
            let side: CGFloat = 54
            RoundedRectangle(cornerRadius: 5)
                .stroke(color, lineWidth: lost ? 1.4 : 2)
                .frame(width: side, height: side)
                .position(x: box.midX * proxy.size.width, y: box.midY * proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityLabel(lost ? "主体跟踪丢失，正在重新寻找" : "主体已锁定")
    }
}
