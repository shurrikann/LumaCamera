import SwiftUI
import AVFoundation

extension CameraView {
    var manualPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Button { model.closePopups() } label: {
                    Image(systemName: "xmark").rotatingCaptureContent().font(.system(size: 18, weight: .light)).frame(width: 36, height: 36)
                }.accessibilityLabel("关闭参数面板")
                Spacer()
                Text(model.parameterTitle(model.parameter)).rotatingCaptureContent().font(.system(size: 15, weight: .medium))
                Spacer()
                Button { model.toggleAutomatic() } label: {
                    Text(model.parameterAutomatic ? "A" : "M").rotatingCaptureContent().font(.system(size: 19, weight: .medium))
                        .foregroundStyle(AppTheme.accent).frame(width: 36, height: 36)
                }.disabled(!model.parameterCanEdit).accessibilityLabel("切换参数自动与手动")
            }
            Text(model.parameterDisplay).font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.45)
                .contentTransition(.numericText()).frame(height: 42)
            CameraRuler(value: model.editableParameterBinding, range: model.parameterRange, tint: AppTheme.accent,
                        temperature: model.parameter == .wb, tintAdjustment: model.parameter == .tint,
                        reversedScale: model.parameter == .shutter, quantizedValues: model.parameterTickValues)
                .disabled(!model.parameterCanEdit).padding(.horizontal, 12)
                .accessibilityHint(model.parameter == .shutter ? "刻度左侧为慢快门，右侧为快快门" : "滑动调整参数")
            if model.parameter == .focus {
                HStack {
                    Image(systemName: "person.fill")
                    Spacer()
                    Image(systemName: "mountain.2.fill")
                }
                .font(.system(size: 19, weight: .regular)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 18).padding(.top, -4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("左侧人像表示近焦，右侧山峰表示远焦；数值越小越近，越大越远")
            }
            if model.parameter == .wb { whiteBalancePresets }
            if !camera.demo && !model.parameterCanEdit {
                Text(model.captureKind == .video && model.cinematicVideoEnabled && model.parameter == .focus
                     ? "电影模式由系统跟踪主体对焦"
                     : "当前镜头不支持此参数")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 42)
        .modifier(PopupSurface(radius: 36, glass: true,
                               materialOpacity: AppTheme.cameraPopupMaterialOpacity,
                               bottomRadius: parameterBottomCornerRadius))
    }

    var whiteBalancePresets: some View {
        HStack(spacing: 4) {
            Button { model.activateParameterAuto() } label: {
                Text("AWB").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.parameterAutomatic ? AppTheme.accent : .white.opacity(0.7))
                    .frame(maxWidth: .infinity).frame(height: 42)
            }
            ForEach(Array(model.whiteBalancePresetValues.enumerated()), id: \.offset) { index, value in
                Button { model.editableParameterBinding.wrappedValue = value } label: {
                    Image(systemName: ["lightbulb", "light.beacon.max", "sun.max", "cloud", "house"][index])
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity).frame(height: 42)
                }.accessibilityLabel("\(Int(value)) 开尔文")
            }
        }.disabled(!model.parameterCanEdit)
    }
}
