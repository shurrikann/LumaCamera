import XCTest
import UIKit
import SwiftUI
import ImageIO
@testable import LumaCamera

@MainActor final class GlobalMeteringPhysicalTests: XCTestCase {
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
        model.metering = .global; model.ev = 0
        camera.setExposure(iso: nil, seconds: nil, bias: 0)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.submitGlobalMeteringSampleForTesting(mean: 0.36)
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
        XCTAssertTrue(camera.globalMeteringReadout.automatic)
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
            XCTAssertNotNil(parameters.globalMeteringBiasEV); XCTAssertNotNil(parameters.deviceExposureBiasEV)
            XCTAssertEqual(parameters.exifExposureBiasEV ?? .nan, value, accuracy: 0.001)
            print("GLOBAL-METERING-PHOTO user=\(userEV) correction=\(parameters.globalMeteringBiasEV ?? .nan) device=\(parameters.deviceExposureBiasEV ?? .nan) fileEXIF=\(value) captureSeconds=\(CACurrentMediaTime()-started)")
        }
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(1200))
        model.manualExposure = true
        camera.setExposure(iso: 100, seconds: 1.0/60, bias: 0)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(model.usesGlobalMeteringReadout)
        camera.submitGlobalMeteringSampleForTesting(mean: 0.9)
        let manual = await withCheckedContinuation { c in camera.meteringStateForTesting { _,_,extra,_ in c.resume(returning:extra) } }
        XCTAssertEqual(manual, 0)
        XCTAssertNotNil(camera.globalMeteringReadout.suggestion)
        for (iso, seconds) in [(100.0, 1.0/60), (200.0, 1.0/60), (200.0, 1.0/30)] {
            camera.setExposure(iso: iso, seconds: seconds, bias: 0)
            try await Task.sleep(for: .milliseconds(200))
            camera.submitGlobalMeteringSampleForTesting(mean: 0.36)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let actual = await withCheckedContinuation { c in camera.globalMeteringManualExposureForTesting { c.resume(returning: ($0,$1)) } }
            XCTAssertEqual(actual.0, iso, accuracy: 2)
            XCTAssertEqual(actual.1, seconds, accuracy: 0.0002)
            XCTAssertNotNil(camera.globalMeteringReadout.suggestion)
            XCTAssertFalse(model.usesGlobalMeteringReadout)
            print("GLOBAL-METERING-MANUAL iso=\(actual.0) seconds=\(actual.1) suggestion=\(camera.globalMeteringReadout.suggestion ?? .nan)；只读建议未写曝光")
        }
    }

    /// 读取自然取景的判断输入；不注入亮度、不拍摄，区分没重算和重算后同值。
    func testObserveNaturalGlobalMetering() async throws {
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        let audit = SessionRuntimeErrorAudit()
        defer { model.camera.onGlobalMeteringObservationForTesting = nil; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.photoFormat = .heifPro; model.metering = .global
        model.camera.setExposure(iso: nil, seconds: nil, bias: 0)
        var samples = [String]()
        model.camera.onGlobalMeteringObservationForTesting = { samples.append($0) }
        try await Task.sleep(for: .seconds(8))
        XCTAssertGreaterThanOrEqual(samples.count, 12)
        for sample in samples { print("GLOBAL-NATURAL \(sample)") }
    }

    /// 真机托管布局验证读数在预览中与直方图并排，并覆盖比例、方向与显示状态切换。
    func testMeteringPanelLayoutAcrossRatiosAndOrientations() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        defer { model.setCameraActive(false) }
        model.photoFormat = .heifPro
        model.metering = .global
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
                    let readout = try XCTUnwrap(model.captureButtonFramesForTesting["metering.compensation"])
                    XCTAssertTrue(preview.contains(readout), "\(ratio), \(angle): \(readout) outside \(preview)")
                    XCTAssertEqual(readout.minX, histogram.maxX + 6, accuracy: 1)
                    XCTAssertEqual(readout.minY, histogram.minY, accuracy: 1)
                }
            }
        }

        let histogram = try XCTUnwrap(model.captureButtonFramesForTesting["histogram"])
        model.showHistogram = false
        model.showHistogram = true
        model.showHistogram = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.captureButtonFramesForTesting["histogram"])
        let standalone = try XCTUnwrap(model.captureButtonFramesForTesting["metering.compensation"])
        XCTAssertEqual(standalone.minX, histogram.minX, accuracy: 1)
        XCTAssertEqual(standalone.minY, histogram.minY, accuracy: 1)

        for metering in [CameraMetering.system, .spot] {
            for showHistogram in [false, true] {
                model.metering = .global
                model.showHistogram = showHistogram
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertNotNil(model.captureButtonFramesForTesting["metering.compensation"])

                model.metering = metering
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertNil(model.captureButtonFramesForTesting["metering.compensation"])
                XCTAssertEqual(model.captureButtonFramesForTesting["histogram"] != nil, showHistogram)
            }
        }

        model.metering = .global
        model.photoFormat = .heif
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(model.captureButtonFramesForTesting["histogram"])
        XCTAssertNil(model.captureButtonFramesForTesting["metering.compensation"])

        model.photoFormat = .heifPro
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(model.captureButtonFramesForTesting["metering.compensation"])

        model.toolbarPanel = .tone
        host.rootView = AnyView(VStack {
            CameraView(model: model).toolbarOptionsPanel(availableWidth: window.bounds.width - 16)
            Spacer()
        })
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(model.captureButtonFramesForTesting["videoOptionsPanel"])
        XCTAssertNil(model.captureButtonFramesForTesting["metering.compensation"])

        layoutTimes.sort()
        print("GLOBAL-METERING-LAYOUT n=\(layoutTimes.count) medianMs=\(layoutTimes[layoutTimes.count / 2]) maxMs=\(layoutTimes.last ?? 0)；托管视图布局耗时，非帧率测量")
    }
}
