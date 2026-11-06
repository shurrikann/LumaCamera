import Foundation
import QuartzCore

/// 本地有界记录；磁盘工作只在独立队列执行，不保留媒体、位置或设备标识。
final class CameraResumeDiagnosticStore: @unchecked Sendable {
    static let shared = CameraResumeDiagnosticStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CameraResumeDiagnostics", isDirectory: true))
    private let queue = DispatchQueue(label: "camera.resume.diagnostic.store", qos: .utility)
    private let file: URL
    private var events: [[String: String]]?
    init(directory: URL) { file = directory.appendingPathComponent("recent.json") }
    func append(_ event: [String: String]) {
        queue.async {
            if self.events == nil {
                self.events = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) } ?? []
            }
            self.events?.append(event)
            let excess = (self.events?.count ?? 0) - 64
            if excess > 0 { self.events?.removeFirst(excess) }
            do {
                try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(self.events ?? []).write(to: self.file, options: .atomic)
            } catch { /* 诊断存储失败不阻塞拍摄或弹出提示。 */ }
        }
    }
    #if DEBUG
    func flushForTesting(_ completion: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: completion)) }
    #endif
}

/// 每次恢复观察20秒，每路最多一个未返回探针；卡住时不向主线程积压任务。
final class CameraResumeDiagnostics: @unchecked Sendable {
    typealias Probe = (@escaping ([String: String]) -> Void) -> Void
    private let queue = DispatchQueue(label: "camera.resume.diagnostic.monitor", qos: .utility)
    private let store: CameraResumeDiagnosticStore
    private let clock: () -> Double
    private let automaticSampling: Bool
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var started = 0.0
    private var context: [String: String] = [:]
    private var probes: [String: Probe] = [:]
    private var pending = Set<String>()
    private var acknowledgements: [String: Double] = [:]
    private var snapshots: [String: [String: String]] = [:]
    private var stalled = false
    init(store: CameraResumeDiagnosticStore = .shared, clock: @escaping () -> Double = { CACurrentMediaTime() }, automaticSampling: Bool = true) {
        self.store = store; self.clock = clock; self.automaticSampling = automaticSampling
    }
    deinit { timer?.cancel() }

    func record(_ stage: String, context: [String: String] = [:]) {
        queue.async { self.save(stage, extra: context) }
    }
    func start(context: [String: String], probes: [String: Probe]) {
        queue.async { [self] in
            self.timer?.cancel(); self.generation = UUID()
            self.context = context; self.probes = probes; self.pending = []
            self.acknowledgements = [:]; self.snapshots = [:]; self.stalled = false
            self.started = self.clock(); self.save("start")
            guard self.automaticSampling else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in guard let self else { return }; self.tick(now: self.clock()) }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.async {
            self.save("stop"); self.generation = UUID()
            self.timer?.cancel(); self.timer = nil; self.probes = [:]; self.pending = []
        }
    }
    private func tick(now: Double) {
        if now - started >= 20 {
            save("observation-ended")
            timer?.cancel(); timer = nil; probes = [:]; return
        }
        let overdue = probes.keys.filter { now - (acknowledgements[$0] ?? started) >= 3 }.sorted()
        let frameAge = snapshots["preview"]?["frameAge"].flatMap(Double.init)
        let staleFrame = now - started >= 3 && (frameAge.map { $0 >= 3 } ?? true)
        let unhealthy = !overdue.isEmpty || staleFrame
        if unhealthy != stalled {
            stalled = unhealthy
            save(unhealthy ? "stalled" : "recovered", extra: ["unanswered": overdue.joined(separator: ","), "staleFrame": String(staleFrame)])
        }
        let token = generation
        for (name, probe) in probes where !pending.contains(name) {
            pending.insert(name)
            probe { [weak self] values in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == token else { return }
                    self.pending.remove(name); self.acknowledgements[name] = self.clock()
                    self.snapshots[name] = values
                }
            }
        }
    }
    private func save(_ stage: String, extra: [String: String] = [:]) {
        var event = context
        event["stage"] = stage; event["time"] = ISO8601DateFormatter().string(from: Date())
        event["observation"] = generation.uuidString
        for (probe, values) in snapshots { for (key, value) in values { event[probe + "." + key] = value } }
        event.merge(extra, uniquingKeysWith: { _, new in new }); store.append(event)
    }
    #if DEBUG
    func sampleForTesting(_ completion: @escaping () -> Void) {
        queue.async { self.tick(now: self.clock()); completion() }
    }
    func drainForTesting(_ completion: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: completion)) }
    #endif
}
