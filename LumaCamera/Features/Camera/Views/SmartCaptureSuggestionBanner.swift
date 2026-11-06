import SwiftUI

extension CameraView {
    /// One non-blocking hint above the preview. It never moves the shutter or
    /// lens controls; A mode may apply it, M mode only shows it as reference.
    func smartSuggestionBanner(_ suggestion: SmartCaptureSuggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
            Text(suggestion.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            if model.mode == .auto, let action = suggestion.actionTitle {
                Button {
                    model.applySmartSuggestion()
                } label: {
                    Text(action)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action)
            } else {
                Text("参考")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Button { model.dismissSmartSuggestion() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭智拍建议")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(PreviewSurface(radius: 14, opacity: 0.18, curve: .continuous, interactive: false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("智拍建议：\(suggestion.title)")
    }
}
