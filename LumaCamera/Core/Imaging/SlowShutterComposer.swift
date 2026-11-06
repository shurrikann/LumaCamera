import CoreImage
import CoreGraphics
import UIKit

struct SlowShutterAccumulationPreview {
    let id:UUID
    let image:UIImage
    let revision:Int
    var isFinal = false
}

/// 全分辨率慢门合成：旧短序列保留惰性图；长序列每帧渲染检查点，释放历史源图。
/// 跨队列传递时由调用方保证仅在 slowShutterCompositionQueue 访问。
final class SlowShutterComposer: @unchecked Sendable {
    let blend: SlowShutterBlendMode
    private let context: CIContext
    private var accumulator: CIImage?
    private var count = 0
    private let materializeFrames: Bool
    private var subjectAlignment: SlowShutterSubjectAlignment?
    private var globalAlignment: SlowShutterGlobalAlignment?
    private var bestSingleFrame: CIImage?
    private var bestSharpness = -Double.infinity
    private(set) var usedSingleFrameFallback = false
    private(set) var rejectedFrameCount = 0
    private var acceptedFrameCount = 0

    init(blend: SlowShutterBlendMode, context: CIContext = CIContext(options: [.cacheIntermediates: false]),
         materializeFrames: Bool = false) {
        self.blend = blend
        self.context = context
        self.materializeFrames = materializeFrames
        if blend == .subjectAlignedAverage { subjectAlignment = SlowShutterSubjectAlignment(context:context) }
        if blend == .handheldAlignedAverage || blend == .handheldAlignedLighten { globalAlignment = SlowShutterGlobalAlignment(context: context) }
    }

    var frameCount: Int { count }
    /// frameCount统计真实采集；回退时最终融合帧数只能记1，不能把未融合的源图冒充合成。
    var effectiveFrameCount: Int {
        if usedSingleFrameFallback && count > 0 { return 1 }
        return subjectAlignment != nil || globalAlignment != nil ? acceptedFrameCount : count
    }
    var result: CIImage? { usedSingleFrameFallback ? bestSingleFrame : accumulator }

    /// 仅渲染当前真实累积结果的小图；与add在同一串行队列调用，不重新融合或编码照片。
    func renderPreview(look:CaptureLook,maximumDimension:CGFloat = 900)->UIImage? {
        guard let source = result else { return nil }
        let extent = source.extent,scale = min(1,maximumDimension/max(extent.width,extent.height))
        let small = source.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        var previewLook = look; previewLook.border = false
        return Imaging.renderProcessed(Imaging.filtered(small,look:previewLook),look:previewLook,context:context)
    }

    @discardableResult func add(_ image: CIImage) -> Bool {
        defer { if materializeFrames { context.clearCaches() } }
        guard image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width > 0, image.extent.height > 0 else { return false }
        var image = image
        let alignment = subjectAlignment?.evaluate(image) ?? globalAlignment?.evaluate(image)
        if let result = alignment {
            if acceptedFrameCount < 2, result.sharpness > bestSharpness {
                guard let stored = checkpoint(image) else { return false }
                bestSingleFrame = stored; bestSharpness = result.sharpness
            }
            if !result.reliable {
                count += 1
                rejectedFrameCount += 1
                usedSingleFrameFallback = acceptedFrameCount < 2
                if acceptedFrameCount == 0 { accumulator = bestSingleFrame; usedSingleFrameFallback = true }
                return accumulator != nil
            }
            image = result.image
            if acceptedFrameCount == 0 {
                guard let stored = checkpoint(image) else { return false }
                accumulator = stored; count += 1; acceptedFrameCount = 1; usedSingleFrameFallback = true
                return true
            }
        }
        guard let current = accumulator else {
            guard let stored = checkpoint(image) else { return false }
            accumulator = stored
            count = 1
            acceptedFrameCount = 1
            return true
        }
        let extent: CGRect
        if alignment != nil {
            // 配准后保持参考画布；新帧未覆盖的窄边沿沿用已有真实像素，避免逐帧裁掉视野。
            extent = current.extent
            guard !extent.intersection(image.extent).isEmpty else { return false }
            image = image.composited(over:current).cropped(to:extent)
        } else { extent = current.extent.intersection(image.extent) }
        guard extent.width > 0, extent.height > 0 else { return false }
        let combined: CIImage
        switch blend {
        case .lighten, .handheldAlignedLighten:
            combined = CIFilter(name: "CILightenBlendMode", parameters: [
                kCIInputImageKey: image,
                kCIInputBackgroundImageKey: current
            ])?.outputImage ?? current
        case .average, .subjectAlignedAverage, .handheldAlignedAverage:
            let blendedCount = alignment != nil ? acceptedFrameCount : count
            let newWeight = 1.0 / Double(blendedCount + 1)
            // 用标量权重在工作色彩空间插值；同时缩放 RGB 和 alpha 会重复预乘、逐帧变暗。
            combined = CIFilter(name: "CIDissolveTransition", parameters: [
                kCIInputImageKey: current,
                kCIInputTargetImageKey: image,
                kCIInputTimeKey: newWeight
            ])?.outputImage ?? current
        }
        // 新长序列每帧立即渲染，切断对历史源图的惰性依赖；旧短序列保持原路径。
        guard let stored = checkpoint(combined.cropped(to: extent)) else { return false }
        count += 1
        acceptedFrameCount += 1
        usedSingleFrameFallback = false
        // 已有两张有效融合后不会再回退单帧，无需长期多持有一张全分辨率检查点。
        bestSingleFrame = nil
        accumulator = stored
        return true
    }

    private func checkpoint(_ image: CIImage) -> CIImage? {
        guard materializeFrames else { return image }
        // 16 位 P3 保留 SDR 色彩及平均时的精度，不把长序列反复量化为 8 位。
        let extent = image.extent
        guard let bitmap = Imaging.ownedCGImage(image, from: extent, context: context, format: .RGBA16,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) else { return nil }
        return CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

}
