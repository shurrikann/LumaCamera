import CoreImage

/// 高动态是显影处理，不改变相机快门/ISO。只分析小图，全尺寸使用GPU亮度曲线。
enum AdaptiveDynamicRenderer {
    struct Analysis {
        let median: Double
        let white: Double
        let contrast: Double
        let shadowEV: Double
        let deepShadowEV: Double
        let regionalShadowEV: Double
        let deepShadowLuminance: Double
        let brightAreaLuminance: Double
    }
    private static let kernel = MetalImageKernels.color("adaptiveDynamic")
    private static let matchedHDRKernel = MetalImageKernels.color("rawMatchedHDR")

    /// Use the SDR development for shadows and midtones. The HDR development
    /// supplies highlight detail, with additional restrained gain near white.
    static func matchingHDR(_ image: CIImage, to base: CIImage) -> CIImage? {
        guard image.extent == base.extent else { return nil }
        return matchedHDRKernel?.apply(extent: image.extent, arguments: [image, base])?
            .settingProperties(image.properties)
    }
    private static let sdrBase = MetalImageKernels.color("adaptiveSDRBase")
    private static let restoreHDR = MetalImageKernels.color("adaptiveHDRRestore")
    /// LUT通常只定义0–1域；分离逐像素亮度余量后调色，再恢复余量，避免滤镜截断HDR层次。
    static func filtered(_ image:CIImage,look:CaptureLook,hdr:Bool) -> CIImage {
        if hdr, look.tone != .natural, let layers = Imaging.filteredHDR(image, look: look) {
            return layers.hdr
        }
        guard hdr, let base = sdrBase?.apply(extent:image.extent,arguments:[image]), let restoreHDR else {
            return Imaging.filtered(image,look:look)
        }
        let styled = Imaging.filtered(base,look:look,hdr:true)
        return restoreHDR.apply(extent:image.extent,arguments:[image,styled])?.settingProperties(image.properties) ?? styled
    }
    static func analyze(_ image: CIImage, context: CIContext) -> Analysis {
        let e = image.extent, scale = min(1,192 / max(e.width,e.height))
        let thumb = image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY))
            .clampedToExtent()
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            .cropped(to:CGRect(x:0,y:0,width:e.width*scale,height:e.height*scale))
        let width = max(1,Int(thumb.extent.width)), height = max(1,Int(thumb.extent.height))
        var rgba = [Float](repeating:0,count:width*height*4)
        rgba.withUnsafeMutableBytes {
            context.render(thumb,toBitmap:$0.baseAddress!,rowBytes:width*16,
                bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        }
        var values:[Double] = []; values.reserveCapacity(width*height)
        var tileSums = Array(repeating: 0.0, count: 16)
        var tileCounts = Array(repeating: 0, count: 16)
        for p in stride(from:0,to:rgba.count,by:4) {
            // 缩小图边缘无效透明像素不是场景黑位，不能压住2%分位使深暗补偿失效。
            guard rgba[p+3].isFinite, rgba[p+3] >= 0.99 else { continue }
            let y = Double(rgba[p])*0.2126+Double(rgba[p+1])*0.7152+Double(rgba[p+2])*0.0722
            guard y.isFinite else { continue }
            values.append(max(0, y))
            let row = (p / 4 / width) * 4 / height
            let column = (p / 4 % width) * 4 / width
            let tile = row * 4 + column
            tileSums[tile] += min(1, max(0, y))
            tileCounts[tile] += 1
        }
        guard !values.isEmpty else { return Analysis(median:0,white:1,contrast:1,shadowEV:0,deepShadowEV:0,regionalShadowEV:0,deepShadowLuminance:0,brightAreaLuminance:0) }
        values.sort()
        func percentile(_ p:Double) -> Double { values[min(values.count-1,Int(Double(values.count-1)*p))] }
        let median = percentile(0.5), white = percentile(0.998)
        let contrast = percentile(0.95)/max(percentile(0.1),0.008)
        // 逆光不能只保窗外：以线性中灰0.14为亮度参考，最多补偿3挡。
        // 用p90而非孤立最亮点判定亮区，避免只有小灯的夜景被整体提灰。
        // 这是项目显影策略，不是相机曝光或苹果平台保证；黑位由单调曲线保留。
        let contrastWeight = min(1,max(0,(contrast-5)/15))
        let target = 0.14, anchor = 0.45
        let gain = median > 0 && median < target
            ? target*(anchor-median)/(median*(anchor-target)) : 1
        let shadow = white > 0.3 && percentile(0.90) > 0.18
            ? min(3,max(0,log2(max(1,gain))))*contrastWeight : 0
        // 大面积亮墙会让中位数正常，但小门洞仍可能漆黑；独立检查约2%深暗区域。
        // 第二条单调曲线只作用于线性0...0.12，不再拉高已明亮的墙面或灯光。
        let tail = percentile(0.02), baseGain = pow(2, shadow)
        let raisedTail = tail < anchor ? tail * baseGain / (1 + (baseGain - 1) * tail / anchor) : tail
        let deepAnchor = 0.12, deepTarget = 0.018
        let deepContrast = percentile(0.90) / max(tail, 0.001)
        let deepWeight = min(1, max(0, (deepContrast - 12) / 36))
        let deepGain = raisedTail >= 0.0001 && raisedTail < deepTarget
            ? deepTarget * (deepAnchor - raisedTail) / (raisedTail * (deepAnchor - deepTarget)) : 1
        let deep = white > 0.3 && percentile(0.90) > 0.18
            ? min(3, max(0, log2(max(1, deepGain)))) * deepWeight : 0
        let tiles = zip(tileSums, tileCounts).map { $1 > 0 ? $0 / Double($1) : nil }
        let regional = regionalRecovery(tiles, globalEV: shadow, deepEV: deep)
        return Analysis(median:median,white:white,contrast:contrast,shadowEV:shadow,deepShadowEV:deep,
                        regionalShadowEV:regional,deepShadowLuminance:tail,brightAreaLuminance:percentile(0.90))
    }
    /// Look for substantial bright and dark areas on opposite sides, including
    /// top/bottom framing. Isolated lamps and small dark patches use the old policy.
    private static func regionalRecovery(_ tiles: [Double?], globalEV: Double, deepEV: Double) -> Double {
        let halves = [
            [0, 1, 4, 5, 8, 9, 12, 13],
            Array(0..<8)
        ]
        var recovery = 0.0
        for indices in halves {
            let first = indices.compactMap { tiles[$0] }
            let second = tiles.indices.filter { !indices.contains($0) }.compactMap { tiles[$0] }
            for (darkSide, lightSide) in [(first, second), (second, first)] {
                let dark = darkSide.filter { (0.005...0.08).contains($0) }.sorted()
                guard dark.count >= 3, lightSide.filter({ $0 >= 0.28 }).count >= 3 else { continue }
                let level = dark[dark.count / 2]
                let gain = pow(2, globalEV)
                let raised = level * gain / (1 + (gain - 1) * level / 0.45)
                let deepGain = pow(2, deepEV)
                let recovered = raised < 0.12 ? raised * deepGain / (1 + (deepGain - 1) * raised / 0.12) : raised
                guard recovered < 0.055 else { continue }
                let needed = 0.055 * (0.18 - recovered) / (recovered * (0.18 - 0.055))
                recovery = max(recovery, min(1.25, log2(needed)))
            }
        }
        return recovery
    }
    static func apply(_ image:CIImage,hdr:Bool,context:CIContext,limitHighlights:Bool = true) -> CIImage {
        let a = analyze(image,context:context)
        // HDR and SDR share the same backlight recovery. A matched HDR/SDR
        // pair applies its final highlight shoulder after combining both developments.
        let knee = hdr ? 1.0 : 0.65
        let cap = hdr ? 4.0 : 1.0
        let scale = limitHighlights ? max(cap-knee,(a.white-knee)/3.7) : 0
        return kernel?.apply(extent:image.extent,arguments:[image,a.shadowEV,a.deepShadowEV,a.regionalShadowEV,knee,cap,scale]) ?? image
    }
}

