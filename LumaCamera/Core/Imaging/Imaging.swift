import CoreImage
import UIKit

enum Imaging {
    private static let hdrExpandKernel = MetalImageKernels.color("hdrExpand")
    private static let hdrBlendKernel = MetalImageKernels.color("filterStrength")

    struct FilteredHDR {
        let hdr: CIImage
        let sdr: CIImage
    }

    /// HDR 滤镜一次产出预览用 HDR 主图与成片用 SDR 基底；
    /// 成片不再在预览结果上二次压软肩。
    static func filteredHDR(_ image: CIImage, look: CaptureLook) -> FilteredHDR? {
        guard look.requiresImageProcessing, #available(iOS 18.0, *),
              let hdrExpandKernel, let hdrBlendKernel else { return nil }
        let base = image.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputSourceHeadroom": Float(4.0),
            "inputTargetHeadroom": Float(1.0)
        ])
        let fullStyle = look.style.apply(to: base, intensity: 1)
        let sourceAdjusted = FilterAdjustmentRenderer.apply(look.adjustments,
            to: look.tone.apply(to: base, hdr: false), grainPhase: look.grainPhase)
        let filteredAdjusted = FilterAdjustmentRenderer.apply(look.adjustments,
            to: look.tone.apply(to: fullStyle, hdr: false), grainPhase: look.grainPhase)
        guard let sourceHDR = hdrExpandKernel.apply(extent: base.extent, arguments: [sourceAdjusted, HDRToneMapping.previewMaxGain]),
              let filteredHDR = hdrExpandKernel.apply(extent: base.extent, arguments: [filteredAdjusted, HDRToneMapping.previewMaxGain]),
              let mixed = hdrBlendKernel.apply(extent: base.extent,
                  arguments: [sourceHDR, filteredHDR, min(max(look.intensity, 0), 1)]) else { return nil }
        var hdr = mixed.cropped(to: image.extent)
        if #available(iOS 26.0, *) { hdr = hdr.settingContentHeadroom(HDRToneMapping.headroom) }
        // 成片SDR基底从同一份HDR主图压一次软肩，预览也用这份HDR主图。
        let sdr: CIImage
        if let shoulder = MetalImageKernels.color("hdrSoftShoulder"),
           let mapped = shoulder.apply(extent: hdr.extent,
                                       arguments: [hdr, HDRToneMapping.knee, HDRToneMapping.headroom]) {
            sdr = mapped.cropped(to: hdr.extent)
        } else {
            sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: [
                "inputSourceHeadroom": HDRToneMapping.headroom,
                "inputTargetHeadroom": Float(1.0)
            ])
        }
        return FilteredHDR(hdr: VirtualApertureRenderer.apply(hdr, fNumber: look.virtualAperture),
                           sdr: VirtualApertureRenderer.apply(sdr, fNumber: look.virtualAperture))
    }

    static func filtered(_ image: CIImage, look: CaptureLook, hdr: Bool = false) -> CIImage {
        if hdr, let layers = filteredHDR(image, look: look) { return layers.hdr }
        let filtered = FilterAdjustmentRenderer.apply(look.adjustments, to: look.tone.apply(to: look.style.apply(to: image, intensity: look.intensity), hdr: hdr), grainPhase: look.grainPhase)
        return VirtualApertureRenderer.apply(filtered, fNumber: look.virtualAperture)
    }

    static func meanLuminance(_ image: CIImage, context: CIContext) -> Double {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(average, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        }
        return max(0, Double(pixel[0]) * 0.2126 + Double(pixel[1]) * 0.7152 + Double(pixel[2]) * 0.0722)
    }

    static func histogram(_ image: CIImage, context: CIContext) -> [Double] {
        let size = 64
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size) / image.extent.width, y: CGFloat(size) / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(normalized, toBitmap: bytes.baseAddress!, rowBytes: size * 4, bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        var bins = [Double](repeating: 0, count: 128)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
            bins[min(127, Int(luminance / 2))] += 1
        }
        let maximum = max(bins.max() ?? 1, 1)
        return bins.map { $0 / maximum }
    }

    /// 跨帧/跨队列保留的图像使用独立像素，避免UIImage/CIImage长时间占有渲染输出的IOSurface。
    static func ownedCGImage(_ image: CIImage, from extent: CGRect, context: CIContext,
                             format: CIFormat = .RGBA8, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
                             headroom: Float? = nil) -> CGImage? {
        autoreleasepool {
            if format == .RGBA8 || format == .RGBA16 {
                let bounds=extent.integral
                guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0,
                      bounds.width<=16384,bounds.height<=16384 else { return nil }
                let width=Int(bounds.width),height=Int(bounds.height),bits=format == .RGBA16 ? 16:8
                let rowBytes=((width*4*(bits/8)+63)/64)*64
                guard rowBytes*height<=512*1024*1024 else { return nil }
                var pixels=Data(count:rowBytes*height)
                do {
                    try pixels.withUnsafeMutableBytes { bytes in
                        let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:width,height:height,
                            bytesPerRow:rowBytes,format:format)
                        destination.colorSpace=colorSpace;destination.isFlipped=true
                        destination.alphaMode = .premultiplied
                        let task=try context.startTask(toRender:image,from:bounds,to:destination,at:.zero)
                        _ = try task.waitUntilCompleted()
                    }
                } catch { context.clearCaches(); return nil }
                let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(bits == 16 ? .byteOrder16Little:.byteOrder32Big)
                guard let provider=CGDataProvider(data:pixels as CFData) else { return nil }
                return CGImage(width:width,height:height,bitsPerComponent:bits,bitsPerPixel:bits*4,
                    bytesPerRow:rowBytes,space:colorSpace,bitmapInfo:info,provider:provider,decode:nil,
                    shouldInterpolate:false,intent:.defaultIntent)
            }
            guard let rendered = context.createCGImage(image, from: extent, format: format,
                    colorSpace: colorSpace, deferred: false),
                  let provider = rendered.dataProvider, let pixels = provider.data,
                  let bytes = CFDataGetBytePtr(pixels) else { return nil }
            let owned = Data(bytes: bytes, count: CFDataGetLength(pixels))
            guard let dataProvider = CGDataProvider(data: owned as CFData),
                  var result = CGImage(width: rendered.width, height: rendered.height,
                    bitsPerComponent: rendered.bitsPerComponent, bitsPerPixel: rendered.bitsPerPixel,
                    bytesPerRow: rendered.bytesPerRow, space: rendered.colorSpace ?? colorSpace,
                    bitmapInfo: rendered.bitmapInfo, provider: dataProvider, decode: rendered.decode,
                    shouldInterpolate: rendered.shouldInterpolate, intent: rendered.renderingIntent) else { return nil }
            let resolvedHeadroom = max(headroom ?? 0, max(rendered.contentHeadroom, image.contentHeadroom))
            if resolvedHeadroom > 0, let hdr = CGImageCreateCopyWithContentHeadroom(resolvedHeadroom, result) { result = hdr }
            if #available(iOS 26.0, *) {
                let average = rendered.contentAverageLightLevel
                if average > 0, let hdr = result.copy(contentAverageLightLevel: average) { result = hdr }
            }
            return result
        }
    }

    static func render(_ image: CIImage, look: CaptureLook, context: CIContext) -> UIImage? {
        renderProcessed(filtered(image, look: look), look: look, context: context)
    }

    static func renderProcessed(_ image: CIImage, look: CaptureLook, context: CIContext, hdr: Bool = false) -> UIImage? {
        let filtered = look.ratio.crop(image, landscape: look.landscape)
        let extended = hdr && !look.border
        guard let cg = ownedCGImage(filtered, from: filtered.extent, context: context, format: extended ? .RGBAh : .RGBA8, colorSpace: CGColorSpace(name: extended ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)!) else { return nil }
        let photo = UIImage(cgImage: cg)
        guard look.border else { return photo }
        let margin = photo.size.width * 0.035
        let footer = photo.size.width * 0.12
        let size = CGSize(width: photo.size.width + margin * 2, height: photo.size.height + margin * 2 + footer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor(white: 0.96, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            photo.draw(at: CGPoint(x: margin, y: margin))
            let textY = photo.size.height + margin + footer * 0.25
            ("LUMA / 光屿" as NSString).draw(at: CGPoint(x: margin, y: textY), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: photo.size.width * 0.027, weight: .medium), .foregroundColor: UIColor.black])
            let detail = "\(look.style.title) · \(Date().formatted(.dateTime.year().month().day()))"
            (detail as NSString).draw(at: CGPoint(x: margin, y: textY + photo.size.width * 0.04), withAttributes: [.font: UIFont.systemFont(ofSize: photo.size.width * 0.019), .foregroundColor: UIColor.darkGray])
        }
    }

}
