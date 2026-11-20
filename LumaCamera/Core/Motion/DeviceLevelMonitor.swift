import CoreMotion

/// Owns motion updates and delivers gravity in the device axes on the main queue.
final class DeviceLevelMonitor {
    struct Sample {
        let x: Double
        let y: Double
        let z: Double
        var roll: Double { atan2(x, -y) }
    }

    private let motion = CMMotionManager()

    func start(onUpdate: @escaping (Sample) -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let gravity = motion?.gravity else { return }
            onUpdate(.init(x: gravity.x, y: gravity.y, z: gravity.z))
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
    deinit { stop() }
}
