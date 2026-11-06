import CoreImage
import XCTest
@testable import LumaCamera

final class OpenGateCapabilityTests: XCTestCase {
    func testOnlySquareOrFourByThreeNativeVideoFormatsQualify() {
        XCTAssertTrue(OpenGateCapability.supportsNativeVideoDimensions(width: 4032, height: 3024))
        XCTAssertTrue(OpenGateCapability.supportsNativeVideoDimensions(width: 3840, height: 3840))
        XCTAssertFalse(OpenGateCapability.supportsNativeVideoDimensions(width: 3840, height: 2160))
        XCTAssertFalse(OpenGateCapability.supportsNativeVideoDimensions(width: 0, height: 0))
    }

    func testOutputDimensionsPreserveNativeGateAspectAndUseEvenPixels() throws {
        let fourByThree = try XCTUnwrap(OpenGateCapability.outputDimensions(longEdge: 3840,
                                                                            nativeWidth: 4032,
                                                                            nativeHeight: 3024))
        XCTAssertEqual(fourByThree.width, 3840)
        XCTAssertEqual(fourByThree.height, 2880)
        XCTAssertEqual(fourByThree.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(fourByThree.height.truncatingRemainder(dividingBy: 2), 0)

        let square = try XCTUnwrap(OpenGateCapability.outputDimensions(longEdge: 1920,
                                                                        nativeWidth: 3840,
                                                                        nativeHeight: 3840))
        XCTAssertEqual(square, CGSize(width: 1920, height: 1920))
    }

    func testOpenGatePhotoCropLeavesTheWholeNativeFrame() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertEqual(FrameRatio.openGate.crop(source).extent, source.extent)
    }

    func testSupportedSpecsSummaryGroupsFrameRateRangeByColorSpaceAndResolution() {
        let specs: [VideoCaptureSettings] = [
            .init(resolution: .hd720, frameRate: .fps24, colorSpace: .sdr),
            .init(resolution: .hd720, frameRate: .fps30, colorSpace: .sdr),
            .init(resolution: .hd720, frameRate: .fps60, colorSpace: .sdr),
            .init(resolution: .hd1080, frameRate: .fps24, colorSpace: .sdr),
            .init(resolution: .hd1080, frameRate: .fps60, colorSpace: .sdr),
            .init(resolution: .uhd4K, frameRate: .fps24, colorSpace: .sdr),
            .init(resolution: .uhd4K, frameRate: .fps30, colorSpace: .sdr),
            .init(resolution: .hd720, frameRate: .fps30, colorSpace: .p3)
        ]
        XCTAssertEqual(
            OpenGateCapability.supportedSpecsSummary(from: specs),
            "SDR：720p：24–60 / 1080p：24–60 / 4K：24–30\nP3：720p：30"
        )
        XCTAssertEqual(OpenGateCapability.supportedSpecsSummary(from: []), "暂无可用规格")
    }
}
