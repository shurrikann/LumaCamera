import CoreImage
import AVFoundation
import UIKit
import ImageIO

enum PhotoEncodingError: LocalizedError {
    case encoding, missingRAW
    var errorDescription: String? { self == .missingRAW ? "当前拍摄未提供 RAW 数据。" : "无法编码所选照片格式。" }
}
enum PhotoEncoder {
    static func encode(source: CIImage, raw: Data?, look: CaptureLook, options: PhotoOptions, context: CIContext, location: PhotoLocation? = nil,
                       portraitMatte: AVPortraitEffectsMatte? = nil, portraitMask: CIImage? = nil, portraitHeadMask: CIImage? = nil) throws -> CapturedPhoto {
        defer { context.clearCaches() }
        guard source.extent.width.isFinite, source.extent.height.isFinite,
              source.extent.width > 0, source.extent.height > 0 else { throw PhotoEncodingError.encoding }
        let look = look.forOutput(options.format)
        if options.adaptiveHighDynamic && (options.format != .heifPro || raw == nil) { throw PhotoEncodingError.missingRAW }
        // 高动态在影调/滤镜之前完成；RAW白平衡与曝光已由解码器处理，不能重复应用。
        var renderLook = look
        if options.adaptiveHighDynamic { renderLook.adjustments = AdaptiveRAWDeveloper.withoutRAWControls(look.adjustments) }
        let developed = options.adaptiveHighDynamic ? AdaptiveDynamicRenderer.apply(source,hdr:options.hdr,context:context) : source
        let maxPixels = Double(options.resolution.rawValue) * 1_000_000
        let pixels = source.extent.width * source.extent.height
        let scale = min(1, sqrt(maxPixels / pixels))
        let portraitSource: CIImage
        let captureMask = portraitMask ?? portraitMatte.map { CIImage(cvPixelBuffer: $0.mattingImage) }
        if options.portraitMode, options.portraitBlurStrength > 0, let captureMask {
            let protectedMask = PortraitPhotoRenderer.faceProtectedMask(captureMask, image: developed, headMask: portraitHeadMask)
            portraitSource = PortraitPhotoRenderer.apply(developed, foregroundMask: protectedMask,
                                                         radius: PortraitPhotoRenderer.blurRadius(for: options.portraitBlurStrength))
        } else {
            portraitSource = options.portraitMode
                ? PortraitPhotoRenderer.apply(developed, matte: portraitMatte,
                                              radius: PortraitPhotoRenderer.blurRadius(for: options.portraitBlurStrength))
                : developed
        }
        // HDR 成片必须让影调处理保留超出 SDR 的高光范围。
        let hdrDestination = options.hdr && (options.format == .heif || options.format == .heifPro)
        let hdrLayers = !options.adaptiveHighDynamic && hdrDestination ? Imaging.filteredHDR(portraitSource, look: renderLook) : nil
        let styled = options.adaptiveHighDynamic ? AdaptiveDynamicRenderer.filtered(portraitSource,look:renderLook,hdr:options.hdr) : (hdrLayers?.hdr ?? Imaging.filtered(portraitSource,look:renderLook,hdr:hdrDestination))
        let processed = styled.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let processedSDR = hdrLayers?.sdr.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let previewScale = min(1, 2400 / max(processed.extent.width, processed.extent.height))
        let previewSource = processed.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        guard let preview = Imaging.renderProcessed(previewSource, look: look, context: context, hdr: options.hdr && (options.format == .heifPro || options.format == .heif)) else { throw PhotoEncodingError.encoding }
        let prefix = "Luma-" + UUID().uuidString
        if options.format == .raw {
            guard let raw else { throw PhotoEncodingError.missingRAW }
            return CapturedPhoto(preview: preview, resources: [PhotoResource(data: raw, filename: prefix + ".dng")], location: location)
        }
        var image = look.ratio.crop(processed, landscape: look.landscape)
        var sdrForEncoding = processedSDR.map { look.ratio.crop($0, landscape: look.landscape) }
        if look.border {
            sdrForEncoding = nil
            guard let fullPreview = Imaging.renderProcessed(processed, look: look, context: context),
                  let bordered = CIImage(image: fullPreview) else { throw PhotoEncodingError.encoding }
            image = bordered
        }
        // 解码及处理后方向已体现在像素中，清除继承的 EXIF/TIFF 旋转，
        // 避免系统相册再次旋转，导致成片与相册按钮的 UIImage 预览方向不同。
        image = PhotoMetadata.applying(to: CaptureOrientation.normalizedPhotoMetadata(image),
                                       location: location, copyright: options.copyright)
        if options.adaptiveHighDynamic {
            image = try RAWDevelopmentRecipe.applying(RAWDevelopmentRecipe.initial(source:source,look:look,hdr:options.hdr,maximumPixels:maxPixels),to:image)
        }
        if let aperture = look.virtualAperture {
            var properties = source.properties.merging(image.properties) { _, processed in processed }
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let old = exif[kCGImagePropertyExifUserComment as String] as? String ?? ""
            exif[kCGImagePropertyExifUserComment as String] = old + (old.isEmpty ? "" : "\n") + String(format: "LumaCamera.VirtualAperture=%.4f", aperture)
            properties[kCGImagePropertyExifDictionary as String] = exif
            image = CaptureOrientation.normalizedPhotoMetadata(image.settingProperties(properties))
        }
        let fileExtension: String
        switch options.format {
        case .heif, .heifPro: fileExtension = "heic"
        case .tiff: fileExtension = "tiff"
        case .jpeg, .rawJPEG: fileExtension = "jpg"
        case .raw: throw PhotoEncodingError.missingRAW
        }
        // CIContext 的表示 API 不写 image.properties，导致 App 照片没有 EXIF。
        // 统一走 ImageIO destination，既保留元数据，也继续支持 HDR 10-bit。
        let data = try Self.encodeImageData(image, fileExtension: fileExtension,
                                            hdr: options.hdr && !look.border,
                                            sdrBase: sdrForEncoding, context: context)
        guard let data else { throw PhotoEncodingError.encoding }
        var resources = [PhotoResource(data: data, filename: prefix + "." + fileExtension)]
        if options.format == .rawJPEG || options.adaptiveHighDynamic {
            guard let raw else { throw PhotoEncodingError.missingRAW }
            resources.append(PhotoResource(data: raw, filename: prefix + ".dng", alternate: true))
        }
        var result = CapturedPhoto(preview: preview, resources: resources, location: location)
        if options.saveUnfilteredOriginal, options.format == .jpeg || options.format == .heif,
           (look.style != .original && look.intensity > 0) || !look.adjustments.isNeutral || look.virtualAperture != nil {
            var originalOptions = options; originalOptions.saveUnfilteredOriginal = false; originalOptions.live = false
            var originalLook = look; originalLook.style = .original; originalLook.intensity = 0; originalLook.adjustments = FilterAdjustments(); originalLook.tone = .natural; originalLook.border = false; originalLook.virtualAperture = nil
            let original = try encode(source: source, raw: nil, look: originalLook, options: originalOptions, context: context,
                                      location: location, portraitMatte: portraitMatte, portraitMask: portraitMask, portraitHeadMask: portraitHeadMask)
            result.unfilteredOriginal = original.resources.first
        }

        return result
    }

