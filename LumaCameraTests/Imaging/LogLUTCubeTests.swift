import CoreImage
import XCTest
@testable import LumaCamera

final class LogLUTCubeTests: XCTestCase {
    func testBundledLUTsRetainTheirOriginal33Or65Grid() throws {
        let presets = LogLUTCubeRepository.presets()
        XCTAssertEqual(presets.count, 110)
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
        XCTAssertEqual(presets.count, 110)
        XCTAssertEqual(pickerOptions.first?.id, LogLUTPreset.originalID)
        XCTAssertTrue(pickerOptions.contains { $0.id == "AppleLog_Rec709" })
        XCTAssertTrue(pickerOptions.contains { $0.id == "AppleLog2_Rec709" })
        XCTAssertTrue(pickerOptions.contains { $0.id == "appleLog2_arri" })
    }

    func testDisplayNamesAreSeparatedForRec709() {
        let presets = LogLUTCubeRepository.presets()
        let appleLog = presets.first { $0.id == "AppleLog_Rec709" }
        let appleLog2 = presets.first { $0.id == "AppleLog2_Rec709" }
        XCTAssertEqual(appleLog?.equipment, "Log")
        XCTAssertEqual(appleLog?.title, "Rec709")
        XCTAssertEqual(appleLog?.displayName, "Log Rec709")
        XCTAssertEqual(appleLog2?.equipment, "Log2")
        XCTAssertEqual(appleLog2?.title, "Rec709")
        XCTAssertEqual(appleLog2?.displayName, "Log2 Rec709")
        XCTAssertTrue(presets.contains { $0.id == "AppleLog_Rec709" })
        XCTAssertTrue(presets.contains { $0.id == "AppleLog2_Rec709" })
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

    func testAppleLog2ToLog1KernelMapsNeutralGrayBackToSameCodeValue() throws {
        let value = 0.48827245852686763 // 18% scene gray in Apple Log
        let input = CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = AppleLogLUTInput.log2ToLog1(input)
        let context = CIContext()
        var pixels = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixels, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let expected = Int((value * 255).rounded())
        XCTAssertEqual(Int(pixels[0]), expected, accuracy: 2)
        XCTAssertEqual(Int(pixels[1]), expected, accuracy: 2)
        XCTAssertEqual(Int(pixels[2]), expected, accuracy: 2)
    }

    func testPrecomposedLog2CubeMatchesDirectCubeOnNeutralGray() throws {
        let preset = try XCTUnwrap(LogLUTCubeRepository.presets().first { $0.id == "AppleLog_Rec709" })
        let cube = try LogLUTCubeRepository.load(preset)
        let composed = try XCTUnwrap(cube.convertingAppleLog2ToAppleLog())
        XCTAssertEqual(composed.dimension, min(cube.dimension, 33))
        let context = CIContext()
        func pixel(_ cube: LogLUTCube) -> [UInt8] {
            let gray: Float = 0.48827245852686763
            let image = CIImage(color: CIColor(red: CGFloat(gray), green: CGFloat(gray), blue: CGFloat(gray)))
                .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            let output = cube.apply(to: image)
            var pixels = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixels, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixels
        }
        let direct = pixel(cube), precomposed = pixel(composed)
        print("LOG-PRECOMPOSE direct=\(direct) composed=\(precomposed)")
        for i in 0..<3 { XCTAssertEqual(Int(precomposed[i]), Int(direct[i]), accuracy: 3) }
    }
}
