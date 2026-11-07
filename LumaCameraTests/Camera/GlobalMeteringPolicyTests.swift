import XCTest
import CoreImage
@testable import LumaCamera

final class GlobalMeteringPolicyTests: XCTestCase {
    private func sample(_ time: Double, mean: Double = 0.36, product: Double = 1,
                        bias: Double = 0, user: Double = 0, shape: [Double] = [0,1,-1,0], route: String = "main") -> GlobalMeteringPolicy.Sample {
        .init(mean: mean, shape: shape, exposureProduct: product, deviceBias: bias, userBias: user, time: time, route: route)
    }
    private func initial(_ policy: inout GlobalMeteringPolicy) -> Double? {
        XCTAssertNil(policy.consider(sample(0), adjusting: false))
        XCTAssertNil(policy.consider(sample(0.4), adjusting: false))
        return policy.consider(sample(0.8), adjusting: false)
    }
    func testStableSceneAppliesOnceWithoutAccumulating() throws {
        var p = GlobalMeteringPolicy()
        XCTAssertEqual(try XCTUnwrap(initial(&p)), -1, accuracy: 0.0001)
        p.complete(at: 1)
        // 补偿后的画面和快门/ISO一起变化，不是新场景。
        for index in 0..<200 {
            XCTAssertNil(p.consider(sample(2.3 + Double(index)*0.4, mean: 0.18, product: 0.5, bias: -1), adjusting: false))
        }
        XCTAssertEqual(p.applications, 1)
    }
    func testRealSceneChangeRequiresStableDwellAndAppliesAbsoluteTarget() throws {
        var p = GlobalMeteringPolicy(); _ = initial(&p); p.complete(at: 1)
        XCTAssertNil(p.consider(sample(2.3, bias: -1), adjusting: false))
        XCTAssertNil(p.consider(sample(3, mean: 0.045, bias: -1), adjusting: false))
        XCTAssertNil(p.consider(sample(3.4, mean: 0.045, bias: -1), adjusting: false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(3.8, mean: 0.045, bias: -1), adjusting: false)), 1, accuracy: 0.001)
        XCTAssertEqual(p.applications, 2)
    }
    func testFlickerAndMovingSceneDoNotApply() {
        var p = GlobalMeteringPolicy()
        for index in 0..<100 {
            XCTAssertNil(p.consider(sample(Double(index)*0.4, mean: index%2 == 0 ? 0.01 : 0.8), adjusting: false))
        }
        XCTAssertEqual(p.applications, 0)
    }
    func testAEAdjustmentAndCancelledCandidateRequireFreshDwell() {
        var p = GlobalMeteringPolicy()
        _ = p.consider(sample(0), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.09), adjusting: true)
        XCTAssertNil(p.consider(sample(0.8), adjusting: false))
        p.suspend()
        XCTAssertNil(p.consider(sample(1.2), adjusting: false))
        XCTAssertNil(p.consider(sample(1.6), adjusting: false))
        XCTAssertNotNil(p.consider(sample(2), adjusting: false))
    }
    func testAdjustmentFlagsCannotStarveStableSamplesForever() throws {
        var p = GlobalMeteringPolicy()
        for time in [0.0, 0.2, 0.4] { XCTAssertNil(p.consider(sample(time), adjusting: true)) }
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.6), adjusting: true)), -1, accuracy: 0.001)
    }
    func testStableSceneComputesAfterPointFourSeconds() throws {
        var p = GlobalMeteringPolicy()
        XCTAssertNil(p.consider(sample(0), adjusting: false))
        XCTAssertNil(p.consider(sample(0.2), adjusting: false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.4), adjusting: false)), -1, accuracy: 0.001)
    }
    func testRealtimeTargetUpdatesWithoutWaitingOrApplyingExposure() throws {
        var p = GlobalMeteringPolicy()
        XCTAssertEqual(try XCTUnwrap(GlobalMeteringPolicy.target(for:sample(0))), -1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(GlobalMeteringPolicy.target(for:sample(0.2,mean:0.09))), 1, accuracy: 0.001)
        XCTAssertEqual(p.applications, 0)
        XCTAssertNil(p.consider(sample(0), adjusting: false))
        XCTAssertNil(p.consider(sample(0.2,mean:0.09), adjusting: false))
        XCTAssertEqual(p.applications, 0, "实时读数变化不能变成逐帧下发曝光")
    }
    func testNewCompositionDuringCooldownIsNotSwallowed() throws {
        var p = GlobalMeteringPolicy(); _ = initial(&p); p.complete(at:1)
        let shape = [-2.0, 1, 1, 0]
        XCTAssertNil(p.consider(sample(1.5,mean:0.045,bias:-1,shape:shape),adjusting:false))
        XCTAssertNil(p.consider(sample(1.7,mean:0.045,bias:-1,shape:shape),adjusting:false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(1.9,mean:0.045,bias:-1,shape:shape),adjusting:false)),1,accuracy:0.001)
    }
    func testNewStableTargetInSameSceneCanFollowWithoutAccumulatingError() throws {
        var p = GlobalMeteringPolicy(); _ = initial(&p); p.complete(at:1)
        let post = sample(1.5,mean:0.3,product:0.8,bias:-0.5)
        XCTAssertNil(p.consider(post,adjusting:false))
        XCTAssertNil(p.consider(sample(1.7,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
        XCTAssertNil(p.consider(sample(1.9,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
        XCTAssertNotNil(p.consider(sample(2.1,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
    }
    func testApplicationMovesTowardFreshTargetAndSettlesWithoutOvershoot() {
        var actual = 0.0
        for _ in 0..<10 {
            let next = GlobalMeteringPolicy.appliedCorrection(target:-1,current:actual)
            XCTAssertLessThanOrEqual(abs(next-actual),0.5)
            XCTAssertGreaterThanOrEqual(next,-1)
            actual = next
        }
        XCTAssertEqual(actual,-1,accuracy:0.002)
        XCTAssertGreaterThan(GlobalMeteringPolicy.appliedCorrection(target:1,current:actual),actual,"更换目标直接朝新值移动，不沿用上一轮的误差")
    }
    func testUserEVIsNotCancelledByMeteringFeedback() {
        var p = GlobalMeteringPolicy(); _ = initial(&p)
        p.complete(at: 1)
        _ = p.consider(sample(2.3, mean: 0.18, product: 0.5, bias: -1), adjusting: false)
        // 用户增加一档，重新建立观察基准，不撤销用户的调整。
        p.complete(at: 3)
        for i in 0..<20 {
            XCTAssertNil(p.consider(sample(4.3+Double(i)*0.4, mean: 0.36, product: 1, bias: 0, user: 1), adjusting: false))
        }
        XCTAssertEqual(p.applications, 1)
    }
    func testUserBiasIsRemovedFromBrightnessBeforeComputingNewTarget() throws {
        var p = GlobalMeteringPolicy()
        _ = p.consider(sample(0, mean: 0.72, bias: 1, user: 1), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.72, bias: 1, user: 1), adjusting: false)
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.8, mean: 0.72, bias: 1, user: 1), adjusting: false)), -1, accuracy: 0.001)
    }
    func testManualISOAndShutterChangesRecomputeEvenWhenSceneIsUnchanged() throws {
        var p = GlobalMeteringPolicy()
        func observe(_ time: Double, product: Double) -> Double? {
            let observed = sample(time, mean: 0.18, product: 1, bias: -1)
            return p.consider(GlobalMeteringPolicy.manualSample(observed, plannedExposureProduct: product), adjusting: false)
        }
        _ = observe(0, product: 1); _ = observe(0.4, product: 1); _ = observe(0.8, product: 1)
        XCTAssertEqual(p.lastComputedTarget ?? .nan, 0, accuracy: 0.001)
        // 场景和预览不变；ISO翻倍或快门时间翻倍，都应重新得到-1EV的建议。
        _ = observe(1.2, product: 2); _ = observe(1.6, product: 2)
        XCTAssertEqual(try XCTUnwrap(observe(2, product: 2)), -1, accuracy: 0.001)
        p.complete(at: 2)
        _ = observe(3.3, product: 2)
        _ = observe(4, product: 0.5); _ = observe(4.4, product: 0.5)
        XCTAssertEqual(try XCTUnwrap(observe(4.8, product: 0.5)), 1, accuracy: 0.001)
    }
    func testManualSuggestionUsesCaptureExposureInsteadOfSmoothPreviewExposure() {
        let observed = sample(0, mean: 0.09, product: 0.5, bias: -2, user: 1)
        let predicted = GlobalMeteringPolicy.manualSample(observed, plannedExposureProduct: 2)
        XCTAssertEqual(predicted.mean, 0.36, accuracy: 0.001)
        XCTAssertEqual(predicted.exposureProduct, 2)
        XCTAssertEqual(predicted.deviceBias, 0, "custom曝光不能把无实际作用的bias当作画面增益")
        XCTAssertEqual(predicted.userBias, 0)
    }
    func testRouteChangeAndResetReleasePendingApplication() {
        var p = GlobalMeteringPolicy(); _ = initial(&p)
        XCTAssertNil(p.consider(sample(1, route: "tele"), adjusting: false))
        XCTAssertNil(p.consider(sample(1.4, route: "tele"), adjusting: false))
        XCTAssertNotNil(p.consider(sample(1.8, route: "tele"), adjusting: false))
        p.reset(); XCTAssertNotNil(initial(&p))
    }
    func testMissingCompletionDoesNotLeavePolicyStuckOrReapply() {
        var p = GlobalMeteringPolicy(); _ = initial(&p)
        for i in 0..<50 { XCTAssertNil(p.consider(sample(1+Double(i)*0.4), adjusting: false)) }
        XCTAssertEqual(p.applications, 1)
    }
    func testInvalidSamplesAndClampedTargets() {
        var p = GlobalMeteringPolicy()
        XCTAssertNil(p.consider(sample(0, mean: .nan), adjusting: false))
        XCTAssertNil(p.consider(sample(0, product: 0), adjusting: false))
        _ = p.consider(sample(0, mean: 0.00002), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.00002), adjusting: false)
        XCTAssertEqual(p.consider(sample(0.8, mean: 0.00002), adjusting: false), 2)
    }
    func testLinearWholeFrameAnalysisAndPerformance() {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        let image = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 1200))
        let first = GlobalMeteringPolicy.analyze(image, context: context)
        XCTAssertEqual(first.mean, 0.18, accuracy: 0.002)
        XCTAssertEqual(first.shape.count, 64)
        var samples = [Double]()
        for _ in 0..<100 {
            let start = CACurrentMediaTime()
            let result = GlobalMeteringPolicy.analyze(image, context: context)
            samples.append(CACurrentMediaTime()-start)
            XCTAssertEqual(result.mean, first.mean, accuracy: 0.001)
        }
        samples.sort()
        print("GLOBAL-METERING-ANALYSIS n=100 medianSeconds=\(samples[50]) p95Seconds=\(samples[95]) maxSeconds=\(samples[99]); 同一900x1200合成图的均值+8x8结构读取耗时，不是预览帧率")
    }
}
