import AVFoundation
import XCTest
@testable import LumaCamera

final class StarCaptureCapabilityTests: XCTestCase {
    func testBackCameraSupportsOneSecondOneFPSFrames() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Camera capability requires a device")
        #else
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .back).devices
        let supported = devices.contains { device in
            device.formats.contains { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width >= 1920 else { return false }
                let maxExposure = CMTimeGetSeconds(format.maxExposureDuration)
                let ranges = format.videoSupportedFrameRateRanges
                let supportsOneFPS = ranges.contains { $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 0.999 }
                return maxExposure >= 0.999 && supportsOneFPS
            }
        }
        XCTAssertTrue(supported, "Back camera must expose 1 fps and 1 s exposure for star capture")
        #endif
    }
}
