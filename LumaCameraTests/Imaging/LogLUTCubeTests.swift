import CoreImage
import XCTest
@testable import LumaCamera

final class LogLUTCubeTests: XCTestCase {
    func testBundledLUTsRetainTheirOriginal33Or65Grid() throws {
        let presets = LogLUTCubeRepository.presets()
        XCTAssertEqual(presets.count, 46)
        for preset in presets {
            let cube = try LogLUTCubeRepository.load(preset)
            XCTAssertTrue(cube.dimension == 33 || cube.dimension == 65)
            XCTAssertEqual(cube.rgbaData.count, cube.dimension * cube.dimension * cube.dimension * 16)
        }
    }

    func testOriginalChoiceIsAvailableAlongsideBundledLUTs() {
        let presets = LogLUTCubeRepository.presets()
        let pickerOptions = [LogLUTPreset.original] + presets
        XCTAssertEqual(LogLUTPreset.original.title, "原片")
        XCTAssertEqual(LogLUTPreset.original.id, LogLUTPreset.originalID)
        XCTAssertEqual(presets.count, 46)
        XCTAssertEqual(Array(pickerOptions.prefix(3).map(\.id)), [
            LogLUTPreset.originalID, "AppleLog_Rec709", "AppleLog2_Rec709"
        ])
    }

    func testDisplayNamesAreSeparatedForRec709AndBohemianLUTs() {
        let presets = LogLUTCubeRepository.presets()
        let appleLog = presets.first { $0.id == "AppleLog_Rec709" }
        let appleLog2 = presets.first { $0.id == "AppleLog2_Rec709" }
        let bohemianV1 = presets.first { $0.id == "波西米亚_V1" }
        let bohemianV2 = presets.first { $0.id == "波西米亚_V2" }

        XCTAssertEqual(appleLog?.equipment, "Log")
        XCTAssertEqual(appleLog?.title, "Rec709")
        XCTAssertEqual(appleLog?.displayName, "Log Rec709")
        XCTAssertEqual(appleLog2?.equipment, "Log2")
        XCTAssertEqual(appleLog2?.title, "Rec709")
        XCTAssertEqual(appleLog2?.displayName, "Log2 Rec709")
        XCTAssertEqual(bohemianV1?.equipment, "波西米亚")
        XCTAssertEqual(bohemianV1?.title, "V1")
        XCTAssertEqual(bohemianV2?.equipment, "波西米亚")
        XCTAssertEqual(bohemianV2?.title, "V2")
        XCTAssertEqual(Array(presets.prefix(2).map(\.id)), ["AppleLog_Rec709", "AppleLog2_Rec709"])
    }

    func testCubeCanBeAppliedToImage() throws {
        let dimension = 2
        var data = Data()
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let channels: [Float] = [Float(1 - red), Float(green), Float(blue), 1]
                    for value in channels {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                    }
                }
            }
        }
        let cube = try XCTUnwrap(LogLUTCube(dimension: dimension, rgbaData: data))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceColor = try XCTUnwrap(CIColor(red: 0.84, green: 0.12, blue: 0.08, alpha: 1, colorSpace: colorSpace))
        let source = CIImage(color: sourceColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let context = CIContext(options: [.cacheIntermediates: false])
        let original = try XCTUnwrap(context.createCGImage(source, from: source.extent, format: .RGBA8, colorSpace: colorSpace))
        let mapped = cube.apply(to: source)
        let result = try XCTUnwrap(context.createCGImage(mapped, from: mapped.extent, format: .RGBA8, colorSpace: colorSpace))
        let originalData = try XCTUnwrap(original.dataProvider?.data) as Data
        let resultData = try XCTUnwrap(result.dataProvider?.data) as Data
        let a = originalData.withUnsafeBytes { $0.bindMemory(to: UInt8.self)[0] }
        let b = resultData.withUnsafeBytes { $0.bindMemory(to: UInt8.self)[0] }
        XCTAssertGreaterThan(abs(Int(a) - Int(b)), 80)
    }

    func testVideoBadgeStoreRetainsLogAndFilterFlagsAcrossReads() {
        let suite = "VideoCaptureBadgeStoreTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VideoCaptureBadgeStore(defaults: defaults)
        store.save(VideoCaptureBadges(logLabel: "LOG2", hasFilter: true), assetID: "asset")
        XCTAssertEqual(store.badges(assetID: "asset"), VideoCaptureBadges(logLabel: "LOG2", hasFilter: true))
        store.save(VideoCaptureBadges(logLabel: nil, hasFilter: false), assetID: "asset")
        XCTAssertNil(store.badges(assetID: "asset"))
    }

    func testRecordingBadgesRetainFilterRecipeForVideoEditing() {
        let look = CaptureLook(style: .leicaM9, intensity: 0.83,
                               adjustments: { var value = FilterAdjustments(); value[.temperature] = 12; return value }())
        let standard = VideoCaptureBadges.forRecording(colorSpace: .p3, burnedLogLUT: false, look: look)
        XCTAssertNil(standard.logLabel)
        XCTAssertTrue(standard.hasFilter)
        XCTAssertEqual(standard.colorSpace, .p3)
        XCTAssertEqual(standard.filmStyleID, FilmStyle.leicaM9.rawValue)
        XCTAssertEqual(standard.filterIntensity, 0.83)
        XCTAssertEqual(standard.filterAdjustments?[.temperature], 12)

        let log = VideoCaptureBadges.forRecording(colorSpace: .appleLog2, burnedLogLUT: true,
                                                   look: look, logLUTID: "sample-lut")
        XCTAssertEqual(log.logLabel, "LOG2")
        XCTAssertTrue(log.hasFilter)
        XCTAssertEqual(log.colorSpace, .appleLog2)
        XCTAssertNil(log.filmStyleID)
        XCTAssertEqual(log.logLUTID, "sample-lut")

        let untouchedLog = VideoCaptureBadges.forRecording(colorSpace: .appleLog, burnedLogLUT: false,
                                                            look: look, logLUTID: "preview-only")
        XCTAssertEqual(untouchedLog.logLabel, "LOG")
        XCTAssertFalse(untouchedLog.hasFilter)
        XCTAssertNil(untouchedLog.logLUTID)
    }
}
