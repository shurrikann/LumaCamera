import SwiftUI

/// 水印“地理位置/参数信息”与各自开关成对排列，避免 Toggle 撑满半区后
/// 把标签和开关拉到两端。相机、照片编辑和星空模式共用同一套间距。
struct WatermarkInfoToggles: View {
    @Binding var showsLocation: Bool
    @Binding var showsParameters: Bool

    var body: some View {
        HStack(spacing: 0) {
            pair("地理位置", isOn: $showsLocation)
            pair("参数信息", isOn: $showsParameters)
        }
    }

    private func pair(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.accent)
                .fixedSize()
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