/// RAW重新显影沿用同一组官方解码选项；预览与最终输出不在8-bit成片上反复加工。
enum AdaptiveRAWDeveloper {
    static func configure(_ filter:CIRAWFilter,adaptive:Bool,hdr:Bool,adjustments:FilterAdjustments) {
        // HEIF Pro 的底片显影不叠加 RAW 解码器边缘增强；用户仍可在后续编辑中主动调整“模糊／锐化”。
        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
        if filter.isDetailSupported { filter.detailAmount = 0 }
        filter.extendedDynamicRangeAmount = adaptive || hdr ? 1 : 0
        // 保留底片自带的系统局部色调映射。固定降到0.35会丢失ProRAW的暗部呈现，
        // 再小幅提亮无法补回预览中的室内层次；此处不覆盖默认localToneMapAmount。
        filter.exposure = Float(adjustments[.exposure])
        if adjustments[.temperature] != 0 { filter.neutralTemperature = min(50000,max(2000,filter.neutralTemperature + Float(adjustments[.temperature])*20)) }
        if adjustments[.tint] != 0 { filter.neutralTint = min(150,max(-150,filter.neutralTint - Float(adjustments[.tint]))) }
    }
    static func withoutRAWControls(_ value:FilterAdjustments) -> FilterAdjustments {
        var result = value
        result[.exposure] = 0; result[.temperature] = 0; result[.tint] = 0
        return result
    }
}
