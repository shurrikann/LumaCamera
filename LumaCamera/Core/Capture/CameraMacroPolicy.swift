import Foundation

/// Automatic macro means a normal/telephoto composition supplied by the ultra-wide camera.
/// Selecting 0.5× alone is not evidence that automatic macro is active.
enum CameraMacroPolicy {
    static func isActive(manual: Bool, virtual: Bool, rear: Bool, ultraWide: Bool, displayZoom: CGFloat,
                         routeChangePending: Bool = false) -> Bool {
        // A/M挡统一：手动曝光不改变系统微距镜头选择。
        _ = manual
        return !routeChangePending && virtual && rear && ultraWide && displayZoom.isFinite && displayZoom >= 0.99
    }
}
