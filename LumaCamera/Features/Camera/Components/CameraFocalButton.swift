import SwiftUI
import UIKit

/// UIButton keeps its normal short-tap tracking. A recognized long press cancels
/// that tracking, so releasing a long press cannot also select the fixed focal length.
struct CameraFocalButton: UIViewRepresentable {
    @Environment(\.captureControlAngle) private var controlAngle
    let title: String
    var imageName: String? = nil
    let selected: Bool
    let enabled: Bool
    let accessibilityLabel: String
    var usesEnclosingGlassBackground = false
    var supportsContinuousZoom = true
    var acceptsNewTouches: () -> Bool = { true }
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDrag: (CGFloat, CGFloat) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIButton {
        let button = makeButton(coordinator: context.coordinator)
        updateUIView(button, context: context)
        return button
    }

    func makeButton(coordinator: Coordinator) -> UIButton {
        let button = CameraFocalControl(type: .custom)
        button.usesEnclosingGlassBackground = usesEnclosingGlassBackground
        button.acceptsNewTouches = acceptsNewTouches
        button.titleLabel?.font = .systemFont(ofSize: 10, weight: .medium)
        button.layer.cornerCurve = .circular
        button.backgroundColor = .clear
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.65
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.lineBreakMode = .byClipping
        button.titleLabel?.baselineAdjustment = .alignCenters
        button.addTarget(coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPress(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 24
        press.cancelsTouchesInView = true
        button.addGestureRecognizer(press)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        // 焦段条已提供整条液态玻璃时，不再叠加选中按钮自己的玻璃层。
        (button as? CameraFocalControl)?.usesEnclosingGlassBackground = usesEnclosingGlassBackground
        (button as? CameraFocalControl)?.acceptsNewTouches = acceptsNewTouches
        button.isSelected = selected
        let transform = CGAffineTransform(rotationAngle: controlAngle * .pi / 180)
        if let imageName {
            button.setTitle(nil, for: .normal)
            let configuration = UIImage.SymbolConfiguration(pointSize: selected ? 16 : 15, weight: .medium)
            button.setImage(UIImage(systemName: imageName, withConfiguration: configuration)?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = selected ? UIColor(AppTheme.accent) : UIColor.white.withAlphaComponent(0.9)
            if button.imageView?.transform != transform {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { button.imageView?.transform = transform }
            }
            button.titleLabel?.transform = .identity
        } else {
            button.setImage(nil, for: .normal)
            button.setTitle(title, for: .normal)
            if button.titleLabel?.transform != transform {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { button.titleLabel?.transform = transform }
            }
            button.imageView?.transform = .identity
            button.setTitleColor(selected ? UIColor(AppTheme.accent) : UIColor.white.withAlphaComponent(0.85), for: .normal)
        }
        button.titleLabel?.font = .systemFont(ofSize: selected ? 12.5 : 10, weight: selected ? .semibold : .medium)
        // The enclosing lens bar already supplies the glass background; a
        // selected inner background produced a visible double layer on tap.
        button.backgroundColor = .clear
        button.isEnabled = enabled
        button.gestureRecognizers?.forEach { $0.isEnabled = enabled && supportsContinuousZoom }
        button.setNeedsLayout()
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityHint = supportsContinuousZoom ? "点击切换焦段，长按打开变焦转盘" : "点击切换固定焦段"
    }

    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
        coordinator.finish()
    }

    final class Coordinator: NSObject {
        var parent: CameraFocalButton
        private var origin: CGFloat?
        init(parent: CameraFocalButton) { self.parent = parent }

        @objc func tap() {
            guard parent.enabled, parent.acceptsNewTouches(), origin == nil else { return }
            parent.onTap()
        }

        @objc func longPress(_ press: UILongPressGestureRecognizer) {
            guard let window = press.view?.window else { return }
            handlePress(press.state, x: press.location(in: window).x, width: window.bounds.width)
        }

        func handlePress(_ state: UIGestureRecognizer.State, x: CGFloat, width: CGFloat) {
            switch state {
            case .began:
                guard parent.enabled, parent.acceptsNewTouches(), parent.supportsContinuousZoom else { return }
                origin = x
                parent.onLongPress()
            case .changed:
                guard let origin else { return }
                parent.onDrag(x - origin, width)
            case .ended, .cancelled, .failed: finish()
            default: break
            }
        }

        func finish() {
            guard origin != nil else { return }
            origin = nil
            parent.onFinish()
        }
    }
}

/// Fit native presets inside narrow panoramic viewports, alongside the mode buttons.
private final class CameraFocalControl: UIButton {
    var usesEnclosingGlassBackground = false
    var acceptsNewTouches: () -> Bool = { true }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, isUserInteractionEnabled, acceptsNewTouches() else { return false }
        // Keep adjacent focal buttons from stealing each other's taps: only 1 pt
        // horizontal overlap into the 2 pt inter-button gap, plus 4 pt vertically.
        return bounds.insetBy(dx: -1, dy: -4).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.width, bounds.height)
        layer.cornerRadius = diameter / 2
        if #available(iOS 26.0, *) {
            if isSelected && !usesEnclosingGlassBackground {
                if !(liquidGlassBackground.effect is UIGlassEffect) {
                    liquidGlassBackground.effect = UIGlassEffect(style: .regular)
                }
                liquidGlassBackground.isHidden = false
            } else {
                liquidGlassBackground.effect = nil
                liquidGlassBackground.isHidden = true
            }
            liquidGlassBackground.frame = bounds
            liquidGlassBackground.layer.cornerRadius = diameter / 2
            liquidGlassBackground.layer.cornerCurve = .circular
            liquidGlassBackground.layer.masksToBounds = true
            if liquidGlassBackground.superview == nil { insertSubview(liquidGlassBackground, at: 0) }
            backgroundColor = .clear
        } else {
            liquidGlassBackground.effect = nil
            liquidGlassBackground.isHidden = true
            backgroundColor = isSelected && !usesEnclosingGlassBackground ? UIColor.white.withAlphaComponent(0.06) : .clear
        }
        sendSubviewToBack(liquidGlassBackground)
        // UIButton lays out an unrotated title using its font-height frame. Once
        // rotated that narrow frame can truncate even "0.5". A square title slot
        // keeps the same usable width in both orientations, without moving hit areas.
        let side = max(1, diameter - 6)
        titleLabel?.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        titleLabel?.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private let liquidGlassBackground: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: nil)
        view.isUserInteractionEnabled = false
        return view
    }()
}

enum CameraLensBarLayout {
    /// Share one diameter with the mode, tools and macro controls, including narrow screens.
    static func controlDiameter(containerWidth: CGFloat, count: Int) -> CGFloat {
        guard containerWidth.isFinite else { return 40 }
        let count = max(1, count)
        let gaps = CGFloat(max(0, count - 1)) * 2
        return max(16, min(40, (containerWidth - 60 - gaps) / CGFloat(count + 2)))
    }
    static func buttonWidth(availableWidth: CGFloat, count: Int) -> CGFloat {
        guard availableWidth.isFinite, count > 0 else { return 42 }
        let spacing = CGFloat(max(0, count - 1)) * 2
        return max(16, min(42, (availableWidth - 4 - spacing) / CGFloat(count)))
    }
}
