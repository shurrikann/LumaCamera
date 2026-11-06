import Foundation

/// One deletion owns one asynchronous navigation, bound to the photo it removed.
struct PhotoDeletionNavigation {
    private(set) var token: UUID?
    private var origin: GalleryRoute?

    mutating func begin(from source: GalleryRoute, current: GalleryRoute) -> UUID? {
        guard source == current, token == nil else { return nil }
        let next = UUID(); token = next; origin = source
        return next
    }
    func matches(_ request: UUID, current: GalleryRoute) -> Bool {
        token == request && origin == current
    }
    mutating func finish(_ request: UUID) {
        guard token == request else { return }
        token = nil; origin = nil
    }
}
