import XCTest
import UIKit
import SwiftUI
import ImageIO
@testable import LumaCamera

@MainActor final class PhotoMeteringPhysicalTests: XCTestCase {
    /// 已知场景估计仅用于可重复地设置bias；真实HEIF Pro资源由硬件采集，拦截后不存相册。
    func testDeviceBiasReadoutAndCapturedEXIF() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        XCTAssertFalse(camera.demo); XCTAssertTrue(camera.ready)
        model.photoFormat = .heifPro; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.metering = .centerWeighted; model.ev = 0
        camera.setExposure(iso: nil, seconds: nil, bias: 0)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.submitPhotoMeteringSampleForTesting(mean: 0.36, centerRatio: 4)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(100))
        var initial: (Float,Float) = (0,0)
        for _ in 0..<100 {
            initial = await withCheckedContinuation { c in camera.meteringStateForTesting { _,_,extra,actual in c.resume(returning:(extra,actual)) } }
            if abs(initial.1 + 0.5) < 0.02 && abs(model.displayedExposureBias + 0.5) < 0.02 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(initial.0, -0.5, accuracy: 0.02)
        XCTAssertEqual(initial.1, -0.5, accuracy: 0.02)
        XCTAssertTrue(camera.photoMeteringReadout.automatic)
        XCTAssertEqual(model.displayedExposureBias, Double(initial.1), accuracy: 0.02)
        let old = camera.onCaptureCompleted
        defer { camera.onCaptureCompleted = old }
        for userEV in [0.0, 0.3] {
            model.ev = userEV
            camera.setExposure(iso: nil, seconds: nil, bias: userEV)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(150))
            let done = expectation(description: "临时HEIF Pro")
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; done.fulfill() }
            let started = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: model.photoOptions)
            await fulfillment(of: [done], timeout: 40)
            let photo = try XCTUnwrap(result, camera.message ?? "拍摄失败")
            let data = try XCTUnwrap(photo.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString:Any])
            let value = try XCTUnwrap(exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber).doubleValue
            let parameters = try XCTUnwrap(photo.diagnostics?.parameters)
            XCTAssertTrue(value.isFinite)
            XCTAssertEqual(parameters.requestedExposureBiasEV ?? .nan, userEV, accuracy: 0.0001)
            let correction = try XCTUnwrap(parameters.meteringCorrectionEV)
            let deviceBias = try XCTUnwrap(parameters.deviceExposureBiasEV)
            XCTAssertEqual(correction, -0.5, accuracy: 0.12, "中心相对修正应保持 -0.5EV")
            XCTAssertEqual(deviceBias, userEV + correction, accuracy: 0.12, "用户EV应叠加在中心修正之外")
            XCTAssertEqual(parameters.exifExposureBiasEV ?? .nan, value, accuracy: 0.001)
            print("PHOTO-METERING-PHOTO user=\(userEV) correction=\(correction) device=\(deviceBias) fileEXIF=\(value) captureSeconds=\(CACurrentMediaTime()-started)")
        }
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(1200))
        model.manualExposure = true
        camera.setExposure(iso: 100, seconds: 1.0/60, bias: 0)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.usesPhotoMeteringReadout)
        camera.submitPhotoMeteringSampleForTesting(mean: 0.9, centerRatio: 4)
        let manual = await withCheckedContinuation { c in camera.meteringStateForTesting { _,_,extra,_ in c.resume(returning:extra) } }
        XCTAssertEqual(manual, 0)
        XCTAssertNotNil(camera.photoMeteringReadout.suggestion)
        for (iso, seconds) in [(100.0, 1.0/60), (200.0, 1.0/60), (200.0, 1.0/30)] {
            camera.setExposure(iso: iso, seconds: seconds, bias: 0)
            try await Task.sleep(for: .milliseconds(200))
            camera.submitPhotoMeteringSampleForTesting(mean: 0.36, centerRatio: 4)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let actual = await withCheckedContinuation { c in camera.photoMeteringManualExposureForTesting { c.resume(returning: ($0,$1)) } }
            XCTAssertEqual(actual.0, iso, accuracy: 2)
            XCTAssertEqual(actual.1, seconds, accuracy: 0.0002)
            XCTAssertNotNil(camera.photoMeteringReadout.suggestion)
            XCTAssertFalse(model.usesPhotoMeteringReadout)
            print("GLOBAL-METERING-MANUAL iso=\(actual.0) seconds=\(actual.1) suggestion=\(camera.photoMeteringReadout.suggestion ?? .nan)；只读建议未写曝光")
        }
    }

    func testHighlightMeteringCapturesHEIFProWithHDRAndAdaptiveRecovery() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.photoFormat = .heifPro
        model.photoResolution = .standard
        model.metering = .highlight
        model.ev = 0
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.hdr = true
        model.setAdaptiveHighDynamic(true)
        camera.setExposure(iso: nil, seconds: nil, bias: 0)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertTrue(model.photoOptions.hdr)
        XCTAssertTrue(model.photoOptions.adaptiveHighDynamic)
        let highlights = Array(repeating: 0.18, count: 850) + Array(repeating: 1.0, count: 150)
        camera.submitPhotoMeteringSampleForTesting(mean: 0.30, highlights: highlights)
        let compensation = await withCheckedContinuation { c in
            camera.meteringStateForTesting { _, _, correction, _ in c.resume(returning: correction) }
        }
        XCTAssertLessThan(compensation, -0.1)
        let done = expectation(description: "HEIF Pro HDR")
        let old = camera.onCaptureCompleted
        defer { camera.onCaptureCompleted = old }
        var result: CapturedPhoto?
        camera.onCaptureCompleted = { result = $0; done.fulfill() }
        let start = CACurrentMediaTime()
        camera.capture(flashMode: .off, options: model.photoOptions)
        await fulfillment(of: [done], timeout: 40)
        let photo = try XCTUnwrap(result, camera.message ?? "拍摄失败")
        let heif = try XCTUnwrap(photo.resources.first { !$0.alternate })
        let source = try XCTUnwrap(CGImageSourceCreateWithData(heif.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let recipe = try XCTUnwrap(RAWDevelopmentRecipe.read(properties))
        XCTAssertEqual(recipe.rawDevelopment?.hdr, true)
        XCTAssertEqual(recipe.rawDevelopment?.adaptive, true)
        XCTAssertEqual(photo.diagnostics?.parameters?.meteringMode, CameraMetering.highlight.rawValue)
        XCTAssertNotNil(photo.resources.first { $0.alternate && $0.filename.hasSuffix(".dng") })
        HDRImageAssertions.assertHDR(source, "高光保护＋高动态")
        print("PHOTO-METERING-HDR correction=\(compensation) captureSeconds=\(CACurrentMediaTime() - start)")
    }

    /// 读取自然取景的判断输入；不注入亮度、不拍摄，区分没重算和重算后同值。
    func testObserveNaturalPhotoMetering() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let audit = SessionRuntimeErrorAudit()
        defer { model.camera.onPhotoMeteringObservationForTesting = nil; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.photoFormat = .heifPro; model.metering = .centerWeighted
        model.camera.setExposure(iso: nil, seconds: nil, bias: 0)
        var samples = [String]()
        model.camera.onPhotoMeteringObservationForTesting = { samples.append($0) }
        try await Task.sleep(for: .seconds(8))
        XCTAssertGreaterThanOrEqual(samples.count, 12)
        for sample in samples { print("GLOBAL-NATURAL \(sample)") }
    }

    /// 真机托管布局验证独立 EV 窗口隐藏，直方图位置稳定。
    func testHistogramWithoutMeteringPanelAcrossRatiosAndOrientations() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        defer { model.setCameraActive(false) }
        model.photoFormat = .heifPro
        model.metering = .centerWeighted
        model.showHistogram = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }

        var layoutTimes = [Double]()
        for width in [CGFloat(390), window.bounds.width] {
            for ratio in FrameRatio.allCases {
                model.ratio = ratio
                for angle in [0.0, 90, -90, 180] {
                    host.rootView = AnyView(CameraViewfinderTestHost(model: model, camera: model.camera)
                        .environment(\.captureControlAngle, angle)
                        .frame(width: width))
                    try await Task.sleep(for: .milliseconds(60))
                    host.view.setNeedsLayout()
                    let start = CACurrentMediaTime()
                    host.view.layoutIfNeeded()
                    layoutTimes.append((CACurrentMediaTime() - start) * 1000)
                    let preview = model.previewFrameForTesting.insetBy(dx: -1, dy: -1)
                    let histogram = try XCTUnwrap(model.captureButtonFramesForTesting["histogram"])
                    XCTAssertTrue(preview.contains(histogram), "\(ratio), \(angle): \(histogram) outside \(preview)")
                    XCTAssertNil(model.captureButtonFramesForTesting["metering.compensation"])
                }
            }
        }

        let original = try XCTUnwrap(model.captureButtonFramesForTesting["histogram"])
        for metering in [CameraMetering.highlight, .system, .spot, .centerWeighted, .highlight] {
            model.metering = metering
            for showHistogram in [true, false, true] {
                model.showHistogram = showHistogram
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNil(model.captureButtonFramesForTesting["metering.compensation"])
                if showHistogram {
                    let histogram = try XCTUnwrap(model.captureButtonFramesForTesting["histogram"])
                    XCTAssertEqual(histogram.minX, original.minX, accuracy: 1)
                    XCTAssertEqual(histogram.minY, original.minY, accuracy: 1)
                } else {
                    XCTAssertNil(model.captureButtonFramesForTesting["histogram"])
                }
            }
        }

        layoutTimes.sort()
        print("PHOTO-METERING-HISTOGRAM-LAYOUT n=\(layoutTimes.count) medianMs=\(layoutTimes[layoutTimes.count / 2]) maxMs=\(layoutTimes.last ?? 0)；托管视图布局耗时，非帧率测量")
    }
}
