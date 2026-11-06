import SwiftUI

/// Top-right recording capacity panel: remaining time, storage bar and free space.
struct RecordingCapacityPanel: View {
    let info: RecordingCapacity.Info

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.isEstimated ? "≈\(info.timeText)" : info.timeText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(Color(red: 1.0, green: 0.33, blue: 0.22))
                        .frame(width: geometry.size.width * info.usedFraction)
                }
            }.frame(height: 3.5)
            HStack(spacing: 3) {
                Text("\(info.usedPercent)%")
                Circle().fill(.white.opacity(0.5)).frame(width: 2, height: 2)
                Text(info.freeText)
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(width: info.isExternal ? 112 : 80, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.isExternal ? "外接存储" : "设备存储")剩余可拍摄时间 \(info.isEstimated ? "约 " : "")\(info.timeText)，已用 \(info.usedPercent)%，可用 \(info.freeText)")
    }
}
