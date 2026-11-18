import SwiftUI
import UIKit

/// Fixed 0...hours tick scale with a moving pointer. Hours are quantized to
/// whole hours and the scale spans the full available width.
struct AstroTimeRuler: View {
    @Binding var hour: Double
    var maxHour: Double = 47
    var tint: Color = AppTheme.accent
    @State private var feedback = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let fraction = min(max(hour / maxHour, 0), 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for index in 0...Int(maxHour) {
                        let x = CGFloat(index) / CGFloat(maxHour) * size.width
                        var path = Path()
                        let major = index % 6 == 0
                        path.move(to: CGPoint(x: x, y: major ? 12 : 20))
                        path.addLine(to: CGPoint(x: x, y: 34))
                        context.stroke(path, with: .color(.white.opacity(major ? 0.65 : 0.28)),
                                       lineWidth: major ? 1.2 : 0.8)
                    }
                }
                .frame(height: 46)
                VStack(spacing: 2) {
                    Capsule().fill(tint).frame(width: 2, height: 34)
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                .shadow(color: tint.opacity(0.35), radius: 4)
                .position(x: fraction * width, y: 23)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = min(max(value.location.x / width, 0), 1)
                    let next = (fraction * maxHour).rounded()
                    if next != hour {
                        hour = next
                        feedback.selectionChanged()
                    }
                })
        }
        .frame(height: 46)
        .accessibilityElement()
        .accessibilityLabel("未来 48 小时时间轴")
        .accessibilityValue("第 \(Int(hour.rounded())) 小时")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1.0 : -1.0
            hour = min(max(hour + delta, 0), maxHour)
        }
    }
}
