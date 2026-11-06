import SwiftUI
import UIKit

/// 调色盘仅替换编辑控件；参数 key、渲染与旧版滑条共用，设置默认关闭。
struct FilterDialLayout {
    let x: FilterParameter
    let y: FilterParameter
    let left: FilterParameter
    let right: FilterParameter
    let bottom: [FilterParameter]

    static func layout(for tab: FilterEditorTab) -> Self {
        switch tab {
        case .color: return .init(x: .temperature, y: .tint, left: .strength, right: .saturation, bottom: [.fade])
        case .light: return .init(x: .exposure, y: .contrast, left: .highlights, right: .shadows, bottom: [.brightness])
        case .effects: return .init(x: .softness, y: .halation, left: .detail, right: .vignette,
                                   bottom: [.aberration, .grainSize, .grainSaturation])
        }
    }
    var parameters: [FilterParameter] { [x, y, left, right] + bottom }
    static func title(_ parameter: FilterParameter) -> String {
        switch parameter {
        case .exposure: return "曝光"
        case .detail: return "细节"
        case .halation: return "胶片光晕"
        default: return parameter.title
        }
    }
}

struct FilterDialEditor: View {
    @ObservedObject var model: CameraViewModel
    let tab: FilterEditorTab
    @State private var textureParameter: FilterParameter = .aberration
    private var layout: FilterDialLayout { .layout(for: tab) }
    private var enabled: Bool { model.filterControlsEnabled && !model.camera.videoBusy && !model.filterResetVisible }
    private var bottomParameter: FilterParameter { tab == .effects ? textureParameter : layout.bottom[0] }

    var body: some View {
        VStack(spacing: 9) {
            parameterReadout
            // 两侧轨道嵌在同一个横向区域内；宽度随弹窗适配，不扩大弹窗或移动焦段条。
            HStack(spacing: 8) {
                rail(layout.left)
                FilterDialPad(style: padStyle, point: model.filterParameterPairBinding(layout.x, layout.y),
                              xParameter: layout.x, yParameter: layout.y,
                              xLabel: padXLabel, yLabel: padYLabel, enabled: enabled,
                              onEditingChanged: { model.setFilterParameterEditing($0) })
                rail(layout.right)
            }
            .padding(8)
            .frame(height: 140)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            bottomSelector
            bottomSlider
        }
        .padding(.top, 8).padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.dialPad")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.filterDialPadFrameForTesting = $0 }
        #endif
        .onChange(of: tab) { _, _ in model.setFilterParameterEditing(false) }
        .onDisappear {
            model.setFilterParameterEditing(false)
            #if DEBUG
            model.filterDialPadFrameForTesting = .zero
            #endif
        }
    }

    private var parameterReadout: some View {
        HStack(spacing: 4) {
            ForEach([layout.x, layout.y, layout.left, layout.right]) { parameter in
                VStack(spacing: 2) {
                    Text(FilterDialLayout.title(parameter)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(model.filterParameterText(parameter))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.white)
                }.frame(maxWidth: .infinity)
            }
        }.frame(height: 34)
    }

