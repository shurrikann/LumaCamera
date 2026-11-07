import SwiftUI

extension CameraView {
    var filterAdjustmentPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { model.flushFilterSettings(); withAnimation(AppTheme.popupAnimation) { filters.showStrength = false } } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32)
                }.accessibilityLabel("返回滤镜列表")
                Spacer(minLength: 0)
                Text(model.style.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.presentFilterReset() } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("滤镜参数操作")
                Button { model.flushFilterSettings(); model.togglePanel(.film) } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32)
                }.accessibilityLabel("收起滤镜参数")
            }.font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
            FilterAdjustmentTabs(model: model)
            if model.preferences.filterDialPad {
                FilterDialEditor(model: model, tab: model.filterEditorTab)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.filterEditorTab.parameters) { parameter in
                            HStack(spacing: 10) {
                                Text(parameter.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 72, alignment: .leading)
                                Slider(value: model.filterParameterBinding(parameter), in: parameter.range, onEditingChanged: { model.setFilterParameterEditing($0) })
                                    .tint(AppTheme.accent).disabled(!model.filterControlsEnabled || camera.videoBusy || (parameter == .strength && model.style == .original))
                                    .accessibilityLabel("滤镜" + parameter.title)
                                Text(model.filterParameterText(parameter))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                                    .foregroundStyle(AppTheme.accent).frame(width: 38, alignment: .trailing)
                            }.frame(minHeight: 34)
                        }
                    }.padding(.vertical, 8)
                }.id(model.filterEditorTab).scrollIndicators(.visible).scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("filter-adjustment-parameters-scroll")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .frame(height: model.preferences.filterDialPad ? 348 : 334)
        .onDisappear { model.setFilterParameterEditing(false); model.dismissFilterReset(); model.flushFilterSettings() }
    }
}

/// 两处入口共用分类选项卡和分类还原，保证按钮布局/动画一致。
struct FilterAdjustmentTabs<Model: FilterEditingControls>: View {
    @ObservedObject var model: Model
    var onClose: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
                ForEach(FilterEditorTab.allCases) { tab in
                    Button {
                        model.setFilterParameterEditing(false)
                        if model.filterDialPadEnabled {
                            withAnimation(AppTheme.popupAnimation) { model.filterEditorTab = tab }
                        } else { model.filterEditorTab = tab }
                    } label: {
                        Text(tab.rawValue).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.filterEditorTab == tab ? AppTheme.accentForeground : .white.opacity(0.7))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(model.filterEditorTab == tab ? AppTheme.accent : .white.opacity(0.05), in: Capsule())
                    }.accessibilityAddTraits(model.filterEditorTab == tab ? .isSelected : [])
                }
                Button { model.resetCurrentFilterTab() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.filterDialControlsEnabled)
                .accessibilityLabel("还原当前" + model.filterEditorTab.rawValue + "参数")
                .accessibilityIdentifier("filter.resetCurrentTab")
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8)).frame(width: 28, height: 32)
                    }.buttonStyle(.plain).accessibilityLabel("收起滤镜参数")
                }
            }
    }
}
