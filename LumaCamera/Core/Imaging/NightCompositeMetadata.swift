import CoreImage
import ImageIO

/// 只记录已经成功对齐融合的结果，不把请求张数或单帧回退冒充多帧。
enum NightCompositeMetadata {
    static func applying(to image: CIImage, sources: [CIImage], usedIndices: [Int], referenceIndex: Int) -> CIImage {
        guard usedIndices.count >= 2, Set(usedIndices).count == usedIndices.count,
              usedIndices.allSatisfy({ sources.indices.contains($0) }) else { return image }
        // 合成滤镜会丢掉源图属性；以参考帧的EXIF/TIFF为底，再写composite统计。
        var properties = sources.indices.contains(referenceIndex) ? sources[referenceIndex].properties : [:]
        for (key, value) in image.properties { properties[key] = value }
        properties[kCGImagePropertyOrientation as String] = 1
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        exif[kCGImagePropertyExifCompositeImage as String] = 2 // general composite; no assertion of identical optical conditions
        exif[kCGImagePropertyExifSourceImageNumberOfCompositeImage as String] = [sources.count,usedIndices.count]
        exif.removeValue(forKey:kCGImagePropertyExifSourceExposureTimesOfCompositeImage as String)
        let times = sources.compactMap { source -> Double? in
            let values = source.properties[kCGImagePropertyExifDictionary as String] as? [String:Any]
            guard let time = (values?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
                  time.isFinite, time > 0 else { return nil }
            return time
        }
        if times.count == sources.count {
            let used = usedIndices.map { times[$0] }
            // ImageIO 数值数组：七项曝光统计、序列数、序列张数、各源曝光秒数。
            // 首项0表示未知总历时；不能用快门秒数之和冒充包含批次间隔的真实历时。
            let statistics = [0.0,times.reduce(0,+),used.reduce(0,+),times.max()!,used.max()!,times.min()!,used.min()!,1.0,Double(times.count)]
            exif[kCGImagePropertyExifSourceExposureTimesOfCompositeImage as String] = statistics + times
        }
        properties[kCGImagePropertyExifDictionary as String] = exif
        return image.settingProperties(properties)
    }
}
