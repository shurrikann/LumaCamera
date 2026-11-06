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
