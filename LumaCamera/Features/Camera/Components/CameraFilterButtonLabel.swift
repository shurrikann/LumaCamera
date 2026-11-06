import SwiftUI

/// Device and filter names have separate bounded lines, keeping the capture row stable.
struct CameraFilterButtonLabel: View {
    let title: String
    var equipment: String? = nil
    let active: Bool
    var size: CGFloat = 52
    var dimmed = false
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "camera.filters").font(.system(size: equipment == nil ? 19 : 17))
                .foregroundStyle(active ? AppTheme.accent : .white)
            VStack(spacing: 0) {
                Text(title).font(.system(size: equipment == nil ? 8 : 7.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle).frame(width: size - 8, height: 11)
                if let equipment {
                    Text(equipment).font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle).frame(width: size - 8, height: 9)
                }
            }
        }.opacity(dimmed ? AppTheme.disabledControlOpacity : 1)
            .rotatingCaptureContent().frame(width: size, height: size).modifier(GlassSurface(radius: size / 2)).contentShape(Circle())
    }
}
