import Foundation

enum FilterCategory: String, CaseIterable, Identifiable {
    case all = "全部", favorites = "收藏"
    var id: String { rawValue }

    func includes(_ style: FilmStyle) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return false // Membership is determined by the user's saved favorites.
        }
    }
}
