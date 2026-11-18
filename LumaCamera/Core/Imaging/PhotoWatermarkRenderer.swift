import UIKit
import CoreImage

/// A baked still-image glass appearance; no live UI material is flattened into the file.
enum PhotoWatermarkRenderer {
    private static let glassContext = CIContext(options:[.cacheIntermediates:false])
    static func render(_ photo: UIImage, settings: PhotoWatermarkSettings,
                       content: PhotoWatermarkContent) -> UIImage {
        let layout = PhotoWatermarkLayout(photoSize:photo.size,settings:settings,content:content)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        format.preferredRange = .standard
        let nativeGlass = settings.style == .glassStrip ? layout.decoration.flatMap {
            NativePhotoGlassRenderer.render(photo:photo,card:$0,cornerRadius:PhotoWatermarkLayout.glassCornerRadius(photoSize:photo.size,card:$0))
        } : nil
        let glass = settings.style == .glassStrip && nativeGlass == nil ? layout.decoration.flatMap { glassSample(photo,rect:$0) } : nil
        let backdrop = settings.style == .blurredPhoto ? blurredBackdrop(photo) : nil
        return UIGraphicsImageRenderer(size:layout.size,format:format).image { renderer in
            let c = renderer.cgContext
            UIColor(white:0.965,alpha:1).setFill(); renderer.fill(CGRect(origin:.zero,size:layout.size))
            if settings.style == .newYear {
                NewYearWatermarkRenderer.drawBackground(in: CGRect(origin:.zero,size:layout.size), context:c)
            }
            if let backdrop {
                let scale = max(layout.size.width / backdrop.size.width, layout.size.height / backdrop.size.height)
                let size = CGSize(width: backdrop.size.width * scale, height: backdrop.size.height * scale)
                backdrop.draw(in: CGRect(x: (layout.size.width-size.width)/2, y: (layout.size.height-size.height)/2,
                                         width: size.width, height: size.height))
                UIColor.black.withAlphaComponent(0.25).setFill()
                c.fill(CGRect(origin: .zero, size: layout.size))
                c.saveGState()
                c.setShadow(offset: CGSize(width: 0, height: layout.size.width*0.008),
                            blur: layout.size.width*0.02, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                photo.draw(in: layout.photo)
                c.restoreGState()
            } else {
                photo.draw(in:layout.photo)
            }
            if let decoration = layout.decoration {
                switch settings.style {
                case .glassStrip:
                    if let nativeGlass {
                        c.saveGState()
                        UIBezierPath(roundedRect:decoration,cornerRadius:PhotoWatermarkLayout.glassCornerRadius(photoSize:photo.size,card:decoration)).addClip()
                        nativeGlass.image.draw(in:nativeGlass.sourceRect)
                        c.restoreGState()
                    } else {
                        drawGlass(in:decoration,sample:glass,cornerRadius:PhotoWatermarkLayout.glassCornerRadius(photoSize:photo.size,card:decoration),context:c)
                    }
                case .newYear:
                    NewYearWatermarkRenderer.drawFrame(canvas: CGRect(origin:.zero,size:layout.size), photo:layout.photo, context:c)
                    NewYearWatermarkRenderer.draw(in: decoration, settings: settings, content: content,
                        illustrationCenter:CGPoint(x:(layout.photo.maxX+layout.size.width)/2,y:layout.size.height/2),context:c)
                case .blurredPhoto: break
                case .whiteFrame: break
                }
            }
            let foreground: UIColor = settings.style == .whiteFrame ? UIColor(white:0.10,alpha:1)
                : .white
            if settings.style == .blurredPhoto || settings.style == .glassStrip {
                PhotoFrameInformationLayout(photoSize:photo.size,settings:settings,content:content,
                    informationWidth:layout.information.width,compact:settings.style == .glassStrip).draw(in:layout.information)
            } else if settings.style != .newYear {
                drawInformation(in:layout.information,settings:settings,content:content,color:foreground)
            }
        }
    }

    private static func blurredBackdrop(_ photo: UIImage) -> UIImage? {
        guard let cg = photo.cgImage else { return nil }
        let scale = min(1, 768 / CGFloat(max(cg.width, cg.height)))
        let source = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
            .cropped(to: source.extent)
        return glassContext.createCGImage(blurred, from: blurred.extent).map { UIImage(cgImage: $0) }
    }

    private static func glassSample(_ photo:UIImage,rect:CGRect)->UIImage? {
        guard let cg = photo.cgImage else { return nil }
        let crop = CGRect(x:rect.minX*CGFloat(cg.width)/photo.size.width,
                          y:rect.minY*CGFloat(cg.height)/photo.size.height,
                          width:rect.width*CGFloat(cg.width)/photo.size.width,
                          height:rect.height*CGFloat(cg.height)/photo.size.height).integral
        guard let strip = cg.cropping(to:crop) else { return nil }
        let scale = min(1,512/CGFloat(strip.width))
        let source = CIImage(cgImage:strip).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let image = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:6]).cropped(to:source.extent)
        return glassContext.createCGImage(image,from:image.extent).map { UIImage(cgImage:$0) }
    }
    private static func drawGlass(in rect:CGRect,sample:UIImage?,cornerRadius:CGFloat,context:CGContext) {
        let face = rect
        let shape = UIBezierPath(roundedRect:face,cornerRadius:cornerRadius)
        context.saveGState()
        shape.addClip()
        if let sample { sample.draw(in:face,blendMode:.normal,alpha:0.45) }
        else { UIColor(white: 0.18, alpha: 1).setFill(); context.fill(face) }
        UIColor.black.withAlphaComponent(0.14).setFill(); context.fill(face)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            UIColor.white.withAlphaComponent(0.08).cgColor,
            UIColor.white.withAlphaComponent(0.02).cgColor,
            UIColor.black.withAlphaComponent(0.04).cgColor] as CFArray, locations: [0, 0.46, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: face.midX, y: face.minY),
                                       end: CGPoint(x: face.midX, y: face.maxY), options: [])
        }
        context.restoreGState()

    }

    private static func drawInformation(in bounds:CGRect,settings:PhotoWatermarkSettings,
                                        content:PhotoWatermarkContent,color:UIColor) {
        let w = bounds.width, line = w*0.031
        let left = CGRect(x:bounds.minX,y:bounds.minY,width:w*0.42,height:bounds.height)
        let right = CGRect(x:bounds.maxX-w*0.42,y:bounds.minY,width:w*0.42,height:bounds.height)
        let date = DateFormatter(); date.locale = Locale(identifier:"en_US_POSIX")
        date.calendar = Calendar(identifier:.gregorian); date.timeZone = .current; date.dateFormat = "yyyy.MM.dd HH:mm:ss"
        var leftLines = [date.string(from:content.capturedAt)]
        if settings.showsLocation,let location = content.location,!location.isEmpty { leftLines.append(location) }
        let signature = content.signature.trimmingCharacters(in:.whitespacesAndNewlines)
        var rightLines:[String]
        if settings.showsParameters {
            leftLines.append("光屿相机")
            if !signature.isEmpty { leftLines.append(signature) }
            rightLines = parameterLines(content)
        } else { rightLines = ["光屿相机"] + (signature.isEmpty ? [] : [signature]) }
        func lines(_ text:[String],in rect:CGRect,rightAligned:Bool) {
            let total = CGFloat(text.count)*line
            for (index,value) in text.enumerated() {
                let y = rect.midY-total/2+CGFloat(index)*line
                let primary = index == 0
                drawText(value,in:CGRect(x:rect.minX,y:y,width:rect.width,height:line),
                    font:primary && !settings.showsParameters && rightAligned
                        ? .systemFont(ofSize:w*0.026,weight:.semibold)
                        : .systemFont(ofSize:w*(primary ? 0.022 : 0.018),weight:primary ? .medium : .regular),
                    color:color.withAlphaComponent(primary ? 1 : 0.76),alignment:rightAligned ? .right : .left)
            }
        }
        lines(leftLines,in:left,rightAligned:false); lines(rightLines,in:right,rightAligned:true)
        let logoSize = CGSize(width:w*0.049,height:w*0.060)
        UIImage(systemName:"apple.logo")?.withTintColor(color,renderingMode:.alwaysOriginal)
            .draw(in:CGRect(x:bounds.midX-logoSize.width/2,y:bounds.midY-logoSize.height/2,width:logoSize.width,height:logoSize.height))
    }
    static func parameterLines(_ content: PhotoWatermarkContent) -> [String] {
            let shutter = content.exposureSeconds.flatMap { $0.isFinite && $0 > 0 ? CameraNumericText.shutter($0) : nil } ?? "—"
            let iso = content.iso.flatMap { $0.isFinite && $0 > 0 ? String(format:"%.0f",$0) : nil } ?? "—"
            let wb = content.whiteBalanceKelvin.flatMap { $0.isFinite && $0 > 0 ? String(format:"%.0fK",$0) : nil } ?? (content.whiteBalanceAutomatic ? "自动" : "—")
            let ev = content.ev.flatMap { $0.isFinite ? String(format:"%+.1f",$0) : nil } ?? "—"
        return ["S \(shutter)   ISO \(iso)","WB \(wb)   EV \(ev)","滤镜  \(content.filter)"]
    }

    private static func drawText(_ text:String,in rect:CGRect,font:UIFont,color:UIColor,alignment:NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to: rect)
        (String(text.prefix(256)) as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
        context.restoreGState()
    }
}
