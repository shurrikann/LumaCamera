import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum PortraitPhotoRenderer {
    /// 静态成片补充人脸前景保护。原生/分割蒙版都可能在脸颊、眼镜边缘漏分，
    /// 用已定向的同一张原片检测，不从预览复制坐标，也不在实时滑块上重复跑检测。
    static func faceProtectedMask(_ mask: CIImage, image: CIImage, headMask: CIImage? = nil, faceRects supplied: [CGRect]? = nil) -> CIImage {
        let extent = image.extent, maskExtent = mask.extent
        guard extent.width > 0, extent.height > 0, maskExtent.width > 0, maskExtent.height > 0 else { return mask }
        let faces: [CGRect]
        if let supplied { faces = supplied }
        else {
            let scale = min(1, 1200 / max(extent.width, extent.height))
            let probe = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let request = VNDetectFaceRectanglesRequest()
            do { try VNImageRequestHandler(ciImage: probe, orientation: .up).perform([request]) }
            catch { return mask }
            faces = (request.results ?? []).filter { $0.confidence >= 0.7 && $0.boundingBox.height >= 0.04 }.map(\.boundingBox)
        }
        guard !faces.isEmpty else { return mask }
        func aligned(_ input: CIImage) -> CIImage {
            input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / input.extent.width, y: extent.height / input.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
        }
        let originalMask = aligned(mask)
        var protected = originalMask
        let semantic = headMask.flatMap { $0.extent.width > 0 && $0.extent.height > 0 ? aligned($0) : nil }
        for box in faces where box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0 {
            // Vision与Core Image均为左下原点。适度扩展脸部椭圆，保护脸颊/下巴，
            // 不整体膨胀人物蒙版，避免把大面积背景也变为清晰前景。
            let rect = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                              width: box.width * extent.width, height: box.height * extent.height)
            // 脸部沿用有限椭圆，眼镜外角由下方语义轮廓补充，不画大矩形清晰区。
            let face = CIFilter.radialGradient()
            face.center = .zero; face.radius0 = 0.47; face.radius1 = 0.5
            face.color0 = .white; face.color1 = .black
            guard let faceImage = face.outputImage?.transformed(by: CGAffineTransform(scaleX: rect.width * 1.25, y: rect.height * 1.16))
                .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY)).cropped(to: extent) else { continue }
            let black = CIImage(color: .black).cropped(to: extent)
            let guardMask = faceImage.composited(over: black).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, rect.width * 0.004)]).cropped(to: extent)
            protected = protected.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: guardMask]).cropped(to: extent)
            if let semantic {
                // 人脸框不包含头顶；只在脸框附近引入同图准确分割的真实轮廓，不画一个大头椭圆。
                let headBounds = CGRect(x: rect.midX - rect.width * 0.95, y: rect.minY - rect.height * 0.15,
                                        width: rect.width * 1.9, height: rect.height * 1.85)
                let region = CIImage(color: .white).cropped(to: headBounds).composited(over: black)
                    .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, rect.width * 0.025)]).cropped(to: extent)
                let semanticHead = semantic.clampedToExtent()
                    .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": extent.width / 900 * 1.5])
                    .cropped(to: extent)
                // 准确人物分割可能把透明眼镜的外框判成背景。只在眼部窄带保留原蒙版的
                // 已有前景细节，不填白整条窄带；脸颊旁的绿叶仍能被语义背景排除。
                let eyes = CGRect(x: rect.midX - rect.width * 0.625, y: rect.minY + rect.height * 0.50,
                                  width: rect.width * 1.25, height: rect.height * 0.60)
                let eyeRegion = CIImage(color: .white).cropped(to: eyes).composited(over: black)
                    .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, rect.width * 0.015)]).cropped(to: extent)
                let nativeEyes = originalMask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: eyeRegion])
                let head = semanticHead.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: nativeEyes])
                // 不能只取最大值：脸部椭圆或原生蒙版误含的绿叶也会被永久保留清晰。
                // 头部附近按同图准确分割双向校正，区域外仍保留既有身体蒙版。
                protected = head.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: protected, kCIInputMaskImageKey: region]).cropped(to: extent)
            }
        }
        return protected
    }
    // 保持 0...1 滑块与既有 8.8 上限（900 像素宽参考），前后置共用并按输出尺寸换算。
    static let maximumBlurRadius: Float = 8.8
    static let defaultBlurRadius: Float = maximumBlurRadius * 0.5
    static let previewMaskExpansionRadius: Float = 1.5
    static let previewMaskFeatherRadius: Float = 1.5

    static func normalizedStrength(_ strength: Double) -> Double {
        guard strength.isFinite else { return 0.5 }
        return min(1, max(0, strength))
    }

    static func blurRadius(for strength: Double) -> Float {
        Float(normalizedStrength(strength)) * maximumBlurRadius
    }

    static func apply(_ image: CIImage, matte: AVPortraitEffectsMatte?, radius: Float = defaultBlurRadius) -> CIImage {
        guard let matte else { return image }
        let mask = CIImage(cvPixelBuffer: matte.mattingImage)
        return apply(image, foregroundMask: mask, radius: radius)
    }

    static func matteImage(fromProRAW data: Data) -> CIImage? {
        CIRAWFilter(imageData: data, identifierHint: nil)?.portraitEffectsMatte
    }

    static func apply(_ image: CIImage, foregroundMask: CIImage, radius: Float = defaultBlurRadius) -> CIImage {
        apply(image, foregroundMask: foregroundMask, radius: radius, refineMaskEdges: false)
    }

    /// 实时预览的人物分割蒙版分辨率较低；稍微向人物侧扩展并柔化边缘，减轻发丝周围的亮边和锯齿。
    static func applyPreview(_ image: CIImage, foregroundMask: CIImage, radius: Float) -> CIImage {
        apply(image, foregroundMask: foregroundMask, radius: radius, refineMaskEdges: true)
    }

    private static func apply(_ image: CIImage, foregroundMask: CIImage, radius: Float,
                              refineMaskEdges: Bool) -> CIImage {
        guard radius > 0,
              image.extent.width > 0, image.extent.height > 0,
              foregroundMask.extent.width > 0, foregroundMask.extent.height > 0 else { return image }

        let maskExtent = foregroundMask.extent
        let scaleX = image.extent.width / maskExtent.width
        let scaleY = image.extent.height / maskExtent.height
        let alignedMask = foregroundMask
            .transformed(by: CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .cropped(to: image.extent)

        // 半径以 900 像素宽预览为基准，成片按实际尺寸等比换算，避免后置大图几乎没有虚化。
        let pixelScale = Float(image.extent.width / 900)
        let actualRadius = max(0, radius) * pixelScale
        let expansion = (refineMaskEdges ? Self.previewMaskExpansionRadius : 0.35) * pixelScale
        let feather = (refineMaskEdges ? Self.previewMaskFeatherRadius : 0.6) * pixelScale
        let foreground = alignedMask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": expansion])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": feather])
            .cropped(to: image.extent)
        // 背景取样再避开一小圈混合边缘，防止羽化过渡本身把人物颜色纳入背景。
        let backgroundWeight = foreground.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": min(pixelScale * 2, actualRadius * 0.35)])
            .applyingFilter("CIColorInvert").cropped(to: image.extent)

        // 归一化背景卷积：先排除人物颜色再模糊，并除以相同半径的背景权重。
        // 防止头发、皮肤和亮衣服被卷进背景，形成光晕；最后把清晰人物单独合回。
        let weightedBackground = image.applyingFilter("CIMultiplyCompositing",
            parameters: [kCIInputBackgroundImageKey: backgroundWeight])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": actualRadius])
        let blurredWeight = backgroundWeight.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": actualRadius])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0.001, y: 0.001, z: 0.001, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        // CIDivideBlendMode 的定义为背景 / 输入，因此权重作为 inputImage。
        let background = blurredWeight.applyingFilter("CIDivideBlendMode",
            parameters: [kCIInputBackgroundImageKey: weightedBackground]).cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: foreground])
            .cropped(to: image.extent).settingProperties(image.properties)
    }
}
