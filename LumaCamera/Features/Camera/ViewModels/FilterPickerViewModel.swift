import Combine
import CoreImage
import UIKit

@MainActor
final class FilterPickerViewModel: ObservableObject {
    @Published var category = FilterCategory.all
    @Published var showStrength = false
    @Published private(set) var favorites: Set<FilmStyle>
    @Published private(set) var thumbnails: [FilmStyle: UIImage] = [:]
    private let defaults: UserDefaults
    private let favoritesKey = "camera.favoriteFilmStyles"
    private static let thumbnailQueue = DispatchQueue(label: "camera.filterThumbnails", qos: .userInitiated)
    private static var thumbnailCache: [FilmStyle: UIImage] = [:]
    private static var thumbnailWaiters: [([FilmStyle: UIImage]) -> Void] = []
    #if DEBUG
    private(set) static var thumbnailRenderPassesForTesting = 0
    #endif
    private var preparing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thumbnails = Self.thumbnailCache
        favorites = Set((defaults.stringArray(forKey: favoritesKey) ?? []).compactMap(FilmStyle.init(rawValue:)).filter { FilmStyle.availableStyles.contains($0) })
    }

    var styles: [FilmStyle] {
        FilmStyle.availableStyles.filter { category == .favorites ? favorites.contains($0) : category.includes($0) }
    }

    func toggleFavorite(_ style: FilmStyle) {
        guard FilmStyle.availableStyles.contains(style) else { return }
        if favorites.contains(style) { favorites.remove(style) } else { favorites.insert(style) }
        defaults.set(FilmStyle.allCases.filter { favorites.contains($0) }.map(\.rawValue), forKey: favoritesKey)
    }

    func prepareThumbnails() {
        guard thumbnails.isEmpty, !preparing else { return }
        preparing = true
        if !Self.thumbnailCache.isEmpty {
            thumbnails = Self.thumbnailCache; preparing = false
            return
        }
        Self.thumbnailWaiters.append { [weak self] images in
            self?.thumbnails = images; self?.preparing = false
        }
        guard Self.thumbnailWaiters.count == 1 else { return }
        #if DEBUG
        Self.thumbnailRenderPassesForTesting += 1
        #endif
        Self.thumbnailQueue.async {
            let images: [FilmStyle: UIImage] = autoreleasepool {
                FilterAdjustmentRenderer.prepare()
                let context = CIContext(options: [.cacheIntermediates: false])
                guard let photo = UIImage(named: "FilterLandscape"), let source = CIImage(image: photo) else { return [:] }
                let square = FrameRatio.square.crop(source)
                let scaled = square.transformed(by: CGAffineTransform(scaleX: 180 / square.extent.width, y: 180 / square.extent.height))
                var images: [FilmStyle: UIImage] = [:]
                for style in FilmStyle.availableStyles {
                    autoreleasepool {
                        images[style] = Imaging.render(scaled, look: CaptureLook(style: style, intensity: 0.8, ratio: .square), context: context)
                    }
                }
                return images
            }
            DispatchQueue.main.async {
                Self.thumbnailCache = images
                let callbacks = Self.thumbnailWaiters
                Self.thumbnailWaiters.removeAll()
                callbacks.forEach { $0(images) }
            }
        }
    }
}
