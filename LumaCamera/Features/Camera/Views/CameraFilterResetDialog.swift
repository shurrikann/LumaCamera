import SwiftUI

extension CameraView {
    var filterResetDialog: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { model.dismissFilterReset() }
                .accessibilityLabel("取消重置滤镜")
            VStack(spacing: 18) {
                Text("重置" + model.style.title + "？").font(.system(size: 17, weight: .semibold))
                Text("恢复当前滤镜的默认参数，其他滤镜保持不变。")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { model.dismissFilterReset() } label: {
                        Text("取消").frame(maxWidth: .infinity).frame(height: 44)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    Button { model.confirmFilterReset() } label: {
                        Text("重置").fontWeight(.semibold).foregroundStyle(AppTheme.accentForeground)
                            .frame(maxWidth: .infinity).frame(height: 44).background(AppTheme.accent, in: Capsule())
                    }.accessibilityLabel("确认重置当前滤镜")
                }.font(.system(size: 14)).buttonStyle(.plain)
            }
            .padding(22).frame(maxWidth: 310).modifier(PopupSurface(radius: 28, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity)).orientedPopup(maximumWidth: 310)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

/// 单项数值输入：输入框＋还原图标，下方取消/确定；键盘只移动弹窗，底层相机布局不动。
struct FilterNumericInputDialog<Model: FilterEditingControls>: View {
    @ObservedObject var model: Model
    @FocusState private var inputFocused: Bool
    @State private var keyboardFrame: CGRect = .null
    private var parameter: FilterParameter { model.filterNumericParameter ?? .exposure }
    private func dismiss() {
        inputFocused = false
        withAnimation(AppTheme.popupAnimation) { model.dismissFilterNumericInput() }
    }
    var body: some View {
        GeometryReader { geometry in
            let keyboardOverlap = keyboardFrame.isNull ? 0 : max(0, geometry.frame(in: .global).maxY - keyboardFrame.minY)
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityLabel("取消输入")
                VStack(spacing: 12) {
                    Text(FilterDialLayout.title(parameter)).font(.system(size: 15, weight: .medium))
                    HStack(spacing: 8) {
                        TextField("数值", text: $model.filterNumericDraft)
                            .keyboardType(.numbersAndPunctuation).submitLabel(.done)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 17, design: .monospaced)).monospacedDigit()
                            .focused($inputFocused)
                            .accessibilityLabel("参数数值")
                            .accessibilityIdentifier("filter.numeric.input")
                            .onSubmit { if model.filterNumericValue != nil { model.confirmFilterNumericInput() } }
                        Button { model.restoreFilterNumericDraft() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(AppTheme.accent).frame(width: 40, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("还原默认值")
                        .accessibilityIdentifier("filter.numeric.restore")
                    }
                    .padding(.leading, 12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    Text("范围 \(parameter.text(parameter.range.lowerBound)) ～ \(parameter.text(parameter.range.upperBound))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        .frame(height: 14).opacity(model.filterNumericValue == nil ? 1 : 0)
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Text("取消").frame(maxWidth: .infinity).frame(height: 40)
                                .background(.white.opacity(0.07), in: Capsule())
                        }.accessibilityIdentifier("filter.numeric.cancel")
                        Button {
                            inputFocused = false
                            withAnimation(AppTheme.popupAnimation) { model.confirmFilterNumericInput() }
                        } label: {
                            Text("确定").foregroundStyle(AppTheme.accentForeground)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(AppTheme.accent, in: Capsule())
                        }
                        .disabled(model.filterNumericValue == nil)
                        .accessibilityIdentifier("filter.numeric.confirm")
                    }.font(.system(size: 14)).buttonStyle(.plain)
                }
                .padding(20).frame(maxWidth: 310)
                .modifier(PopupSurface(radius: 24, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
                .padding(.horizontal, 18)
                .padding(.bottom, min(geometry.size.height, keyboardOverlap))
            }
        }
        .accessibilityIdentifier("filter.numeric.dialog")
        .task { inputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(AppTheme.popupAnimation) { keyboardFrame = frame }
        }
    }
}
