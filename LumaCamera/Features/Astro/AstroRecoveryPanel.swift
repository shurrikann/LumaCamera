import SwiftUI
import ImageIO

struct AstroRecoveryPanel: View {
    @ObservedObject var store: AstroRecoveryStore
    let onClose: () -> Void
    @State private var discarding: AstroRecoveryItem?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onClose)
                VStack(spacing: 16) {
                    HStack {
                        Text("未完成的拍摄").font(.headline)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                            .accessibilityLabel("关闭恢复拍摄")
                    }
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(store.items) { item in
                                HStack(spacing: 12) {
                                    RecoveryThumbnail(file: store.journal.url(for: item), video: item.isVideo)
                                        .frame(width: 56, height: 66).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(item.kind).font(.subheadline)
                                        Text(item.phase == "importing" ? "上次保存状态待核对" : "已保留完成的画面")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        HStack(spacing: 14) {
                                            Button { store.recover(item) } label: {
                                                if store.busy == item.id { ProgressView().frame(width: 70) }
                                                else { Text("保存到相册").font(.caption) }
                                            }.frame(minWidth: 80, minHeight: 44)
                                            .disabled(store.busy != nil).tint(AppTheme.accent)
                                            Button("丢弃") { discarding = item }.font(.caption).foregroundStyle(.secondary)
                                                .frame(minWidth: 44, minHeight: 44).disabled(store.busy != nil)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }.frame(height: min(max(110, CGFloat(store.items.count) * 110 - 18), geometry.size.height * 0.55))
                    if let message = store.message {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20).frame(width: max(1, geometry.size.width - 24))
                .modifier(PopupSurface(radius: 28, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
                .foregroundStyle(.white)
            }
            .alert("丢弃这次未完成的拍摄？", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
                Button("丢弃", role: .destructive) { if let item = discarding { store.discard(item.id) }; discarding = nil }
                Button("保留", role: .cancel) { discarding = nil }
            }
        }
    }
}

private struct RecoveryThumbnail: View {
    let file: URL?
    let video: Bool
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: video ? "film" : "photo").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: file) {
            guard !video, let file else { return }
            thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
    }
}
