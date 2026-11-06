import SwiftUI

/// A bounded square in landscape keeps the two-line title inside its glass surface.
/// The outer slot is constant, so orientation does not displace selection controls.
struct GalleryScopeLabel: View {
    let recentOnly: Bool
    @Environment(\.captureControlsLandscape) private var landscape
    var body: some View {
        ZStack {
            if landscape {
                VStack(spacing: 1) {
                    Text(recentOnly ? "本次" : "所有")
                    HStack(spacing: 2) {
                        Text(recentOnly ? "拍摄" : "内容")
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    }
                }.font(.system(size: 12, weight: .medium)).fixedSize()
                    .rotatingCaptureContent().frame(width: 44, height: 44)
                    .modifier(PopupSurface(radius: 14)).transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Text(recentOnly ? "本次拍摄" : "所有内容").font(.system(size: 15, weight: .medium))
                    Image(systemName: "chevron.down.circle.fill").font(.system(size: 17))
                }.frame(width: 132, height: 44).modifier(PopupSurface(radius: 22)).transition(.opacity)
            }
        }.frame(width: 132, height: 44)
            .animation(AppTheme.popupAnimation, value: landscape)
            .accessibilityElement(children: .ignore).accessibilityLabel(recentOnly ? "本次拍摄" : "所有内容")
    }
}
