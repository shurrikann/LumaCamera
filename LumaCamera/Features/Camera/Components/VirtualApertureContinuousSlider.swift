import SwiftUI
import UIKit

/// 在已有玻璃胶囊内使用固定轨道图，避免iOS26系统滑块按下时再生成动态背景。
/// 仍使用UISlider的原生连续拖动、无障碍调节及取消事件，不改变光圈数值映射。
struct VirtualApertureContinuousSlider: UIViewRepresentable {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UISlider {
        let control = UISlider()
        control.minimumValue = 0; control.maximumValue = 1; control.isContinuous = true
        control.backgroundColor = .clear
        let minimum = Self.track(color: UIColor(AppTheme.accent))
        let maximum = Self.track(color: UIColor.white.withAlphaComponent(0.24))
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 22)).image { _ in
            UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x:0,y:0,width:32,height:22), cornerRadius:11).fill()
        }
        // 官方UISlider文档说明自定义轨道图会停止系统动态外观；所有按压状态使用同一组图。
        for state in [UIControl.State.normal, .highlighted, .selected, [.highlighted,.selected], .disabled] {
            control.setMinimumTrackImage(minimum, for: state)
            control.setMaximumTrackImage(maximum, for: state)
            control.setThumbImage(thumb, for: state)
        }
        control.accessibilityIdentifier = "camera.virtualAperture.slider"
        control.accessibilityLabel = "虚拟光圈"
        context.coordinator.attach(control)
        return control
    }
    func updateUIView(_ control: UISlider, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = isEnabled
        let next = Float(min(max(value,0),1))
        if abs(control.value-next) > 0.000001 { control.setValue(next, animated:false) }
        control.accessibilityValue = VirtualApertureRenderer.label(VirtualApertureRenderer.value(at:value))
    }
    static func dismantleUIView(_ control: UISlider, coordinator: Coordinator) { coordinator.finish() }
    private static func track(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size:CGSize(width:8,height:4)).image { _ in
            color.setFill(); UIBezierPath(roundedRect:CGRect(x:0,y:0,width:8,height:4),cornerRadius:2).fill()
        }.resizableImage(withCapInsets:UIEdgeInsets(top:0,left:3,bottom:0,right:3),resizingMode:.stretch)
    }
    final class Coordinator: NSObject {
        var parent: VirtualApertureContinuousSlider
        private var editing = false
        init(parent: VirtualApertureContinuousSlider) { self.parent = parent }
        func attach(_ control: UISlider) {
            control.addTarget(self,action:#selector(begin),for:.touchDown)
            control.addTarget(self,action:#selector(changed(_:)),for:.valueChanged)
            control.addTarget(self,action:#selector(finish),for:[.touchUpInside,.touchUpOutside,.touchCancel])
        }
        @objc func begin() { guard !editing else { return }; editing = true; parent.onEditingChanged(true) }
        @objc func changed(_ control: UISlider) { parent.value = Double(control.value) }
        @objc func finish() { guard editing else { return }; editing = false; parent.onEditingChanged(false) }
    }
}
