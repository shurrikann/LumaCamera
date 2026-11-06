import UIKit

/// Local illustration used by filter thumbnails, simulator previews and rendering tests.
enum DemoImageFactory {
    // A local illustration for simulator preview; never presented as a live camera feed.
    static func make() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            let colors = [UIColor(red: 0.36, green: 0.55, blue: 0.57, alpha: 1).cgColor, UIColor(red: 0.91, green: 0.79, blue: 0.57, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 900), options: [])
            UIColor(red: 0.99, green: 0.9, blue: 0.66, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: 600, y: 205, width: 125, height: 125))
            for index in 0..<3 {
                let path = UIBezierPath()
                let base = CGFloat(620 + index * 150)
                path.move(to: CGPoint(x: 0, y: base))
                path.addCurve(to: CGPoint(x: 900, y: base - 40), controlPoint1: CGPoint(x: 320, y: base - 400), controlPoint2: CGPoint(x: 560, y: base + 130))
                path.addLine(to: CGPoint(x: 900, y: 1200))
                path.addLine(to: CGPoint(x: 0, y: 1200))
                path.close()
                UIColor(red: 0.16 + CGFloat(index) * 0.025, green: 0.34 - CGFloat(index) * 0.025, blue: 0.34 - CGFloat(index) * 0.04, alpha: 1).setFill()
                path.fill()
            }
            let road = UIBezierPath()
            road.move(to: CGPoint(x: 460, y: 1200))
            road.addCurve(to: CGPoint(x: 480, y: 760), controlPoint1: CGPoint(x: 250, y: 1030), controlPoint2: CGPoint(x: 680, y: 830))
            UIColor(red: 0.84, green: 0.76, blue: 0.6, alpha: 1).setStroke()
            road.lineWidth = 28
            road.stroke()
        }
    }
}
