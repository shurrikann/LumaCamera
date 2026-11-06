import XCTest
@testable import LumaCamera

final class AdaptiveWaterExposureTests: XCTestCase {
    func testBrightIndoorAndDarkPlansPreserveMeteredExposure() throws {
        let points: [(Double,Double)] = [(54,1/2000),(200,1/125),(800,1/30),(1600,1/8),(6400,1)]
        var lastSeconds = 0.0
        for (iso,seconds) in points {
            let plan = try XCTUnwrap(AdaptiveWaterExposurePolicy.plan(meteredISO:iso,meteredSeconds:seconds,
                isoRange:54...6400,shutterRange:log2(1/64000)...0))
            XCTAssertLessThanOrEqual(abs(log2(plan.iso*plan.seconds/(iso*seconds))),0.2)
            XCTAssertGreaterThanOrEqual(plan.seconds,lastSeconds); lastSeconds = plan.seconds
            XCTAssertEqual(plan.duration,8); XCTAssertEqual(plan.maximumFrames,64)
        }
    }
    func testManualExposureIsPreservedAndInvalidReadingsRejected() throws {
        let manual = try XCTUnwrap(AdaptiveWaterExposurePolicy.plan(meteredISO:100,meteredSeconds:1/1000,
            isoRange:54...6400,shutterRange:log2(1/64000)...0,manualISO:400,manualSeconds:0.5))
        XCTAssertEqual(manual.iso,400); XCTAssertEqual(manual.seconds,0.5)
        for value in [Double.nan,Double.infinity,0,-1] {
            XCTAssertNil(AdaptiveWaterExposurePolicy.plan(meteredISO:value,meteredSeconds:1/100,
                isoRange:54...6400,shutterRange:log2(1/64000)...0))
        }
        XCTAssertNil(AdaptiveWaterExposurePolicy.plan(meteredISO:64000,meteredSeconds:10,
            isoRange:54...6400,shutterRange:log2(1/64000)...0))
    }

    func testHandheldWaterPrefersShorterAutomaticFrameExposure() throws {
        let automatic = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset: .silkyWater,
            meteredISO: 80, meteredSeconds: 1.0 / 15,
            hardwareISO: 50...6400, hardwareShutter: log2(1.0 / 64000)...0))
        XCTAssertLessThanOrEqual(automatic.spec.frameExposureSeconds, 1.0 / 30)
        XCTAssertLessThanOrEqual(abs(log2(automatic.iso * automatic.spec.frameExposureSeconds / (80.0 / 15))), 0.2)

        let manual = try XCTUnwrap(AdaptiveSlowShutterExposurePolicy.plan(preset: .silkyWater,
            meteredISO: 80, meteredSeconds: 1.0 / 15,
            hardwareISO: 50...6400, hardwareShutter: log2(1.0 / 64000)...0,
            manualISO: 80, manualSeconds: 1.0 / 15))
        XCTAssertEqual(manual.iso, 80)
        XCTAssertEqual(manual.spec.frameExposureSeconds, 1.0 / 15)
    }
}
