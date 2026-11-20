import SwiftUI

struct PhotoFilterBadge: View {
    var body: some View {
        Image(systemName: "camera.filters").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("已应用滤镜").allowsHitTesting(false)
    }
}

struct PhotoAstroBadge: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 19)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("星空模式拍摄")
            .allowsHitTesting(false)
    }
}
