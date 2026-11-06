import SwiftUI
import UIKit

/// Filter editor with the optional dial-pad layout. Legacy sliders remain in CameraFilterAdjustmentPanel.
struct FilterDialEditor: View {
    @ObservedObject var model: CameraViewModel
    let tab: FilterEditorTab

    private var enabled: Bool { model.filterControlsEnabled && !model.camera.videoBusy }

    var body: some View {
        VStack(spacing: 9) {
            parameterReadout
            HStack(spacing: 10) {
                rail(leftSpec)
                pad
                rail(rightSpec)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.dialPad")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.filterDialPadFrameForTesting = $0 }
        #endif
        .onDisappear {
            model.setFilterParameterEditing(false)
            #if DEBUG
            model.filterDialPadFrameForTesting = .zero
            #endif
        }
    }

    private var parameters: [FilterParameter] {
        switch tab {
        case .color: return [.temperature, .tint, .saturation]
        case .light: return [.exposure, .contrast, .highlights, .shadows]
        case .effects: return [.detail, .grainSize]
        }
    }

    private var parameterReadout: some View {
        HStack(spacing: 0) {
            ForEach(parameters) { parameter in
                Spacer(minLength: 2)
                VStack(spacing: 1) {
                    Text(displayName(parameter)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.52))
                    Text(readoutText(parameter)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit().foregroundStyle(parameter == .strength ? AppTheme.accent : .white)
                }
                Spacer(minLength: 2)
            }
            if tab == .effects {
                Spacer(minLength: 2)
                VStack(spacing: 1) {
                    Text("光晕").font(.system(size: 9)).foregroundStyle(.white.opacity(0.52))
                    Text(valueText(glowValue)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit().foregroundStyle(.white)
                }
                Spacer(minLength: 2)
            }
        }
        .frame(height: 32)
        .background(.white.opacity(0.055), in: Capsule())
    }

    private var pad: some View {
        FilterDialPad(style: padStyle, x: padXBinding, y: padYBinding,
                      xRange: padXRange, yRange: padYRange,
                      xLabel: padXLabel, yLabel: padYLabel,
                      enabled: enabled,
                      onEditingChanged: { model.setFilterParameterEditing($0) })
            .frame(width: 220, height: 220)
    }

    private func rail(_ spec: DialRailSpec) -> some View {
        FilterDialRail(title: spec.title, value: spec.binding, range: spec.range,
                       gradient: spec.gradient, enabled: enabled,
                       onEditingChanged: { model.setFilterParameterEditing($0) })
            .frame(width: 44, height: 220)
    }

    private var padStyle: FilterDialPad.Style {
        switch tab { case .color: return .color; case .light: return .light; case .effects: return .texture }
    }
    private var padXBinding: Binding<Double> {
        switch tab { case .color: return model.filterParameterBinding(.temperature); case .light: return model.filterParameterBinding(.exposure); case .effects: return model.filterParameterBinding(.detail) }
    }
    private var padYBinding: Binding<Double> {
        switch tab {
        case .color:
            return model.filterParameterBinding(.tint)
        case .light:
            // 上方柔、下方硬：界面纵轴是 -contrast。
            return Binding(get: { -model.filterAdjustments[.contrast] },
                           set: { model.filterAdjustments[.contrast] = -$0 })
        case .effects:
            // 底部干净、顶部颗粒；0 在轨底，与暗角/光晕的零位一致。
            return model.filterParameterBinding(.grainSize)
        }
    }
    private var padXRange: ClosedRange<Double> {
        switch tab { case .color: return -100...100; case .light: return -5...5; case .effects: return -100...100 }
    }
    private var padYRange: ClosedRange<Double> {
        switch tab { case .color: return -100...100; case .light: return -100...100; case .effects: return 0...100 }
    }
    private var padXLabel: (String, String) {
        switch tab { case .color: return ("冷", "暖"); case .light: return ("欠曝", "过曝"); case .effects: return ("柔", "锐") }
    }
    private var padYLabel: (String, String) {
        switch tab { case .color: return ("绿", "洋红"); case .light: return ("柔", "硬"); case .effects: return ("颗粒", "干净") }
    }
    private var leftSpec: DialRailSpec {
        switch tab {
        case .color: return .init(title: "浓度", binding: model.filterParameterBinding(.strength), range: 0...100,
                                  gradient: LinearGradient(colors: [Color(red: 0.96, green: 0.78, blue: 0.62), AppTheme.accent, Color(white: 0.28)], startPoint: .top, endPoint: .bottom))
        case .light: return .init(title: "高光", binding: model.filterParameterBinding(.highlights), range: -100...100,
                                  gradient: LinearGradient(colors: [Color(white: 0.96), Color(white: 0.72), Color(white: 0.34)], startPoint: .top, endPoint: .bottom))
        case .effects: return .init(title: "暗角", binding: model.filterParameterBinding(.vignette), range: 0...100,
                                    gradient: LinearGradient(colors: [Color(white: 0.88), Color(white: 0.48), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
        }
    }
    private var rightSpec: DialRailSpec {
        switch tab {
        case .color: return .init(title: "饱和度", binding: model.filterParameterBinding(.saturation), range: -100...100,
                                  gradient: LinearGradient(colors: [Color(white: 0.92), Color(red: 0.93, green: 0.56, blue: 0.62), Color(red: 0.65, green: 0.54, blue: 0.60)], startPoint: .top, endPoint: .bottom))
        case .light: return .init(title: "阴影", binding: model.filterParameterBinding(.shadows), range: -100...100,
                                  gradient: LinearGradient(colors: [Color(white: 0.30), Color(white: 0.56), Color(white: 0.94)], startPoint: .top, endPoint: .bottom))
        case .effects: return .init(title: "光晕", binding: glowBinding, range: 0...100,
                                    gradient: LinearGradient(colors: [Color(red: 0.94, green: 0.78, blue: 0.57), Color(red: 0.63, green: 0.54, blue: 0.48), Color(white: 0.28)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var glowBinding: Binding<Double> {
        Binding(get: { max(model.filterAdjustments[.softness], model.filterAdjustments[.halation]) },
                set: { value in
                    model.filterAdjustments[.softness] = value
                    model.filterAdjustments[.halation] = value
                })
    }
    private var glowValue: Double { max(model.filterAdjustments[.softness], model.filterAdjustments[.halation]) }
    private func valueText(_ value: Double) -> String { String(format: "%.0f", value) }
    private func displayName(_ parameter: FilterParameter) -> String {
        switch parameter {
        case .exposure: return "曝光"
        case .detail: return "细节"
        case .grainSize: return "颗粒"
        default: return parameter.title
        }
    }
    private func readoutText(_ parameter: FilterParameter) -> String {
        if parameter == .strength && model.style == .original { return "—" }
        return model.filterParameterText(parameter)
    }
}

private struct DialRailSpec {
    let title: String
    let binding: Binding<Double>
    let range: ClosedRange<Double>
    let gradient: LinearGradient
}

private struct FilterDialRail: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: LinearGradient
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let topInset: CGFloat = 27
            let bottomInset: CGFloat = 25
            let usable = max(1, h - topInset - bottomInset)
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous).fill(.white.opacity(0.055))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(gradient).frame(width: 16)
                    .padding(.top, topInset).padding(.bottom, bottomInset)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 0.5).padding(.top, topInset).padding(.bottom, bottomInset))
                Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                    .position(x: proxy.size.width/2, y: 13)
                Text(valueText).font(.system(size: 8, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72)).position(x: proxy.size.width/2, y: h - 12)
                Circle().fill(.white).frame(width: 25, height: 25)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.85), lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .position(x: proxy.size.width/2, y: topInset + usable * (1 - fraction))
            }
            .contentShape(RoundedRectangle(cornerRadius: 21))
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                if !editing { editing = true; onEditingChanged(true) }
                let y = min(max(g.location.y, topInset), topInset + usable)
                let f = 1 - Double((y - topInset) / usable)
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            }.onEnded { _ in
                guard enabled else { return }
                editing = false; onEditingChanged(false)
            })
            .opacity(enabled ? 1 : 0.36)
            .allowsHitTesting(enabled)
        }
        .accessibilityElement().accessibilityLabel(title)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let step = (range.upperBound - range.lowerBound) / 100
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
    private var valueText: String { String(format: "%.0f", value) }
}

private struct FilterDialPad: View {
    enum Style { case color, light, texture }
    let style: Style
    @Binding var x: Double
    @Binding var y: Double
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    let xLabel: (String, String)
    let yLabel: (String, String)
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    private var nx: Double { fraction(x, in: xRange) }
    private var ny: Double { fraction(y, in: yRange) }
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 19, style: .continuous).fill(baseGradient)
                RoundedRectangle(cornerRadius: 19, style: .continuous).fill(overlayGradient).blendMode(.softLight)
                dots
                Path { p in
                    p.move(to: CGPoint(x: size.width/2, y: 10)); p.addLine(to: CGPoint(x: size.width/2, y: size.height-10))
                    p.move(to: CGPoint(x: 10, y: size.height/2)); p.addLine(to: CGPoint(x: size.width-10, y: size.height/2))
                }.stroke(.white.opacity(0.16), lineWidth: 1)
                Circle().stroke(.white.opacity(0.66), lineWidth: 1).frame(width: 7, height: 7)
                    .position(x: size.width/2, y: size.height/2)
                Circle().fill(.white).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(AppTheme.accent, lineWidth: 2))
                    .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                    .position(x: max(13, min(size.width-13, CGFloat(nx) * size.width)),
                              y: max(13, min(size.height-13, (1 - CGFloat(ny)) * size.height)))
                axisLabel(xLabel.0, alignment: .leading, size: size)
                axisLabel(xLabel.1, alignment: .trailing, size: size)
                axisLabel(yLabel.0, alignment: .top, size: size)
                axisLabel(yLabel.1, alignment: .bottom, size: size)
            }
            .contentShape(RoundedRectangle(cornerRadius: 19))
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                if !editing { editing = true; onEditingChanged(true) }
                let px = min(max(g.location.x, 0), size.width)
                let py = min(max(g.location.y, 0), size.height)
                x = value(Double(px / size.width), in: xRange)
                y = value(1 - Double(py / size.height), in: yRange)
            }.onEnded { _ in
                guard enabled else { return }
                editing = false; onEditingChanged(false)
            })
            .opacity(enabled ? 1 : 0.4)
            .allowsHitTesting(enabled)
        }
        .accessibilityElement().accessibilityLabel("二维调色盘")
        .accessibilityValue("\(xLabel.0)\(Int(x))，\(yLabel.0)\(Int(y))")
    }
    private var dots: some View {
        Canvas { context, size in
            let step: CGFloat = 15
            for yy in stride(from: step, to: size.height, by: step) {
                for xx in stride(from: step, to: size.width, by: step) {
                    context.fill(Path(ellipseIn: CGRect(x: xx, y: yy, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.36)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .blendMode(.overlay)
    }
    private var baseGradient: LinearGradient {
        switch style {
        case .color: return LinearGradient(colors: [
            Color(red: 0.54, green: 0.65, blue: 0.91), Color(red: 0.78, green: 0.80, blue: 0.88),
            Color(red: 0.94, green: 0.88, blue: 0.86), Color(red: 0.96, green: 0.76, blue: 0.75),
            Color(red: 0.93, green: 0.61, blue: 0.63)], startPoint: .leading, endPoint: .trailing)
        case .light: return LinearGradient(colors: [Color(white: 0.08), Color(white: 0.28), Color(white: 0.58), Color(white: 0.86), Color(white: 0.96)], startPoint: .leading, endPoint: .trailing)
        case .texture: return LinearGradient(colors: [Color(red: 0.91, green: 0.89, blue: 0.84), Color(red: 0.76, green: 0.73, blue: 0.67), Color(red: 0.54, green: 0.52, blue: 0.48), Color(red: 0.24, green: 0.23, blue: 0.22)], startPoint: .leading, endPoint: .trailing)
        }
    }
    private var overlayGradient: LinearGradient {
        switch style {
        case .color: return LinearGradient(colors: [Color.green.opacity(0.28), .clear, Color.pink.opacity(0.34)], startPoint: .bottom, endPoint: .top)
        case .light: return LinearGradient(colors: [Color.white.opacity(0.18), .clear, Color.black.opacity(0.32)], startPoint: .bottom, endPoint: .top)
        case .texture: return LinearGradient(colors: [Color(red: 0.95, green: 0.82, blue: 0.63).opacity(0.34), .clear, Color.black.opacity(0.30)], startPoint: .bottom, endPoint: .top)
        }
    }
    @ViewBuilder private func axisLabel(_ text: String, alignment: Alignment, size: CGSize) -> some View {
        Text(text).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.72))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(10)
    }
    private func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    private func value(_ fraction: Double, in range: ClosedRange<Double>) -> Double {
        let f = min(max(fraction, 0), 1)
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }
}
