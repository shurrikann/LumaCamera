import Foundation

enum FocusLockMode: String, Codable, CaseIterable, Identifiable {
    case exposure = "AE"
    case focus = "AF"
    case exposureAndFocus = "AE/AF"
    case tracking = "AF追踪"
    var id: String { rawValue }
    var locksExposure: Bool { self != .focus && self != .tracking }
    var locksFocus: Bool { self != .exposure && self != .tracking }
    var accessibilityTitle: String {
        switch self {
        case .exposure: return "锁定曝光"
        case .focus: return "锁定对焦"
        case .exposureAndFocus: return "锁定曝光和对焦"
        case .tracking: return "AF 追踪对焦"
        }
    }
}
