import Foundation

/// Gravity is expressed in the portrait sensor axes. Measure tilt relative to
/// the nearest upright edge, including both landscape orientations.
struct CameraLevelReading {
    let reference: Double
    let tilt: Double
    init(roll: Double) {
        let value = roll.isFinite ? roll : 0
        reference = (value / (.pi / 2)).rounded() * (.pi / 2)
        tilt = value - reference
    }
    var isLevel: Bool { abs(tilt) < 0.025 }
}