    /// 质感三项共享最底部滑条；其它分类保留同高的单项标签，切换时布局不跳动。
    private var bottomSelector: some View {
        HStack(spacing: 8) {
            ForEach(layout.bottom) { parameter in
                Button {
                    guard tab == .effects, textureParameter != parameter else { return }
                    model.setFilterParameterEditing(false)
                    withAnimation(AppTheme.popupAnimation) { textureParameter = parameter }
                } label: {
                    Text(FilterDialLayout.title(parameter))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(bottomParameter == parameter ? AppTheme.accent : .white.opacity(0.65))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(.white.opacity(bottomParameter == parameter ? 0.08 : 0), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filter.dial.bottom." + parameter.rawValue)
                .accessibilityAddTraits(bottomParameter == parameter ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.frame(height: 30)
    }

    private var bottomSlider: some View {
        HStack(spacing: 8) {
            Text(FilterDialLayout.title(bottomParameter))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(2).frame(width: 60, alignment: .leading)
            Slider(value: model.filterParameterBinding(bottomParameter), in: bottomParameter.range,
                   onEditingChanged: { model.setFilterParameterEditing($0) })
                .tint(AppTheme.accent).disabled(!enabled)
                .accessibilityLabel("滤镜" + FilterDialLayout.title(bottomParameter))
                .accessibilityIdentifier("filter.dial.bottomSlider")
            Text(model.filterParameterText(bottomParameter))
                .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundStyle(AppTheme.accent).frame(width: 32, alignment: .trailing)
        }
        .id(bottomParameter)
        .transition(.opacity)
        .frame(height: 34)
    }

    private func rail(_ parameter: FilterParameter) -> some View {
        FilterDialRail(title: FilterDialLayout.title(parameter), value: model.filterParameterBinding(parameter),
                       range: parameter.range, enabled: enabled && (parameter != .strength || model.style != .original),
                       onEditingChanged: { model.setFilterParameterEditing($0) })
            .frame(width: 40)
            .accessibilityIdentifier("filter.dial.rail." + parameter.rawValue)
    }
    private var padStyle: FilterDialPad.Style {
        switch tab { case .color: return .color; case .light: return .light; case .effects: return .texture }
    }
    private var padXLabel: (String, String) {
        switch tab { case .color: return ("冷", "暖"); case .light: return ("欠曝", "过曝"); case .effects: return ("柔光弱", "柔光强") }
    }
    private var padYLabel: (String, String) {
        switch tab { case .color: return ("洋红", "绿"); case .light: return ("高对比", "低对比"); case .effects: return ("光晕强", "光晕弱") }
    }
}

/// 轨道与盘面使用相同的触点内缩，避免端点处手柄显示与实际参数位置不一致。
enum FilterDialGeometry {
    static let inset: CGFloat = 13
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    static func value(at location: CGFloat, length: CGFloat, in range: ClosedRange<Double>) -> Double {
        let f = min(max(Double((location - inset) / max(1, length - 2 * inset)), 0), 1)
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }
}

private struct FilterDialRail: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
                .lineLimit(1).minimumScaleFactor(0.8)
            GeometryReader { proxy in
                let h = proxy.size.height
                ZStack {
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 12).padding(.vertical, FilterDialGeometry.inset)
                    Circle().fill(.white).frame(width: 21, height: 21)
                        .overlay(Circle().stroke(AppTheme.accent.opacity(0.8), lineWidth: 1.5))
                        .position(x: proxy.size.width/2, y: FilterDialGeometry.inset + (h - 2 * FilterDialGeometry.inset) * (1 - FilterDialGeometry.fraction(value, in: range)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard enabled else { return }
                    if !editing { editing = true; onEditingChanged(true) }
                    value = FilterDialGeometry.value(at: h - g.location.y, length: h, in: range)
                }.onEnded { _ in editing = false; onEditingChanged(false) })
            }
            Text(String(format: "%.0f", value)).font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        }
        .allowsHitTesting(enabled)
        .accessibilityElement().accessibilityLabel(title)
        .accessibilityValue(String(format: "%.0f", value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let step = (range.upperBound - range.lowerBound) / 100
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
        .onDisappear { if editing { onEditingChanged(false) } }
    }
}

private struct FilterDialPad: View {
    enum Style { case color, light, texture }
    let style: Style
    @Binding var point: CGPoint
    let xParameter: FilterParameter
    let yParameter: FilterParameter
    private var xRange: ClosedRange<Double> { xParameter.range }
    private var yRange: ClosedRange<Double> { yParameter.range }
    let xLabel: (String, String)
    let yLabel: (String, String)
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    private var nx: Double { FilterDialGeometry.fraction(Double(point.x), in: xRange) }
    private var ny: Double { FilterDialGeometry.fraction(Double(point.y), in: yRange) }
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
                    .position(x: 13 + CGFloat(FilterDialGeometry.fraction(0, in: xRange)) * (size.width - 26),
                              y: 13 + (1 - CGFloat(FilterDialGeometry.fraction(0, in: yRange))) * (size.height - 26))
                Circle().fill(.white).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(AppTheme.accent, lineWidth: 2))
                    .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                    .position(x: 13 + CGFloat(nx) * (size.width - 26),
                              y: 13 + (1 - CGFloat(ny)) * (size.height - 26))
                axisLabel(xLabel.0, alignment: .leading, size: size)
                axisLabel(xLabel.1, alignment: .trailing, size: size)
                axisLabel(yLabel.0, alignment: .top, size: size)
                axisLabel(yLabel.1, alignment: .bottom, size: size)
            }
            .contentShape(RoundedRectangle(cornerRadius: 19))
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                if !editing { editing = true; onEditingChanged(true) }
                // 两轴一次提交，避免每个触摸事件触发两次配方保存与渲染请求。
                point = CGPoint(x: FilterDialGeometry.value(at: g.location.x, length: size.width, in: xRange),
                                y: FilterDialGeometry.value(at: size.height - g.location.y, length: size.height, in: yRange))
            }.onEnded { _ in
                editing = false; onEditingChanged(false)
            })
            .allowsHitTesting(enabled)
        }
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { Double(point.x) }, set: { point = CGPoint(x: $0, y: point.y) }), in: xRange)
                    .accessibilityLabel(FilterDialLayout.title(xParameter))
                Slider(value: Binding(get: { Double(point.y) }, set: { point = CGPoint(x: point.x, y: $0) }), in: yRange)
                    .accessibilityLabel(FilterDialLayout.title(yParameter))
            }.disabled(!enabled)
        }
        .onDisappear { if editing { onEditingChanged(false) } }
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
}
