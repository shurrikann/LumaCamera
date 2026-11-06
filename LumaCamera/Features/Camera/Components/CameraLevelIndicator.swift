import SwiftUI

struct CameraLevelIndicator: View {
    let roll: Double
    var body: some View {
        let reading = CameraLevelReading(roll: roll)
        HStack(spacing: 4) {
            Rectangle().frame(width: 25, height: 1)
            Capsule().frame(width: 55, height: 2).rotationEffect(.radians(-reading.tilt))
            Rectangle().frame(width: 25, height: 1)
        }
        .foregroundStyle(reading.isLevel ? AppTheme.accent : .white.opacity(0.7))
        .rotatingCaptureContent()
        .accessibilityLabel(reading.isLevel ? "水平仪，已水平" : "水平仪，未水平")
        .allowsHitTesting(false)
    }
}
