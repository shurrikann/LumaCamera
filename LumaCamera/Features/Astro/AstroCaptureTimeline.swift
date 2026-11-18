import Foundation

/// Source PTS schedules acquisition; encoded frames remain a 30fps time-lapse.
struct AstroCaptureTimeline {
    let interval: Double
    let fusion: Double
    let duration: Double?
    private var origin: Double?
    private var last: Double?
    private(set) var window = -1
    private var completed = false
    struct Tick { let window: Int; let newWindow: Bool; let collect: Bool; let complete: Bool; let finished: Bool }
    init(interval: Double, fusion: Double, duration: Double?) {
        self.fusion = max(1, fusion)
        self.interval = max(1, interval, fusion)
        self.duration = duration
    }
    mutating func next(pts: Double) -> Tick? {
        guard pts.isFinite, last == nil || pts > last! else { return nil }
        if origin == nil { origin = pts }
        last = pts
        let elapsed = max(0, pts - origin!)
        if let duration, elapsed >= duration { return Tick(window: window, newWindow: false, collect: false, complete: false, finished: true) }
        let index = Int(floor((elapsed + 0.001) / interval))
        let changed = index != window
        if changed { window = index; completed = false }
        let phase = elapsed - Double(index) * interval
        let collect = !completed && phase < fusion - 0.001
        let end = !completed && phase + 1 >= fusion - 0.001
        if end { completed = true }
        return Tick(window: index, newWindow: changed, collect: collect, complete: end, finished: false)
    }
}
