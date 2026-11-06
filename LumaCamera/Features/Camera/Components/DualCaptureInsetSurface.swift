import SwiftUI
import UIKit

/// 原生手势把拖动、双击与单击分开：单击只消费触摸，不穿透到取景对焦，也不交换画面。
@MainActor struct DualCaptureInsetSurface: UIViewRepresentable {
    let rect: CGRect
    let previewSize: CGSize
    let onMove: (CGRect, CGSize) -> Void
    let onSwap: () -> Void
    var accessibilityTitle = "双拍小窗"
    var accessibilityDescription = "拖动移动位置，双击交换主副画面"

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> InsetView {
        let view = InsetView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = accessibilityTitle
        view.accessibilityHint = accessibilityDescription
        view.accessibilityTraits = .button
        view.accessibilityIdentifier = "camera.dualCapture.swap"
        view.activate = { context.coordinator.parent.onSwap() }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.require(toFail: pan)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: pan)
        view.addGestureRecognizer(pan); view.addGestureRecognizer(doubleTap); view.addGestureRecognizer(singleTap)
        return view
    }
    func updateUIView(_ uiView: InsetView, context: Context) {
        context.coordinator.parent = self
    }
    final class InsetView: UIView {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool { activate?(); return true }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width * 0.075).contains(point)
        }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: DualCaptureInsetSurface
        private var origin: CGRect?
        init(_ parent: DualCaptureInsetSurface) { self.parent = parent }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard parent.previewSize.width > 0, parent.previewSize.height > 0 else { return }
            let state = gesture.state
            if state == .began { origin = parent.rect }
            if state == .began || state == .changed || state == .ended {
                let delta = gesture.translation(in: gesture.view?.window)
                parent.onMove(origin ?? parent.rect,
                    CGSize(width: delta.x / parent.previewSize.width, height: delta.y / parent.previewSize.height))
            }
            if state == .ended || state == .cancelled || state == .failed { origin = nil }
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { parent.onSwap() }
        }
        @objc func singleTap(_ gesture: UITapGestureRecognizer) { /* 单击不操作，避免穿透到背后的对焦手势。 */ }
    }
}
