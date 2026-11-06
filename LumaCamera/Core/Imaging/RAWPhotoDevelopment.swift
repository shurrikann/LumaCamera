import CoreImage
import UIKit
import ImageIO

/// 每个编辑会话持有底片；预览复用缩放后的RAW解码器，最终保存另建全尺寸解码器。
/// 两者均串行保护，防止连续拖动与保存同时修改CIRAWFilter。
final class RAWPhotoDevelopment {
    let raw: Data
    let initial: PhotoAdjustments
    let metadata: [String:Any]
    private let lock = NSLock()
    private var previewFilter: CIRAWFilter?
    private var asShotTemperature: Float = 5500
    private var asShotTint: Float = 0
    private var asShotLocalTone: Float = 1
    private let context = CIContext(options:[.cacheIntermediates:false])
    init(raw:Data,initial:PhotoAdjustments,metadata:[String:Any]) {
        self.raw = raw; self.initial = initial; self.metadata = metadata
    }
    func source(_ adjustments:PhotoAdjustments,preview:Bool) throws -> CIImage {
        lock.lock(); defer { lock.unlock() }
        guard let recipe = adjustments.rawDevelopment, recipe.version == 1 else { throw PhotoEncodingError.missingRAW }
        let filter:CIRAWFilter
        if preview {
            if previewFilter == nil {
                previewFilter = CIRAWFilter(imageData:raw,identifierHint:nil)
                asShotTemperature = previewFilter?.neutralTemperature ?? 5500; asShotTint = previewFilter?.neutralTint ?? 0
                asShotLocalTone = previewFilter?.localToneMapAmount ?? 1
            }
            guard let cached = previewFilter else { throw PhotoEncodingError.missingRAW }
            filter = cached; filter.neutralTemperature = asShotTemperature; filter.neutralTint = asShotTint
            if filter.isLocalToneMapSupported { filter.localToneMapAmount = asShotLocalTone }
            filter.scaleFactor = Float(min(1,1200 / max(filter.nativeSize.width,filter.nativeSize.height)))
        } else {
            guard let full = CIRAWFilter(imageData:raw,identifierHint:nil) else { throw PhotoEncodingError.missingRAW }
            filter = full
        }
        AdaptiveRAWDeveloper.configure(filter,adaptive:recipe.adaptive,hdr:recipe.hdr,adjustments:adjustments.filterAdjustments)
        guard let image = filter.outputImage else { throw PhotoEncodingError.missingRAW }
        return recipe.adaptive ? AdaptiveDynamicRenderer.apply(image,hdr:recipe.hdr,context:context) : image
    }
    func preview(_ adjustments:PhotoAdjustments) throws -> UIImage {
        let image = adjustments.apply(to:try source(adjustments,preview:true),rawControlsApplied:true)
        let hdr = adjustments.rawDevelopment?.hdr == true
        guard let cg = Imaging.ownedCGImage(image,from:image.extent,context:context,format:hdr ? .RGBAh : .RGBA8,
            colorSpace:CGColorSpace(name:hdr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)!) else { throw PhotoEncodingError.encoding }
        return UIImage(cgImage:cg)
    }
    func render(_ adjustments:PhotoAdjustments) throws -> PhotoEditResult {
        let developed = try source(adjustments,preview:false)
        let maximum = max(1,adjustments.rawDevelopment?.maximumPixels ?? developed.extent.width*developed.extent.height)
        let scale = min(1,sqrt(maximum/(developed.extent.width*developed.extent.height)))
        let adjusted = adjustments.apply(to:developed.transformed(by:CGAffineTransform(scaleX:scale,y:scale)),rawControlsApplied:true)
        // HEIF输出采用整像素尺寸，避免自由裁切产生的小数边界与EXIF尺寸不一致。
        let image = adjusted.cropped(to:CGRect(x:0,y:0,width:max(2,floor(adjusted.extent.width/2)*2),height:max(2,floor(adjusted.extent.height/2)*2)))
        var properties = image.properties.merging(metadata) { _,original in original }
        // 拍摄事实保留，但裁切/旋转后的尺寸和输出色彩空间必须描述新文件。
        for key in [kCGImagePropertyPixelWidth,kCGImagePropertyPixelHeight,kCGImagePropertyDepth,kCGImagePropertyColorModel,kCGImagePropertyProfileName] {
            properties.removeValue(forKey:key as String)
        }
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        for key in [kCGImagePropertyExifMakerNote,kCGImagePropertyExifSubjectArea,kCGImagePropertyExifSubjectLocation] { exif.removeValue(forKey:key as String) }
        exif[kCGImagePropertyExifPixelXDimension as String] = Int(image.extent.width.rounded())
        exif[kCGImagePropertyExifPixelYDimension as String] = Int(image.extent.height.rounded())
        exif[kCGImagePropertyExifColorSpace as String] = adjustments.rawDevelopment?.hdr == true ? 65535 : 1
        properties[kCGImagePropertyExifDictionary as String] = exif
        properties[kCGImagePropertyOrientation as String] = 1
        let described = try RAWDevelopmentRecipe.applying(adjustments,to:CaptureOrientation.normalizedPhotoMetadata(image.settingProperties(properties)))
        let hdr = adjustments.rawDevelopment?.hdr == true
        let space = CGColorSpace(name:hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB)!
        let data = try hdr ? context.heif10Representation(of:described,colorSpace:space,options:[:])
            : context.heifRepresentation(of:described,format:.RGBA8,colorSpace:space,options:[:])
        guard let data else { throw PhotoEncodingError.encoding }
        return PhotoEditResult(preview:try preview(adjustments),resource:PhotoResource(data:data,filename:"Luma-Developed-"+UUID().uuidString+".heic"),filterApplied:adjustments.usesFilter)
    }
}
