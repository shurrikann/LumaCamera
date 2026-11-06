import CoreMotion

/// Owns motion updates. Values are delivered on the main queue as radians.
final class DeviceLevelMonitor {
    private let motion = CMMotionManager()

    func start(onUpdate: @escaping (Double) -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let gravity = motion?.gravity else { return }
            onUpdate(atan2(gravity.x, -gravity.y))
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
    deinit { stop() }
}
