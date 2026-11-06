import CoreGraphics
import Foundation

/// 以固定关键帧纹理复核对象跟踪。模板不逐帧更新，防止错误位置被不断学成新目标。
struct SmartFeatureAnchor {
    struct Frame {
        let width:Int, height:Int
        let pixels:[UInt8]
        init?(_ image:CGImage) {
            let scale = min(1,320/CGFloat(max(image.width,image.height)))
            width = max(1,Int(CGFloat(image.width)*scale)); height = max(1,Int(CGFloat(image.height)*scale))
            var data = [UInt8](repeating:0,count:width*height)
            guard let context = CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); pixels = data
        }
    }
    let template:[Float]
    private static let radius = 5
    static func seed(in frame:Frame,rect:CGRect) -> (SmartFeatureAnchor,CGPoint)? {
        let r = radius
        // CGImage/灰度缓冲以左上为图像坐标；Vision对象框从左下起算。
        let bounds = CGRect(x:rect.minX*CGFloat(frame.width),y:(1-rect.maxY)*CGFloat(frame.height),
            width:rect.width*CGFloat(frame.width),height:rect.height*CGFloat(frame.height))
        let interior = bounds.insetBy(dx:max(CGFloat(r+1),bounds.width*0.10),dy:max(CGFloat(r+1),bounds.height*0.10))
        let minX = max(r+1,Int(ceil(interior.minX))), maxX = min(frame.width-r-2,Int(floor(interior.maxX)))
        let minY = max(r+1,Int(ceil(interior.minY))), maxY = min(frame.height-r-2,Int(floor(interior.maxY)))
        guard minX < maxX, minY < maxY else { return nil }
        var best:([Float],Int,Int,Float)?
        for y in stride(from:minY,through:maxY,by:3) { for x in stride(from:minX,through:maxX,by:3) {
            var patch:[Float] = []; patch.reserveCapacity(121)
            for dy in -r...r { for dx in -r...r { patch.append(Float(frame.pixels[(y+dy)*frame.width+x+dx])) } }
            let mean = patch.reduce(0,+)/Float(patch.count), centered = patch.map { $0-mean }
            let energy = centered.reduce(0) { $0+$1*$1 }
            guard energy/Float(patch.count) > 36 else { continue } // 无纹理墙面不提名假锚点。
            let distance = hypot(Float(x)-Float(bounds.midX),Float(y)-Float(bounds.midY))/max(1,Float(min(bounds.width,bounds.height)))
            let rank = energy/(1+distance*4)
            if best == nil || rank > best!.3 { best = (centered.map { $0/sqrt(energy) },x,y,rank) }
        } }
        guard let best else { return nil }
        return (Self(template:best.0),CGPoint(x:CGFloat(best.1)/CGFloat(frame.width),y:CGFloat(best.2)/CGFloat(frame.height)))
    }
    func match(in frame:Frame,near predicted:CGPoint) -> CGPoint? {
        let cx = Int(predicted.x*CGFloat(frame.width)), cy = Int(predicted.y*CGFloat(frame.height)), r = Self.radius
        let minX = max(r+1,cx-12), maxX = min(frame.width-r-2,cx+12)
        let minY = max(r+1,cy-12), maxY = min(frame.height-r-2,cy+12)
        guard minX <= maxX, minY <= maxY else { return nil }
        var scores:[(Float,Int,Int)] = []
        for y in minY...maxY { for x in minX...maxX {
            var sum:Float = 0, squared:Float = 0, dot:Float = 0, i = 0
            for dy in -r...r { for dx in -r...r {
                let value = Float(frame.pixels[(y+dy)*frame.width+x+dx])
                sum += value; squared += value*value; dot += value*template[i]; i += 1
            } }
            let energy = squared-sum*sum/Float(template.count)
            let score = energy > 1 ? dot/sqrt(energy) : 0
            scores.append((score,x,y))
        } }
        guard let best = scores.max(by:{ $0.0 < $1.0 }), best.0 >= 0.84 else { return nil }
        // 重复窗格等存在多个近乎等价匹配时不猜位置，避免突然跳到相邻纹理。
        let alternative = scores.filter { hypot(Double($0.1-best.1),Double($0.2-best.2)) > 5 }.map(\.0).max() ?? -1
        guard best.0-alternative >= 0.025 else { return nil }
        return CGPoint(x:CGFloat(best.1)/CGFloat(frame.width),y:CGFloat(best.2)/CGFloat(frame.height))
    }
}

/// 局部纹理有重复（如风扇格栅）时，用对象内部的低分辨率整体结构做第二路复核。
/// 仅和最初模板比较，不逐帧学习新位置，避免把漂移后的背景学成主体。
struct SmartSubjectAppearance {
    private let template:[Float]
    init?(frame:SmartFeatureAnchor.Frame,rect:CGRect) {
        guard let values = Self.samples(frame,rect:rect),let normalized = Self.normalized(values) else { return nil }
        template = normalized
    }
    func matches(frame:SmartFeatureAnchor.Frame,rect:CGRect) -> Bool {
        guard let values = Self.samples(frame,rect:rect),let normalized = Self.normalized(values) else { return false }
        return zip(template,normalized).reduce(Float(0)) { $0+$1.0*$1.1 } >= 0.90
    }
    private static func normalized(_ values:[Float]) -> [Float]? {
        let mean = values.reduce(0,+)/Float(values.count),centered = values.map { $0-mean }
        let energy = centered.reduce(0) { $0+$1*$1 }
        guard energy/Float(values.count) >= 12 else { return nil }
        return centered.map { $0/sqrt(energy) }
    }
    private static func samples(_ frame:SmartFeatureAnchor.Frame,rect:CGRect) -> [Float]? {
        guard rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,
              rect.width>0.01,rect.height>0.01,rect.minX>=0,rect.maxX<=1,rect.minY>=0,rect.maxY<=1 else { return nil }
        let inner = rect.insetBy(dx:rect.width*0.08,dy:rect.height*0.08)
        var values:[Float] = [];values.reserveCapacity(144)
        for y in 0..<12 { for x in 0..<12 {
            let px = Int((inner.minX+(CGFloat(x)+0.5)/12*inner.width)*CGFloat(frame.width))
            let py = Int((1-inner.maxY+(CGFloat(y)+0.5)/12*inner.height)*CGFloat(frame.height))
            var sum:Float = 0,count:Float = 0
            // 小邻域均值降低对焦变清晰/传感器噪声造成的单像素差异，不扩大搜索到别的对象。
            for dy in -1...1 { for dx in -1...1 {
                let sx = min(frame.width-1,max(0,px+dx)),sy = min(frame.height-1,max(0,py+dy))
                sum += Float(frame.pixels[sy*frame.width+sx]);count += 1
            } }
            values.append(sum/count)
        } }
        return values
    }
}
