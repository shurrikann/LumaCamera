import SwiftUI
import UIKit

/// A fresh pan owns each new contact on the visible wheel, above hidden focal buttons.
/// Installing this surface does not cancel the button's already recognized long press.
struct CameraZoomPanSurface: UIViewRepresentable {
    let region: CGRect
    let excluded: [CGRect]
    let dialWidth: CGFloat
    let onBegin: () -> Void
    let onDrag: (CGFloat, CGFloat) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> CameraZoomTouchView {
        let view = CameraZoomTouchView()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "camera.zoom.panSurface"
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: CameraZoomTouchView, context: Context) {
        context.coordinator.parent = self
        view.region = region; view.excluded = excluded
    }
    static func dismantleUIView(_ view: CameraZoomTouchView, coordinator: Coordinator) { coordinator.finish() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CameraZoomPanSurface
        private var dragging = false
        init(parent: CameraZoomPanSurface) { self.parent = parent }
        @objc func pan(_ pan: UIPanGestureRecognizer) {
            handlePan(pan.state, translation: pan.translation(in:pan.view).x)
        }
        func handlePan(_ state: UIGestureRecognizer.State, translation: CGFloat) {
            switch state {
            case .began:
                dragging = true; parent.onBegin()
                parent.onDrag(translation,parent.dialWidth)
            case .changed:
                guard dragging else { return }
                parent.onDrag(translation,parent.dialWidth)
            case .ended:
                if dragging { parent.onDrag(translation,parent.dialWidth) }
                finish()
            case .cancelled, .failed: finish()
            default: break
            }
        }
        func finish() {
            guard dragging else { return }
            dragging = false; parent.onFinish()
        }
    }
}

final class CameraZoomTouchView: UIView {
    var region = CGRect.zero
    var excluded: [CGRect] = []
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return region.contains(point) && !excluded.contains { $0.contains(point) }
    }
}

struct CameraZoomDialLayout {
    let preview: CGRect
    let dialWidth: CGFloat
    let top: CGFloat
    let visible: CGRect
    init(size: CGSize, ratio: FrameRatio, openGatePortraitRatio: CGFloat? = nil) {
        preview = CameraPreviewLayout.frame(in:CGSize(width:max(1,size.width-16),height:size.height),ratio:ratio,openGatePortraitRatio:openGatePortraitRatio).offsetBy(dx:8,dy:0)
        dialWidth = max(1,size.width-16)
        top = min(size.height-CameraControlLayout.zoomBottom-100,preview.maxY-100)
        visible = CGRect(x:preview.minX,y:max(top,preview.minY),width:preview.width,height:max(0,preview.maxY-max(top,preview.minY)))
    }
}
