import SwiftUI
import UIKit

struct CameraRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    var temperature = false
    var tintAdjustment = false
    var reversedScale = false
    var quantizedValues: [Double]? = nil
    var rulerScale: CGFloat? = nil
    @State private var dragOrigin: Double?
    @State private var detents = CameraRulerDetents()
    @State private var tickFeedback = UIImpactFeedbackGenerator(style: .light)
    @State private var majorFeedback = UIImpactFeedbackGenerator(style: .medium)
    @Environment(\.isEnabled) private var isEnabled

    private var displayTickValues: [Double]? {
        guard let quantizedValues else { return nil }
        let valid = quantizedValues.filter(\.isFinite).sorted()
        guard valid.count > 1 else { return nil }
        return reversedScale ? Array(valid.reversed()) : valid
    }

    private var effectiveRulerScale: CGFloat {
        if let rulerScale, rulerScale.isFinite, rulerScale > 0 { return rulerScale }
        return CameraRulerMapping.scale(tickCount: displayTickValues?.count ?? 101)
    }

    private func tickIndex(for value: Double, in ticks: [Double]) -> Int? {
        CameraRulerTickValues.nearestIndex(to: value, in: ticks)
    }

    var body: some View {
        GeometryReader { geometry in
            let ticks = displayTickValues
            let currentIndex = ticks.flatMap { tickIndex(for: value, in: $0) }
            let fraction = ticks.flatMap { values in
                currentIndex.map { Double($0) / Double(values.count - 1) }
            } ?? CameraRulerMapping.fraction(value: value, range: range, reversed: reversedScale)
            Canvas { context, size in
                let tickCount = ticks?.count ?? 101
                for index in 0..<tickCount {
                    let position = tickCount > 1 ? Double(index) / Double(tickCount - 1) : 0.5
                    let x = size.width / 2 + (position - fraction) * size.width * (ticks == nil ? 3 : effectiveRulerScale)
                    guard x >= 0, x <= size.width else { continue }
                    var path = Path()
                    let major = index % 5 == 0
                    path.move(to: CGPoint(x: x, y: major ? 15 : 23))
                    path.addLine(to: CGPoint(x: x, y: 38))
                    let color: Color
                    if tintAdjustment { color = Color(red: 0.3 + position * 0.55, green: 0.8 - position * 0.45, blue: 0.4 + position * 0.4) }
                    else if temperature { color = Color(hue: 0.64 - position * 0.59, saturation: 0.35, brightness: 0.8) }
                    else { color = .white.opacity(major ? 0.7 : 0.35) }
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            }
            .overlay {
                Capsule().fill(tint).frame(width: 3, height: 42)
                    .shadow(color: tint.opacity(0.2), radius: 4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard isEnabled else { return }
                    if dragOrigin == nil {
                        dragOrigin = value
                        if ticks != nil, let currentIndex { detents.reset(atTick: currentIndex) }
                        else { detents.reset(at: value, range: range, reversed: reversedScale) }
                        tickFeedback.prepare(); majorFeedback.prepare()
                    }
                    if let ticks, let origin = dragOrigin, let originIndex = tickIndex(for: origin, in: ticks) {
                        let nextIndex = CameraRulerMapping.draggedTickIndex(originIndex: originIndex,
                            translation: drag.translation.width, width: geometry.size.width,
                            tickCount: ticks.count, scale: effectiveRulerScale)
                        value = ticks[nextIndex]
                        feedback(tickIndex: nextIndex)
                    } else {
                        value = CameraRulerMapping.draggedValue(origin: dragOrigin ?? value, translation: drag.translation.width,
                                                              width: geometry.size.width, range: range, reversed: reversedScale)
                        feedback()
                    }
                }
                .onEnded { _ in dragOrigin = nil })
        }.frame(height: 46)
            .accessibilityElement().accessibilityLabel("参数刻度")
            .accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                if let ticks = displayTickValues, let index = tickIndex(for: value, in: ticks) {
                    detents.reset(atTick: index)
                    let change = direction == .increment ? 1 : -1
                    let next = min(max(index + change, 0), ticks.count - 1)
                    value = ticks[next]
                    feedback(tickIndex: next)
                } else {
                    detents.reset(at: value, range: range, reversed: reversedScale)
                    let step = (range.upperBound - range.lowerBound) / 100
                    value = min(max(value + (direction == .increment ? step : -step) * (reversedScale ? -1 : 1), range.lowerBound), range.upperBound)
                    feedback()
                }
            }
    }
    private func feedback() {
        switch detents.move(to: value, range: range, reversed: reversedScale) {
        case .tick: tickFeedback.impactOccurred(intensity: 0.35); tickFeedback.prepare()
        case .major: majorFeedback.impactOccurred(intensity: 0.8); majorFeedback.prepare()
        case nil: break
        }
    }

    private func feedback(tickIndex: Int) {
        switch detents.move(toTick: tickIndex) {
        case .tick: tickFeedback.impactOccurred(intensity: 0.35); tickFeedback.prepare()
        case .major: majorFeedback.impactOccurred(intensity: 0.8); majorFeedback.prepare()
        case nil: break
        }
    }
}

enum CameraRulerMapping {
    static func fraction(value: Double, range: ClosedRange<Double>, reversed: Bool = false) -> Double {
        let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return reversed ? 1 - fraction : fraction
    }
    static func draggedValue(origin: Double, translation: CGFloat, width: CGFloat, range: ClosedRange<Double>, reversed: Bool = false) -> Double {
        guard origin.isFinite, translation.isFinite, width.isFinite, width > 0 else { return origin }
        // A moving ruler follows the finger. Reverse both its tick order and value mapping.
        // Shutter uses log2(seconds), with long durations on the left and short ones on the right.
        let delta = -Double(translation / max(width * 3, 1)) * (range.upperBound - range.lowerBound) * (reversed ? -1 : 1)
        return min(max(origin + delta, range.lowerBound), range.upperBound)
    }
}
