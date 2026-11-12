import CoreGraphics
import Foundation
import QuartzCore
import Vision

/// Known-good V1 tracking only. Recovery is intentionally not part of this path.
final class VisionSubjectTracker {
    enum Phase { case tracking, reacquiring, lost }
    struct Debug {
        let candidateCount: Int
        let identityMatched: Bool
        let matches: Int
        let elapsed: TimeInterval
        static let none = Debug(candidateCount: 0, identityMatched: false, matches: 0, elapsed: 0)
    }

    private let queue = DispatchQueue(label: "camera.vision.subject.v1", qos: .userInitiated)
    private var handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var lastBox: CGRect?
    private var failureSince: TimeInterval?
    private var busy = false

    func start(box: CGRect) {
        queue.async {
            self.handler = VNSequenceRequestHandler()
            let visionBox = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            let tracking = VNTrackObjectRequest(detectedObjectObservation:
                VNDetectedObjectObservation(boundingBox: visionBox))
            tracking.trackingLevel = .accurate
            self.request = tracking
            self.lastBox = box
            self.failureSince = nil
            self.busy = false
        }
    }

    func process(_ image: CGImage, completion: @escaping (CGRect?, Phase, Debug) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            defer { self.busy = false }
            let now = CACurrentMediaTime()
            guard let request = self.request else {
                DispatchQueue.main.async { completion(nil, .lost, .none) }
                return
            }
            do {
                try self.handler.perform([request], on: image)
            } catch {
                self.fail(now, completion: completion)
                return
            }
            guard let observation = request.results?.first as? VNDetectedObjectObservation,
                  observation.confidence >= 0.55 else {
                self.fail(now, completion: completion)
                return
            }
            let raw = observation.boundingBox
            let box = CGRect(x: raw.minX, y: 1 - raw.maxY, width: raw.width, height: raw.height)
            if let last = self.lastBox {
                let jump = hypot(box.midX - last.midX, box.midY - last.midY)
                let scale = box.width / max(0.0001, last.width)
                guard jump <= 0.28, (0.45...2.2).contains(scale) else {
                    self.fail(now, completion: completion)
                    return
                }
            }
            self.failureSince = nil
            self.lastBox = box
            request.inputObservation = observation
            DispatchQueue.main.async { completion(box, .tracking, .none) }
        }
    }

    private func fail(_ now: TimeInterval, completion: @escaping (CGRect?, Phase, Debug) -> Void) {
        if failureSince == nil { failureSince = now }
        if let last = lastBox, now - (failureSince ?? now) < 0.30 {
            DispatchQueue.main.async { completion(last, .tracking, .none) }
            return
        }
        request = nil
        DispatchQueue.main.async { completion(nil, .lost, .none) }
    }

    func stop() {
        queue.async {
            self.request = nil
            self.lastBox = nil
            self.failureSince = nil
            self.busy = false
        }
    }
}
