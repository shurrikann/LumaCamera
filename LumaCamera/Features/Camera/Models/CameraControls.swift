import Foundation

enum CameraShootingMode: String { case auto = "A", manual = "M" }
enum CameraPanel: String, CaseIterable { case film = "胶片", manual = "专业" }
enum CameraParameter: String, CaseIterable { case shutter = "S", iso = "ISO", ev = "EV", focus = "MF", wb = "WB", tint = "TINT" }

extension CameraParameter {
    var readoutLabel: String {
        switch self {
        case .focus: "AF"
        case .wb: "WEB"
        case .tint: "T"
        default: rawValue
        }
    }
}
