import SwiftUI
import UIKit

@MainActor
@Observable
final class PreviewControlContrastMonitor {
    private struct Control {
        let frame: CGRect
        let foreground: Double
        let target: Double
        var hysteresis = PreviewContrastHysteresis()
    }

    @ObservationIgnored private var controls: [UUID: Control] = [:]
    private(set) var enhanced: Set<UUID> = []

    func register(_ id: UUID, frame: CGRect, accent: Bool, icon: Bool) {
        let previous = controls[id]?.hysteresis ?? PreviewContrastHysteresis()
        controls[id] = Control(frame: frame, foreground: accent ? PreviewContrastSample.orange : 1,
                               target: icon ? 3 : 4.5, hysteresis: previous)
    }

    func remove(_ id: UUID) {
        controls.removeValue(forKey: id)
        if enhanced.contains(id) { enhanced.remove(id) }
    }

    func run(frame: @MainActor () -> CGRect, image: @MainActor () -> UIImage?) async {
        var lastImage: CGImage?
        var sample: PreviewContrastSample?
        while !Task.isCancelled {
            if let current = image()?.cgImage, !controls.isEmpty {
                if current !== lastImage {
                    sample = await Task.detached(priority: .utility) {
                        PreviewContrastSample.render(current)
                    }.value
                    lastImage = current
                }
                guard !Task.isCancelled else { return }
                if let sample {
                    update(sample: sample, imageSize: CGSize(width: current.width, height: current.height),
                           preview: frame(), time: ProcessInfo.processInfo.systemUptime)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func update(sample: PreviewContrastSample, imageSize: CGSize, preview: CGRect, time: TimeInterval) {
        var next: Set<UUID> = []
        for (id, var control) in controls {
            let region = PreviewContrastSample.imageRegion(for: control.frame, preview: preview, imageSize: imageSize)
            let contrast = sample.minimumContrast(in: region, foreground: control.foreground)
            control.hysteresis.update(contrast: contrast, target: control.target, at: time)
            controls[id] = control
            if control.hysteresis.enhanced { next.insert(id) }
        }
        if next != enhanced { enhanced = next }
    }
}

extension EnvironmentValues {
    @Entry var previewEdgeEnhanced = false
    @Entry fileprivate var previewControlContrastMonitor: PreviewControlContrastMonitor? = nil
}

private struct PreviewControlContrastScope: ViewModifier {
    let active: Bool
    let image: @MainActor () -> UIImage?
    @State private var monitor = PreviewControlContrastMonitor()
    @State private var previewFrame = CGRect.zero
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.previewControlContrastMonitor, monitor)
            .onPreferenceChange(PreviewContrastFrameKey.self) { previewFrame = $0 }
            .task(id: active && scenePhase == .active) {
                guard active && scenePhase == .active else { return }
                await monitor.run(frame: { previewFrame }, image: image)
            }
    }
}

private struct PreviewContrastFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let frame = nextValue()
        if !frame.isEmpty { value = frame }
    }
}

private struct PreviewControlEdge: ViewModifier {
    let accent: Bool
    let icon: Bool
    let glyphSize: CGSize?
    @Environment(\.previewControlContrastMonitor) private var monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.captureControlAngle) private var controlAngle
    @State private var id = UUID()
    @State private var measuredFrame = CGRect.zero

    func body(content: Content) -> some View {
        let enhanced = monitor?.enhanced.contains(id) == true
        content
            .environment(\.previewEdgeEnhanced, enhanced)
            .shadow(color: .black.opacity(enhanced && glyphSize == nil ? 0.94 : 0), radius: 0.85, y: 0.35)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: enhanced)
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                guard let glyphSize else { return frame }
                let angle = controlAngle * .pi / 180
                let width = min(frame.width, glyphSize.width * abs(cos(angle)) + glyphSize.height * abs(sin(angle)))
                let height = min(frame.height, glyphSize.width * abs(sin(angle)) + glyphSize.height * abs(cos(angle)))
                return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
            } action: { frame in
                measuredFrame = frame
                monitor?.register(id, frame: frame, accent: accent, icon: icon)
            }
            .onAppear { monitor?.register(id, frame: measuredFrame, accent: accent, icon: icon) }
            .onChange(of: accent) { _, _ in
                monitor?.register(id, frame: measuredFrame, accent: accent, icon: icon)
            }
            .onDisappear { monitor?.remove(id) }
    }
}

extension View {
    func previewControlContrastSource(active: Bool, image: @escaping @MainActor () -> UIImage?) -> some View {
        modifier(PreviewControlContrastScope(active: active, image: image))
    }

    func previewControlContrastFrame() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PreviewContrastFrameKey.self, value: proxy.frame(in: .global))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    func previewControlContrast(accent: Bool = false, icon: Bool = false, glyphSize: CGSize? = nil) -> some View {
        modifier(PreviewControlEdge(accent: accent, icon: icon, glyphSize: glyphSize))
    }
}