    /// 系统照片仍依赖 Apple HDRGainMap 才稳定显示 HDR；与 ISO 增益图同数据双写。
    private static func addAppleHDRGainMap(to data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any]
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, gain as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, gain as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func encodeImageData(_ image: CIImage, fileExtension: String, hdr: Bool,
                                        sdrBase: CIImage? = nil, context: CIContext) throws -> Data? {
        if hdr, fileExtension == "heic", #available(iOS 18.0, *) {
            // 普通 HEIF 增益图的 AlternateHeadroom 实际写为 2.0；
            // 把编码 headroom 和 SDR 肩部对齐到同一个 2.0，避免文件按4.0解释。
            let headroom = HDRToneMapping.headroom
            let baseImage = if #available(iOS 26.0, *) {
                image.settingContentHeadroom(headroom)
            } else { image }
            // 只提升HDR主图；SDR基底保持原亮度，增益比才会真正增大。
            let hdrImage = baseImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.7])
            let sdr: CIImage
            if let sdrBase {
                sdr = sdrBase
            } else if let shoulder = MetalImageKernels.color("hdrSoftShoulder"),
               let mapped = shoulder.apply(extent: image.extent, arguments: [baseImage, HDRToneMapping.knee, headroom]) {
                sdr = mapped.cropped(to: image.extent)
            } else {
                sdr = baseImage.applyingFilter("CIToneMapHeadroom", parameters: [
                    "inputSourceHeadroom": headroom,
                    "inputTargetHeadroom": 1.0
                ])
            }
            if let data = context.heifRepresentation(of: sdr, format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                     options: [.hdrImage: hdrImage]) {
                return try? addAppleHDRGainMap(to: data)
            }
        }
        let colorSpace = CGColorSpace(name: hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB)!
        let pixelFormat: CIFormat = hdr ? .RGBA16 : .RGBA8
        guard let cgImage = context.createCGImage(image, from: image.extent.integral,
                                                  format: pixelFormat, colorSpace: colorSpace) else {
            throw PhotoEncodingError.encoding
        }
        let type: CFString = fileExtension == "heic" ? "public.heic" as CFString
            : fileExtension == "tiff" ? "public.tiff" as CFString : "public.jpeg" as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw PhotoEncodingError.encoding
        }
        var properties = image.properties
        if fileExtension == "jpg" {
            properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEncodingError.encoding }
        return output as Data
    }
}
