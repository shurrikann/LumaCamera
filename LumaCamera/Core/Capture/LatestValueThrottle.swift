import Foundation

/// One scheduled delivery and one latest value, regardless of input event frequency.
final class LatestValueThrottle<Value> {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let deliver: (Value) -> Void
    private var pending: Value?
    private var scheduled = false
    private var ticket: UInt64 = 0
    init(queue: DispatchQueue, interval: TimeInterval, deliver: @escaping (Value) -> Void) {
        self.queue = queue; self.interval = interval; self.deliver = deliver
    }
    func submit(_ value: Value) {
        lock.lock()
        pending = value
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let request = ticket
        lock.unlock()
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.ticket == request else { self.lock.unlock(); return }
            let value = self.pending
            self.pending = nil; self.scheduled = false
            self.lock.unlock()
            if let value { self.deliver(value) }
        }
    }
    /// Must run on the delivery queue. Used before taking a photo to apply the last drag value.
    func flush() {
        lock.lock()
        let value = pending
        pending = nil; scheduled = false; ticket &+= 1
        lock.unlock()
        if let value { deliver(value) }
    }
    func cancel() {
        lock.lock()
        pending = nil; scheduled = false; ticket &+= 1
        lock.unlock()
    }
}
