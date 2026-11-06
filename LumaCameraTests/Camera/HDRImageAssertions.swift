import XCTest
import ImageIO

enum HDRImageAssertions {
    static func hasGainMap(_ source: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }
    static func assertHDR(_ source: CGImageSource, _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let depth = props[kCGImagePropertyDepth] as? Int ?? -1
        XCTAssertTrue(hasGainMap(source) || depth == 10,
                      "\(label) 应为增益图 HEIF 或 10-bit HDR（当前 depth=\(depth)）", file: file, line: line)
    }
}
