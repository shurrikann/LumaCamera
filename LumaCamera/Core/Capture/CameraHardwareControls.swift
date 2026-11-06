import AVFoundation

struct CameraHardwareControlSpec {
    let id: String
    let title: String
    let icon: String
    let range: ClosedRange<Float>
    let value: Float
    var choices: [Float] = []
    var choiceTitles: [String] = []
}

/// All AVFoundation control construction and value updates stay on the session queue.
final class CameraHardwareControls: NSObject, AVCaptureSessionControlsDelegate {
    private let session: AVCaptureSession
    private let queue: DispatchQueue
    private let action: (String, Float) -> Void
    private let activated: () -> Void
    private var specs: [CameraHardwareControlSpec] = []
    private var controls: [AVCaptureControl] = []
    private var revision = UUID()

    init(session: AVCaptureSession, queue: DispatchQueue,
         action: @escaping (String, Float) -> Void, activated: @escaping () -> Void) {
        self.session = session; self.queue = queue; self.action = action; self.activated = activated
        super.init()
    }

    func update(_ requested: [CameraHardwareControlSpec], enabled: Bool) {
        guard session.supportsControls else { return }
        let valid = requested.filter { $0.range.lowerBound.isFinite && $0.range.upperBound.isFinite &&
            $0.range.lowerBound < $0.range.upperBound && $0.value.isFinite }
        let unchanged = specs.count == valid.count && zip(specs, valid).allSatisfy {
            $0.id == $1.id && $0.range == $1.range && $0.choices == $1.choices && $0.choiceTitles == $1.choiceTitles
        }
        if !unchanged {
            revision = UUID()
            let token = revision
            controls.forEach { session.removeControl($0) }
            controls = []; specs = []
            session.setControlsDelegate(self, queue: queue)
            for spec in valid.prefix(session.maxControlsCount) {
                let control: AVCaptureControl
                if !spec.choices.isEmpty && spec.choices.count == spec.choiceTitles.count {
                    let picker = AVCaptureIndexPicker(spec.title, symbolName: spec.icon, localizedIndexTitles: spec.choiceTitles)
                    picker.setActionQueue(queue) { [weak self] index in
                        guard let self, self.revision == token, spec.choices.indices.contains(index) else { return }
                        self.action(spec.id, spec.choices[index])
                    }
                    control = picker
                } else {
                    let slider = AVCaptureSlider(spec.title, symbolName: spec.icon, in: spec.range)
                    slider.setActionQueue(queue) { [weak self] value in
                        guard let self, self.revision == token, value.isFinite else { return }
                        self.action(spec.id, value)
                    }
                    if spec.id == "A.zoom" { slider.localizedValueFormat = "%@×" }
                    control = slider
                }
                guard session.canAddControl(control) else { continue }
                session.addControl(control); controls.append(control); specs.append(spec)
            }
        }
        for (control, spec) in zip(controls, specs) {
            control.isEnabled = enabled
            guard let current = valid.first(where: { $0.id == spec.id }) else { continue }
            if let slider = control as? AVCaptureSlider {
                let value = min(max(current.value, spec.range.lowerBound), spec.range.upperBound)
                if abs(slider.value - value) > 0.0001 { slider.value = value }
            } else if let picker = control as? AVCaptureIndexPicker,
                      let index = spec.choices.indices.min(by: { abs(spec.choices[$0] - current.value) < abs(spec.choices[$1] - current.value) }),
                      picker.selectedIndex != index { picker.selectedIndex = index }
        }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { activated() }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { activated() }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}

    #if DEBUG
    var identifiersForTesting: [String] { specs.map(\.id) }
    #endif
}
