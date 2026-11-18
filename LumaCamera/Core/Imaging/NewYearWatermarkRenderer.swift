import UIKit

/// The Chinese calendar's cyclic year begins at lunar New Year, rather than January 1.
enum CaptureZodiac {
    static let names = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]
    static func index(at date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = timeZone
        return ((calendar.component(.year, from: date) - 1) % 12 + 12) % 12
    }
    static func title(at date: Date) -> String {
        let year = Calendar(identifier:.chinese).component(.year,from:date)-1
        let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥")
        return "农历 \(stems[year % 10])\(branches[year % 12])\(names[index(at:date)])年"
    }
}

enum NewYearWatermarkRenderer {
    // A bundled 4×3 transparent atlas; crop once, keeping the capture path offline.
    private static let animals: [UIImage] = {
        guard let atlas = UIImage(named: "ZodiacGoldAtlas")?.cgImage else { return [] }
        let w = atlas.width / 4, h = atlas.height / 3
        return (0..<12).compactMap { index in
            atlas.cropping(to: CGRect(x: (index % 4)*w, y: (index / 4)*h, width: w, height: h))
                .map { UIImage(cgImage: $0) }
        }
    }()

    static func animal(at index: Int) -> UIImage? {
        animals.indices.contains(index) ? animals[index] : nil
    }

    struct InformationLayout {
        let upperText: String
        let lowerText: String
        let attributes: [NSAttributedString.Key: Any]
        let upper: CGRect
        let lower: CGRect
        let animal: CGRect
        let caption: CGRect
        let fontSize: CGFloat
    }

