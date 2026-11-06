import SwiftUI

struct RoundTextControlLabel: View {
    let title: String
    var highlighted = false
    var diameter: CGFloat = 44
    static func lines(_ title: String) -> String {
        if title == "颗粒饱和度" { return "颗粒\n饱和度" }
        if title == "模糊／锐化" { return "模糊\n锐化" }
        let characters = Array(title)
        guard characters.count > 3 else { return title }
        let middle = (characters.count + 1) / 2
        return String(characters.prefix(middle)) + "\n" + String(characters.dropFirst(middle))
    }
    var body: some View {
        Text(Self.lines(title)).font(.system(size: title.count > 4 ? 10 : 12, weight: .medium))
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            .foregroundStyle(highlighted ? AppTheme.accent : .white.opacity(0.8))
            .frame(width: diameter - 8, height: diameter - 8).rotatingCaptureContent()
            .frame(width: diameter, height: diameter).modifier(PopupSurface(radius: diameter / 2, glass: true))
            .overlay(Circle().stroke(highlighted ? AppTheme.accent.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(Circle()).accessibilityLabel(title)
    }
}
