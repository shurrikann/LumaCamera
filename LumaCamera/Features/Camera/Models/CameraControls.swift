import Foundation

enum CameraShootingMode: String { case auto = "A", manual = "M" }
enum CameraPanel: String, CaseIterable { case film = "胶片", manual = "专业" }
enum CameraParameter: String, CaseIterable { case shutter = "S", iso = "ISO", ev = "EV", focus = "MF", wb = "WB", tint = "TINT" }

