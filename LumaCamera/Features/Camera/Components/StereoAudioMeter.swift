import SwiftUI

/// Compact horizontal left/right level rows shown beneath the capacity panel.
struct StereoAudioMeter: View {
    let left: Float
    let right: Float

    var body: some View {
        VStack(spacing: 3) {
            channel("L", level: left)
            channel("R", level: right)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(width: 64)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.10), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("双声道音频电平")
        .accessibilityValue("左 \(Int(left * 100))%，右 \(Int(right * 100))%")
    }

    private func channel(_ label: String, level: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 8, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 38, height: 3)
                Capsule().fill(Color(red: 0.25, green: 0.95, blue: 0.25))
                    .frame(width: max(1, 38 * CGFloat(min(max(level, 0), 1))), height: 3)
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
