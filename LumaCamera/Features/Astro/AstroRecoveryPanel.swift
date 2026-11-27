import SwiftUI
import ImageIO
import AVFoundation

struct AstroRecoveryPanel: View {
    @ObservedObject var store: AstroRecoveryStore
    let onClose: () -> Void
    @State private var discarding: AstroRecoveryItem?
    var body: some View {
        GeometryReader { geometry in
            let cardWidth = max(64, (geometry.size.width - 96) / 3)
            let imageHeight = cardWidth
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onClose)
                VStack(spacing: 10) {
                    HStack {
                        Text("未完成的拍摄").font(.headline)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭恢复拍摄")
                    }.padding(.horizontal, 20)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(store.items) { item in
                                VStack(spacing: 8) {
                                    Text(item.kind).font(.subheadline.weight(.medium))
                                        .lineLimit(2).multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                    RecoveryThumbnail(file: store.journal.url(for: item), video: item.isVideo)
                                        .frame(width: cardWidth, height: imageHeight)
                                        .background(.black.opacity(0.25))
                                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                        .overlay(alignment: .topTrailing) {
                                            Button { discarding = item } label: {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 15, weight: .medium))
                                                    .frame(width: 32, height: 32)
                                                    .background(.ultraThinMaterial, in: Circle())
                                                    .frame(width: 44, height: 44)
                                            }
                                            .buttonStyle(.plain)
                                            .padding([.top, .trailing], 4)
                                            .disabled(store.busy != nil)
                                            .accessibilityLabel("丢弃" + item.kind)
                                        }
                                    Button { store.recover(item) } label: {
                                        ZStack {
                                            Text("保存到相册").opacity(store.busy == item.id ? 0 : 1)
                                            if store.busy == item.id { ProgressView().tint(AppTheme.accent) }
                                        }
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1).minimumScaleFactor(0.8)
                                        .frame(maxWidth: .infinity).frame(height: 44)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).foregroundStyle(AppTheme.accent)
                                    .disabled(store.busy != nil)
                                    .accessibilityLabel("保存" + item.kind + "到相册")
                                }.frame(width: cardWidth).id(item.id)
                            }
                        }.scrollTargetLayout().padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .frame(height: imageHeight + 24 + 16 + 44)
                    if let message = store.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
                    }
                }
                .padding(.top, 8).padding(.bottom, 8)
                .frame(width: max(1, geometry.size.width - 24))
                .modifier(PopupSurface(radius: 28, glass: true, materialOpacity: AppTheme.cameraPopupMaterialOpacity))
                .foregroundStyle(.white)
                .padding(.bottom, 10)
            }
            .alert("丢弃这次未完成的拍摄？", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
                Button("丢弃", role: .destructive) { if let item = discarding { store.discard(item.id) }; discarding = nil }
                Button("保留", role: .cancel) { discarding = nil }
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
            guard let file else { return }
            let rendered = await Task.detached(priority: .utility) { () async -> UIImage? in
                if video {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 900, height: 900)
                    guard let frame = try? await generator.image(at: .zero).image else { return nil }
                    return UIImage(cgImage: frame)
                }
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 900,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = rendered
        }
    }
}
