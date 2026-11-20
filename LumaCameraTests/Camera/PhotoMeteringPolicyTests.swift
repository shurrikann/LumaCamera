import XCTest
import CoreImage
@testable import LumaCamera

final class PhotoMeteringPolicyTests: XCTestCase {
    /// 默认让中心比全画面亮两档，稳定得到 -1EV 的相对修正，便于复用稳定性测试。
    private func sample(_ time: Double, mean: Double = 0.36, product: Double = 1,
                        bias: Double = 0, user: Double = 0, shape: [Double] = [0,1,-1,0], route: String = "main",
                        highlights: [Double] = [], centerRatio: Double = 4,
                        headroom: Double = 1) -> PhotoMeteringPolicy.Sample {
        .init(mean: mean, shape: shape, exposureProduct: product, deviceBias: bias, userBias: user,
              time: time, route: route, highlights: .init(luminances: highlights), centerRatio: centerRatio,
              highlightHeadroom: headroom)
    }
    private func initial(_ policy: inout PhotoMeteringPolicy) -> Double? {
        XCTAssertNil(policy.consider(sample(0), adjusting: false))
        XCTAssertNil(policy.consider(sample(0.4), adjusting: false))
        return policy.consider(sample(0.8), adjusting: false)
    }
    func testStableSceneAppliesOnceWithoutAccumulating() throws {
        var p = PhotoMeteringPolicy()
        XCTAssertEqual(try XCTUnwrap(initial(&p)), -1, accuracy: 0.0001)
        p.complete(at: 1)
        // 补偿后的画面和快门/ISO一起变化，不是新场景。
        for index in 0..<200 {
            XCTAssertNil(p.consider(sample(2.3 + Double(index)*0.4, mean: 0.18, product: 0.5, bias: -1), adjusting: false))
        }
        XCTAssertEqual(p.applications, 1)
    }
    func testRealSceneChangeRequiresStableDwellAndAppliesAbsoluteTarget() throws {
        var p = PhotoMeteringPolicy(); _ = initial(&p); p.complete(at: 1)
        XCTAssertNil(p.consider(sample(2.3, bias: -1), adjusting: false))
        XCTAssertNil(p.consider(sample(3, mean: 0.045, bias: -1, centerRatio: 0.5), adjusting: false))
        XCTAssertNil(p.consider(sample(3.4, mean: 0.045, bias: -1, centerRatio: 0.5), adjusting: false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(3.8, mean: 0.045, bias: -1, centerRatio: 0.5), adjusting: false)), 0.5, accuracy: 0.001)
        XCTAssertEqual(p.applications, 2)
    }
    func testFlickerAndMovingSceneDoNotApply() {
        var p = PhotoMeteringPolicy()
        for index in 0..<100 {
            XCTAssertNil(p.consider(sample(Double(index)*0.4, mean: index%2 == 0 ? 0.01 : 0.8), adjusting: false))
        }
        XCTAssertEqual(p.applications, 0)
    }
    func testAEAdjustmentAndCancelledCandidateRequireFreshDwell() {
        var p = PhotoMeteringPolicy()
        _ = p.consider(sample(0), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.09), adjusting: true)
        XCTAssertNil(p.consider(sample(0.8), adjusting: false))
        p.suspend()
        XCTAssertNil(p.consider(sample(1.2), adjusting: false))
        XCTAssertNil(p.consider(sample(1.6), adjusting: false))
        XCTAssertNotNil(p.consider(sample(2), adjusting: false))
    }
    func testAdjustmentFlagsCannotStarveStableSamplesForever() throws {
        var p = PhotoMeteringPolicy()
        for time in [0.0, 0.2, 0.4] { XCTAssertNil(p.consider(sample(time), adjusting: true)) }
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.6), adjusting: true)), -1, accuracy: 0.001)
    }
    func testStableSceneComputesAfterPointFourSeconds() throws {
        var p = PhotoMeteringPolicy()
        XCTAssertNil(p.consider(sample(0), adjusting: false))
        XCTAssertNil(p.consider(sample(0.2), adjusting: false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.4), adjusting: false)), -1, accuracy: 0.001)
    }
    func testRealtimeTargetUpdatesWithoutWaitingOrApplyingExposure() throws {
        var p = PhotoMeteringPolicy()
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for:sample(0))), -1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for:sample(0.2,mean:0.09,centerRatio:0.5))), 0.5, accuracy: 0.001)
        XCTAssertEqual(p.applications, 0)
        XCTAssertNil(p.consider(sample(0), adjusting: false))
        XCTAssertNil(p.consider(sample(0.2,mean:0.09), adjusting: false))
        XCTAssertEqual(p.applications, 0, "实时读数变化不能变成逐帧下发曝光")
    }
    func testNewCompositionDuringCooldownIsNotSwallowed() throws {
        var p = PhotoMeteringPolicy(); _ = initial(&p); p.complete(at:1)
        let shape = [-2.0, 1, 1, 0]
        XCTAssertNil(p.consider(sample(1.5,mean:0.045,bias:-1,shape:shape,centerRatio:0.5),adjusting:false))
        XCTAssertNil(p.consider(sample(1.7,mean:0.045,bias:-1,shape:shape,centerRatio:0.5),adjusting:false))
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(1.9,mean:0.045,bias:-1,shape:shape,centerRatio:0.5),adjusting:false)),0.5,accuracy:0.001)
    }
    func testNewStableTargetInSameSceneCanFollowWithoutAccumulatingError() throws {
        var p = PhotoMeteringPolicy(); _ = initial(&p); p.complete(at:1)
        let post = sample(1.5,mean:0.3,product:0.8,bias:-0.5)
        XCTAssertNil(p.consider(post,adjusting:false))
        XCTAssertNil(p.consider(sample(1.7,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
        XCTAssertNil(p.consider(sample(1.9,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
        XCTAssertNotNil(p.consider(sample(2.1,mean:0.3,product:0.8,bias:-0.5),adjusting:false))
    }
    func testApplicationMovesTowardFreshTargetAndSettlesWithoutOvershoot() {
        var actual = 0.0
        for _ in 0..<10 {
            let next = PhotoMeteringPolicy.appliedCorrection(target:-1,current:actual)
            XCTAssertLessThanOrEqual(abs(next-actual),0.5)
            XCTAssertGreaterThanOrEqual(next,-1)
            actual = next
        }
        XCTAssertEqual(actual,-1,accuracy:0.002)
        XCTAssertGreaterThan(PhotoMeteringPolicy.appliedCorrection(target:1,current:actual),actual,"更换目标直接朝新值移动，不沿用上一轮的误差")
    }
    func testUserEVIsNotCancelledByMeteringFeedback() {
        var p = PhotoMeteringPolicy(); _ = initial(&p)
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
        var p = PhotoMeteringPolicy()
        _ = p.consider(sample(0, mean: 0.72, bias: 1, user: 1), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.72, bias: 1, user: 1), adjusting: false)
        XCTAssertEqual(try XCTUnwrap(p.consider(sample(0.8, mean: 0.72, bias: 1, user: 1), adjusting: false)), -1, accuracy: 0.001)
    }
    func testCenterCorrectionIsRelativeAndUserEVStacks() throws {
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, centerRatio: 0.5))), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, centerRatio: 2))), -0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, centerRatio: 0.01))), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, centerRatio: 100))), -1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, bias: 1, user: 1, centerRatio: 0.5))), 0.5, accuracy: 0.001,
                       "用户EV不能进入中心相对修正")
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, bias: -1, user: -1, centerRatio: 0.5))), 0.5, accuracy: 0.001)
    }
    func testManualISOAndShutterChangesRecomputeEvenWhenSceneIsUnchanged() throws {
        var p = PhotoMeteringPolicy()
        func observe(_ time: Double, product: Double) -> Double? {
            let observed = sample(time, mean: 0.18, product: 1, bias: -1)
            return p.consider(PhotoMeteringPolicy.manualSample(observed, plannedExposureProduct: product), adjusting: false)
        }
        _ = observe(0, product: 1); _ = observe(0.4, product: 1); _ = observe(0.8, product: 1)
        XCTAssertEqual(p.lastComputedTarget ?? .nan, -1, accuracy: 0.001)
        // 场景和预览不变；ISO翻倍或快门时间翻倍，都应重新得到-1EV的建议。
        _ = observe(1.2, product: 2); _ = observe(1.6, product: 2)
        XCTAssertEqual(try XCTUnwrap(observe(2, product: 2)), -1, accuracy: 0.001)
        p.complete(at: 2)
        _ = observe(3.3, product: 2)
        _ = observe(4, product: 0.5); _ = observe(4.4, product: 0.5)
        XCTAssertEqual(try XCTUnwrap(observe(4.8, product: 0.5)), -1, accuracy: 0.001)
    }
    func testManualSuggestionUsesCaptureExposureInsteadOfSmoothPreviewExposure() {
        let observed = sample(0, mean: 0.09, product: 0.5, bias: -2, user: 1)
        let predicted = PhotoMeteringPolicy.manualSample(observed, plannedExposureProduct: 2)
        XCTAssertEqual(predicted.mean, 0.36, accuracy: 0.001)
        XCTAssertEqual(predicted.exposureProduct, 2)
        XCTAssertEqual(predicted.deviceBias, 0, "custom曝光不能把无实际作用的bias当作画面增益")
        XCTAssertEqual(predicted.userBias, 0)
    }
    func testRouteChangeAndResetReleasePendingApplication() {
        var p = PhotoMeteringPolicy(); _ = initial(&p)
        XCTAssertNil(p.consider(sample(1, route: "tele"), adjusting: false))
        XCTAssertNil(p.consider(sample(1.4, route: "tele"), adjusting: false))
        XCTAssertNotNil(p.consider(sample(1.8, route: "tele"), adjusting: false))
        p.reset(); XCTAssertNotNil(initial(&p))
    }
    func testMissingCompletionDoesNotLeavePolicyStuckOrReapply() {
        var p = PhotoMeteringPolicy(); _ = initial(&p)
        for i in 0..<50 { XCTAssertNil(p.consider(sample(1+Double(i)*0.4), adjusting: false)) }
        XCTAssertEqual(p.applications, 1)
    }
    func testInvalidSamplesAndClampedTargets() {
        var p = PhotoMeteringPolicy()
        XCTAssertNil(p.consider(sample(0, mean: .nan), adjusting: false))
        XCTAssertNil(p.consider(sample(0, product: 0), adjusting: false))
        _ = p.consider(sample(0, mean: 0.00002), adjusting: false)
        _ = p.consider(sample(0.4, mean: 0.00002), adjusting: false)
        XCTAssertEqual(p.consider(sample(0.8, mean: 0.00002), adjusting: false), -1)
        XCTAssertEqual(PhotoMeteringPolicy.target(for: sample(0, centerRatio: 0)), 0)
    }
    func testCenterWeightingUsesShortEdgeAndStaysFixedAtFrameCenter() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB))
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        func gray(_ value: CGFloat, _ frame: CGRect) -> CIImage {
            CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: colorSpace)!).cropped(to: frame)
        }
        for (width, height) in [(320.0, 320.0), (640, 320), (320, 640), (768, 320)] {
            let frame = CGRect(x: 40, y: 70, width: width, height: height)
            let background = gray(0.10, frame)
            let mid = CGRect(x: frame.midX - 52, y: frame.midY - 52, width: 104, height: 104)
            let offset = height > width ? CGPoint(x: 0, y: (height - mid.height) / 2)
                : CGPoint(x: (width - mid.width) / 2, y: 0)
            let means = [mid, mid.offsetBy(dx: -offset.x, dy: -offset.y), mid.offsetBy(dx: offset.x, dy: offset.y)].map {
                PhotoMeteringPolicy.analyze(gray(0.50, $0).composited(over: background), context: context).centerMean
            }
            XCTAssertGreaterThan(means[0], means[1] + 0.004)
            XCTAssertEqual(means[1], means[2], accuracy: 0.003)
        }
    }

    func testHighlightProtectsBroadAndNarrowPatchesButIgnoresSpecularPoints() throws {
        func target(brightCount: Int, luminance: Double = 1, bias: Double = 0, user: Double = 0) throws -> Double {
            // Preview already contains the total exposure bias; user EV and system
            // correction must both be removed before computing base protection.
            let gain = exp2(bias)
            let lights = Array(repeating: 0.18 * gain, count: 1000 - brightCount)
                + Array(repeating: luminance * gain, count: brightCount)
            return try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, mean: 0.18 * gain,
                product: gain, bias: bias, user: user, highlights: lights), mode: .highlight))
        }
        XCTAssertEqual(try target(brightCount: 0), 0)
        XCTAssertLessThan(try target(brightCount: 20), -0.2, "2%面积应进入保护")
        XCTAssertLessThan(try target(brightCount: 30), -0.2)
        let broad = try target(brightCount: 350)
        XCTAssertLessThan(broad, -0.2)
        XCTAssertEqual(try target(brightCount: 350, bias: 1, user: 1), broad, accuracy: 0.0001,
                       "用户EV不能改变基础高光保护量")
        XCTAssertEqual(try target(brightCount: 350, bias: 1, user: 0), broad, accuracy: 0.0001,
                       "系统总bias也必须先从高光估计中移除")
        XCTAssertEqual(try target(brightCount: 350, luminance: 8), -2)
    }

    func testHighlightAreaHysteresisAndHeadroomTarget() throws {
        let small = Array(repeating: 0.18, count: 982) + Array(repeating: 1.0, count: 18)
        let smallSample = sample(0, highlights: small)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: smallSample, mode: .highlight)), 0,
                       "未进入保护前，1.8%面积不介入")
        XCTAssertLessThan(try XCTUnwrap(PhotoMeteringPolicy.target(for: smallSample, mode: .highlight,
            highlightActive: true)), -0.2, "已保护时1.5%退出阈值内继续保护")

        let sdr = sample(0, highlights: Array(repeating: 0.18, count: 850) + Array(repeating: 1.0, count: 150))
        let hdr = sample(0, highlights: Array(repeating: 0.72, count: 850) + Array(repeating: 4.0, count: 150),
                         headroom: 4)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sdr, mode: .highlight)),
                       try XCTUnwrap(PhotoMeteringPolicy.target(for: hdr, mode: .highlight)), accuracy: 0.0001,
                       "HDR阈值按headroom缩放后，相对保护量应与SDR一致")
        let sdrValuesWithHDRHeadroom = sample(0,
            highlights: Array(repeating: 0.18, count: 850) + Array(repeating: 1.0, count: 150), headroom: 4)
        XCTAssertEqual(try XCTUnwrap(PhotoMeteringPolicy.target(for: sdrValuesWithHDRHeadroom, mode: .highlight)), 0,
                       "预览没有EDR余量时不能假装高光还在headroom内")
    }

    func testIsolatedSpecularPointsAreIgnoredButBroadHighlightsRemain() {
        var lights = [Double](repeating: 0.18, count: 32 * 32)
        lights[0] = 5
        lights[100] = 5; lights[101] = 5; lights[132] = 5; lights[133] = 5; lights[134] = 5
        let filtered = PhotoMeteringPolicy.removingIsolatedSpeculars(lights, size: 32, threshold: 0.9)
        XCTAssertEqual(filtered[0], 0, "单像素点光源应忽略")
        XCTAssertEqual(filtered[100], 5, "超过4像素的连通亮区应保留")
        XCTAssertEqual(filtered[134], 5)
    }

    func testHighlightCorrectionStaysStableAcrossFivePercentBoundary() throws {
        let expected = log2(0.90 / 0.92) - 0.15
        for brightCount in 40...80 {
            let lights = Array(repeating: 0.02, count: 1000 - brightCount)
                + Array(repeating: 0.92, count: brightCount)
            let target = try XCTUnwrap(PhotoMeteringPolicy.target(for: sample(0, highlights: lights), mode: .highlight))
            XCTAssertEqual(target, expected, accuracy: 0.0001, "面积 \(Double(brightCount) / 10)%")
        }
    }

    func testSpatialHighlightFilteringUsesTheSameExposureBaselineAsAreaAndPeak() throws {
        let side = 32
        let background = Array(repeating: 0.2, count: side * side)
        var isolated = background
        for row in stride(from: 0, to: 8, by: 2) {
            for column in stride(from: 0, to: 16, by: 2) {
                isolated[row * side + column] = 0.97
            }
        }
        var patch = background
        for row in 0..<4 {
            for column in 0..<8 { patch[row * side + column] = 0.97 }
        }
        let start = CACurrentMediaTime()
        for index in 0..<100 {
            let bias = [-1.0, -0.5, 0, 0.5, 1.0][index % 5]
            let gain = exp2(bias)
            for (lights, expected) in [(isolated, 0.0), (patch, log2(0.90 / 0.97) - 0.15)] {
                var input = sample(0, mean: 0.25 * gain, product: gain, bias: bias, user: bias)
                input.highlights = .init(luminances: lights.map { $0 * gain }, gridSize: side)
                let target = try XCTUnwrap(PhotoMeteringPolicy.target(for: input, mode: .highlight))
                XCTAssertEqual(target, expected, accuracy: 0.0001, "偏置 \(bias) EV")
            }
        }
        print("PHOTO-METERING baseNormalizedGridSamples=200 totalMS=\((CACurrentMediaTime() - start) * 1000)")
    }

    func testHighlightStableDwellFeedbackAndRelease() throws {
        var policy = PhotoMeteringPolicy()
        let brightLights = Array(repeating: 1.0, count: 100)
        let dark = Array(repeating: 0.15, count: 100)
        func observe(_ time: Double, bright: Bool, bias: Double = 0) -> Double? {
            let gain = exp2(bias)
            let lights = (Array(repeating: 0.18, count: 900) + (bright ? brightLights : dark)).map { $0 * gain }
            return policy.consider(sample(time, mean: 0.19 * gain, product: gain, bias: bias,
                highlights: lights), adjusting: false, mode: .highlight)
        }
        for n in 0..<20 { XCTAssertNil(observe(Double(n) * 0.21, bright: n.isMultiple(of: 2))) }
        XCTAssertNil(observe(5, bright: true))
        XCTAssertNil(observe(5.21, bright: true))
        let correction = try XCTUnwrap(observe(5.42, bright: true))
        XCTAssertLessThan(correction, 0)
        policy.complete(at: 5.5)
        for n in 0..<20 { XCTAssertNil(observe(5.7 + Double(n) * 0.21, bright: true, bias: correction)) }
        XCTAssertNil(observe(11, bright: false, bias: correction))
        XCTAssertNil(observe(11.21, bright: false, bias: correction))
        XCTAssertEqual(observe(11.42, bright: false, bias: correction), 0)
    }

    func testLinearGridAnalysisAndPerformance() {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        let image = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 1200))
        let first = PhotoMeteringPolicy.analyze(image, context: context)
        XCTAssertEqual(first.centerMean, 0.18, accuracy: 0.002)
        XCTAssertEqual(first.sceneMean, 0.18, accuracy: 0.002)
        XCTAssertEqual(first.shape.count, 64)
        var samples = [Double]()
        for _ in 0..<100 {
            let start = CACurrentMediaTime()
            let result = PhotoMeteringPolicy.analyze(image, context: context)
            samples.append(CACurrentMediaTime()-start)
            XCTAssertEqual(result.centerMean, first.centerMean, accuracy: 0.001)
        }
        samples.sort()
        print("GLOBAL-METERING-ANALYSIS n=100 medianSeconds=\(samples[50]) p95Seconds=\(samples[95]) maxSeconds=\(samples[99]); 同一900x1200合成图的均值+8x8结构读取耗时，不是预览帧率")
    }
}
