import SwiftUI
import UIKit

/// 相机与照片编辑共用控件契约；只转发各自配方，不共享拍摄/编辑状态。
@MainActor
protocol FilterEditingControls: ObservableObject {
    var style: FilmStyle { get }
    var filterEditorTab: FilterEditorTab { get set }
    var filterDialPadEnabled: Bool { get }
    var filterDialControlsEnabled: Bool { get }
    var filterNumericParameter: FilterParameter? { get }
    var filterNumericDraft: String { get set }
    var filterNumericValue: Double? { get }
    func filterParameterBinding(_ parameter: FilterParameter) -> Binding<Double>
    func filterParameterPairBinding(_ x: FilterParameter, _ y: FilterParameter) -> Binding<CGPoint>
    func filterParameterText(_ parameter: FilterParameter) -> String
    func setFilterParameterEditing(_ editing: Bool)
    func resetCurrentFilterTab()
    func presentFilterNumericInput(_ parameter: FilterParameter)
    func dismissFilterNumericInput()
    func restoreFilterNumericDraft()
    func confirmFilterNumericInput()
    #if DEBUG
    var filterDialPadFrameForTesting: CGRect { get set }
    var captureButtonFramesForTesting: [String: CGRect] { get set }
    #endif
}

extension CameraViewModel: FilterEditingControls {
    var filterDialPadEnabled: Bool { preferences.filterDialPad }
    var filterDialControlsEnabled: Bool { filterControlsEnabled && !camera.videoBusy && !filterResetVisible }
}

/// 调色盘仅替换编辑控件；参数 key、渲染与旧版滑条共用，设置默认关闭。
struct FilterDialLayout {
    let x: FilterParameter
    let y: FilterParameter
    let left: FilterParameter
    let right: FilterParameter
    let bottom: [FilterParameter]
    var vertical: [FilterParameter] = []

    static func layout(for tab: FilterEditorTab) -> Self {
        switch tab {
        case .color: return .init(x: .temperature, y: .tint, left: .strength, right: .saturation, bottom: [.fade])
        case .light: return .init(x: .exposure, y: .contrast, left: .highlights, right: .shadows, bottom: [.brightness])
        case .effects: return .init(x: .softness, y: .halation, left: .detail, right: .vignette, bottom: [],
                                   vertical: [.detail, .softness, .halation, .grainSize, .grainSaturation, .aberration, .vignette])
        }
    }
    var parameters: [FilterParameter] { vertical.isEmpty ? [x, y, left, right] + bottom : vertical }
    static func title(_ parameter: FilterParameter) -> String {
        switch parameter {
        case .exposure: return "曝光"
        case .detail: return "细节"
        case .halation: return "胶片光晕"
        default: return parameter.title
        }
    }
}

struct FilterDialEditor<Model: FilterEditingControls>: View {
    @ObservedObject var model: Model
    let tab: FilterEditorTab
    private var layout: FilterDialLayout { .layout(for: tab) }
    private var enabled: Bool { model.filterDialControlsEnabled }
    private var bottomParameter: FilterParameter { layout.bottom.first ?? .fade }

    var body: some View {
        Group {
            if tab == .effects {
                textureSliders
                    .transition(.opacity)
            } else {
                paletteControls
                    .transition(.opacity)
            }
        }
        .padding(.top, 8).padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.dialPad")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.filterDialPadFrameForTesting = $0 }
        #endif
        .onChange(of: tab) { _, _ in model.setFilterParameterEditing(false) }
        .onDisappear {
            model.dismissFilterNumericInput()
            model.setFilterParameterEditing(false)
            #if DEBUG
            model.filterDialPadFrameForTesting = .zero
            #endif
        }
    }

