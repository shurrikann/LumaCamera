import SwiftUI

/// A logarithmic arc keeps low focal lengths precise and high magnifications reachable.
struct CameraZoomDial: View {
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    var body: some View {
        GeometryReader { geometry in
            let radius = max(1, geometry.size.width / 2)
            let center = CGPoint(x: geometry.size.width / 2, y: radius + 6)
            ZStack(alignment: .top) {
                // The complete circle extends under the lower controls. Only the
                // viewfinder clips it, so the wheel has no artificial flat base.
                PopupGlassBackground(shape: Circle(), materialOpacity: AppTheme.cameraPopupMaterialOpacity)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                    .allowsHitTesting(false)
                Canvas { context, size in
                    let low = max(range.lowerBound, 0.01), high = max(range.upperBound, low)
                    let current = min(max(value, low), high)
                    let first = Int(floor(log2(low) * 12)), last = Int(ceil(log2(high) * 12))
                    for index in first...last {
                        let zoom = pow(2, Double(index) / 12)
                        guard zoom >= Double(low), zoom <= Double(high) else { continue }
                        let angle = -Double.pi / 2 + log2(zoom / Double(current)) * 0.7
                        guard abs(angle + .pi / 2) < 1.15, abs(angle + .pi / 2) > 0.035 else { continue }
                        let major = index % 12 == 0
                        let outer = radius - 12, inner = outer - (major ? 16 : 8)
                        var tick = Path()
                        tick.move(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                        tick.addLine(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                        context.stroke(tick, with: .color(.white.opacity(major ? 0.75 : 0.35)), lineWidth: 1)
                    }
                    for zoom in [0.5, 1, 2, 3, 4, 5, 8, 10, 15, 20, 30, 40] where zoom >= Double(low) && zoom <= Double(high) {
                        let offset = log2(zoom / Double(current)) * 0.7
                        guard abs(offset) < 1.05, abs(offset) > 0.15 else { continue }
                        let angle = -Double.pi / 2 + offset, distance = radius - 44
                        var label = context
                        label.translateBy(x: center.x + distance * cos(angle), y: center.y + distance * sin(angle))
                        label.rotate(by: .radians(offset))
                        label.draw(Text(zoom == 0.5 ? "0.5" : String(Int(zoom))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.75)), at: .zero)
                    }
                }
                VStack(spacing: 12) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(AppTheme.accent)
                    Text(String(format: "%.1f×", Double(value))).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(AppTheme.accent)
                }.padding(.top, 8)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("变焦转盘").accessibilityValue(String(format: "%.1f 倍", Double(value)))
    }
}

