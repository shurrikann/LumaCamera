import SwiftUI

/// Shares the same circular reel and gesture behavior as the left mode button.
struct AstroSubmodeSwitchButton: View {
    let current: AstroCaptureMode
    var size: CGFloat = 52
    let onSelect: (AstroCaptureMode) -> Void
    var body: some View {
        CyclicModeSwitchButton(current: current, modes: AstroCaptureMode.allCases, size: size,
            label: current.rawValue, hint: "上下滑动循环切换星空照片、星轨和星空延时",
            icon: { AstroSubmodeIcon(mode: $0, size: 26) }, onSelect: onSelect)
    }
}

struct AstroSubmodeIcon: View {
    let mode: AstroCaptureMode
    let size: CGFloat

    var body: some View {
        ZStack {
            glyph.stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            accents.fill()
        }
            .frame(width: 24, height: 24)
            .scaleEffect(size / 24)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var glyph: Path {
        var path = Path()
        switch mode {
        case .photo:
            path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 16), cornerSize: CGSize(width: 2.4, height: 2.4))
            path.move(to: CGPoint(x: 3, y: 14.5))
            path.addQuadCurve(to: CGPoint(x: 9, y: 17), control: CGPoint(x: 7, y: 14.2))
            path.addCurve(to: CGPoint(x: 21, y: 12), control1: CGPoint(x: 11, y: 10.5), control2: CGPoint(x: 17, y: 9.5))
        case .trails:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            path.addEllipse(in: CGRect(x: 6.4, y: 6.4, width: 11.2, height: 11.2))
        case .timelapse:
            path.addArc(center: CGPoint(x: 12, y: 13), radius: 8.4,
                startAngle: .degrees(-68), endAngle: .degrees(248), clockwise: false)
        }
        return path
    }

    private var accents: Path {
        var path = Path()
        switch mode {
        case .photo:
            star(&path, center: CGPoint(x: 7.6, y: 8.8), radius: 2.1)
        case .trails:
            path.addEllipse(in: CGRect(x: 10.1, y: 10.1, width: 3.8, height: 3.8))
            star(&path, center: CGPoint(x: 5.65, y: 5.65), radius: 2.4)
        case .timelapse:
            star(&path, center: CGPoint(x: 12, y: 4.2), radius: 2.2)
            path.move(to: CGPoint(x: 6.9, y: 7.9))
            path.addLine(to: CGPoint(x: 10.8, y: 14.1))
            path.addQuadCurve(to: CGPoint(x: 13.1, y: 11.8), control: CGPoint(x: 14.5, y: 15.5))
            path.closeSubpath()
        }
        return path
    }

    private func star(_ path: inout Path, center: CGPoint, radius: CGFloat) {
        let r = radius, c = center
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.18, y: c.y - r * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * 0.18, y: c.y + r * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * 0.18, y: c.y + r * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * 0.18, y: c.y - r * 0.18))
        path.closeSubpath()
    }
}
