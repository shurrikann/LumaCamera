import XCTest
import UIKit
@testable import LumaCamera

@MainActor
final class HEIFProMeteringScopeTests: XCTestCase {
    func testOnlyPhotoHEIFProUsesSelectedMeteringAndRetainsSelection() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        defer { model.setCameraActive(false) }
        for selected in CameraMetering.allCases {
            model.metering = selected
            for format in PhotoFileFormat.allCases {
                model.photoFormat = format
                XCTAssertEqual(model.effectiveMetering, format == .heifPro ? selected : .system)
                XCTAssertEqual(model.metering, selected, "普通格式不能擦掉Pro的已选测光方式")
            }
            model.photoFormat = .heifPro
            model.setCaptureKind(.video)
            XCTAssertEqual(model.effectiveMetering, .system)
            model.setCaptureKind(.photo)
            XCTAssertEqual(model.effectiveMetering, selected)
        }
    }

    /// 真机验证：制造可重复的负补偿，再检查切出Pro、恢复参数、快速往返都不会带入普通格式。
    func testPhysicalFormatChangesClearGlobalBiasAndRestoreProSelection() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let runtime = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish() }
        model.hdr = false
        model.metering = .global
        model.ev = 0
        func state() async -> (CameraMetering, Float, Float, Float) {
            await withCheckedContinuation { c in camera.meteringStateForTesting { c.resume(returning: ($0,$1,$2,$3)) } }
        }
        var times = [Double]()
        for mode in [CameraShootingMode.auto, .manual] {
            model.setMode(mode)
            try await Task.sleep(for: .milliseconds(1200))
            model.manualExposure = false
            camera.setExposure(iso: nil, seconds: nil, bias: 0)
            for _ in 0..<3 {
                model.photoFormat = .heifPro
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                camera.submitGlobalMeteringSampleForTesting(mean: 0.9)
                let pro = await state()
                XCTAssertEqual(pro.0, .global); XCTAssertEqual(pro.1, 0)
                XCTAssertLessThan(pro.2, 0, "应先实际制造全局负补偿")
                for format in PhotoFileFormat.allCases where format != .heifPro {
                    let start = CACurrentMediaTime()
                    model.photoFormat = format
                    var value = await state()
                    for _ in 0..<100 {
                        if abs(value.3) < 0.001 { break }
                        try await Task.sleep(for: .milliseconds(20))
                        value = await state()
                    }
                    times.append(CACurrentMediaTime() - start)
                    XCTAssertEqual(value.0, .system, "\(format)")
                    XCTAssertEqual(value.1, 0); XCTAssertEqual(value.2, 0)
                    XCTAssertEqual(value.3, 0, accuracy: 0.001, "硬件不能残留Pro全局补偿：\(format)")
                    camera.submitGlobalMeteringSampleForTesting(mean: 0.9)
                    let late = await state()
                    XCTAssertEqual(late.2, 0, "旧预览亮度样本不可再次给普通格式加补偿")
                }
                // 复用原恢复路径，不允许恢复代码绕过格式限制重新启用全局测光。
                model.restoreDeviceParametersForTesting()
                do { let value = await state(); XCTAssertEqual(value.0, .system) }
                model.photoFormat = .heifPro; model.photoFormat = .heif; model.photoFormat = .heifPro; model.photoFormat = .jpeg
                do { let value = await state(); XCTAssertEqual(value.0, .system) }
                model.photoFormat = .heifPro
                do { let value = await state(); XCTAssertEqual(value.0, .global) }
            }
        }
        model.photoFormat = .heifPro
        model.metering = .spot
        do { let value = await state(); XCTAssertEqual(value.0, .spot) }
        model.photoFormat = .heif
        do { let value = await state(); XCTAssertEqual(value.0, .system) }
        model.photoFormat = .heifPro
        do { let value = await state(); XCTAssertEqual(value.0, .spot) }
        print("PRO-METERING-SCOPE samples=\(times.count) maxHardwareReadbackSeconds=\(times.max() ?? 0)；从切换属性到设备bias读回为零，包含等待生效，不是画面稳定耗时/帧率")
        XCTAssertNil(camera.message)
    }
}
