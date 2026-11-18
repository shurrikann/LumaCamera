import SwiftUI

/// Shutter button face. Fractional speeds are stacked as numerator over
/// denominator so a 42pt control can show 1/125 without shrinking sideways.
struct ShutterValueText: View {
    let text: String
    var size: CGFloat = 9

    var body: some View {
        if let slash = text.firstIndex(of: "/") {
            let numerator = String(text[..<slash])
            let denominator = String(text[text.index(after: slash)...])
            VStack(spacing: -1) {
                Text(numerator)
                Text(denominator)
            }
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            Text(text)
                .font(.system(size: size + 1, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}
