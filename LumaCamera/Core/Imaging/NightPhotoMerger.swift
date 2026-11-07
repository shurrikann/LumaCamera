import CoreImage
import ImageIO
import Foundation
import Vision
import simd

struct NightPhotoMergeResult {
    let image: CIImage
    let alignedFrameCount: Int
    let croppedFraction: Double
    var perspectiveAlignedFrameCount = 0
    var rotationAlignedFrameCount = 0
    var referenceCrop: CGRect? = nil
}

enum NightPhotoMerger {
    enum MergeError: Error { case noUsableFrame }

    private struct RegistrationProbe {
        let image: CGImage
        let scaleX: CGFloat
        let scaleY: CGFloat
    }

    /// 单次融合独占的连续像素内存。只在处理队列写入，离开函数后释放；不维护跨照片缓存。
    /// 直接渲染至 bitmap，省去 CGImage→CFData→逐像素 Swift 数组的往返与拷贝。
    private final class ProbeBuffer {
        let storage: NSMutableData
        let bytes: UnsafeMutablePointer<UInt8>
        let count: Int
        init?(count: Int, fill: UInt8 = 0) {
            guard count > 0, let data = NSMutableData(length: count) else { return nil }
            storage = data
            self.count = count
            bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
            bytes.initialize(repeating: fill, count: count)
        }
    }

    /// 缩小的探针只用于配准/运动判断，最终融合保持照片分辨率。
    /// 参考曝光始终保留：其他帧的运动区域退回参考，避免手持或主体移动产生重影。
    static func merge(_ sources: [CIImage], context: CIContext, maximumRegistrationDimension: CGFloat = 1600, referenceIndex requestedReference: Int? = nil, adaptiveTone: Bool = false) throws -> NightPhotoMergeResult {
        guard !sources.isEmpty else { throw MergeError.noUsableFrame }
        let referenceIndex = min(max(requestedReference ?? sources.count / 2, 0), sources.count - 1)
        let reference = normalized(sources[referenceIndex])
        guard reference.extent.width > 0, reference.extent.height > 0 else { throw MergeError.noUsableFrame }
        guard let referenceProbe = registrationImage(reference, context: context, maximumDimension: maximumRegistrationDimension) else {
            return NightPhotoMergeResult(image: reference, alignedFrameCount: 1, croppedFraction: 0)
        }

        var aligned = [CIImage?](repeating: nil, count: sources.count)
        var perspectiveCount = 0
        var rotationCount = 0
        aligned[referenceIndex] = reference
        for (index, source) in sources.enumerated() where index != referenceIndex {
            let candidate = normalized(source)
            guard candidate.extent.width > 0, candidate.extent.height > 0,
                  let probe = registrationImage(candidate, context: context, maximumDimension: maximumRegistrationDimension) else { continue }
            let translation = alignment(from:probe,to:referenceProbe).flatMap { transform -> CIImage? in
                guard abs(transform.tx) <= reference.extent.width * 0.10,
                      abs(transform.ty) <= reference.extent.height * 0.10 else { return nil }
                return candidate.transformed(by:transform)
            }
            let baselineError = translation.map { registrationError($0,reference:reference,context:context) } ?? .infinity
            // 平移足够时保留快速路径；旋转/轻微透视导致残差时再尝试单应配准。
            if baselineError > 0.012,
               let warped = perspectiveAlignment(candidate,probe:probe,reference:referenceProbe),
               registrationError(warped,reference:reference,context:context) < min(0.10,baselineError * 0.9) {
                aligned[index] = warped
                perspectiveCount += 1
            } else if baselineError > 0.012,
                      let rotated = rotationalAlignment(candidate,reference:reference,context:context),
                      rotated.error < min(0.10,baselineError*0.9) {
                aligned[index] = rotated.image
                rotationCount += 1
            } else { aligned[index] = baselineError < 0.10 ? translation : nil }
        }

        let accepted = aligned.compactMap { $0 }
        guard accepted.count > 1 else {
            return NightPhotoMergeResult(image: reference, alignedFrameCount: 1, croppedFraction: 0)
        }
        let commonExtent = accepted.reduce(reference.extent) { $0.intersection($1.extent) }
        guard commonExtent.width > 0, commonExtent.height > 0 else {
            return NightPhotoMergeResult(image: reference, alignedFrameCount: 1, croppedFraction: 0)
        }

        // 所有有效帧使用同一个交集；单张配准失败不再丢弃另外两张的合成结果。
        let cropTranslation = CGAffineTransform(translationX: -commonExtent.minX, y: -commonExtent.minY)
        let acceptedIndices = aligned.indices.filter { aligned[$0] != nil }
        // 配准/滤镜节点不应决定拍摄元数据是否存在；按原始序号显式带入真实ISO和曝光。
        let cropped = acceptedIndices.map { aligned[$0]!.cropped(to: commonExtent).transformed(by: cropTranslation)
            .settingProperties(sources[$0].properties) }
        let extent = CGRect(origin: .zero, size: commonExtent.size)
        guard let referenceInAccepted = acceptedIndices.firstIndex(of: referenceIndex),
              let composite = fuseAlignedFrames(cropped, referenceIndex: referenceInAccepted, context: context,
                                               maximumDimension: min(maximumRegistrationDimension, 900), adaptiveTone: adaptiveTone) else {
            return NightPhotoMergeResult(image: reference, alignedFrameCount: 1, croppedFraction: 0)
        }
        let originalArea = max(1, reference.extent.width * reference.extent.height)
        let retainedArea = commonExtent.width * commonExtent.height
        let output = NightCompositeMetadata.applying(to:composite.cropped(to:extent),sources:sources,usedIndices:acceptedIndices,referenceIndex:referenceIndex)
        return NightPhotoMergeResult(image: output, alignedFrameCount: cropped.count,
                                     croppedFraction: min(max(1 - retainedArea / originalArea, 0), 1),
                                     perspectiveAlignedFrameCount:perspectiveCount,rotationAlignedFrameCount:rotationCount,referenceCrop:commonExtent)
    }

