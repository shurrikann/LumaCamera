import CoreImage
import ImageIO

/// Video buffers use a fixed, unmirrored connection. Apply portrait and selfie mirroring together.
enum CaptureOrientation {
    /// Save one of the four physical holding directions; preserve the preview's independent layout.
    static func cardinalAngle(_ angle: CGFloat) -> CGFloat {
        let normalized = ((angle / 90).rounded() * 90).truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }
    static func rearLandscape(angle: CGFloat) -> Bool {
        Int(cardinalAngle(angle) / 90) % 2 == 0
    }

    /// 动态横竖画幅以传感器为参照；成片按重力方向侧转后，裁切轴也必须互换。
    /// 否则虽然像素朝上，却会把全幅横图再次裁成竖图，损失视野与像素。
    static func frontPhotoLandscape(sensorLandscape: Bool, captureAngle: CGFloat) -> Bool {
        guard captureAngle.isFinite else { return sensorLandscape }
        let quarterTurns = Int((captureAngle.truncatingRemainder(dividingBy: 360) / 90).rounded())
        return abs(quarterTurns) % 2 == 1 ? !sensorLandscape : sensorLandscape
    }
    static func portraitFrame(_ image: CIImage, mirrored: Bool = false) -> CIImage {
        let portrait = image.extent.width > image.extent.height ? image.oriented(.right) : image
        return mirrored ? portrait.oriented(.upMirrored) : portrait
    }

    /// 解码器已经应用快门时的 EXIF 方向；这里仅归一化元数据，不按宽高二次旋转。
    static func nativeFrontPhotoFrame(_ image: CIImage) -> CIImage {
        normalizedPhotoMetadata(image)
    }

    static func nativeFrontPreviewFrame(_ image: CIImage) -> CIImage {
        image
    }

    /// 官方相机内参以输出像素为单位。前置动态画幅可能产生非方形像素缩放，
    /// fx/fy 明显偏离 1 时，压回被拉伸的轴；近似方形像素保留原图，避免放大校准噪声。
    static func correctingIntrinsicScale(_ image: CIImage, focalX: Float, focalY: Float) -> CIImage {
        guard focalX.isFinite, focalY.isFinite, focalX > 0, focalY > 0 else { return image }
        let ratio = CGFloat(focalX / focalY)
        guard ratio > 0.25, ratio < 4, abs(log(ratio)) > 0.02 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: min(1, 1 / ratio), y: min(1, ratio)))
    }

    /// Pixels have already been oriented by the decoder. Do not ask Photos to
    /// rotate or mirror those same pixels a second time using inherited EXIF.
    static func normalizedPhotoMetadata(_ image: CIImage) -> CIImage {
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return image.settingProperties(properties)
    }

}