    private var paletteControls: some View {
        VStack(spacing: 9) {
            parameterReadout
            // 两侧轨道嵌在同一个横向区域内；宽度随弹窗适配，不扩大弹窗或移动焦段条。
            HStack(spacing: 8) {
                rail(layout.left)
                FilterDialPad(style: padStyle, point: model.filterParameterPairBinding(layout.x, layout.y),
                              xParameter: layout.x, yParameter: layout.y,
                              xLabel: padXLabel, yLabel: padYLabel, enabled: enabled,
                              onEditingChanged: { model.setFilterParameterEditing($0) })
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        model.captureButtonFramesForTesting["filter.dial.plane"] = $0
                    }
                    #endif
                rail(layout.right)
            }
            .padding(8)
            .frame(height: 140)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .id(tab)
            .transition(.opacity)
            bottomSlider
        }
    }

    /// 质感参数从零独立增加，用并排竖轨替代左下角起步的二维盘；沿用同高容器。
    private var textureSliders: some View {
        VStack(spacing: 9) {
            // 数值独立成行，与下方七条轨道使用相同的列宽和间距。
            HStack(spacing: 4) {
                ForEach(layout.vertical) { parameter in
                    numericValueButton(parameter)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8).frame(height: 34)
            HStack(spacing: 4) {
                ForEach(layout.vertical) { parameter in
                    FilterDialRail(title: FilterDialLayout.title(parameter), value: model.filterParameterBinding(parameter),
                                   range: parameter.range, enabled: enabled, texture: true, showsValue: false,
                                   onEditingChanged: { model.setFilterParameterEditing($0) })
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("filter.texture." + parameter.rawValue)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 14)
            .frame(height: 184)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .frame(height: 227)
    }

    private var parameterReadout: some View {
        HStack(spacing: 4) {
            ForEach(layout.parameters) { parameter in
                VStack(spacing: 2) {
                    Text(FilterDialLayout.title(parameter)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    numericValueButton(parameter)
                }.frame(maxWidth: .infinity)
            }
        }.frame(height: 34)
    }

    private var bottomSlider: some View {
        HStack(spacing: 6) {
            Text(FilterDialLayout.title(bottomParameter))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                // 中央盘面距左边56点；名称右对齐，距轨道仅6点。
                .lineLimit(2).frame(width: 50, alignment: .trailing)
            FilterDialTrack(value: model.filterParameterBinding(bottomParameter), range: bottomParameter.range,
                            enabled: enabled, vertical: false,
                            onEditingChanged: { model.setFilterParameterEditing($0) })
                .accessibilityLabel("滤镜" + FilterDialLayout.title(bottomParameter))
                .accessibilityIdentifier("filter.dial.bottomSlider")
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.captureButtonFramesForTesting["filter.dial.horizontalTrack"] = $0
                }
                #endif
        }
        // 与盘面的8点内边距＋40点竖轨＋8点间距相同，左右端点精确对齐。
        .padding(.trailing, 56)
        .id(bottomParameter)
        .transition(.opacity)
        .frame(height: 34)
    }

    private func numericValueButton(_ parameter: FilterParameter) -> some View {
        Button {
            withAnimation(AppTheme.popupAnimation) { model.presentFilterNumericInput(parameter) }
        } label: {
            Text(parameter == .strength && model.style == .original ? "—" :
                 parameter.numericDisplayText(model.filterParameterBinding(parameter).wrappedValue))
                .font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 32, minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || (parameter == .strength && model.style == .original))
        .accessibilityLabel("输入" + FilterDialLayout.title(parameter))
        .accessibilityIdentifier("filter.numeric." + parameter.rawValue)
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
    static let trackThickness: CGFloat = 28
    static let thumbDiameter: CGFloat = 22
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
    var texture = false
    var showsValue = true
    let onEditingChanged: (Bool) -> Void
    private var textureTitle: String {
        switch title {
        case "胶片光晕": return "胶片\n光晕"
        case "颗粒大小": return "颗粒\n大小"
        case "颗粒饱和度": return "颗粒\n饱和度"
        default: return title
        }
    }
    var body: some View {
        VStack(spacing: 4) {
            if texture && showsValue {
                Text(String(format: "%.0f", value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(AppTheme.accent).frame(height: 22)
            } else if !texture {
                Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            FilterDialTrack(value: $value, range: range, enabled: enabled, vertical: true,
                            onEditingChanged: onEditingChanged)
            if texture {
                Text(textureTitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).lineLimit(2).frame(height: 32, alignment: .top)
            } else {
                Text(String(format: "%.0f", value)).font(.system(size: 10, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .allowsHitTesting(enabled)
        .accessibilityElement().accessibilityLabel(title)
        .accessibilityValue(String(format: "%.0f", value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let step = (range.upperBound - range.lowerBound) / 100
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// 新版横竖滑条共用包裹式轨道；旧版继续使用原生Slider，不经过此控件。
private struct FilterDialTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool
    let vertical: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let length = vertical ? size.height : size.width
            let fraction = FilterDialGeometry.fraction(value, in: range)
            let position = FilterDialGeometry.inset + (length - 2 * FilterDialGeometry.inset) * (vertical ? 1 - fraction : fraction)
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.14)],
                                         startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing))
                    .frame(width: vertical ? FilterDialGeometry.trackThickness : size.width,
                           height: vertical ? size.height : FilterDialGeometry.trackThickness)
                    .position(x: size.width / 2, y: size.height / 2)
                Circle().fill(.white)
                    .frame(width: FilterDialGeometry.thumbDiameter, height: FilterDialGeometry.thumbDiameter)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.8), lineWidth: 1.5))
                    .position(x: vertical ? size.width / 2 : position, y: vertical ? position : size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                if !editing { editing = true; onEditingChanged(true) }
                value = FilterDialGeometry.value(at: vertical ? size.height - g.location.y : g.location.x,
                                                length: length, in: range)
            }.onEnded { _ in editing = false; onEditingChanged(false) })
        }
        .allowsHitTesting(enabled)
        .accessibilityElement()
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
                matteTexture
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
                    context.fill(Path(ellipseIn: CGRect(x: xx - 1.2, y: yy - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.48)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .allowsHitTesting(false)
    }

    /// 固定磨砂纹理只绘制在控件表面，不参与预览或成片，也不使用逐帧随机噪声。
    private var matteTexture: some View {
        Canvas { context, size in
            for row in 0..<Int(size.height / 4) {
                for column in 0..<Int(size.width / 4) {
                    let seed = (row * 37 + column * 61) % 17
                    let x = CGFloat(column) * 4 + CGFloat(seed % 4) * 0.6
                    let y = CGFloat(row) * 4 + CGFloat(seed % 3) * 0.7
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.8, height: 0.8)),
                                 with: .color(seed.isMultiple(of: 2) ? .white.opacity(0.07) : .black.opacity(0.045)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .allowsHitTesting(false)
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
        Text(text).font(.system(size: 8, weight: .semibold)).foregroundStyle(AppTheme.accent)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(10)
    }
}
