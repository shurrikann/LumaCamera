import MapKit
import SwiftUI

struct AstroHorizonPanel: View {
    let request: AstroHorizonRequest
    let events: [AstroHorizonEvent]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dayLabel: String {
        var style = Date.FormatStyle.dateTime.month().day()
        style.timeZone = request.timeZone
        let startOffset = request.day.start.formatted(offsetStyle)
        let endOffset = request.day.end.addingTimeInterval(-1).formatted(offsetStyle)
        let zone = startOffset == endOffset ? startOffset : startOffset + "/" + endOffset
        return request.day.start.formatted(style) + " · " + zone
    }

    private var offsetStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.timeZone(.localizedGMT(.short))
        style.timeZone = request.timeZone
        return style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dayLabel + " · 真北")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            HStack(alignment: .top, spacing: 6) {
                ForEach(AstroHorizonEvent.Kind.allCases, id: \.self) { kind in
                    eventCell(kind)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.79), in: .rect(cornerRadius: 9))
        .contentTransition(.opacity)
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.16), value: events)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("astro.environment.horizon")
    }

    private func eventCell(_ kind: AstroHorizonEvent.Kind) -> some View {
        let matches = (events ?? []).filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: kind.isRise ? "minus" : "ellipsis")
                    .accessibilityHidden(true)
                Text(kind.rawValue)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(uiColor: kind.horizonColor))
            if matches.isEmpty {
                Text(events == nil ? "…" : "—")
                    .accessibilityLabel(events == nil ? "计算中" : "当天无此事件")
            }
            ForEach(matches, id: \.date) { event in
                Text(timeLabel(event.date)).monospacedDigit()
                Text(event.direction).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func timeLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = request.timeZone
        return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}

private extension AstroHorizonEvent.Kind {
    var horizonColor: UIColor {
        isSolar ? UIColor(red: 1, green: 0.72, blue: 0.32, alpha: 1) :
            UIColor(red: 0.60, green: 0.85, blue: 1, alpha: 1)
    }
}

final class AstroHorizonAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var events: [AstroHorizonEvent] = []
}

final class AstroHorizonAnnotationView: MKAnnotationView {
    private var events: [AstroHorizonEvent] = []

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        zPriority = .min
    }

    required init?(coder: NSCoder) { nil }

    func setEvents(_ events: [AstroHorizonEvent]) {
        guard self.events != events else { return }
        self.events = events
        let size = CGSize(width: 108, height: 108)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        image = UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            context.setLineCap(.round)
            for event in events {
                let angle = event.azimuth * .pi / 180
                let radius: Double = event.kind.isSolar ? 49 : 36
                let end = Self.point(from: center, angle: angle, radius: radius)
                let shaft = CGMutablePath()
                shaft.move(to: Self.point(from: center, angle: angle, radius: 12))
                shaft.addLine(to: Self.point(from: center, angle: angle, radius: radius - 5))
                context.setLineDash(phase: 0, lengths: event.kind.isRise ? [] : [4, 3])
                context.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
                context.setLineWidth(4)
                context.addPath(shaft)
                context.strokePath()
                context.setStrokeColor(event.kind.horizonColor.cgColor)
                context.setLineWidth(2)
                context.addPath(shaft)
                context.strokePath()
                let arrow = CGMutablePath()
                arrow.move(to: end)
                arrow.addLine(to: Self.point(from: end, angle: angle + .pi * 0.83, radius: 8))
                arrow.addLine(to: Self.point(from: end, angle: angle - .pi * 0.83, radius: 8))
                arrow.closeSubpath()
                context.setLineDash(phase: 0, lengths: [])
                context.setFillColor(event.kind.horizonColor.cgColor)
                context.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
                context.setLineWidth(1)
                context.addPath(arrow)
                context.drawPath(using: .fillStroke)
            }
        }
    }

    static func point(from origin: CGPoint, angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: origin.x + sin(angle) * radius, y: origin.y - cos(angle) * radius)
    }
}
