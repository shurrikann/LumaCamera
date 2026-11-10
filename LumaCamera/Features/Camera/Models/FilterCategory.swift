import Foundation

enum FilterCategory: String, CaseIterable, Identifiable {
    case all = "全部", favorites = "收藏", film = "胶片", cinema = "电影"
    case portrait = "人像", life = "生活", landscape = "风光", street = "街拍", mono = "黑白"
    var id: String { rawValue }

    func includes(_ style: FilmStyle) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return false // Membership is determined by the user's saved favorites.
        case .film: return style.filterCategory == .film
        case .cinema: return style.filterCategory == .cinema
        case .portrait: return style.filterCategory == .portrait
        case .life: return style.filterCategory == .life
        case .landscape: return style.filterCategory == .landscape
        case .street: return style.filterCategory == .street
        case .mono: return style.filterCategory == .mono
        }
    }
}
