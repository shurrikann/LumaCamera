import XCTest
import Combine
import AVFoundation
import UIKit
import ImageIO
@testable import LumaCamera

/// 分别记录硬件切回自动、下一次数字读数和下一帧预览；不把AE/AWB/AF最终收敛误称为瞬时完成。
final class ManualAutoRecoveryPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 覆盖普通M挡硬件最慢快门，而不是只用半秒曝光推断一秒曝光的响应。
    @MainActor func testSlowestOrdinaryShutterReturnToAutoLatency() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let preferences = model.preferences, smooth = model.smoothPreview
        UIApplication.shared.isIdleTimerDisabled = true
        camera.photoPhaseTracingForTesting = true
        defer { camera.photoPhaseTracingForTesting = false; model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        }
        func wait(_ label:String,_ predicate:() async -> Bool) async throws {
            let end = CACurrentMediaTime()+12
            while CACurrentMediaTime()<end { if await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
            XCTFail(label); throw CancellationError()
        }
        model.setCameraActive(true)
        try await wait("相机未准备") { camera.ready && camera.preview != nil }
        model.setMode(.manual)
        try await wait("M挡未准备") { await state()?.engineManual == true && camera.ready }
        XCTAssertFalse(model.nightModeEnabled); XCTAssertFalse(model.slowShutterEnabled)
        model.parameter = .shutter
        let requested = min(1,pow(2,model.parameterRange.upperBound))
        for assisted in [false,true] { for sample in 0..<3 {
            model.smoothPreview = assisted; model.manualExposure = true
            model.iso = 100; model.shutter = log2(requested); model.applyExposure()
            try await wait("最低快门未应用") {
                guard let s = await state() else { return false }
                return assisted ? s.previewExposureAssistEnabled : s.exposureMode == .custom && abs(s.seconds-requested)<0.003
            }
            // 覆盖长曝光帧内不同的点击时刻。
            try await Task.sleep(for:.milliseconds(2500+[150,450,750][sample]))
            var automaticReadings = [Double](), previewTimes = [Double]()
            let readingsToken = camera.$readings.dropFirst().sink { values in
                if values?.customExposure == false, (values?.seconds ?? 10)<requested*0.75 { automaticReadings.append(CACurrentMediaTime()) }
            }
            let previewToken = camera.$preview.dropFirst().sink { _ in previewTimes.append(CACurrentMediaTime()) }
            defer { readingsToken.cancel(); previewToken.cancel() }
            let start = CACurrentMediaTime(), oldFrame = camera.previewFrameTimeForTesting
            model.activateParameterAuto()
            XCTAssertFalse(model.manualExposure)
            try await wait("未恢复真实AE") {
                guard let s = await state() else { return false }
                return s.exposureMode == .continuousAutoExposure && !s.engineCustom
            }
            let hardware = CACurrentMediaTime()-start
            try await wait("未收到自动读数") { !automaticReadings.isEmpty }
            let reading = automaticReadings[0]-start
            if !assisted {
                XCTAssertLessThan(reading,2.0,"应用定向回归预算：一秒快门稳定后恢复自动新读数不应再次超过2秒；非平台保证")
            }
            try await wait("无新预览") { camera.previewFrameTimeForTesting>oldFrame }
            let nextFrame = CACurrentMediaTime()-start
            try await Task.sleep(for:.seconds(1))
            let after = await state()
            let points = [start]+previewTimes
            let longestGap = zip(points,points.dropFirst()).map { $1-$0 }.max() ?? -1
            print("SLOWEST-AUTO sample=\(sample) assist=\(assisted) settled=true requested=\(requested) hardware=\(hardware) autoReading=\(reading) newPreviewUpperBound=\(nextFrame) actualSeconds=\(after?.seconds ?? -1) longestPublicationGap=\(longestGap) publications=\(previewTimes.count)")
        } }
    }

    /// 检查会话恢复不丢WB/对焦锁、即刻拍摄不误用旧曝光，取消/快速反向请求能最终收敛。
    @MainActor func testLongExposureAutoReturnKeepsLocksCapturesAndCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let preferences = model.preferences, smooth = model.smoothPreview
        let originalCallback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.onCaptureCompleted = originalCallback; model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        }
        func wait(_ label:String,_ predicate:() async -> Bool) async throws {
            let end = CACurrentMediaTime()+15
            while CACurrentMediaTime()<end { if await predicate() { return }; try await Task.sleep(for:.milliseconds(15)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func capture(_ format:PhotoFileFormat) async throws -> CapturedPhoto {
            let done = expectation(description:"恢复交接真实照片")
            var result:CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; done.fulfill() }
            camera.capture(flashMode:.off,options:PhotoOptions(format:format))
            await fulfillment(of:[done],timeout:35)
            let photo = try XCTUnwrap(result,camera.message ?? "没有返回真实照片")
            try await wait("拍后任务未清空") { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            return photo
        }
        func exposure(_ photo:CapturedPhoto) throws -> (Double,Double) {
            let data = try XCTUnwrap(photo.resources.first?.data)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
            return (try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue),
                    try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double))
        }
        model.setCameraActive(true)
        try await wait("相机未准备") { camera.ready && camera.preview != nil }
        model.setMode(.manual); model.smoothPreview = false
        try await wait("M挡未准备") { await state()?.engineManual == true && camera.ready }
        model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 8; model.applyWhiteBalance()
        model.manualFocus = true; model.focus = 0.45; camera.setFocus(position:0.45)
        model.manualExposure = true; model.iso = 100; model.shutter = 0; model.applyExposure()
        try await wait("一秒曝光未应用") { abs((await state()?.seconds ?? 0)-1)<0.002 }
        let beforeSnapshot = await state()
        let before = try XCTUnwrap(beforeSnapshot)
        let manual = try exposure(try await capture(.jpeg))
        XCTAssertEqual(manual.0,100,accuracy:2); XCTAssertEqual(manual.1,1,accuracy:0.002)
        model.parameter = .shutter; model.activateParameterAuto()
        let automatic = try exposure(try await capture(.heif))
        XCTAssertLessThan(automatic.1,0.5,"交接后立即拍摄不能还使用旧的一秒曝光")
        let afterSnapshot = await state()
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(after.exposureMode,.continuousAutoExposure)
        XCTAssertEqual(after.whiteBalanceMode,.locked); XCTAssertEqual(after.focusMode,.locked)
        XCTAssertEqual(after.lensPosition,before.lensPosition,accuracy:0.01)
        XCTAssertEqual(after.gains.redGain,before.gains.redGain,accuracy:0.02)
        XCTAssertEqual(after.gains.greenGain,before.gains.greenGain,accuracy:0.02)
        XCTAssertEqual(after.gains.blueGain,before.gains.blueGain,accuracy:0.02)
        XCTAssertEqual(model.mode,.manual); XCTAssertFalse(model.manualExposure)
        XCTAssertTrue(model.manualFocus); XCTAssertTrue(model.manualWB)
        // 快速反向请求保留最后一次用户意图；随后再验1秒手动真实文件，而非只读数值。
        for _ in 0..<5 {
            model.manualExposure = true; model.iso = 100; model.shutter = 0; model.applyExposure()
            model.activateParameterAuto()
            model.manualExposure = true; model.iso = 200; model.shutter = log2(0.25); model.applyExposure()
        }
        try await wait("快速反向未保留最后的手动值") {
            guard let s = await state() else { return false }
            return s.engineCustom && s.exposureMode == .custom && abs(s.seconds-0.25)<0.002 && abs(s.iso-200)<2
        }
        let returned = try exposure(try await capture(.heif))
        XCTAssertEqual(returned.0,200,accuracy:2); XCTAssertEqual(returned.1,0.25,accuracy:0.002)
        model.iso = 100; model.shutter = 0; model.applyExposure()
        try await wait("取消检查前未到一秒") { abs((await state()?.seconds ?? 0)-1)<0.002 }
        model.activateParameterAuto(); model.setCameraActive(false)
        try await wait("取消后会话仍运行") {
            await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: !$0) } }
        }
        model.setCameraActive(true)
        try await wait("取消后返回未出新帧") { camera.ready && camera.preview != nil }
        try await wait("返回未恢复自动") { await state()?.exposureMode == .continuousAutoExposure }
        _ = try await capture(.jpeg)
        print("LONG-AUTO-STABILITY manualEXIF=\(manual) automaticEXIF=\(automatic) finalManualEXIF=\(returned) preservedWBFocus=true reverseCycles=5 cancelReturn=true temporaryPhotos=4 noSystemPhotos=true")
    }

    /// 覆盖前后物理镜头；返回自动必须保留同一镜头、倍率和画幅，并持续交付新图像。
    @MainActor func testLongExposureReturnAcrossPhysicalLenses() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let preferences = model.preferences, smooth = model.smoothPreview
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        }
        func wait(_ label:String,_ predicate:() async -> Bool) async throws {
            let end = CACurrentMediaTime()+15
            while CACurrentMediaTime()<end { if await predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true)
        try await wait("相机未准备") { camera.ready && camera.preview != nil }
        model.setMode(.manual); model.smoothPreview = false
        try await wait("M挡未准备") { await state()?.engineManual == true }
        var seen = Set<String>(), tested = 0
        let lenses = camera.lenses.filter { !$0.device.isVirtualDevice && seen.insert($0.device.uniqueID).inserted }
        for lens in lenses {
            model.manualExposure = false; model.applyExposure()
            let previousFrame = camera.previewFrameTimeForTesting
            model.selectFocalLength(lens)
            try await wait("物理路由未出帧 \(lens.title)") {
                let s = await state()
                return camera.ready && s?.deviceID == lens.device.uniqueID && camera.previewFrameTimeForTesting>previousFrame
            }
            let routedSnapshot = await state()
            let routed = try XCTUnwrap(routedSnapshot)
            guard routed.maximumExposureSeconds>=0.5 else { print("LONG-AUTO-LENS skipped=\(lens.title) max=\(routed.maximumExposureSeconds)"); continue }
            let seconds = min(1,routed.maximumExposureSeconds)
            model.manualExposure = true; model.iso = 100; model.shutter = log2(seconds); model.applyExposure()
            try await wait("镜头长曝光未应用") {
                guard let s = await state() else { return false }
                return s.exposureMode == .custom && abs(s.seconds-seconds)<0.002
            }
            try await Task.sleep(for:.seconds(3))
            let beforeSize = try XCTUnwrap(camera.preview?.size), beforeZoom = camera.currentZoom
            let frame = camera.previewFrameTimeForTesting, start = CACurrentMediaTime()
            model.parameter = .shutter; model.activateParameterAuto()
            try await wait("镜头未恢复自动新帧") {
                guard let s = await state() else { return false }
                return s.exposureMode == .continuousAutoExposure && !s.engineCustom && camera.previewFrameTimeForTesting>frame
                    && camera.readings?.customExposure == false && (camera.readings?.seconds ?? 10)<0.125
            }
            let elapsed = CACurrentMediaTime()-start
            let afterSnapshot = await state()
            let after = try XCTUnwrap(afterSnapshot)
            XCTAssertEqual(after.deviceID,lens.device.uniqueID)
            XCTAssertEqual(camera.currentZoom,beforeZoom,accuracy:0.001)
            XCTAssertEqual(camera.preview?.size,beforeSize)
            XCTAssertEqual(model.mode,.manual); XCTAssertFalse(model.smoothPreview)
            XCTAssertLessThan(elapsed,2.0,"后续硬件可能不同；本设备定向预算不能称平台保证")
            let resumedFrame = camera.previewFrameTimeForTesting
            try await Task.sleep(for:.milliseconds(350))
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting,resumedFrame)
            tested += 1
            print("LONG-AUTO-LENS type=\(lens.device.deviceType.rawValue) position=\(lens.device.position.rawValue) seconds=\(seconds) recovery=\(elapsed) preview=\(beforeSize) zoom=\(beforeZoom) sameInput=true newFrames=true")
        }
        XCTAssertGreaterThanOrEqual(tested,3,"本机应覆盖后置三镜头；实际前置覆盖见日志")
        print("LONG-AUTO-LENS total=\(tested) noCapture=true")
    }

    /// 同一设备/会话/场景交替旧路径与优化路径，避免把隔夜光线差异写成性能收益。
    @MainActor func testSameSceneLegacyAndOptimizedLongExposureReturn() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let preferences = model.preferences, smooth = model.smoothPreview
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.setAutomaticExposureLegacyForTesting(false) { _ in }
            model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
        }
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        }
        func wait(_ label:String,_ predicate:() async -> Bool) async throws {
            let end = CACurrentMediaTime()+12
            while CACurrentMediaTime()<end { if await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
            XCTFail(label); throw CancellationError()
        }
        func policy(_ legacy:Bool) async -> Int {
            await withCheckedContinuation { c in camera.setAutomaticExposureLegacyForTesting(legacy) { c.resume(returning:$0) } }
        }
        model.setCameraActive(true)
        try await wait("相机未准备") { camera.ready && camera.preview != nil }
        model.setMode(.manual); model.smoothPreview = false; model.parameter = .shutter
        try await wait("M挡未准备") { await state()?.engineManual == true }
        var baseline = [Double](), optimized = [Double]()
        for index in 0..<3 { for legacy in [true,false] {
            let beforeCount = await policy(legacy)
            model.manualExposure = true; model.iso = 100; model.shutter = 0; model.applyExposure()
            try await wait("一秒曝光未设置") {
                guard let s = await state() else { return false }
                return s.exposureMode == .custom && abs(s.seconds-1)<0.002
            }
            try await Task.sleep(for:.milliseconds(2500))
            // 以一张实际到达的长曝光帧作时间锚点，再在相同偏移处操作。
            let anchor = camera.previewFrameTimeForTesting
            try await wait("长曝光无新帧") { camera.previewFrameTimeForTesting>anchor }
            try await Task.sleep(for:.milliseconds([150,450,750][index]))
            var readings = [Double]()
            let token = camera.$readings.dropFirst().sink { value in
                if value?.customExposure == false, (value?.seconds ?? 10)<0.125 { readings.append(CACurrentMediaTime()) }
            }
            let start = CACurrentMediaTime()
            model.activateParameterAuto()
            try await wait("未收到新的自动读数") { !readings.isEmpty }
            token.cancel()
            let elapsed = readings[0]-start
            let count = await policy(legacy)
            XCTAssertEqual(count-beforeCount,legacy ? 0 : 1)
            XCTAssertFalse(model.smoothPreview)
            if legacy { baseline.append(elapsed) } else { optimized.append(elapsed) }
            print("LONG-AUTO-AB legacy=\(legacy) sample=\(index) freshAutomaticReading=\(elapsed) sameSession=true realExposurePreview=true restarts=\(count-beforeCount)")
        } }
        let medianBefore = baseline.sorted()[1], medianAfter = optimized.sorted()[1]
        XCTAssertLessThan(medianAfter,medianBefore*0.75,"同场景3对样本中位数须有明确收益；这是应用回归预算，不是平台承诺")
        print("LONG-AUTO-AB-SUMMARY baseline=\(baseline) optimized=\(optimized) medianRatio=\(medianAfter/medianBefore) pairedSamples=3 noSystemPhotos=true")
    }

    @MainActor func testAllManualParametersReturnToAutomaticAndPublishFreshValues() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let preferences = model.preferences
        let smooth = model.smoothPreview
        UIApplication.shared.isIdleTimerDisabled = true
        camera.photoPhaseTracingForTesting = true
        defer { camera.photoPhaseTracingForTesting = false; model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        }
        func wait(_ label: String,_ predicate: () async -> Bool) async throws {
            let end = CACurrentMediaTime()+15
            while CACurrentMediaTime()<end { if await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        try await wait("相机未出帧") { camera.ready && camera.preview != nil }
        model.setMode(.manual)
        try await wait("M挡未准备好") { let s = await state(); return camera.ready && s?.engineManual == true }
        var summaries = [String]()
        for assisted in [false,true] {
            model.smoothPreview = assisted
            for parameter in [CameraParameter.shutter,.iso,.wb,.tint,.focus] {
                model.parameter = parameter
                switch parameter {
                case .shutter,.iso:
                    model.manualExposure = true; model.iso = 100; model.shutter = log2(0.5); model.applyExposure()
                    try await wait("手动曝光未应用") {
                        guard let s = await state() else { return false }
                        return assisted ? s.previewExposureAssistEnabled : s.exposureMode == .custom && abs(s.seconds-0.5)<0.002
                    }
                case .wb,.tint:
                    model.manualWB = true; model.wb = 2800; model.whiteBalanceTint = 30; model.applyWhiteBalance()
                    try await wait("手动白平衡未应用") { await state()?.whiteBalanceMode == .locked }
                case .focus:
                    model.manualFocus = true; model.focus = 0.2; camera.setFocus(position:0.2)
                    try await wait("手动对焦未应用") { await state()?.focusMode == .locked }
                case .ev: break
                }
                try await Task.sleep(for:.milliseconds(150))
                var publications = [Double]()
                let token = camera.$readings.dropFirst().sink { _ in publications.append(CACurrentMediaTime()) }
                let started = CACurrentMediaTime(), previousFrame = camera.previewFrameTimeForTesting
                model.activateParameterAuto()
                XCTAssertTrue(model.parameterAutomatic)
                try await wait("硬件未恢复自动") {
                    guard let s = await state() else { return false }
                    switch parameter {
                    case .shutter,.iso: return s.exposureMode == .continuousAutoExposure && !s.engineCustom
                    case .wb,.tint: return s.whiteBalanceMode == .continuousAutoWhiteBalance
                    case .focus: return s.focusMode == .continuousAutoFocus
                    case .ev: return true
                    }
                }
                let hardwareSeconds = CACurrentMediaTime()-started
                try await wait("自动参数未回传") { !publications.isEmpty }
                let publicationSeconds = publications[0]-started
                try await wait("自动模式预览未恢复") { camera.previewFrameTimeForTesting>previousFrame }
                let freshFrameSeconds = CACurrentMediaTime()-started
                token.cancel()
                let afterSnapshot = await state()
                let after = try XCTUnwrap(afterSnapshot)
                XCTAssertTrue(model.currentParameterNumber.isFinite)
                summaries.append("\(parameter): assist=\(assisted) hardware=\(hardwareSeconds) reading=\(publicationSeconds) freshPreview=\(freshFrameSeconds) maxFrame=\(after.activeMaxFrameSeconds) minFrame=\(after.activeMinFrameSeconds)")
            }
        }
        // 连续手动/自动请求以及退出/返回，最后一次自动状态应保留。
        for _ in 0..<20 {
            model.parameter = .iso; model.editableParameterBinding.wrappedValue = 200; model.activateParameterAuto()
            model.parameter = .wb; model.editableParameterBinding.wrappedValue = 4500; model.activateParameterAuto()
            model.parameter = .focus; model.editableParameterBinding.wrappedValue = 0.3; model.activateParameterAuto()
        }
        try await wait("快速切换最终未恢复自动") {
            guard let s = await state() else { return false }
            return !s.engineCustom && s.exposureMode == .continuousAutoExposure
                && s.whiteBalanceMode == .continuousAutoWhiteBalance && s.focusMode == .continuousAutoFocus
        }
        model.setCameraActive(false)
        try await Task.sleep(for:.milliseconds(300)); model.setCameraActive(true)
        try await wait("返回相机未恢复") { camera.ready && camera.preview != nil }
        XCTAssertFalse(model.manualExposure); XCTAssertFalse(model.manualWB); XCTAssertFalse(model.manualFocus)
        // 快速回传窗口必须自行结束，不能为了参数手感永久提高采样负载。
        try await Task.sleep(for:.seconds(2))
        var quietTimes = [Double]()
        let quietToken = camera.$readings.dropFirst().sink { _ in quietTimes.append(CACurrentMediaTime()) }
        try await Task.sleep(for:.milliseconds(1200)); quietToken.cancel()
        XCTAssertGreaterThanOrEqual(quietTimes.count,1)
        XCTAssertLessThanOrEqual(quietTimes.count,5)
        print("MANUAL-AUTO-QUIET duration=1.2 readings=\(quietTimes.count) afterBurstExpired=true")
        print("MANUAL-AUTO-RECOVERY samples=\(summaries.count) measurements=\(summaries) rapidCycles=20 systemPhotosWrites=0")
    }
    #endif
}
