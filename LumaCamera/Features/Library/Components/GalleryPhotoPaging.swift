import Foundation

/// Follow the displayed grid order, including a capture not yet indexed by Photos.
enum GalleryPhotoPaging {
    /// Video detail loads its AVAsset directly and must not wait on the still-image service.
    static func requiresImagePreload(_ route: GalleryRoute, afterDeletion: Bool = false) -> Bool {
        // 删除已成功时不能继续展示已删除对象，下一页自己加载（含 iCloud 图像）。
        // 普通滑动仍等待预加载，保留已有的平滑翻页体验。
        if afterDeletion { return false }
        switch route {
        case .capture: return true
        case .asset(let photo): return !photo.isVideo
        }
    }

    /// Turns a horizontal gesture on the media canvas into the same page direction used by photos.
    static func swipeStep(horizontal: CGFloat, vertical: CGFloat, threshold: CGFloat = 36) -> Int? {
        guard horizontal.isFinite, vertical.isFinite, threshold.isFinite, threshold > 0,
              abs(horizontal) >= threshold, abs(horizontal) > abs(vertical) * 1.2 else { return nil }
        return horizontal < 0 ? 1 : -1
    }

    static func afterDeleting(_ current: GalleryRoute, photos: [LibraryPhoto], hasCapture: Bool, captureID: String?) -> GalleryRoute? {
        neighbor(of: current, step: 1, photos: photos, hasCapture: hasCapture, captureID: captureID)
    }
    static func neighbor(of current: GalleryRoute, step: Int, photos: [LibraryPhoto], hasCapture: Bool, captureID: String?) -> GalleryRoute? {
        guard step == -1 || step == 1 else { return nil }
        var pages: [GalleryRoute] = []
        // The open capture page still exists even after its cache has been cleared,
        // or before its saved asset has appeared in the paginated grid.
        if (hasCapture || current == .capture) && !photos.contains(where: { $0.id == captureID }) { pages.append(.capture) }
        pages += photos.map(GalleryRoute.asset)
        let index = pages.firstIndex { candidate in
            switch (current, candidate) {
            case (.capture, .capture): return true
            case (.capture, .asset(let photo)): return photo.id == captureID
            case (.asset(let a), .asset(let b)): return a.id == b.id
            default: return false
            }
        }
        guard let index, pages.indices.contains(index + step) else { return nil }
        return pages[index + step]
    }
}

/// 照片和视频详情共用相同的横向翻页方向与动画时长；仅媒体画布移动，详情控件固定。
enum GalleryPageTransition {
    static let duration: TimeInterval = 0.28

    static func horizontalOffset(direction: Int, extent: CGFloat, progress: CGFloat,
                                 incoming: Bool, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let progress = min(max(progress, 0), 1)
        return CGFloat(incoming ? direction : -direction) * extent * (incoming ? 1 - progress : progress)
    }

    static func opacity(progress: CGFloat, incoming: Bool, reduceMotion: Bool) -> Double {
        guard reduceMotion else { return 1 }
        let progress = min(max(progress, 0), 1)
        return Double(incoming ? progress : 1 - progress)
    }
}
