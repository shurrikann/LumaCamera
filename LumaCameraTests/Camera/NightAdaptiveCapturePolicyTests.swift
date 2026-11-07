import XCTest
@testable import LumaCamera

final class NightAdaptiveCapturePolicyTests: XCTestCase {
    func testNightAndManualExposureUseSpeedToPreserveFrameTiming() {
        XCTAssertEqual(NightCapturePolicy.qualityPriority(nightMode: true, usesRAW: false, usesManualExposure: false,
                                                          maximum: .quality), .speed)
        XCTAssertEqual(NightCapturePolicy.qualityPriority(nightMode: true, usesRAW: false, usesManualExposure: false,
                                                          maximum: .balanced), .speed)
        XCTAssertEqual(NightCapturePolicy.qualityPriority(nightMode: false, usesRAW: false, usesManualExposure: true,
                                                          maximum: .quality), .speed)
        XCTAssertEqual(NightCapturePolicy.qualityPriority(nightMode: false, usesRAW: false, usesManualExposure: false,
                                                          maximum: .quality), .balanced)
    }

    func testDarkAutomaticExposureCollectsMoreLightWithinHardwareBounds() throws {
        let base = try XCTUnwrap(NightAdaptiveCapturePolicy.automaticExposure(iso: 10000, seconds: 1.0 / 15,
            durationRange: (1.0 / 10000)...1, isoRange: 54...10000))
        XCTAssertEqual(base.seconds, 1, accuracy: 0.00001)
        XCTAssertEqual(base.iso, 2666.6667, accuracy: 0.1)
        XCTAssertEqual(base.seconds * base.iso / (10000 / 15), 4, accuracy: 0.0001)
        for bias in [-1.0, 0, 1] {
            let frame = NightAdaptiveCapturePolicy.bracket(base, bias: bias, durationRange: (1.0 / 10000)...1, isoRange: 54...10000)
            XCTAssertLessThanOrEqual(frame.seconds, 1)
            XCTAssertEqual(frame.seconds * frame.iso, base.seconds * base.iso * pow(2, bias), accuracy: 0.01)
        }
        XCTAssertNil(NightAdaptiveCapturePolicy.automaticExposure(iso: 100, seconds: 0.001, durationRange: 0.0001...1, isoRange: 54...10000))
        XCTAssertNil(NightAdaptiveCapturePolicy.automaticExposure(iso: .nan, seconds: 1, durationRange: 0.0001...1, isoRange: 54...10000))
        let limited = try XCTUnwrap(NightAdaptiveCapturePolicy.automaticExposure(iso: 10000, seconds: 1.0 / 15,
            durationRange: 0.001...(1.0 / 15), isoRange: 54...10000))
        XCTAssertEqual(limited.seconds, 1.0 / 15, accuracy: 0.00001)
        XCTAssertEqual(limited.iso, 10000)
    }
    func testAutomaticExposureUsesTwoSecondHandheldCeiling() throws {
        let base = try XCTUnwrap(NightAdaptiveCapturePolicy.automaticExposure(
            iso: 3200, seconds: 1, durationRange: (1.0 / 10000)...30, isoRange: 54...10000))
        XCTAssertEqual(base.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(base.iso, 6400, accuracy: 0.1)
        XCTAssertEqual(base.seconds * base.iso / 3200, 4, accuracy: 0.001)
    }

    func testManualNightRangesAndMeteringDoNotTreatUserExposureAsDarkness() throws {
        XCTAssertEqual(NightManualExposurePolicy.isoRange(hardware:54...6400),100...3200)
        XCTAssertEqual(NightManualExposurePolicy.shutterRange(hardware:log2(1.0/64000)...0),log2(1.0/30)...0)
        XCTAssertEqual(NightManualExposurePolicy.isoRange(hardware:200...1600),200...1600)
        // 相同场景，手动多曝光4EV时系统offset也多4EV；环境判定不应被人为调高ISO触发。
        let a = try XCTUnwrap(NightManualExposurePolicy.meteringBias(userBias:0,customExposure:true,offsetEV:0))
        let b = try XCTUnwrap(NightManualExposurePolicy.meteringBias(userBias:0,customExposure:true,offsetEV:4))
        XCTAssertEqual(NightAdaptiveCapturePolicy.exposureIndex(iso:100,seconds:0.1,bias:a),
                       NightAdaptiveCapturePolicy.exposureIndex(iso:1600,seconds:0.1,bias:b))
        XCTAssertNil(NightManualExposurePolicy.meteringBias(userBias:0,customExposure:true,offsetEV:nil))
        XCTAssertEqual(NightManualExposurePolicy.meteringBias(userBias:1,customExposure:false,offsetEV:nil),1)
    }
    func testDarknessPlansThreeSixAndNineFramesWithoutEVBiasInflation() throws {
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 32, constrained: false), 3)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 63.9, constrained: false), 3)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 64, constrained: false), 6)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 255, constrained: false), 6)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 256, constrained: false), 9)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: 1024, constrained: true), 3)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex: nil, constrained: false), 3)
        XCTAssertNil(NightAdaptiveCapturePolicy.exposureIndex(iso: .nan, seconds: 1, bias: 0))
        let index = try XCTUnwrap(NightAdaptiveCapturePolicy.exposureIndex(iso: 3200, seconds: 1.0 / 25, bias: 1))
        XCTAssertEqual(index, 64, accuracy: 0.001)
    }

    func testMotionMissingFramesBudgetsAndResourcePressureStopAdditionalBatches() {
        func continues(motion: NightSceneMotion = .stable, received: Int = 3, elapsed: Double = 1,
                       nextBatchSeconds: Double = 1, bytes: Int = 1000, constrained: Bool = false) -> Bool {
            NightAdaptiveCapturePolicy.shouldContinue(target: 9, submitted: 3, received: received, motion: motion,
                elapsed: elapsed, nextBatchSeconds: nextBatchSeconds, compressedBytes: bytes, constrained: constrained)
        }
        XCTAssertTrue(continues())
        XCTAssertFalse(continues(motion: .moving)); XCTAssertTrue(continues(motion: .unknown))
        XCTAssertFalse(continues(received: 2)); XCTAssertFalse(continues(constrained: true))
        XCTAssertFalse(continues(elapsed: 8)); XCTAssertFalse(continues(elapsed: .nan))
        XCTAssertTrue(continues(elapsed: 5, nextBatchSeconds: 3))
        XCTAssertFalse(continues(elapsed: 5.1, nextBatchSeconds: 3))
        XCTAssertFalse(continues(elapsed: 3, nextBatchSeconds: 6))
        XCTAssertFalse(continues(nextBatchSeconds: .nan))
        XCTAssertFalse(continues(bytes: NightAdaptiveCapturePolicy.maximumCompressedBytes))
        XCTAssertFalse(NightAdaptiveCapturePolicy.shouldContinue(target: 6, submitted: 6, received: 6,
            motion: .stable, elapsed: 3, nextBatchSeconds: 1, compressedBytes: 1000, constrained: false))
        XCTAssertTrue(NightAdaptiveCapturePolicy.shouldContinue(target: 9, submitted: 6, received: 6,
            motion: .stable, elapsed: 3, nextBatchSeconds: 1, compressedBytes: 1000, constrained: false))
        XCTAssertFalse(NightAdaptiveCapturePolicy.shouldContinue(target: 9, submitted: 6, received: 6,
            motion: .unknown, elapsed: 3, nextBatchSeconds: 1, compressedBytes: 1000, constrained: false))
    }

    func testActualAutomaticExposureRetainsDenoisingFramesDespiteBiasCorrectedMetering() {
        let exposure = NightAdaptiveCapturePolicy.Exposure(seconds:0.5,iso:1600)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex:50,constrained:false,automaticExposure:exposure),9)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex:50,constrained:true,automaticExposure:exposure),3)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex:32,constrained:false,
            automaticExposure:.init(seconds:0.125,iso:200)),3)
        XCTAssertEqual(NightAdaptiveCapturePolicy.targetFrameCount(exposureIndex:nil,constrained:false,
            automaticExposure:.init(seconds:.nan,iso:1600)),3)
    }
}
