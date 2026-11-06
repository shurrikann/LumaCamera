import CoreImage
import UIKit
import Accelerate

struct ImportedFilterDefinition {
    let style: FilmStyle
    let title: String
    let equipment: String?
    let buttonName: String
    let asset: String
    let dimension: Int
    let compact: Bool
}

/// Bounded, thread-safe cache; importing many filters must not retain every 64³ Float32 cube.
enum ImportedFilterCatalog {
    static let entries: [ImportedFilterDefinition] = [
        .init(style: .leicaM9, title: "徕卡 M9", equipment: "徕卡", buttonName: "M9", asset: "FilmLUT-M9", dimension: 64, compact: false),
        .init(style: .fujiNC, title: "富士 NC", equipment: "富士", buttonName: "NC", asset: "ImportedLUT-fujiNC", dimension: 64, compact: true),
        .init(style: .fujiCC, title: "富士 CC", equipment: "富士", buttonName: "CC", asset: "ImportedLUT-fujiCC", dimension: 64, compact: true),
        .init(style: .lut8e01931695, title: "ARRI V1", equipment: "ARRI", buttonName: "V1", asset: "ImportedLUT-lut8e01931695", dimension: 33, compact: false),
        .init(style: .lut2822fe566f, title: "ARRI V2", equipment: "ARRI", buttonName: "V2", asset: "ImportedLUT-lut2822fe566f", dimension: 33, compact: false),
        .init(style: .lut0f0bbcb69e, title: "冷影暖肤", equipment: nil, buttonName: "冷影暖肤", asset: "ImportedLUT-lut0f0bbcb69e", dimension: 64, compact: true),
        .init(style: .lut3d9aec28a2, title: "哈苏 HNCS", equipment: "哈苏", buttonName: "HNCS", asset: "ImportedLUT-lut3d9aec28a2", dimension: 64, compact: true),
        .init(style: .lut32a8226ccc, title: "哈苏 HNCS自然", equipment: "哈苏", buttonName: "HNCS自然", asset: "ImportedLUT-lut32a8226ccc", dimension: 64, compact: true),
        .init(style: .lut5f95b51579, title: "复古柔光CCD", equipment: nil, buttonName: "复古柔光CCD", asset: "ImportedLUT-lut5f95b51579", dimension: 64, compact: true),
        .init(style: .lut3675b050d8, title: "复古柔黑", equipment: nil, buttonName: "复古柔黑", asset: "ImportedLUT-lut3675b050d8", dimension: 64, compact: true),
        .init(style: .lutabf0a1a1fc, title: "富士 3513", equipment: "富士", buttonName: "3513", asset: "ImportedLUT-lutabf0a1a1fc", dimension: 64, compact: true),
        .init(style: .lut74f0c757a6, title: "富士 ACROS", equipment: "富士", buttonName: "ACROS", asset: "ImportedLUT-lut74f0c757a6", dimension: 64, compact: true),
        .init(style: .lut65f12b4421, title: "富士 ASTIA", equipment: "富士", buttonName: "ASTIA", asset: "ImportedLUT-lut65f12b4421", dimension: 64, compact: true),
        .init(style: .lutff68264412, title: "富士 ETERNA", equipment: "富士", buttonName: "ETERNA", asset: "ImportedLUT-lutff68264412", dimension: 64, compact: true),
        .init(style: .lut68decd78c9, title: "富士 PRO NEG", equipment: "富士", buttonName: "PRO NEG", asset: "ImportedLUT-lut68decd78c9", dimension: 64, compact: true),
        .init(style: .lut65079c544d, title: "富士 PROVIA", equipment: "富士", buttonName: "PROVIA", asset: "ImportedLUT-lut65079c544d", dimension: 64, compact: true),
        .init(style: .lut366e84500d, title: "富士 PROVIA100F", equipment: "富士", buttonName: "PROVIA100F", asset: "ImportedLUT-lut366e84500d", dimension: 64, compact: true),
        .init(style: .lut7e90ddc039, title: "富士 REALA", equipment: "富士", buttonName: "REALA", asset: "ImportedLUT-lut7e90ddc039", dimension: 64, compact: true),
        .init(style: .lut1775a81171, title: "富士 VELVIA", equipment: "富士", buttonName: "VELVIA", asset: "ImportedLUT-lut1775a81171", dimension: 64, compact: true),
        .init(style: .lut1e53d98a81, title: "明艳", equipment: nil, buttonName: "明艳", asset: "ImportedLUT-lut1e53d98a81", dimension: 64, compact: true),
        .init(style: .lut2141527536, title: "柔和亮调", equipment: nil, buttonName: "柔和亮调", asset: "ImportedLUT-lut2141527536", dimension: 64, compact: true),
        .init(style: .lut49ad230de7, title: "柯达 2383", equipment: "柯达", buttonName: "2383", asset: "ImportedLUT-lut49ad230de7", dimension: 64, compact: true),
        .init(style: .lut6e13efd4c3, title: "柯达 2393", equipment: "柯达", buttonName: "2393", asset: "ImportedLUT-lut6e13efd4c3", dimension: 64, compact: true),
        .init(style: .lute3e60113bd, title: "柯达 5207", equipment: "柯达", buttonName: "5207", asset: "ImportedLUT-lute3e60113bd", dimension: 64, compact: true),
        .init(style: .lut4680f1508c, title: "柯达 5213", equipment: "柯达", buttonName: "5213", asset: "ImportedLUT-lut4680f1508c", dimension: 64, compact: true),
        .init(style: .lut8eac246ff8, title: "柯达 5219", equipment: "柯达", buttonName: "5219", asset: "ImportedLUT-lut8eac246ff8", dimension: 64, compact: true),
        .init(style: .lut3831567476, title: "柯达 FUNSAVER", equipment: "柯达", buttonName: "FUNSAVER", asset: "ImportedLUT-lut3831567476", dimension: 64, compact: true),
        .init(style: .lut6be6214def, title: "淡雅", equipment: nil, buttonName: "淡雅", asset: "ImportedLUT-lut6be6214def", dimension: 64, compact: true),
        .init(style: .lutfcee0c278b, title: "深调黑白", equipment: nil, buttonName: "深调黑白", asset: "ImportedLUT-lutfcee0c278b", dimension: 64, compact: true),
        .init(style: .lut7e0ef8bdc8, title: "清雅", equipment: nil, buttonName: "清雅", asset: "ImportedLUT-lut7e0ef8bdc8", dimension: 64, compact: true),
        .init(style: .lut4d6b1a3c06, title: "炮塔400", equipment: nil, buttonName: "炮塔400", asset: "ImportedLUT-lut4d6b1a3c06", dimension: 64, compact: true),
        .init(style: .lut00ce8780b3, title: "理光 GR", equipment: "理光", buttonName: "GR", asset: "ImportedLUT-lut00ce8780b3", dimension: 64, compact: true),
        .init(style: .lut5de92d3636, title: "电影F6800", equipment: nil, buttonName: "电影F6800", asset: "ImportedLUT-lut5de92d3636", dimension: 64, compact: true),
        .init(style: .lut2873feea08, title: "电影质感", equipment: nil, buttonName: "电影质感", asset: "ImportedLUT-lut2873feea08", dimension: 33, compact: false),
        .init(style: .lut384a1211b6, title: "秋日暖调", equipment: nil, buttonName: "秋日暖调", asset: "ImportedLUT-lut384a1211b6", dimension: 64, compact: true),
        .init(style: .lut54ce806fbb, title: "粉黛", equipment: nil, buttonName: "粉黛", asset: "ImportedLUT-lut54ce806fbb", dimension: 64, compact: true),
        .init(style: .lut64f854a875, title: "红外摄影", equipment: nil, buttonName: "红外摄影", asset: "ImportedLUT-lut64f854a875", dimension: 64, compact: true),
        .init(style: .lut80c7455c11, title: "罪恶之城", equipment: nil, buttonName: "罪恶之城", asset: "ImportedLUT-lut80c7455c11", dimension: 64, compact: true),
        .init(style: .lutc18fc9c98c, title: "莫兰迪", equipment: nil, buttonName: "莫兰迪", asset: "ImportedLUT-lutc18fc9c98c", dimension: 64, compact: true),
        .init(style: .lute3d53fa666, title: "金色日落", equipment: nil, buttonName: "金色日落", asset: "ImportedLUT-lute3d53fa666", dimension: 64, compact: true),
        .init(style: .lut9e49d5257b, title: "阿斯彭冷青", equipment: nil, buttonName: "阿斯彭冷青", asset: "ImportedLUT-lut9e49d5257b", dimension: 64, compact: true),
        .init(style: .lut78143f1938, title: "阿泰勒仿色", equipment: nil, buttonName: "阿泰勒仿色", asset: "ImportedLUT-lut78143f1938", dimension: 33, compact: false),
        .init(style: .lut836114786e, title: "青嫩", equipment: nil, buttonName: "青嫩", asset: "ImportedLUT-lut836114786e", dimension: 64, compact: true),
        .init(style: .lutf83466e34f, title: "马卡龙", equipment: nil, buttonName: "马卡龙", asset: "ImportedLUT-lutf83466e34f", dimension: 64, compact: true),
        .init(style: .food, title: "美食", equipment: nil, buttonName: "美食", asset: "ImportedLUT-food", dimension: 17, compact: false),
    ]
    private static let definitions = Dictionary(uniqueKeysWithValues: entries.map { ($0.style, $0) })
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 4; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    static func definition(for style: FilmStyle) -> ImportedFilterDefinition? { definitions[style] }
    static func table(_ definition: ImportedFilterDefinition) -> FilmColorLUT? {
        if definition.style == .leicaM9 { return FilmColorLUT.m9 }
        if let cached = cache.object(forKey: definition.asset as NSString) {
            return FilmColorLUT(dimension: definition.dimension, bytes: cached as Data)
        }
        guard let source = NSDataAsset(name: definition.asset)?.data else { return nil }
        let count = definition.dimension * definition.dimension * definition.dimension * 4
        let data: Data
        if definition.compact {
            guard source.count == count else { return nil }
            var floats = [Float](repeating: 0, count: count)
            source.withUnsafeBytes { bytes in
                floats.withUnsafeMutableBufferPointer { output in
                    vDSP_vfltu8(bytes.bindMemory(to: UInt8.self).baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(count))
                    var divisor: Float = 255
                    vDSP_vsdiv(output.baseAddress!, 1, &divisor, output.baseAddress!, 1, vDSP_Length(count))
                }
            }
            data = floats.withUnsafeBytes { Data($0) }
        } else {
            guard source.count == count * MemoryLayout<Float>.size else { return nil }
            data = source
        }
        cache.setObject(data as NSData, forKey: definition.asset as NSString, cost: data.count)
        return FilmColorLUT(dimension: definition.dimension, bytes: data)
    }
    static func apply(_ definition: ImportedFilterDefinition, to image: CIImage) -> CIImage {
        table(definition)?.apply(to: image) ?? image
    }
}
