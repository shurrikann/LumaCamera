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
    @State private var evOrigin: Double?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(camera.targetLocked ? AppTheme.accent : Color.white, lineWidth: camera.targetLockActive ? 1.8 : 1.2)
                .frame(width: 50, height: 50).contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in model.lockFocusExposure() }
                    .exclusively(before: TapGesture(count: 2).onEnded { model.unlockFocusExposure() }))
                .accessibilityLabel(camera.targetLockActive ? model.focusLockMode.accessibilityTitle + "对焦框" : "对焦框")
                .accessibilityHint("长按按所选模式锁定，双击解除锁定")
                .accessibilityAction(named: "锁定曝光") { model.lockFocusExposure() }
                .accessibilityAction(named: "解除曝光锁定") { model.unlockFocusExposure() }
                .position(point)
            if camera.targetLockActive {
                let label = FocusTargetLayout.lockLabel(target: point, viewport: size, topInset: topInset)
                Button { model.toggleFocusLockPicker() } label: {
                    Group {
                        if landscape {
                            VStack(spacing: 2) {
                                Image(systemName: camera.targetLocked ? "lock.fill" : "hourglass")
                                Text(model.focusLockMode.rawValue).lineLimit(1).minimumScaleFactor(0.7)
                            }.frame(width: 34, height: 34).rotatingCaptureContent()
                                .frame(width: 40, height: 40).modifier(PreviewSurface(radius: 12))
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: camera.targetLocked ? "lock.fill" : "hourglass")
                                Text(model.focusLockMode.rawValue)
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                            }.padding(.horizontal, 8).frame(height: 24).modifier(PreviewSurface(radius: 8))
                        }
                    }.font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(camera.targetLocked ? AppTheme.accent : Color.white)
                        .frame(minWidth: 72, minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("锁定模式 " + model.focusLockMode.rawValue)
                    .accessibilityHint("选择仅曝光、仅对焦或同时锁定")
                    .position(label)
                if model.focusLockPickerVisible {
                    let rect = FocusTargetLayout.lockPicker(target: point, viewport: size, topInset: topInset)
                    HStack(spacing: 3) {
                        ForEach(FocusLockMode.allCases) { mode in
                            Button { model.selectFocusLockMode(mode) } label: {
                                Text(mode.rawValue).font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(width: 30, height: 30).rotatingCaptureContent()
                                    .foregroundStyle(model.focusLockMode == mode ? Color.black : Color.white)
                                    .frame(maxWidth: .infinity).frame(height: 32)
                                    .background(model.focusLockMode == mode ? AppTheme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(mode.locksFocus && !camera.demo && !camera.supportsTargetFocusLock).accessibilityLabel(mode.accessibilityTitle)
                                .accessibilityAddTraits(model.focusLockMode == mode ? .isSelected : [])
                        }
                    }.padding(5).frame(width: rect.width, height: rect.height)
                        .background(PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 12), materialOpacity: AppTheme.cameraPopupMaterialOpacity))
                        .position(x: rect.midX, y: rect.midY).transition(.opacity).zIndex(2)
                }
            }
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
        }.frame(width: size.width, height: size.height).animation(AppTheme.popupAnimation, value: model.focusLockPickerVisible).disabled(camera.capturing)
    }
}