    /// 只在批次间对少量小探针评估，不常驻处理预览，不启动额外运动传感器。
    /// 相对位移反映手持晃动，曝光归一后的局部变化反映主体运动；低纹理/配准失败返回未知。
    static func assessMotion(_ sources: [CIImage], reference: CIImage, context: CIContext) -> NightSceneAssessment {
        let reference = normalized(reference)
        guard sources.count >= 2,
              let target = registrationImage(reference, context: context, maximumDimension: 320) else {
            return NightSceneAssessment(motion: .unknown)
        }
        let size = CGSize(width: 96, height: 72)
        func probe(_ image: CIImage) -> [Double] {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return [] }
            let scaled = image.transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1])
            var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            context.render(scaled, toBitmap: &pixels, rowBytes: Int(size.width) * 4,
                           bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return stride(from: 0, to: pixels.count, by: 4).map {
                (0.2126 * Double(pixels[$0]) + 0.7152 * Double(pixels[$0 + 1]) + 0.0722 * Double(pixels[$0 + 2])) / 255
            }
        }
        let referenceProbe = probe(reference)
        guard !referenceProbe.isEmpty else { return NightSceneAssessment(motion: .unknown) }
        let mean = referenceProbe.reduce(0, +) / Double(referenceProbe.count)
        let variation = sqrt(referenceProbe.reduce(0) { $0 + pow($1 - mean, 2) } / Double(referenceProbe.count))
        // 只有一条水平/竖直边的场景无法可靠判断另一方向的位移，不能把 Vision 的零位移当作稳定。
        var horizontalTexture = 0.0, verticalTexture = 0.0
        for y in 1..<72 { for x in 1..<96 {
            let index = y * 96 + x
            horizontalTexture += abs(referenceProbe[index] - referenceProbe[index - 1])
            verticalTexture += abs(referenceProbe[index] - referenceProbe[index - 96])
        } }
        let comparisons = Double(71 * 95)
        // 暗景对比度较低，采用相对场景对比度的梯度阈值；保留底限和双方向要求，
        // 避免把单一边缘或平坦噪声认作可可靠配准的二维纹理。
        let textureThreshold = max(0.002, variation * 0.03)
        guard variation >= 0.025, horizontalTexture / comparisons >= textureThreshold,
              verticalTexture / comparisons >= textureThreshold else {
            return NightSceneAssessment(motion: .unknown, reason: String(format: "低纹理 σ=%.4f h=%.4f v=%.4f", variation,
                horizontalTexture / comparisons, verticalTexture / comparisons))
        }
        var result = NightSceneAssessment(motion: .stable)
        for source in sources {
            let source = normalized(source)
            guard let input = registrationImage(source, context: context, maximumDimension: 320),
                  let transform = alignment(from: input, to: target) else { return NightSceneAssessment(motion: .unknown, reason: "配准失败") }
            let shift = max(abs(transform.tx) / reference.extent.width, abs(transform.ty) / reference.extent.height)
            result.maximumShift = max(result.maximumShift, shift)
            // 整体手持位移可由融合配准补偿；主体是否运动在补偿后的画面上另行判断。
            if shift > 0.08 { result.motion = .moving; return result }
            // 配准交集的尺寸/原点不同，直接缩放交集会再次拉伸画面，制造虚假的局部运动。
            // 固定参考画布；本帧未覆盖的窄边沿使用参考，不把缺失边沿计为主体变化。
            let compared = source.transformed(by:transform).composited(over:reference).cropped(to:reference.extent)
            let values = probe(compared)
            guard values.count == referenceProbe.count else { return NightSceneAssessment(motion: .unknown) }
            // 中间范围的像素亮度比中位数消除 AE 包围亮度差，避免把明暗变化当成主体移动。
            let ratios = referenceProbe.indices.compactMap { index -> Double? in
                let a = referenceProbe[index], b = values[index]
                guard a > 0.08, a < 0.85, b > 0.04, b < 0.94 else { return nil }
                return a / b
            }.sorted()
            guard ratios.count >= 64 else { return NightSceneAssessment(motion: .unknown, reason: "曝光可比像素不足") }
            let gain = min(max(ratios[ratios.count / 2], 0.4), 2.5)
            var changed = 0, tested = 0
            // 跳过边缘，避免平移交集的无效边沿成为主体运动。
            for y in 3..<69 { for x in 3..<93 {
                let index = y * 96 + x
                let value = referenceProbe[index]
                guard value > 0.04, value < 0.92, values[index] > 0.04, values[index] < 0.94 else { continue }
                if abs(min(1, values[index] * gain) - value) > 0.12 { changed += 1 }
                tested += 1
            } }
            guard tested >= 64 else { return NightSceneAssessment(motion: .unknown, reason: "有效运动像素不足") }
            result.changedFraction = max(result.changedFraction, Double(changed) / Double(tested))
            if result.changedFraction > 0.10 { result.motion = .moving; return result }
        }
        return result
    }

    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func registrationImage(_ image: CIImage, context: CIContext, maximumDimension: CGFloat) -> RegistrationProbe? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent().applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:0.8])
            .cropped(to:CGRect(x:0,y:0,width:extent.width*scale,height:extent.height*scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return RegistrationProbe(image: cgImage,
                                 scaleX: extent.width / CGFloat(max(1, cgImage.width)),
                                 scaleY: extent.height / CGFloat(max(1, cgImage.height)))
    }

    private static func alignment(from floatingImage: RegistrationProbe, to referenceImage: RegistrationProbe) -> CGAffineTransform? {
        // SDK: targeted image 是 floating，handler 输入才是 reference。
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floatingImage.image)
        do {
            try VNImageRequestHandler(cgImage: referenceImage.image).perform([request])
        } catch { return nil }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let probeTransform = observation.alignmentTransform
        return CGAffineTransform(a: probeTransform.a, b: probeTransform.b, c: probeTransform.c, d: probeTransform.d,
                                tx: probeTransform.tx * referenceImage.scaleX,
                                ty: probeTransform.ty * referenceImage.scaleY)
    }

    #if DEBUG
    static func translationForTesting(_ image:CIImage,reference:CIImage,context:CIContext)->CGAffineTransform? {
        guard let a = registrationImage(image,context:context,maximumDimension:320),
              let b = registrationImage(reference,context:context,maximumDimension:320) else { return nil }
        return alignment(from:a,to:b)
    }
    #endif

    private static func registrationError(_ image:CIImage,reference:CIImage,context:CIContext,stableFraction:Double = 1)->Double {
        let width = stableFraction < 1 ? 320 : 96, height = stableFraction < 1 ? 240 : 72
        let bounds = CGRect(x:0,y:0,width:width,height:height), extent = reference.extent
        func pixels(_ source:CIImage)->[UInt8] {
            var bytes = [UInt8](repeating:0,count:width*height*4)
            let probe = source.transformed(by:CGAffineTransform(scaleX:CGFloat(width)/extent.width,y:CGFloat(height)/extent.height))
                .clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:stableFraction < 1 ? 0.35:1])
            context.render(probe,toBitmap:&bytes,rowBytes:width*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
            return bytes
        }
        let a = pixels(reference), b = pixels(image)
        let indices = stride(from:0,to:a.count,by:4).filter { a[$0+3]>240 && b[$0+3]>240 }
        guard indices.count > width*height/2 else { return .infinity }
        func luma(_ p:[UInt8],_ i:Int)->Double { (Double(p[i])*0.2126+Double(p[i+1])*0.7152+Double(p[i+2])*0.0722)/255 }
        let sumA = indices.reduce(0.0) { $0+luma(a,$1) }, sumB = indices.reduce(0.0) { $0+luma(b,$1) }
        let gain = min(4,max(0.25,sumA/max(0.001,sumB)))
        func photometricError(_ selected: [Int]) -> Double {
            let count = Double(selected.count)
            let meanA = selected.reduce(0.0) { $0+luma(a,$1) }/count
            let meanB = selected.reduce(0.0) { $0+luma(b,$1) }/count
            var varianceA=0.0,varianceB=0.0,covariance=0.0
            var error=0.0
            for i in selected {
                let x=luma(a,i)-meanA,y=luma(b,i)-meanB
                varianceA+=x*x;varianceB+=y*y;covariance+=x*y
                error+=min(0.15,abs(luma(a,i)-luma(b,i)*gain))
            }
            // 平均亮度相近的无关纹理不能冒充配准成功；低纹理仍沿用亮度误差。
            if stableFraction < 1, varianceA/count>0.00005,varianceB/count>0.00005 {
                let correlation=covariance/sqrt(varianceA*varianceB)
                error += count*max(0,0.3-correlation)*0.3
            }
            return error/count
        }
        if stableFraction < 1 {
            var errors = [Double]()
            var tiles = [[Int]](repeating:[],count:24)
            for i in indices {
                let tx=min(5,(i/4)%width*6/width),ty=min(3,(i/4)/width*4/height)
                tiles[ty*6+tx].append(i)
            }
            for tile in tiles {
                guard tile.count>(width/6)*(height/4)/2 else { continue }
                let mean = tile.reduce(0.0) { $0+luma(a,$1) }/Double(tile.count)
                let variance = tile.reduce(0.0) { $0+pow(luma(a,$1)-mean,2) }/Double(tile.count)
                guard variance>0.0004 else { continue }
                errors.append(photometricError(tile))
            }
            if errors.count>=6 {
                errors.sort(); let retained = max(6,Int(ceil(Double(errors.count)*stableFraction)))
                return errors.prefix(retained).reduce(0,+)/Double(retained)
            }
        }
        return photometricError(indices)
    }

    /// 慢门共享几何配准；稳定区域评分允许流水/车辆局部变化，不使用夜景影调或融合掩码。
    static func alignHandheldFrame(_ image:CIImage,reference:CIImage,context:CIContext)->CIImage? {
        guard abs(image.extent.width-reference.extent.width)<1,abs(image.extent.height-reference.extent.height)<1,
              let a = registrationImage(image,context:context,maximumDimension:640),
              let b = registrationImage(reference,context:context,maximumDimension:640) else { return nil }
        var best:CIImage?, error = Double.infinity
        if let shift = alignment(from:a,to:b),abs(shift.tx)<reference.extent.width*0.10,abs(shift.ty)<reference.extent.height*0.10 {
            let candidate = image.transformed(by:shift)
            best = candidate; error = registrationError(candidate,reference:reference,context:context,stableFraction:0.5)
        }
        if error>0.012,let candidate = perspectiveAlignment(image,probe:a,reference:b) {
            let value = registrationError(candidate,reference:reference,context:context,stableFraction:0.5)
            if value<error*0.9 { best = candidate; error = value }
        }
        if error>0.04,let rotated = rotationalAlignment(image,reference:reference,context:context) {
            let value = registrationError(rotated.image,reference:reference,context:context,stableFraction:0.5)
            if value<error*0.9 { best = rotated.image; error = value }
        }
        return error<0.06 ? best:nil
    }

    private static func perspectiveAlignment(_ image:CIImage,probe:RegistrationProbe,reference:RegistrationProbe)->CIImage? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage:probe.image)
        guard (try? VNImageRequestHandler(cgImage:reference.image).perform([request])) != nil,
              let matrix = request.results?.first?.warpTransform else { return nil }
        func point(_ x:CGFloat,_ y:CGFloat)->CGPoint? {
            let v = matrix * SIMD3<Float>(Float(x/probe.scaleX),Float(y/probe.scaleY),1)
            guard v.x.isFinite,v.y.isFinite,v.z.isFinite,abs(v.z)>0.0001 else { return nil }
            return CGPoint(x:CGFloat(v.x/v.z)*reference.scaleX,y:CGFloat(v.y/v.z)*reference.scaleY)
        }
        let w = image.extent.width,h = image.extent.height
        guard let bl = point(0,0),let br = point(w,0),let tl = point(0,h),let tr = point(w,h) else { return nil }
        for (a,b) in zip([bl,br,tl,tr],[CGPoint.zero,CGPoint(x:w,y:0),CGPoint(x:0,y:h),CGPoint(x:w,y:h)]) {
            guard abs(a.x-b.x)/w < 0.18,abs(a.y-b.y)/h < 0.18 else { return nil }
        }
        let bottom = hypot(br.x-bl.x,br.y-bl.y)/w, left = hypot(tl.x-bl.x,tl.y-bl.y)/h
        guard (0.85...1.15).contains(bottom),(0.85...1.15).contains(left),
              abs(atan2(br.y-bl.y,br.x-bl.x)) < .pi/30 else { return nil }
        let inside = CGRect(x:max(bl.x,tl.x),y:max(bl.y,br.y),
                            width:min(br.x,tr.x)-max(bl.x,tl.x),height:min(tl.y,tr.y)-max(bl.y,br.y)).intersection(CGRect(x:0,y:0,width:w,height:h))
        guard inside.width>0,inside.height>0,inside.width*inside.height>w*h*0.72 else { return nil }
        return image.applyingFilter("CIPerspectiveTransform",parameters:[
            "inputBottomLeft":CIVector(cgPoint:bl),"inputBottomRight":CIVector(cgPoint:br),
            "inputTopLeft":CIVector(cgPoint:tl),"inputTopRight":CIVector(cgPoint:tr)]).cropped(to:inside)
    }

    /// 单应匹配在低纹理中可能失败；以少量小角度+平移补偿兜底，仍用真实残差选优。
    private static func rotationalAlignment(_ image:CIImage,reference:CIImage,context:CIContext)->(image:CIImage,error:Double)? {
        guard let target = registrationImage(reference,context:context,maximumDimension:320) else { return nil }
        let w = reference.extent.width,h = reference.extent.height
        var best:(image:CIImage,error:Double)?
        for degrees in [-1.5,1.5,-3.0,3.0] {
            let rotation = CGAffineTransform(translationX:-w/2,y:-h/2)
                .concatenating(CGAffineTransform(rotationAngle:degrees * .pi/180))
                .concatenating(CGAffineTransform(translationX:w/2,y:h/2))
            let rotated = image.transformed(by:rotation).cropped(to:reference.extent)
            guard let probe = registrationImage(rotated,context:context,maximumDimension:320),
                  let shift = alignment(from:probe,to:target),abs(shift.tx)<w*0.1,abs(shift.ty)<h*0.1 else { continue }
            let transform = rotation.concatenating(shift)
            let bl = CGPoint.zero.applying(transform),br = CGPoint(x:w,y:0).applying(transform)
            let tl = CGPoint(x:0,y:h).applying(transform),tr = CGPoint(x:w,y:h).applying(transform)
            let bounds = CGRect(x:max(bl.x,tl.x),y:max(bl.y,br.y),width:min(br.x,tr.x)-max(bl.x,tl.x),height:min(tl.y,tr.y)-max(bl.y,br.y)).intersection(reference.extent)
            guard bounds.width>0,bounds.height>0,bounds.width*bounds.height>w*h*0.72 else { continue }
            let candidate = image.transformed(by:transform).cropped(to:bounds)
            let error = registrationError(candidate,reference:reference,context:context)
            if error < (best?.error ?? .infinity) { best = (candidate,error) }
            if error<0.008 { break }
        }
        return best
    }

    /// 分开处理运动保护与暗部降噪，避免用整体模糊掩盖噪声。此入口也用于确定性的图像测试。
    static func fuseAlignedFrames(_ images: [CIImage], referenceIndex: Int, context: CIContext,
                                  maximumDimension: CGFloat = 900, adaptiveTone: Bool = false) -> CIImage? {
        guard images.indices.contains(referenceIndex), images.count > 1 else { return nil }
        let extent = images[referenceIndex].extent
        guard let prepared = exposureMasks(for: images, referenceIndex: referenceIndex, extent: extent,
                                        context: context, maximumDimension: maximumDimension, noiseAwareMotion: adaptiveTone),
              prepared.masks.count == images.count - 1 else { return nil }
        let masks = prepared.masks
        let normalizedImages = prepared.images
        var composite = normalizedImages[0]
        for index in 1..<images.count {
            composite = normalizedImages[index].applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: composite, kCIInputMaskImageKey: masks[index - 1]
            ]).cropped(to: extent)
        }
        // 仅向暗部混入适度的边缘保持降噪。亮部/纹理不做全局强降噪与额外锐化。
        // 从真实源帧ISO判断残余噪声压力；低ISO/缺失元数据沿用原配方。
        // 不以合成张数等同于每个像素都获得相同降噪量，运动保护区仍可能偏重参考帧。
        let sensitivities = images.compactMap { image -> Double? in
            let exif = image.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let value = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
            return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }.sorted()
        let sourceISO = sensitivities.isEmpty ? 0 : sensitivities[sensitivities.count / 2]
        let noiseStress = min(1, max(0, (sourceISO - 800) / 2400))
        let shadowSlope = 2 - noiseStress * 0.8
        let shadowBias = 0.85 + noiseStress * 0.13
        let shadowSource = adaptiveTone ? composite:images[referenceIndex]
        let shadowMask = shadowSource.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -shadowSlope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -shadowSlope, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -shadowSlope, w: 0),
                "inputBiasVector": CIVector(x: shadowBias, y: shadowBias, z: shadowBias, w: 0)
            ]).applyingFilter("CIColorClamp").cropped(to: extent)
        // 自动提亮会同时放大残余噪声；按即将应用的影调增益调整暗部处理，避免继续锐化颗粒。
        // 不延长手持曝光，也不把运动区域强行平均进来。手动曝光夜景沿用原处理配方。
        let tone = adaptiveTone ? automaticTonePlan(composite, context: context) : (exposureEV: 0.0, shadowLift: 0.06)
        let baseNoiseLevel = adaptiveTone ? min(0.12, 0.055 + tone.exposureEV * 0.035 + max(0, tone.shadowLift - 0.06) * 0.2) : 0.035
        // 高ISO提高边缘保持滤波门限并扩大暗部覆盖，不增加全局高斯模糊或锐化颗粒。
        let noiseLevel = baseNoiseLevel + noiseStress * 0.08
        // 低 ISO 夜景不需要按高 ISO 的强度压彩色噪声；当前 1s/ISO800 样片
        // 在旧配方下被压到接近灰阶。高 ISO 仍保留强彩色降噪。
        let keepLowISColor = sourceISO > 0 && sourceISO < 1600
        let denoiseSharpness: Float = adaptiveTone && noiseStress > 0.2 ? 0 : (keepLowISColor ? 0.2 : 0.25)
        var reduced = composite.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": noiseLevel, "inputSharpness": denoiseSharpness])
        if adaptiveTone && !keepLowISColor {
            // 彩色斑块比单像素颗粒更粗。只借用低频色彩，亮度结构仍来自边缘保持降噪结果。
            let radius = min(3,max(1.2,max(extent.width,extent.height)/1400))
            let color = reduced.clampedToExtent().applyingFilter("CIMedianFilter")
                .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
            reduced = color.applyingFilter("CIColorBlendMode",parameters:[kCIInputBackgroundImageKey:reduced]).cropped(to:extent)
            // 极低信号中的通道偏差会在提亮后变成大块红紫斑，无法靠细粒度平均消除。
            // 按提亮前的平滑亮度降低该区域色度；保留亮度纹理，较亮信号仍保留颜色。
            let colorConfidence = composite.clampedToExtent()
                .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(2,max(extent.width,extent.height)/900)])
                .applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
                .applyingFilter("CIColorMatrix",parameters:[
                    "inputRVector":CIVector(x:31.25,y:0,z:0,w:0),
                    "inputGVector":CIVector(x:0,y:31.25,z:0,w:0),
                    "inputBVector":CIVector(x:0,y:0,z:31.25,w:0),
                    "inputBiasVector":CIVector(x:-0.09375,y:-0.09375,z:-0.09375,w:0)])
                .applyingFilter("CIColorClamp").cropped(to:extent)
            let neutral = reduced.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
            reduced = reduced.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:neutral,kCIInputMaskImageKey:colorConfidence]).cropped(to:extent)
            // 极暗区域用半尺度的边缘保持结果压低残余细颗粒；有效信号区保留原分辨率细节。
            let lowSignal = reduced.clampedToExtent().transformed(by:CGAffineTransform(scaleX:0.5,y:0.5))
                .applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":0.11,"inputSharpness":0])
                .transformed(by:CGAffineTransform(scaleX:2,y:2)).cropped(to:extent)
            reduced = reduced.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:lowSignal,kCIInputMaskImageKey:colorConfidence]).cropped(to:extent)
        }
        composite = reduced.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: composite, kCIInputMaskImageKey: shadowMask
        ])
        // A挡按暗部掩码补光，少量灯泡即使未进入95%分位，也不会被整体增益推白。
        // M挡和非自适应调用不改变原有曝光，只沿用轻量影调曲线。
        if tone.exposureEV > 0 {
            let raised = composite.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: tone.exposureEV])
            composite = raised.applyingFilter("CIBlendWithMask",parameters:[
                kCIInputBackgroundImageKey:composite,kCIInputMaskImageKey:shadowMask])
        }
        return composite.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.18, y: 0.18 + tone.shadowLift),
            "inputPoint2": CIVector(x: 0.5, y: adaptiveTone ? 0.5 + tone.shadowLift * 0.6 : 0.55), "inputPoint3": CIVector(x: 0.8, y: 0.81),
            "inputPoint4": CIVector(x: 1, y: 1)
        ]).cropped(to: extent).settingProperties(images[referenceIndex].properties)
    }

    /// 仅A挡自动夜景在真实融合后使用：小探针估计中位数与高光分位。
    /// 在与CIExposureAdjust一致的线性光域计算增益；长曝光已承担主要补光，
    /// 数字提亮最多 0.5EV，避免把暗部噪点整体放大。
    private static func automaticTonePlan(_ image: CIImage, context: CIContext) -> (exposureEV: Double, shadowLift: Double) {
        // 长曝光已经把主要亮度信息带回传感器；此时再强拉 EV 只会放大暗部噪点。
        // 无 EXIF 的合成测试/短曝光后备仍允许较大的数字提亮，避免深暗场景发黑。
        let exif = image.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let exposureTime = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
        let longExposure = exposureTime >= 1.5
        let extent = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 64 / extent.width, y: 64 / extent.height))
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        context.render(scaled, toBitmap: &bytes, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let values = stride(from: 0, to: bytes.count, by: 4).map {
            (0.2126 * Double(bytes[$0]) + 0.7152 * Double(bytes[$0 + 1]) + 0.0722 * Double(bytes[$0 + 2])) / 255
        }.sorted()
        let median = values[values.count / 2]
        let high = values[Int(Double(values.count - 1) * 0.95)]
        func linear(_ value:Double)->Double {
            value <= 0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)
        }
        let medianEV = log2(linear(0.28) / linear(max(median, 0.02)))
        let highlightEV = log2(linear(0.82) / linear(max(high, 0.05)))
        let exposureCap = longExposure ? 0.5 : 2.5
        let shadowCap = longExposure ? 0.16 : 0.18
        let targetMedian = 0.33
        let exposureEV = min(exposureCap, max(0, min(medianEV, highlightEV)))
        let shadowLift = min(shadowCap, max(0.06, 0.06 + (targetMedian - median) * 0.60))
        return (exposureEV, shadowLift)
    }

    /// 比较曝光归一后的低分辨率亮度/色彩，运动区域只保留参考曝光。
    /// 权重仍依据原曝光的有效亮度计算，以保留较亮曝光的暗部细节及较暗曝光的高光。
    private static func exposureMasks(for images: [CIImage], referenceIndex: Int, extent: CGRect, context: CIContext,
                                      maximumDimension: CGFloat, noiseAwareMotion: Bool = false) -> (images: [CIImage], masks: [CIImage])? {
        guard images.count >= 2, extent.width > 0, extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, maximumDimension / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bytesPerRow = width * 4
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func renderProbe(_ image: CIImage, smoothMotionNoise: Bool = false) -> ProbeBuffer? {
            guard let buffer = ProbeBuffer(count: bytesPerRow * height) else { return nil }
            var resized = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                                  y: CGFloat(height) / extent.height))
            if smoothMotionNoise {
                resized = resized.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]).cropped(to: bounds)
            }
            context.render(resized, toBitmap: buffer.bytes, rowBytes: bytesPerRow,
                           bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
            // toBitmap 没有可空返回值；未得到任何有效 alpha 时按原有路径安全回退。
            guard stride(from: 3, to: buffer.count, by: 4).contains(where: { buffer.bytes[$0] != 0 }) else { return nil }
            return buffer
        }
        let probes = images.compactMap { renderProbe($0) }
        guard probes.count == images.count else { return nil }
        let originalBytes = probes.map(\.bytes)
        let pixelCount = width * height
        @inline(__always) func luma(_ values: UnsafeMutablePointer<UInt8>, _ offset: Int) -> Double {
            (0.2126 * Double(values[offset]) + 0.7152 * Double(values[offset + 1]) + 0.0722 * Double(values[offset + 2])) / 255
        }
        let linearValues = (0...255).map { value -> Double in
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        @inline(__always) func linearLuma(_ values: UnsafeMutablePointer<UInt8>, _ offset: Int) -> Double {
            0.2126 * linearValues[Int(values[offset])] + 0.7152 * linearValues[Int(values[offset + 1])] + 0.0722 * linearValues[Int(values[offset + 2])]
        }
        let reference = originalBytes[referenceIndex]
        let gains = probes.indices.map { frame -> Double in
            guard frame != referenceIndex else { return 1 }
            let candidateBytes = originalBytes[frame]
            var histogram = [Int](repeating: 0, count: 257)
            var count = 0
            for pixel in stride(from: 0, to: pixelCount, by: 4) {
                let offset = pixel * 4
                let target = luma(reference, offset), candidate = luma(candidateBytes, offset)
                guard target > 0.08, target < 0.85, candidate > 0.04, candidate < 0.94 else { continue }
                let logGain = min(max(log2(max(linearLuma(reference, offset), 0.0001) / max(linearLuma(candidateBytes, offset), 0.0001)), -2), 2)
                histogram[Int(((logGain + 2) * 64).rounded())] += 1
                count += 1
            }
            guard count >= 16 else { return 1 }
            var accumulated = 0
            for bin in histogram.indices {
                accumulated += histogram[bin]
                if accumulated > count / 2 { return pow(2, Double(bin) / 64 - 2) }
            }
            return 1
        }
        // 数学配方、色彩空间、探针尺寸和取样规则保持不变，只消除单位增益的重复渲染。
        let normalizedImages = images.indices.map { frame in
            gains[frame] == 1 ? images[frame]
                : images[frame].applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(gains[frame])])
        }
        let normalizedProbes = images.indices.compactMap { frame in
            gains[frame] == 1 && !noiseAwareMotion ? probes[frame] : renderProbe(normalizedImages[frame], smoothMotionNoise: noiseAwareMotion)
        }
        guard normalizedProbes.count == images.count else { return nil }
        let normalizedBytes = normalizedProbes.map(\.bytes)
        let rawMasks = (1..<images.count).compactMap { _ in ProbeBuffer(count: bytesPerRow * height, fill: 255) }
        guard rawMasks.count == images.count - 1 else { return nil }
        let maskBytes = rawMasks.map(\.bytes)
        let weights = UnsafeMutableBufferPointer<Double>.allocate(capacity: images.count)
        weights.initialize(repeating: 0)
        defer { weights.deinitialize(); weights.deallocate() }
        // 原/归一化探针在裸指针使用期间必须保持存活。掩码也各自独占存储，
        // 避免嵌套 Swift Array 在百万级逐像素写入时反复进行写时复制/唯一性检查。
        return withExtendedLifetime((probes, normalizedProbes)) {
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let referenceLuma = luma(reference, offset)
                for frame in images.indices {
                    let luminance = luma(originalBytes[frame], offset)
                    let distance = (luminance - 0.5) / 0.25
                    var weight = exp(-0.5 * distance * distance) + 0.01
                    if frame != referenceIndex {
                        let candidate = normalizedBytes[frame]
                        var difference = 0.0
                        for channel in 0..<3 {
                            let value = Double(candidate[offset + channel]) / 255
                            // 配准后的细碎高ISO噪声不应被当成主体运动；原始探针仍用于曝光权重。
                            let motionReference = normalizedBytes[referenceIndex]
                            difference = max(difference, abs(value - Double(motionReference[offset + channel]) / 255))
                        }
                        let tolerance = 0.08 + referenceLuma * 0.20
                        let confidence = min(max((tolerance * 2 - difference) / tolerance, 0), 1)
                        weight *= confidence * confidence
                    }
                    weights[frame] = weight
                }
                var cumulative = weights[0]
                for frame in 1..<images.count {
                    let total = cumulative + weights[frame]
                    let amount = UInt8(min(max((weights[frame] / max(total, 0.000001) * 255).rounded(), 0), 255))
                    let destination = maskBytes[frame - 1]
                    destination[offset] = amount
                    destination[offset + 1] = amount
                    destination[offset + 2] = amount
                    cumulative = total
                }
            }
            let masks = rawMasks.map { buffer in
                // CIImage 必须拥有独立 Data；退出本作用域后不再依赖临时可写内存。
                let data = Data(bytes: buffer.bytes, count: buffer.count)
                return CIImage(bitmapData: data, bytesPerRow: bytesPerRow,
                               size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
                    .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                                       y: extent.height / CGFloat(height))).cropped(to: extent)
            }
            return (normalizedImages, masks)
        }
    }
}
