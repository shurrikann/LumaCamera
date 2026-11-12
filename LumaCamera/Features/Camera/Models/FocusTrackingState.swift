import Foundation

/// Independent focus half of the AE/AF lock panel.
enum FocusTrackingState: String, Codable, CaseIterable {
    case off
    case locked
    case continuous

    var label: String? {
        switch self {
        case .off: return nil
        case .locked: return "AF"
        case .continuous: return "AF*"
        }
    }

    var next: FocusTrackingState {
        switch self {
        case .off: return .locked
        case .locked: return .continuous
        case .continuous: return .off
        }
    }
}
