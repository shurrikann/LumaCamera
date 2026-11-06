import SwiftUI

struct CameraHistogram: View {
    static let size = CGSize(width: 80, height: 39)
    let bins: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HistogramWaveform(values: HistogramVector(bins))
            .animation(reduceMotion ? nil : .linear(duration: 0.10), value: bins)
            .frame(width: 76, height: 35).padding(.horizontal, 2).padding(.vertical, 2)
            .background(Color(white: 0.12).opacity(0.42), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel("实时亮度直方图")
            .accessibilityHint("左侧为暗部，右侧为亮部，曲线高度表示像素分布")
    }
}

/// A fixed-size vector keeps interrupted animations continuous, including first/empty frames.
struct HistogramVector: VectorArithmetic {
    var bins: [Double]
    init(_ values: [Double]) {
        bins = (0..<128).map { index in
            guard index < values.count, values[index].isFinite else { return 0 }
            return min(max(values[index], 0), 1)
        }
    }
    private init(raw: [Double]) { bins = raw }
    static var zero: Self { Self([]) }
    static func + (lhs: Self, rhs: Self) -> Self { Self(raw: zip(lhs.bins, rhs.bins).map(+)) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(raw: zip(lhs.bins, rhs.bins).map(-)) }
    mutating func scale(by rhs: Double) { bins = bins.map { $0 * rhs } }
    var magnitudeSquared: Double { bins.reduce(0) { $0 + $1 * $1 } }
}

private struct HistogramWaveform: View, Animatable {
    var values: HistogramVector
    var animatableData: HistogramVector {
        get { values }
        set { values = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let values = self.values.bins.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
            guard values.count > 1 else { return }
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height - 1 - CGFloat(value) * (size.height - 3))
            }
            var curve = Path(); curve.move(to: points[0])
            for point in points.dropFirst() { curve.addLine(to: point) }
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            context.fill(area, with: .color(.white.opacity(0.12)))
            context.stroke(curve, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
        }
    }
}
