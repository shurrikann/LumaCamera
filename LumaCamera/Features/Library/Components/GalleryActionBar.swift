import SwiftUI

/// Stable slots prevent share preparation from replacing or moving the other actions.
struct GalleryActionBar: View {
    let selecting: Bool
    let selectedCount: Int
    let preparing: Bool
    let completedCount: Int
    let totalCount: Int
    let libraryBusy: Bool
    let captureInProgress: Bool
    let destructiveBusy: Bool
    let onShare: () -> Void
    let onCamera: () -> Void
    let onDelete: () -> Void
    let onCancelShare: () -> Void

    private var selectionDisabled: Bool { selectedCount == 0 || libraryBusy || captureInProgress || preparing }
    var body: some View {
        HStack(spacing: 0) {
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); if preparing { onCancelShare() } else { onShare() } } label: {
                actionLabel("square.and.arrow.up", title: "分享（\(selectedCount)）", tint: AppTheme.accent, busy: preparing)
            }.disabled((!preparing && selectionDisabled) || !selecting)
                .opacity(selecting ? (selectedCount == 0 ? 0.6 : 1) : 0).accessibilityHidden(!selecting)
                .accessibilityLabel(preparing ? "取消准备分享" : "分享选中的照片").accessibilityValue(preparing ? "\(completedCount)/\(totalCount)" : "\(selectedCount) 张")
            LibraryCameraButton(action: onCamera)
                .disabled(destructiveBusy || preparing).frame(maxWidth: .infinity)
            Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onDelete() } label: {
                actionLabel("trash", title: "删除（\(selectedCount)）", tint: .red, busy: destructiveBusy)
            }.disabled(selectionDisabled || !selecting)
                .opacity(selecting ? (selectedCount == 0 ? 0.6 : 1) : 0).accessibilityHidden(!selecting)
                .accessibilityLabel("删除选中的照片").accessibilityValue("\(selectedCount) 张")
        }.buttonStyle(GalleryStableActionStyle()).frame(height: 84)
            .padding(.vertical, 4)
            .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
    }
    private func actionLabel(_ icon: String, title: String, tint: Color, busy: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 21)).foregroundStyle(tint)
                .frame(width: 48, height: 48).modifier(PopupSurface(radius: 24, glass: true))
                .overlay { if busy { GalleryActivityRing(tint: tint).allowsHitTesting(false) } }
            Text(title).font(.system(size: 11)).foregroundStyle(tint).lineLimit(1)
        }.rotatingCaptureContent().frame(maxWidth: .infinity).frame(height: 84).contentShape(Rectangle())
    }
}

struct GalleryStableActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.isEnabled, true).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct GalleryActivityRing: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30)) { timeline in
            Circle().trim(from: 0, to: 0.72)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2)*180))
                .frame(width: 52, height: 52)
        }.accessibilityHidden(true)
    }
}
