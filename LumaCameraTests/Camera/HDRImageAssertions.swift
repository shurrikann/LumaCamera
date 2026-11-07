import XCTest
import ImageIO

enum HDRImageAssertions {
    static func hasGainMap(_ source: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }
    /// 原生 iPhone HEIF 的 Apple HDRGainMap 与 ISO 21496-1 使用同一份数据、
    /// DataDescription 和 HDRToneMap 元数据；不能要求独立的 HDRGainMap XMP。
    static func assertNativeISOGainMap(_ source: CGImageSource,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
            kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any] else {
            XCTFail("缺少ISO增益图", file: file, line: line); return
        }
        func metadata(_ info: [String: Any]) -> CGImageMetadata? {
            guard let object = info[kCGImageAuxiliaryDataInfoMetadata as String],
                  CFGetTypeID(object as CFTypeRef) == CGImageMetadataGetTypeID() else { return nil }
            return (object as! CGImageMetadata)
        }
        func value(_ metadata: CGImageMetadata?, _ path: String) -> String? {
            guard let metadata else { return nil }
            return CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
        }
        let keys = ["HDRToneMap:Version", "HDRToneMap:AlternateHeadroom",
                    "HDRToneMap:ChannelMetadata[1]/HDRToneMap:GainMapMin",
                    "HDRToneMap:ChannelMetadata[1]/HDRToneMap:GainMapMax",
                    "HDRToneMap:ChannelMetadata[1]/HDRToneMap:Gamma"]
        XCTAssertNotNil(value(metadata(iso), "HDRToneMap:AlternateHeadroom"), "ISO项应有HDRToneMap元数据", file: file, line: line)
        guard let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
            kCGImageAuxiliaryDataTypeHDRGainMap) as? [String: Any] else {
            XCTFail("缺少Apple HDRGainMap", file: file, line: line); return
        }
        XCTAssertEqual(iso[kCGImageAuxiliaryDataInfoData as String] as? Data,
                       apple[kCGImageAuxiliaryDataInfoData as String] as? Data,
                       "Apple/ISO增益图像素必须同源", file: file, line: line)
        XCTAssertEqual(iso[kCGImageAuxiliaryDataInfoDataDescription as String] as? NSDictionary,
                       apple[kCGImageAuxiliaryDataInfoDataDescription as String] as? NSDictionary,
                       "Apple/ISO增益图描述必须一致", file: file, line: line)
        for key in keys {
            XCTAssertEqual(value(metadata(iso), key), value(metadata(apple), key),
                           "Apple/ISO \(key) 必须一致", file: file, line: line)
        }
    }
    static func assertHDR(_ source: CGImageSource, _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let depth = props[kCGImagePropertyDepth] as? Int ?? -1
        XCTAssertTrue(hasGainMap(source) || depth == 10,
                      "\(label) 应为增益图 HEIF 或 10-bit HDR（当前 depth=\(depth)）", file: file, line: line)
    }
}
