import AVFoundation
import XCTest
@testable import LumaCamera

final class AstroManualSettingsTests: XCTestCase {
    func testAutoISOPreservesMeteredExposureAndAppliesEVOnce() {
        var settings = AstroManualSettings()
        XCTAssertTrue(settings.isoAutomatic)
        let limits = 1.0...12800.0
        XCTAssertEqual(settings.resolvedISO(meteredISO: 400, meteredSeconds: 0.5, targetSeconds: 1, range: limits), 200)
        XCTAssertEqual(settings.resolvedISO(meteredISO: 1600, meteredSeconds: 0.5, targetSeconds: 1, range: limits), 800)
        settings.exposureBias = 1
        XCTAssertEqual(settings.resolvedISO(meteredISO: 1600, meteredSeconds: 0.5, targetSeconds: 1, range: limits), 1600)
        // Native +1EV has already doubled the metered exposure; don't add it twice.
        XCTAssertEqual(settings.resolvedISO(meteredISO: 1600, meteredSeconds: 0.5, targetSeconds: 1,
            meteredBias: 1, range: limits), 800)
        settings.exposureBiasAutomatic = true
        XCTAssertEqual(settings.resolvedISO(meteredISO: 1600, meteredSeconds: 0.5, targetSeconds: 1,
            meteredOffset: 1, range: limits), 400)
        settings.isoAutomatic = false; settings.iso = 400; settings.exposureBiasAutomatic = false
        XCTAssertEqual(settings.resolvedISO(meteredISO: 800, meteredSeconds: 1, targetSeconds: 0.1, range: limits), 800)
    }
    func testCaptureShortensOnlyWhenAutomaticISOReachesItsFloor() {
        var settings = AstroManualSettings()
        settings.exposureBias = 1
        func exposure(iso: Double, seconds: Double, minimum: Double = 0.001) -> (seconds: Double, iso: Double) {
            settings.captureExposure(meteredISO: iso, meteredSeconds: seconds, requestedSeconds: 0.5,
                                     meteredOffset: 0, meteredBias: 0, isoRange: 50...3200, minimumSeconds: minimum)
        }
        let dim = exposure(iso: 800, seconds: 1.0 / 15)
        XCTAssertEqual(dim.seconds, 0.5)
        XCTAssertEqual(dim.iso, 213.3333, accuracy: 0.001)
        let bright = exposure(iso: 100, seconds: 0.01)
        XCTAssertEqual(bright.iso, 50)
        XCTAssertEqual(bright.seconds, 0.04, accuracy: 0.000001)
        XCTAssertEqual(exposure(iso: 100, seconds: 0.01, minimum: 0.05).seconds, 0.05)
        XCTAssertEqual(exposure(iso: 0, seconds: 0.01).seconds, 0.5)
        settings.isoAutomatic = false
        settings.iso = 400
        let manual = exposure(iso: 100, seconds: 0.01)
        XCTAssertEqual(manual.seconds, 0.5)
        XCTAssertEqual(manual.iso, 800)
    }

    func testPhotoShutterClampsToRealShutterRange() {
        var settings = AstroManualSettings()
        settings.photoShutterSeconds = 1.0 / 60.0
        XCTAssertEqual(settings.clampedPhotoShutter, 1.0 / 15.0, accuracy: 0.0001)
        settings.photoShutterSeconds = 8
        XCTAssertEqual(settings.clampedPhotoShutter, 1.0, accuracy: 0.0001)
        settings.photoShutterSeconds = 0.5
        XCTAssertEqual(settings.clampedPhotoShutter, 0.5, accuracy: 0.0001)
    }

    func testFusionExposureClampsTo1Through30() {
        var settings = AstroManualSettings()
        settings.fusionExposureSeconds = 0
        XCTAssertEqual(settings.clampedFusionExposure, 1)
        settings.fusionExposureSeconds = 31
        XCTAssertEqual(settings.clampedFusionExposure, 30)
        settings.fusionExposureSeconds = 12
        XCTAssertEqual(settings.clampedFusionExposure, 12)
    }

    func testISOClampsToFormatBounds() throws {
        let format = AVCaptureDevice.default(for: .video)?.formats.first
        guard let format else { throw XCTSkip("需要真实相机格式") }
        var settings = AstroManualSettings()
        settings.setISO(1, in: format)
        XCTAssertEqual(settings.iso, Double(format.minISO), accuracy: 1)
        settings.setISO(1_000_000, in: format)
        XCTAssertEqual(settings.iso, Double(format.maxISO), accuracy: 1)
    }
}
