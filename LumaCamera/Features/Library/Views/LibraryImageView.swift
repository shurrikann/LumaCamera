import SwiftUI

/// Cancels off-screen requests and keeps PhotoKit callbacks from updating a reused cell.
struct LibraryImageView: View {
    let photo: LibraryPhoto
    let browser: PhotoBrowserService
    let size: CGSize
    var onUnavailable: (() -> Void)? = nil
    @State private var loadedAssetID: String?
    @State private var image: UIImage?
    @State private var request: PhotoImageRequest?
    @State private var requestID = UUID()
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.04)
                if let image {
                    LibraryMediaThumbnail(image: image)
                } else if failed {
                    Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                        .accessibilityLabel("照片暂时无法加载，请检查权限和网络")
                } else { ProgressView().tint(.white.opacity(0.5)) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
        }
        .onAppear { load() }
        .onDisappear { requestID = UUID(); request?.cancel(); request = nil }
        .onChange(of: photo.id) { _, _ in load() }
    }

    private func load() {
        request?.cancel()
        let id = UUID()
        requestID = id
        if loadedAssetID != photo.id { image = nil }
        loadedAssetID = photo.id; failed = false
        request = browser.requestImage(id: photo.id, size: size) { image, error in
            guard requestID == id else { return }
            if let image { self.image = image }
            else if error != nil || self.image == nil { failed = true; onUnavailable?() }
        }
    }
}
