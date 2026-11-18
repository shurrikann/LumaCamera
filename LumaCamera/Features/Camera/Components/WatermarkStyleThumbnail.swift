import SwiftUI

/// Monochrome layout diagrams: gray represents the photo, ink the watermark.
/// Both capture pages share the same diagrams and selection treatment.
@MainActor
struct WatermarkStyleThumbnail: View {
    let style: PhotoWatermarkStyle
    let selected: Bool

    private static let layouts: [String:PhotoWatermarkLayout] = Dictionary(uniqueKeysWithValues:
        PhotoWatermarkStyle.allCases.map { style in
            (style.rawValue,PhotoWatermarkLayout(photoSize:CGSize(width:1200,height:1600),
                settings:.init(style:style),content:.init(capturedAt:Date(timeIntervalSince1970:0))))
        })

    var body: some View {
        ZStack {
            diagram(ink:.white).opacity(selected ? 0 : 1)
            diagram(ink:AppTheme.accent).opacity(selected ? 1 : 0)
        }
        .frame(maxWidth:.infinity).frame(height:54)
        .contentShape(RoundedRectangle(cornerRadius:10))
        .animation(AppTheme.popupAnimation,value:selected)
        .accessibilityHidden(true)
    }

    private func diagram(ink: Color) -> some View {
        let layout = Self.layouts[style.rawValue]!
        let photoColor = Color(white:0.28)
        return Canvas { context,size in
            let scale = min((size.width-10)/layout.size.width,(size.height-10)/layout.size.height)
            context.translateBy(x:(size.width-layout.size.width*scale)/2,y:(size.height-layout.size.height*scale)/2)
            context.scaleBy(x:scale,y:scale)
            let line = 1/scale
            let canvas = CGRect(origin:.zero,size:layout.size)
            func fill(_ rect:CGRect,_ color:Color) { context.fill(Path(rect),with:.color(color)) }
            func stroke(_ rect:CGRect) { context.stroke(Path(rect),with:.color(ink),lineWidth:line) }
            switch style {
            case .whiteFrame:
                fill(canvas,ink); fill(layout.photo,photoColor)
            case .glassStrip:
                fill(layout.photo,photoColor)
                let h = max(layout.decoration!.height,layout.photo.height*0.14)
                let bar = CGRect(x:layout.photo.width*0.04,y:layout.photo.maxY-h-layout.photo.height*0.035,
                                 width:layout.photo.width*0.92,height:h)
                context.fill(Path(roundedRect:bar,cornerRadius:h*0.18),with:.color(ink))
            case .blurredPhoto:
                fill(canvas,Color(white:0.48)); stroke(canvas)
                fill(layout.photo,photoColor); stroke(layout.photo)
            case .newYear:
                fill(canvas,ink); fill(layout.photo,photoColor)
                let panel = layout.decoration!
                let diameter = panel.width*0.62
                let center = CGPoint(x:(layout.photo.maxX+layout.size.width)/2,y:layout.size.height/2)
                context.fill(Path(ellipseIn:CGRect(x:center.x-diameter/2,y:center.y-diameter/2,
                                                   width:diameter,height:diameter)),with:.color(photoColor))
            }
        }
    }
}
