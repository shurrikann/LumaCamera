import Foundation

/// Strict latest-look publication normally; while dragging, completed frames may progress
/// monotonically within that edit session so continuous changes cannot starve the preview.
final class PreviewRevision {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var interactive = false
    private var floor: UInt64 = 0
    private var published: UInt64 = 0
    /// 读取当前代次供短同步硬件操作检查生命周期；不因此废弃其他有效请求。
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(resetInteractiveFloor: Bool = false) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        if resetInteractiveFloor { floor = value }
        return value
    }
    func matches(_ revision: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return value == revision }
    func setInteractive(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled && !interactive { floor = value }
        interactive = enabled
    }
    func canRender(_ revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == value || (interactive && revision >= floor && revision <= value)
    }
    func acceptsPublication(_ revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision >= published, revision == value || (interactive && revision >= floor && revision <= value) else { return false }
        published = revision
        return true
    }
}