    static func informationLayout(in panel: CGRect, settings: PhotoWatermarkSettings,
                                  content: PhotoWatermarkContent, illustrationCenter: CGPoint? = nil) -> InformationLayout {
        let width = panel.width*0.90, x = panel.maxX-panel.width*0.035-panel.width*0.90
        let date = DateFormatter()
        date.locale = Locale(identifier:"en_US_POSIX"); date.calendar = Calendar(identifier:.gregorian)
        date.timeZone = .current; date.dateFormat = "yyyy.MM.dd HH:mm:ss"
        var upper = [CaptureZodiac.title(at:content.capturedAt),date.string(from:content.capturedAt)]
        if settings.showsLocation, let location = content.location?.trimmingCharacters(in:.whitespacesAndNewlines), !location.isEmpty {
            upper.append(location)
        }
        upper.append("光屿相机")
        let signature = content.signature.trimmingCharacters(in:.whitespacesAndNewlines)
        if !signature.isEmpty { upper.append(signature) }
        let upperText = upper.joined(separator:"\n")
        let lowerText = settings.showsParameters ? PhotoWatermarkRenderer.parameterLines(content).joined(separator:"\n") : ""
        var fontSize = min(panel.width*0.065,panel.height*0.024)
        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right
            paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = size*0.24
            return [.font:UIFont.systemFont(ofSize:size,weight:.medium),.paragraphStyle:paragraph,
                    .foregroundColor:UIColor(red:0.98,green:0.84,blue:0.57,alpha:1)]
        }
        func height(_ text:String, _ attrs:[NSAttributedString.Key:Any]) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            return ceil((text as NSString).boundingRect(with:CGSize(width:width,height:.greatestFiniteMagnitude),
                options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs,context:nil).height)+1
        }
        // First wrap naturally; reduce type only if the complete text would enter
        // the reserved central illustration area. No single-line truncation.
        for _ in 0..<20 {
            let attrs = attributes(fontSize)
            let fit = min(1, panel.height*0.30/max(1,height(upperText,attrs)),
                          panel.height*0.22/max(1,height(lowerText,attrs)))
            if fit >= 1 || fontSize <= 1 { break }
            fontSize = max(1,fontSize*fit*0.95)
        }
        let attrs = attributes(fontSize)
        let upperFrame = CGRect(x:x,y:panel.minY+panel.height*0.018,width:width,height:height(upperText,attrs))
        let lowerHeight = height(lowerText,attrs)
        let lowerFrame = CGRect(x:x,y:panel.maxY-panel.height*0.018-lowerHeight,width:width,height:lowerHeight)
        let gap = panel.height*0.025, captionHeight = fontSize*1.6
        let center = illustrationCenter ?? CGPoint(x:panel.midX,y:panel.midY)
        let diameter = max(0,min(panel.width*0.80,panel.height*0.30,
            2*min(center.x-panel.minX,panel.maxX-center.x)/1.06,
            2*(center.y-upperFrame.maxY-gap),2*(lowerFrame.minY-center.y-captionHeight-gap*2)))
        let art = CGRect(x:center.x-diameter/2,y:center.y-diameter/2,width:diameter,height:diameter)
        return InformationLayout(upperText:upperText,lowerText:lowerText,attributes:attrs,
            upper:upperFrame,lower:lowerFrame,animal:art,
            caption:CGRect(x:center.x-width/2,y:art.maxY+gap,width:width,height:captionHeight),fontSize:fontSize)
    }

    static func draw(in panel: CGRect, settings: PhotoWatermarkSettings,
                     content: PhotoWatermarkContent, illustrationCenter: CGPoint, context: CGContext) {
        context.saveGState(); context.clip(to: panel)
        defer { context.restoreGState() }
        let layout = informationLayout(in:panel,settings:settings,content:content,illustrationCenter:illustrationCenter)
        (layout.upperText as NSString).draw(in:layout.upper,withAttributes:layout.attributes)
        (layout.lowerText as NSString).draw(in:layout.lower,withAttributes:layout.attributes)
        let gold = UIColor(red:0.98,green:0.84,blue:0.57,alpha:1)
        context.setStrokeColor(gold.withAlphaComponent(0.20).cgColor)
        context.strokeEllipse(in:layout.animal.insetBy(dx:-layout.animal.width*0.03,dy:-layout.animal.height*0.03))
        let zodiac = CaptureZodiac.index(at:content.capturedAt)
        animal(at:zodiac)?.draw(in:layout.animal)
        drawText(CaptureZodiac.names[zodiac]+"年 · 新岁安好",in:layout.caption,
                 size:layout.fontSize,color:gold,alignment:.center)
    }

    static func drawBackground(in rect: CGRect, context: CGContext) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            UIColor(red:0.69,green:0.075,blue:0.10,alpha:1).cgColor,
            UIColor(red:0.43,green:0.025,blue:0.055,alpha:1).cgColor] as CFArray,locations:[0,1])!
        context.drawLinearGradient(gradient,start:rect.origin,end:CGPoint(x:rect.maxX,y:rect.maxY),options:[])
    }

    static func drawFrame(canvas: CGRect, photo: CGRect, context: CGContext) {
        let margin = photo.minX
        let gold = UIColor(red:0.98,green:0.84,blue:0.57,alpha:1)
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(gold.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(max(0.8,margin*0.025))
        context.stroke(canvas.insetBy(dx:margin*0.25,dy:margin*0.25))
        context.stroke(photo.insetBy(dx:-margin*0.12,dy:-margin*0.12))
        guard let ornament = UIImage(named:"NewYearCloudCorner") else { return }
        // Reuse the approved corner artwork with local rotations. Keep all ink
        // inside the border even if an asset's transparent padding changes.
        context.addRect(canvas)
        context.addRect(photo.insetBy(dx:-margin*0.12,dy:-margin*0.12))
        context.clip(using:.evenOdd)
        let size = margin*2.7, inset = margin*0.08
        let corners: [(CGPoint,CGFloat)] = [
            (CGPoint(x:inset,y:inset),0),
            (CGPoint(x:canvas.maxX-inset,y:inset),.pi/2),
            (CGPoint(x:canvas.maxX-inset,y:canvas.maxY-inset),.pi),
            (CGPoint(x:inset,y:canvas.maxY-inset),-.pi/2)]
        for (point,angle) in corners {
            context.saveGState()
            context.translateBy(x:point.x,y:point.y); context.rotate(by:angle)
            ornament.draw(in:CGRect(x:0,y:0,width:size,height:size))
            context.restoreGState()
        }
    }

    private static func drawText(_ value: String, in rect: CGRect, size: CGFloat,
                                 color: UIColor, alignment: NSTextAlignment) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to:rect); defer { context.restoreGState() }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (String(value.prefix(256)) as NSString).draw(in:rect,withAttributes:[
            .font:UIFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color,.paragraphStyle:paragraph])
    }
}
