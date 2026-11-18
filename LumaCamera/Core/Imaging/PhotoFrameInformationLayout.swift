import UIKit

/// Typography follows the source's short edge, so rotating the same photo does
/// not enlarge its information. The frame uses the same measured text as export.
struct PhotoFrameInformationLayout {
    struct Column {
        let rows: [NSAttributedString]
        let heights: [CGFloat]
        var height: CGFloat { heights.reduce(0,+) }
    }
    let left: Column
    let right: Column
    let height: CGFloat
    let scale: CGFloat
    let columnWidth: CGFloat

    init(photoSize: CGSize, settings: PhotoWatermarkSettings, content: PhotoWatermarkContent, informationWidth: CGFloat? = nil, compact: Bool = false) {
        scale = min(photoSize.width,photoSize.height)
        columnWidth = (informationWidth ?? photoSize.width)*0.42
        let date = DateFormatter(); date.locale = Locale(identifier:"en_US_POSIX")
        date.calendar = Calendar(identifier:.gregorian); date.timeZone = .current
        date.dateFormat = "yyyy.MM.dd HH:mm:ss"
        var leftLines = [date.string(from:content.capturedAt)]
        if settings.showsLocation,let text = content.location?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty {
            leftLines.append(text)
        }
        let signature = content.signature.trimmingCharacters(in:.whitespacesAndNewlines)
        var rightLines = [String]()
        if settings.showsParameters {
            leftLines.append("光屿相机")
            if !signature.isEmpty { leftLines.append(signature) }
            rightLines = PhotoWatermarkRenderer.parameterLines(content)
        } else {
            rightLines = ["光屿相机"]
            if !signature.isEmpty { rightLines.append(signature) }
        }
        let base = scale, width = columnWidth
        func column(_ lines: [String], rightAligned: Bool) -> Column {
            var rows = [NSAttributedString](), heights = [CGFloat]()
            for (index,text) in lines.enumerated() {
                let primary = index == 0
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = rightAligned ? .right : .left
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.lineSpacing = base*(compact ? 0.002 : 0.004)
                let size = base*(primary && rightAligned && !settings.showsParameters ? 0.026 : primary ? 0.022 : 0.018)
                var attributes: [NSAttributedString.Key:Any] = [
                    .font:UIFont.systemFont(ofSize:size,weight:primary ? .medium : .regular),
                    .foregroundColor:UIColor.white.withAlphaComponent(primary ? 1 : 0.8),.paragraphStyle:paragraph]
                if compact {
                    let shadow = NSShadow(); shadow.shadowColor = UIColor.black.withAlphaComponent(0.65)
                    shadow.shadowBlurRadius = max(1,base*0.0015)
                    shadow.shadowOffset = CGSize(width:0,height:base*0.0007)
                    attributes[.shadow] = shadow
                }
                let row = NSAttributedString(string:text,attributes:attributes)
                rows.append(row)
                heights.append(ceil(row.boundingRect(with:CGSize(width:width,height:.greatestFiniteMagnitude),
                    options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil).height)+base*(compact ? 0.004 : 0.008))
            }
            return Column(rows:rows,heights:heights)
        }
        left = column(leftLines,rightAligned:false); right = column(rightLines,rightAligned:true)
        height = ceil(max(left.height,right.height,base*0.06)+base*(compact ? 0.012 : 0.024))
    }

    func draw(in bounds: CGRect) {
        func draw(_ column: Column, x: CGFloat) {
            var y = bounds.midY-column.height/2
            for (index,row) in column.rows.enumerated() {
                row.draw(in:CGRect(x:x,y:y,width:columnWidth,height:column.heights[index]))
                y += column.heights[index]
            }
        }
        draw(left,x:bounds.minX); draw(right,x:bounds.maxX-columnWidth)
        let size = CGSize(width:scale*0.049,height:scale*0.060)
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        if let shadow = left.rows.first?.attribute(.shadow,at:0,effectiveRange:nil) as? NSShadow {
            context?.setShadow(offset:shadow.shadowOffset,blur:shadow.shadowBlurRadius,color:UIColor.black.withAlphaComponent(0.65).cgColor)
        }
        defer { context?.restoreGState() }
        UIImage(systemName:"apple.logo")?.withTintColor(.white,renderingMode:.alwaysOriginal)
            .draw(in:CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height))
    }
}
