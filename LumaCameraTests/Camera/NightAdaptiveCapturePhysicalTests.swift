import XCTest
import AVFoundation
import UIKit
import ImageIO
import SwiftUI
@testable import LumaCamera

/// 用受控的测光/运动输入测试真实 3/6/9 帧硬件请求；不把注入条件当作自然环境触发验证。
final class NightAdaptiveCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testNightPreviewRevealMetadataAndCancellationOnPhysicalCamera() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            model.toggleNightMode()
            try await Task.sleep(for:.milliseconds(200))
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let look = await withCheckedContinuation { c in camera.captureLookForTesting { c.resume(returning:$0) } }
            XCTAssertTrue(look.nightPreviewAssist)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let prior = scene.windows.first { $0.isKeyWindow }
            let host = UIHostingController(rootView:NightPreviewPhysicalHost(model:model,camera:camera))
            let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
            try await Task.sleep(for:.milliseconds(500))
            try await self.wait { camera.ready && camera.preview != nil }
            let tools = model.captureButtonFramesForTesting["tools"], mode = model.captureButtonFramesForTesting["mode"]
            camera.nightExposureIndexForTesting = 32
            camera.nightAutomaticExposureForTesting = .init(seconds:0.125,iso:200)
            camera.nightMotionForTesting = .stable
            var progress = [Double](), ids = Set<UUID>()
            let subscription = camera.$nightPreviewReveal.sink { value in
                if let value { progress.append(value.progress); ids.insert(value.id) }
            }
            defer { subscription.cancel() }
            for index in 0..<2 {
                let result = try await self.capture(camera,format:index == 0 ? .jpeg:.heif)
                XCTAssertNotNil(camera.nightPreviewReveal?.finalImage)
                XCTAssertEqual(camera.nightPreviewReveal?.progress,1)
                XCTAssertEqual(model.captureButtonFramesForTesting["tools"],tools)
                XCTAssertEqual(model.captureButtonFramesForTesting["mode"],mode)
                let attachment = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) })
                attachment.name = "Night-Reveal-Final-\(index)"; attachment.lifetime = .keepAlways; self.add(attachment)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(result.resources.first?.data) as CFData,nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
                let counts = try XCTUnwrap(exif[kCGImagePropertyExifSourceImageNumberOfCompositeImage as String] as? [NSNumber])
                XCTAssertEqual(counts.first?.intValue,3); XCTAssertGreaterThanOrEqual(counts.last!.intValue,2)
                let times = try XCTUnwrap(exif[kCGImagePropertyExifSourceExposureTimesOfCompositeImage as String] as? [NSNumber])
                XCTAssertEqual(times.suffix(3).map(\.doubleValue),[0.0625,0.125,0.125])
                try await self.wait { camera.nightPreviewReveal == nil }
            }
            XCTAssertEqual(ids.count,2); XCTAssertTrue(progress.contains { $0>0 && $0<1 })
            camera.nightExposureIndexForTesting = 512
            let appended = self.expectation(description:"Cancel reveal during additional batch")
            camera.onNightBatchSubmittedForTesting = { count in
                if count == 6 { model.setCameraActive(false); appended.fulfill() }
            }
            var options = PhotoOptions(format:.jpeg); options.nightMode = true
            camera.capture(flashMode:.off,options:options)
            await self.fulfillment(of:[appended],timeout:30)
            XCTAssertNil(camera.nightPreviewReveal)
            camera.onNightBatchSubmittedForTesting = nil
            try await self.wait { camera.pendingPhotoCount == 0 }
            print("NIGHT-PREVIEW-REVEAL physicalCaptures=2 progressSamples=\(progress.count) distinctCaptures=\(ids.count) controlsStable=true cancellationClears=true noPhotosWrites=true")
        }
    }

    /// 显式注入较短的安全曝光，仅验证真实硬件遵循A挡请求，不冒充暗光画质对照。
    @MainActor func testAutomaticNightUsesPlannedExposureAndRepeatedCaptureReleasesTasks() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightExposureIndexForTesting = 32
            defer { camera.nightAutomaticExposureForTesting = nil }
            var timings = [Double]()
            var heldBatches = [Bool]()
            var batchPublicationCounts = [Int]()
            camera.onNightBatchSubmittedForTesting = { _ in
                heldBatches.append(camera.nightPreviewHoldForTesting)
                batchPublicationCounts.append(camera.previewPublicationTimesForTestingSnapshot.count)
            }
            defer { camera.onNightBatchSubmittedForTesting = nil }
            for (sample, format) in [PhotoFileFormat.jpeg, .heif, .heif].enumerated() {
                let target = sample == 2 ? 6 : 3
                let plan: NightAdaptiveCapturePolicy.Exposure = sample == 1
                    ? .init(seconds: 1, iso: 3200) : .init(seconds: 0.125, iso: 200)
                camera.nightAutomaticExposureForTesting = plan
                camera.nightExposureIndexForTesting = target == 6 ? 128 : 32
                camera.nightMotionForTesting = .stable
                let beforeRoute = await withCheckedContinuation { c in camera.nightRouteIdentityForTesting { c.resume(returning: $0) } }
                var exposures = [(Int, Double, Double)]()
                camera.onNightSourceForTesting = { data, sequence in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
                          let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
                          let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue else { return }
                    exposures.append((sequence, seconds, iso))
                }
                let started = CACurrentMediaTime()
                let batchStart = heldBatches.count
                let result = try await self.capture(camera, format: format)
                timings.append(CACurrentMediaTime() - started)
                XCTAssertEqual(heldBatches.count - batchStart, target == 6 ? 2 : 1)
                XCTAssertTrue(heldBatches.dropFirst(batchStart).allSatisfy { $0 })
                if target == 6 {
                    XCTAssertEqual(batchPublicationCounts[batchStart], batchPublicationCounts[batchStart + 1],
                                   "追加批次中间不能发布曝光切换帧")
                }
                XCTAssertFalse(camera.nightPreviewHoldForTesting)
                let previewBeforeResume = camera.previewFrameTimeForTesting
                try await self.wait { camera.previewFrameTimeForTesting > previewBeforeResume }
                let saved = try XCTUnwrap(result.resources.first?.data)
                let savedSource = try XCTUnwrap(CGImageSourceCreateWithData(saved as CFData, nil))
                let savedProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(savedSource, 0, nil) as? [String: Any])
                let savedEXIF = try XCTUnwrap(savedProperties[kCGImagePropertyExifDictionary as String] as? [String: Any])
                XCTAssertEqual(try XCTUnwrap((savedEXIF[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue), plan.seconds, accuracy: 0.004)
                XCTAssertEqual(try XCTUnwrap((savedEXIF[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue), plan.iso, accuracy: max(4, plan.iso * 0.02))
                XCTAssertEqual(exposures.count, target)
                for item in exposures {
                    let expected = item.0 == 1 ? plan.seconds / 2 : plan.seconds
                    XCTAssertEqual(item.1, expected, accuracy: 0.004)
                    XCTAssertEqual(item.2, plan.iso, accuracy: max(4, plan.iso * 0.02))
                }
                XCTAssertNotNil(result.diagnostics?.rows.first { $0.title == "夜景自动曝光" })
                XCTAssertEqual(model.mode, .auto)
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy && camera.ready }
                let afterRoute = await withCheckedContinuation { c in camera.nightRouteIdentityForTesting { c.resume(returning: $0) } }
                // configureConnections会正常递增代次；比较真实设备身份而非要求代次倒退。
                XCTAssertEqual(beforeRoute.split(separator: ":").dropFirst().joined(separator: ":"),
                               afterRoute.split(separator: ":").dropFirst().joined(separator: ":"),
                               "夜景结束后必须归还虚拟多摄，不滞留物理镜头")
                print("NIGHT-AUTO-HARDWARE format=\(format) sources=\(exposures) merged=\(result.diagnostics?.isNightComposite == true) seconds=\(timings.last!)")
            }
            print("NIGHT-AUTO-PERF n=3 captureCallbackSeconds=\(timings) injectedPlan=true noPhotosWrites=true")
        }
    }
    @MainActor func testManualNightPreservesExposureProductAndRangesAcrossBatches() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            model.setMode(.manual)
            try await self.wait { camera.ready && model.mode == .manual && camera.supportsNightCapture }
            // A→M 有约1秒路由稳定窗口；窗口内 applyExposure 会延后，先等稳定。
            try await Task.sleep(for: .milliseconds(1200))
            model.toggleNightMode()
            try await self.wait { model.nightModeEnabled && !model.isPreparingSubmode }
            XCTAssertEqual(model.mode,.manual,"开启夜景不能强制切回A挡")
            // 夜景会收窄手动 ISO/快门范围；等能力表落到夜景范围后再验证夹取。
            try await Task.sleep(for: .milliseconds(500))
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.manualExposure = true; model.iso = 10000; model.shutter = log2(1.0/125); model.applyExposure()
            XCTAssertEqual(model.iso,model.manualPhotoISORange.upperBound)
            XCTAssertEqual(model.shutter,model.manualPhotoShutterRange.lowerBound,accuracy:0.00001)
            let hardwareISO = try XCTUnwrap(model.hardwareControlSpecs.first { $0.id == "M." + CameraParameter.iso.rawValue })
            let hardwareShutter = try XCTUnwrap(model.hardwareControlSpecs.first { $0.id == "M." + CameraParameter.shutter.rawValue })
            XCTAssertEqual(hardwareISO.range.lowerBound,Float(model.manualPhotoISORange.lowerBound))
            XCTAssertEqual(hardwareISO.range.upperBound,Float(model.manualPhotoISORange.upperBound))
            XCTAssertEqual(hardwareShutter.range.lowerBound,Float(model.manualPhotoShutterRange.lowerBound))
            XCTAssertEqual(hardwareShutter.range.upperBound,Float(model.manualPhotoShutterRange.upperBound))
            model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 8; model.applyWhiteBalance()
            model.manualFocus = true; model.focus = 0.5; camera.setFocus(position:0.5)
            var times = [Double]()
            let cases: [(PhotoFileFormat,Double,Double,Bool,Int)] = [
                (.jpeg,400,1.0/15,false,6),(.heif,800,1.0/8,true,9),(.jpeg,100,1,true,3)]
            for (format,requestedISO,seconds,assist,target) in cases {
                model.photoFormat = format; model.smoothPreview = assist
                model.iso = requestedISO; model.shutter = log2(seconds); model.applyExposure()
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await Task.sleep(for:.milliseconds(300))
                camera.nightExposureIndexForTesting = target == 9 ? 512 : target == 6 ? 128 : 32
                camera.nightMotionForTesting = .stable
                var sourceValues = [(Double,Double)]()
                camera.onNightSourceForTesting = { data,_ in
                    if let image = CGImageSourceCreateWithData(data as CFData,nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any],
                       let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any],
                       let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
                       let seconds = exif[kCGImagePropertyExifExposureTime as String] as? Double { sourceValues.append((iso,seconds)) }
                }
                let start = CACurrentMediaTime()
                let photo = try await self.capture(camera,format:format)
                times.append(CACurrentMediaTime()-start)
                XCTAssertEqual(sourceValues.count,target)
                let requestedExposureProduct = requestedISO * seconds
                for source in sourceValues {
                    // 手动值会规范化到当前硬件可用的 ISO/快门组合，验证曝光量等价而非字面相等。
                    XCTAssertEqual(source.0 * source.1, requestedExposureProduct,
                                   accuracy: max(1, requestedExposureProduct * 0.08))
                }
                let data = try XCTUnwrap(photo.resources.first?.data)
                let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
                let outputISO = try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue)
                let outputSeconds = try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double)
                XCTAssertGreaterThan(outputISO, 0); XCTAssertGreaterThan(outputSeconds, 0)
                XCTAssertEqual(outputISO * outputSeconds, requestedExposureProduct,
                               accuracy: max(1, requestedExposureProduct * 0.08))
                XCTAssertEqual(photo.diagnostics?.parameters?.mode,"M")
                XCTAssertEqual(model.mode,.manual); XCTAssertTrue(model.manualExposure)
                XCTAssertEqual(model.iso,requestedISO); XCTAssertEqual(pow(2,model.shutter),seconds,accuracy:0.00001)
                XCTAssertEqual(model.wb,5200); XCTAssertEqual(model.whiteBalanceTint,8); XCTAssertTrue(model.manualWB); XCTAssertTrue(model.manualFocus)
                try await self.wait { !camera.shutterBusy && camera.pendingPhotoCount == 0 }
                print("NIGHT-MANUAL target=\(target) format=\(format) assist=\(assist) sources=\(sourceValues) seconds=\(times.last!) rows=\(String(describing:photo.diagnostics?.rows))")
            }
            camera.onNightSourceForTesting = nil
            print("NIGHT-MANUAL-PERFORMANCE samples=3 captureSeconds=\(times) noSystemPhotos=true")
        }
    }

    @MainActor func testNightSupportsMModeAutomaticExposureAndAMSwitching() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            // 真机渲染两种夜景图标：不可用斜线必须改变像素，不能改变按钮尺寸。
            var iconPixels = [Data]()
            for unavailable in [false,true] {
                let renderer = ImageRenderer(content:CameraView(model:model)
                    .nightIndicatorIcon(symbol:"moon.fill",color:.white,unavailable:unavailable))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.width,27); XCTAssertEqual(image.size.height,27)
                iconPixels.append(try XCTUnwrap(image.pngData()))
            }
            XCTAssertNotEqual(iconPixels[0],iconPixels[1])
            model.setMode(.manual)
            try await self.wait { camera.ready && model.mode == .manual }
            model.manualExposure = false; model.applyExposure()
            model.toggleNightMode()
            try await self.wait { model.nightModeEnabled && !model.isPreparingSubmode }
            XCTAssertNil(model.nightUnavailableReason)
            camera.nightExposureIndexForTesting = 32
            let photo = try await self.capture(camera,format:.heif)
            XCTAssertEqual(photo.diagnostics?.parameters?.mode,"M"); XCTAssertFalse(model.manualExposure)
            for _ in 0..<3 {
                model.setMode(.auto); await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait { camera.ready && model.mode == .auto }
                XCTAssertTrue(model.nightModeEnabled)
                model.setMode(.manual); await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait { camera.ready && model.mode == .manual }
                XCTAssertTrue(model.nightModeEnabled); XCTAssertNil(model.nightUnavailableReason)
            }
            model.toggleNightMode(); XCTAssertFalse(model.nightModeEnabled)
            XCTAssertEqual(model.mode,.manual)
            print("NIGHT-M-AUTO capture=1 AMCycles=3 enabledStatePreserved=true")
        }
    }

    @MainActor func testMNightNaturalTriggerAndManualExposureNormalization() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            model.setMode(.manual); model.manualExposure = false; model.applyExposure()
            try await self.wait { camera.ready && model.mode == .manual }
            model.toggleNightMode()
            try await self.wait { model.nightModeEnabled && !model.isPreparingSubmode }
            let end = CACurrentMediaTime()+12
            while !model.nightIndicatorIsTriggered && CACurrentMediaTime()<end { try await Task.sleep(for:.milliseconds(100)) }
            print("NIGHT-M-NATURAL automaticTriggered=\(model.nightIndicatorIsTriggered) reading=\(String(describing:camera.readings)) reason=\(model.nightUnavailableReason ?? "none")")
            guard model.nightIndicatorIsTriggered else { throw XCTSkip("M挡当前真实场景未达到暗光触发阈值，未冒充自然触发通过") }
            // 换手动参数后，按真实offset修正测光，不能把设定值直接当作环境亮度。
            model.manualExposure = true; model.iso = 400; model.shutter = log2(0.25)
            model.smoothPreview = false; model.applyExposure()
            try await Task.sleep(for:.seconds(2))
            XCTAssertTrue(model.nightIndicatorIsTriggered,"同一暗光环境切手动后不应误判成明亮场景")
            XCTAssertTrue(model.photoOptions.nightMode)
            let done = self.expectation(description:"M挡自然触发夜景")
            var result: CapturedPhoto?
            camera.onCaptureCompleted = { result = $0; done.fulfill() }
            model.takePhoto()
            await self.fulfillment(of:[done],timeout:45)
            let photo = try XCTUnwrap(result,camera.message ?? "M挡自然夜景未出片")
            XCTAssertEqual(photo.diagnostics?.parameters?.mode,"M")
            XCTAssertNotNil(photo.diagnostics?.rows.first { $0.title == "夜景实际采集" })
            print("NIGHT-M-NATURAL complete reading=\(String(describing:camera.readings)) rows=\(String(describing:photo.diagnostics?.rows))")
        }
    }

    @MainActor func testManualNightCancelAndReturnRetainsMExposure() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            model.setMode(.manual)
            try await self.wait { camera.ready && model.mode == .manual }
            model.toggleNightMode()
            try await self.wait { model.nightModeEnabled && !model.isPreparingSubmode }
            model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/15)
            model.smoothPreview = true; model.applyExposure()
            camera.nightExposureIndexForTesting = 512; camera.nightMotionForTesting = .stable
            var submitted = false, finished = false, result: CapturedPhoto?
            camera.onNightBatchSubmittedForTesting = { _ in submitted = true }
            camera.onCaptureCompleted = { result = $0; finished = true }
            var options = model.photoOptions; options.nightMode = true
            camera.capture(flashMode:.off,options:options)
            try await self.wait { submitted }
            model.setCameraActive(false)
            // 取消只释放任务，不交付照片；成功回调不应成为取消完成的条件。
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            XCTAssertFalse(finished, "取消组不应交付半成品")
            XCTAssertNil(result)
            model.setCameraActive(true)
            try await self.wait { camera.ready && camera.preview != nil }
            XCTAssertEqual(model.mode,.manual); XCTAssertTrue(model.manualExposure)
            XCTAssertEqual(model.iso,400); XCTAssertEqual(pow(2,model.shutter),1.0/15,accuracy:0.0001)
            camera.onNightBatchSubmittedForTesting = nil; camera.nightExposureIndexForTesting = 32
            _ = try await self.capture(camera,format:.jpeg)
            print("NIGHT-M-CANCEL cancelled=1 returnCapture=1 mode=M exposure=400,1/15 noPhotosWrites=true")
        }
    }

    @MainActor func testRepeatedCancellationDuringExposureAndQueuedCompositionNeverDelivers() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            var cancelTimes = [Double](), captureTimes = [Double]()
            for index in 0..<4 {
                let manual = index % 2 == 1, duringComposition = index >= 2
                model.setMode(manual ? .manual : .auto)
                try await self.wait { camera.ready && model.mode == (manual ? .manual : .auto) }
                if !model.nightModeEnabled { model.toggleNightMode() }
                try await self.wait { model.nightModeEnabled && !model.isPreparingSubmode }
                if manual {
                    model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/15)
                    model.applyExposure()
                }
                camera.nightAutomaticExposureForTesting = .init(seconds:0.125,iso:200)
                camera.nightExposureIndexForTesting = 32; camera.nightMotionForTesting = .stable
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let gate = DispatchSemaphore(value:0)
                defer { gate.signal() }
                if duringComposition { camera.enqueueProcessingBarrierForTesting(gate) }
                var submitted = false, cancelledCallbacks = 0
                camera.onNightBatchSubmittedForTesting = { _ in submitted = true }
                camera.onCaptureCompleted = { _ in cancelledCallbacks += 1 }
                let revision = camera.deliveredPhotoRevision
                var options = PhotoOptions(format:manual ? .heif:.jpeg); options.nightMode = true
                camera.capture(flashMode:.off,options:options)
                try await self.wait { submitted }
                if duringComposition {
                    try await self.wait { !camera.shutterBusy && camera.pendingPhotoCount == 1 }
                    let state = await withCheckedContinuation { c in camera.photoTaskStateForTesting { c.resume(returning:($0,$1,$2,$3)) } }
                    XCTAssertEqual(state.0,0,"夜景已离开硬件上下文，仍须能取消后台合成结果")
                }
                let cancelledAt = CACurrentMediaTime()
                model.setCameraActive(false)
                // 合成中的快速退出/返回/再退出也不能撤销前一请求的取消状态。
                if index == 3 { model.setCameraActive(true); model.setCameraActive(false) }
                gate.signal()
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
                cancelTimes.append(CACurrentMediaTime()-cancelledAt)
                XCTAssertEqual(cancelledCallbacks,0)
                XCTAssertEqual(camera.deliveredPhotoRevision,revision)
                XCTAssertNil(camera.nightPreviewReveal)
                XCTAssertEqual(camera.nightDeliveryCountsForTesting.active,0)
                XCTAssertEqual(camera.nightDeliveryCountsForTesting.cancelled,0)
                camera.onNightBatchSubmittedForTesting = nil
                model.setCameraActive(true)
                try await self.wait { camera.ready && camera.preview != nil && camera.canCapture() }
                var callbacks = 0, result:CapturedPhoto?
                camera.onCaptureCompleted = { result = $0; callbacks += 1 }
                let started = CACurrentMediaTime()
                camera.capture(flashMode:.off,options:options)
                try await self.wait { callbacks > 0 && camera.pendingPhotoCount == 0 }
                captureTimes.append(CACurrentMediaTime()-started)
                let photo = try XCTUnwrap(result,camera.message ?? "取消后夜景未恢复")
                let data = try XCTUnwrap(photo.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
                XCTAssertNotNil(exif[kCGImagePropertyExifSourceExposureTimesOfCompositeImage as String])
                try await Task.sleep(for:.milliseconds(300))
                XCTAssertEqual(callbacks,1); XCTAssertEqual(cancelledCallbacks,0)
                XCTAssertEqual(camera.deliveredPhotoRevision,revision+1)
                if manual {
                    XCTAssertTrue(model.manualExposure); XCTAssertEqual(model.iso,400)
                    XCTAssertEqual(pow(2,model.shutter),1.0/15,accuracy:0.0001)
                }
                print("NIGHT-CANCEL-REPEAT cycle=\(index) manual=\(manual) composition=\(duringComposition) cancelledCallbacks=\(cancelledCallbacks) returnedCallbacks=\(callbacks)")
            }
            print("NIGHT-CANCEL-PERF n=4 releaseSeconds=\(cancelTimes) returnedNightSeconds=\(captureTimes) injectedPlan=true noPhotosWrites=true")
        }
    }

    @MainActor func testAutomaticExposureDemandAndUnknownAssessmentKeepSixRealFramesAcrossLenses() async throws {
        try await withCamera { model in
            let camera=model.camera
            camera.nightExposureIndexForTesting=nil
            camera.nightAutomaticExposureForTesting = .init(seconds:0.0625,iso:1600)
            camera.nightMotionForTesting = .unknown
            var timings=[Double]()
            for zoom in [0.5,1.0] {
                let lens=try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-zoom)<0.01 })
                model.selectFocalLength(lens)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait { camera.ready && camera.selectedLens == lens.id && camera.supportsNightCapture }
                var batches=[Int]()
                camera.onNightBatchSubmittedForTesting={batches.append($0)}
                let started=CACurrentMediaTime()
                let photo=try await self.capture(camera,format:zoom<1 ? .jpeg:.heif)
                timings.append(CACurrentMediaTime()-started)
                XCTAssertEqual(batches,[3,6],"未知评估补足六帧，不能停在三帧或无限追加")
                XCTAssertEqual(photo.diagnostics?.rows.first { $0.title == "夜景实际采集" }?.value,"6 帧")
                let data=try XCTUnwrap(photo.resources.first?.data)
                let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                let props=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let exif=try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
                XCTAssertEqual((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0,0.0625,accuracy:0.0001)
                XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 0,1600,accuracy:32)
                print("NIGHT-DEMAND-HARDWARE zoom=\(zoom) batches=\(batches) captureSeconds=\(timings.last!) unknownAssessment=true countOverride=false noPhotosWrites=true")
            }
            print("NIGHT-DEMAND-PERF n=2 callbackSeconds=\(timings) injectedExposurePlan=true realHardware=true")
        }
    }

    @MainActor func testThreeSixNineFrameBatchesAndActualFileInformation() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            var batches = [Int]()
            camera.onNightBatchSubmittedForTesting = { batches.append($0) }
            let baseline = self.footprint()
            var peak = baseline
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    peak = max(peak, self.footprint())
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            defer { sampler.cancel() }
            for (index, target) in [3, 6, 9, 6, 9].enumerated() {
                try XCTSkipIf(ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious
                    || ProcessInfo.processInfo.thermalState == .critical, "资源保护生效，本轮不强行扩张帧数")
                let format: PhotoFileFormat = index % 2 == 0 ? .jpeg : .heif
                model.photoFormat = format
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                // 规格与实际 UI 保持一致，等待路由自然稳定；不锁主摄，也不改变系统切镜规则。
                var previousRoute = "", stableSamples = 0
                for _ in 0..<150 {
                    let route = await withCheckedContinuation { c in camera.nightRouteIdentityForTesting { c.resume(returning: $0) } }
                    stableSamples = route == previousRoute ? stableSamples + 1 : 0
                    previousRoute = route
                    if stableSamples >= 15 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertGreaterThanOrEqual(stableSamples, 15, "速度样本需先有稳定路由")
                camera.nightExposureIndexForTesting = target == 9 ? 512 : (target == 6 ? 128 : 32)
                camera.nightMotionForTesting = .stable
                batches.removeAll()
                let started = CACurrentMediaTime()
                let photo = try await self.capture(camera, format: format)
                let elapsed = CACurrentMediaTime() - started
                let rows = try XCTUnwrap(photo.diagnostics).rows
                XCTAssertEqual(rows.first { $0.title == "夜景计划帧数" }?.value, "\(target) 帧")
                XCTAssertEqual(rows.first { $0.title == "夜景实际采集" }?.value, "\(target) 帧", "\(rows.filter { $0.title.hasPrefix("夜景") })")
                XCTAssertEqual(batches, Array(stride(from: 3, through: target, by: 3)))
                let merge = try XCTUnwrap(rows.first { $0.title == "夜景曝光合成" }?.value)
                let used = try XCTUnwrap(Int(merge.split(separator: " ").first ?? ""))
                XCTAssertTrue((2...target).contains(used), "必须真实融合，不能只返回单帧：\(merge)")
                XCTAssertTrue(photo.diagnostics?.isNightComposite == true)
                let resource = try XCTUnwrap(photo.resources.first)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                XCTAssertNotNil(exif[kCGImagePropertyExifExposureTime]); XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings])
                print("NIGHT-ADAPTIVE target=\(target) captured=\(rows.first { $0.title == "夜景实际采集" }?.value ?? "missing") merged=\(used) batches=\(batches) seconds=\(elapsed) hostFootprintMiB=\(Double(peak)/1048576) injected-scene=true")
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy && camera.ready }
            }
            print("NIGHT-MEMORY hostIncludingXCTest baselineMiB=\(Double(baseline)/1048576) sampledPeakMiB=\(Double(peak)/1048576) interval=40ms; not standalone-app memory or leak proof")
        }
    }

    /// 用户配合暗房普通手持取景后单独运行；原片只进入测试附件，不写系统相册。
    @MainActor func testNaturalDarkRoomHandheldUltraWideAndMainWithSourceAttachments() async throws {
        try await withCamera { model in
            let camera=model.camera
            camera.nightExposureIndexForTesting=nil; camera.nightMotionForTesting=nil
            camera.nightAutomaticExposureForTesting=nil
            if !model.nightModeEnabled { model.toggleNightMode() }
            try await self.wait { model.nightModeEnabled && camera.ready }
            for zoom in [0.5,1.0] {
                let lens=try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-zoom)<0.01 })
                model.selectFocalLength(lens)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait { camera.ready && camera.selectedLens == lens.id && camera.preview != nil }
                for _ in 0..<120 {
                    if model.photoOptions.nightMode { break }
                    try await Task.sleep(for:.milliseconds(25))
                }
                guard model.photoOptions.nightMode else {
                    XCTFail("自然暗房验收需要暗景触发；请保持暗房取景，不能用亮室替代")
                    throw CancellationError()
                }
                var sources=[Int:Data]()
                camera.onNightSourceForTesting={sources[$1]=$0}
                let began=CACurrentMediaTime()
                let photo=try await self.capture(camera,format:.jpeg)
                let elapsed=CACurrentMediaTime()-began
                camera.onNightSourceForTesting=nil
                for (sequence,data) in sources.sorted(by:{$0.key<$1.key}) {
                    let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.jpeg")
                    attachment.name="Night-Natural-\(zoom)x-source-\(sequence)";attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
                let data=try XCTUnwrap(photo.resources.first?.data)
                let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.jpeg")
                attachment.name="Night-Natural-\(zoom)x-final";attachment.lifetime = .keepAlways;self.add(attachment)
                let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                let props=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let exif=try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
                let used=(exif[kCGImagePropertyExifSourceImageNumberOfCompositeImage as String] as? [NSNumber])?.last?.intValue ?? 1
                XCTAssertGreaterThanOrEqual(used,2,"普通手持暗景应实际融合，而非仅交付单帧")
                let diagnostic="NIGHT-NATURAL-ROOM zoom=\(zoom) captured=\(sources.count) used=\(used) seconds=\(elapsed) exif=\(exif) rows=\(photo.diagnostics?.rows ?? [])"
                print(diagnostic)
                let details=XCTAttachment(string:diagnostic);details.name="Night-Natural-\(zoom)x-information";details.lifetime = .keepAlways;self.add(details)
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            }
        }
    }

    @MainActor func testMotionStopsAppendingAndCancelThenReturnCanCaptureAgain() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            camera.nightExposureIndexForTesting = 512
            camera.nightMotionForTesting = .moving
            let moving = try await self.capture(camera, format: .jpeg)
            XCTAssertEqual(moving.diagnostics?.rows.first { $0.title == "夜景实际采集" }?.value, "3 帧")
            // 同时发生系统切镜时，停止原因优先记路线变化；运动判断仍必须已执行，且只采三张。
            XCTAssertTrue(moving.diagnostics?.rows.contains { $0.title == "夜景运动评估" && $0.value.contains("运动") } == true,
                          "\(moving.diagnostics?.rows ?? [])")
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            camera.nightMotionForTesting = .stable
            let appended = expectation(description: "Additional real bracket submitted")
            var delivered = 0
            camera.onCaptureCompleted = { if $0 != nil { delivered += 1 } }
            camera.onNightBatchSubmittedForTesting = { count in
                if count == 6 { model.setCameraActive(false); appended.fulfill() }
            }
            var options = PhotoOptions(format: .jpeg); options.nightMode = true; options.shootingType = "夜景"
            camera.capture(flashMode: .off, options: options)
            await self.fulfillment(of: [appended], timeout: 30)
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            XCTAssertEqual(delivered, 0, "取消组不能交付半成品或多张相册资源")
            XCTAssertFalse(camera.nightPreviewHoldForTesting)
            camera.onNightBatchSubmittedForTesting = nil
            camera.nightExposureIndexForTesting = nil; camera.nightMotionForTesting = nil
            camera.nightAutomaticExposureForTesting = nil
            model.setCameraActive(true)
            try await self.wait { camera.ready && camera.preview != nil }
            let done = self.expectation(description: "Ordinary capture after cancelled night")
            var ordinary: CapturedPhoto?
            camera.onCaptureCompleted = { ordinary = $0; done.fulfill() }
            camera.capture(flashMode: .off, options: PhotoOptions(format: .jpeg))
            await self.fulfillment(of: [done], timeout: 30)
            XCTAssertFalse(try XCTUnwrap(ordinary).diagnostics?.isNightComposite ?? true)
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            print("NIGHT-ADAPTIVE-STABILITY motion-stops-at=3 cancel-at-submitted=6 cancelled-deliveries=\(delivered) ordinary-return=true")
        }
    }

    @MainActor func testActualSceneMeasurementAndMotionDecision() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            let limit = await withCheckedContinuation { c in camera.nightBracketLimitForTesting { c.resume(returning: $0) } }
            XCTAssertGreaterThanOrEqual(limit, 3)
            print("NIGHT-BRACKET actual-max-per-request=\(limit)")
            try await Task.sleep(for: .seconds(1.5))
            camera.nightExposureIndexForTesting = nil; camera.nightMotionForTesting = nil
            let natural = try await self.capture(camera, format: .jpeg)
            let rows = try XCTUnwrap(natural.diagnostics).rows
            print("NIGHT-NATURAL rows=\(rows.filter { $0.title.hasPrefix("夜景") }) all-inputs-real=true pipeline-requested-independently-of-indicator=true")
            let captured = try XCTUnwrap(Int((rows.first { $0.title == "夜景实际采集" }?.value ?? "").split(separator: " ").first ?? ""))
            XCTAssertTrue([3, 6, 9].contains(captured))
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            // 只模拟更暗的测光需求；画面稳定性必须由本次实际原片分析，不注入运动结论。
            camera.nightExposureIndexForTesting = 512
            let assessed = try await self.capture(camera, format: .heif)
            let info = try XCTUnwrap(assessed.diagnostics)
            XCTAssertNotNil(info.rows.first { $0.title == "夜景运动评估" })
            XCTAssertEqual(info.detailRows.filter { $0.title == "夜景曝光合成" }.count, 1)
            XCTAssertFalse(info.detailRows.contains { $0.title == "夜景计划帧数" || $0.title == "夜景实际采集" })
            print("NIGHT-REAL-MOTION rows=\(info.rows.filter { $0.title.hasPrefix("夜景") }) exposure-index-injected=true motion-from-real-images=true")
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
        }
    }

    @MainActor func testNaturallyTriggeredNightUsesActualMeteringAndFrameCount() async throws {
        try await withCamera { model in
            let camera = model.camera
        camera.setForceOrdinaryNightForTesting(true)
            camera.nightExposureIndexForTesting = nil; camera.nightMotionForTesting = nil
            if !model.nightModeEnabled { model.toggleNightMode() }
            try await self.wait { model.nightModeEnabled && camera.ready }
            for _ in 0..<160 {
                if model.photoOptions.nightMode { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            print("NIGHT-NATURAL-GATE triggered=\(model.photoOptions.nightMode) readings=\(String(describing: camera.readings))")
            try XCTSkipUnless(model.photoOptions.nightMode, "实际场景尚未触发夜景，不能记成自然触发通过")
            var samples = [Double]()
            for index in 0..<3 {
                try await self.wait { camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 }
                let options = model.photoOptions
                XCTAssertTrue(options.nightMode)
                let done = self.expectation(description: "Naturally triggered night \(index)")
                var photo: CapturedPhoto?
                camera.onCaptureCompleted = { photo = $0; done.fulfill() }
                let started = CACurrentMediaTime()
                camera.capture(flashMode: model.flashMode, options: options)
                await self.fulfillment(of: [done], timeout: 45)
                samples.append(CACurrentMediaTime() - started)
                let result = try XCTUnwrap(photo)
                XCTAssertTrue(result.diagnostics?.isNightComposite == true)
                let rows = try XCTUnwrap(result.diagnostics).rows
                let detail = try XCTUnwrap(result.diagnostics).detailRows
                XCTAssertEqual(detail.filter { $0.title == "夜景曝光合成" }.count, 1)
                print("NIGHT-NATURAL-FINAL sample=\(index) seconds=\(samples.last!) rows=\(rows.filter { $0.title.hasPrefix("夜景") }) no-overrides=true")
            }
            print("NIGHT-NATURAL-PERF samples=3 callback-seconds=\(samples)")
            try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
        }
    }

    @MainActor func testIndependentNightDisableDuringCaptureDoesNotFreeze() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.5, iso: 3200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            camera.setContinuousZoom(2)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            var options = PhotoOptions(format: .heif); options.nightMode = true; options.shootingType = "夜景"
            camera.capture(flashMode: .off, options: options)
            try await Task.sleep(for: .milliseconds(500))
            model.toggleNightMode()
            for _ in 0..<600 { if !camera.capturing && camera.pendingPhotoCount == 0 && camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(camera.capturing, "关闭夜景后仍在采集")
            XCTAssertEqual(camera.pendingPhotoCount, 0, "关闭夜景后拍摄任务未释放")
            XCTAssertTrue(camera.ready, "关闭夜景后相机会话未恢复")
            print("INDEPENDENT-NIGHT-CANCEL ready=\(camera.ready) pending=\(camera.pendingPhotoCount) capturing=\(camera.capturing) zoom=\(camera.currentZoom)")
        }
    }

    @MainActor func testIndependentNightLandscapeThreeLenses() async throws {
        try await withCamera { model in
            let camera = model.camera
            // 手机需保持物理横放；XCTest 无权旋转真机。
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for zoom in [CGFloat(0.5), CGFloat(2), CGFloat(4)] {
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                for _ in 0..<200 { if camera.ready && abs(camera.currentZoom - zoom) < 0.05 { break }; try await Task.sleep(for: .milliseconds(20)) }
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                print("INDEPENDENT-NIGHT-LANDSCAPE zoom=\(zoom) final=\(width)x\(height) zoomAfter=\(camera.currentZoom)")
                XCTAssertGreaterThan(width, height, "横屏成片应保持横向")
                XCTAssertEqual(camera.currentZoom, zoom, accuracy: 0.08)
            }
        }
    }

    @MainActor func testManualOneSecondPreviewVersusStillBrightness() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.smoothPreview = false
            model.setMode(.manual)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.manualExposure = true
            model.iso = 100
            model.shutter = 0
            model.applyExposure()
            for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(2500))
            func luma(_ image: UIImage) -> Double {
                guard let cg = image.cgImage else { return -1 }
                var pixel = [UInt8](repeating: 0, count: 4)
                let cs = CGColorSpaceCreateDeviceRGB()
                guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return (Double(pixel[0]) * 0.2126 + Double(pixel[1]) * 0.7152 + Double(pixel[2]) * 0.0722) / 255
            }
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            XCTAssertEqual(state?.seconds ?? 0, 1, accuracy: 0.06, "预览应应用到 1 秒曝光")
            XCTAssertEqual(state?.iso ?? 0, 100, accuracy: 20)
            let previewLuma = camera.preview.map(luma) ?? -1
            let result = try await self.capture(camera, format: .heif)
            let data = try XCTUnwrap(result.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let seconds = exif?[kCGImagePropertyExifExposureTime as String] as? Double ?? -1
            let iso = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] ?? []
            let stillLuma = luma(UIImage(cgImage: cg))
            XCTAssertEqual(seconds, 1, accuracy: 0.02)
            XCTAssertEqual(Set(iso), [100])
            XCTAssertGreaterThan(previewLuma, 0.55, "关闭流畅预览后预览应反映 1 秒曝光亮度")
            print("MANUAL-1S previewLuma=\(previewLuma) stillLuma=\(stillLuma) exifSeconds=\(seconds) exifISO=\(iso)")
        }
    }

    @MainActor func testModeSwitchLatency() async throws {
        try await withCamera { model in
            let camera = model.camera
            var times = [Double]()
            for next in [CameraShootingMode.manual, .auto, .manual, .auto] {
                let start = CACurrentMediaTime()
                let before = camera.previewFrameTimeForTesting
                model.setMode(next)
                for _ in 0..<400 {
                    if camera.ready && model.mode == next && !camera.capturing && camera.previewFrameTimeForTesting > before { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                times.append(CACurrentMediaTime() - start)
            }
            print("A-M-SWITCH-LATENCY times=\(times)")
            XCTAssertLessThan(times[0], 0.9, "首次 A→M 不应超过 0.9 秒")
            XCTAssertLessThan(times[1], 0.6, "M→A 不应超过 0.6 秒")
        }
    }

    @MainActor func testManualPreviewAppliesAcrossSlowShutters() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.smoothPreview = false
            model.setMode(.manual)
            model.manualExposure = true
            model.iso = 100
            for seconds in [1.0 / 20, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1.0] {
                model.shutter = log2(seconds)
                model.applyExposure()
                var applied = -1.0
                for _ in 0..<200 {
                    let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                    applied = state?.seconds ?? -1
                    if abs(applied - seconds) < max(0.002, seconds * 0.03) { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                print("MANUAL-SLOW-RANGE requested=\(seconds) applied=\(applied) device=\(camera.activeCaptureDeviceID)")
                XCTAssertEqual(applied, seconds, accuracy: max(0.002, seconds * 0.03), "预览未应用 \(seconds)s")
            }
        }
    }

    @MainActor func testIndependentNightHDRPhotoAndBrightTone() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.independentNightProfile = .balanced
            model.nightBrightToneEnabled = true
            model.nightHDRPhotoEnabled = true
            model.smoothPreview = false
            model.photoFormat = .heif
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            var result: CapturedPhoto?
            let done = expectation(description: "HDR night")
            let old = camera.onCaptureCompleted
            camera.onCaptureCompleted = { result = $0; done.fulfill() }
            defer { camera.onCaptureCompleted = old }
            var options = model.photoOptions
            options.nightMode = true; options.format = .heif; options.shootingType = "夜景"
            camera.capture(flashMode: .off, options: options)
            await fulfillment(of: [done], timeout: 60)
            let photo = try XCTUnwrap(result, camera.message ?? "HDR夜景未返回")
            let data = try XCTUnwrap(photo.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let depth = props[kCGImagePropertyDepth as String] as? Int ?? -1
            print("NIGHT-HDR-PHOTO bits=\(cg.bitsPerComponent) depth=\(depth) size=\(cg.width)x\(cg.height) resources=\(photo.resources.count)")
            XCTAssertGreaterThanOrEqual(cg.width * cg.height, 11_000_000)
            XCTAssertEqual(photo.resources.count, 1)
            XCTAssertFalse(photo.resources[0].pairedVideo)
        }
    }

    @MainActor func testRearSystemHDRHEIFUsesProcessedSource() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.setCaptureKind(.photo)
            if model.currentPosition != .back { model.flipCamera() }
            for _ in 0..<300 { if camera.ready && model.currentPosition == .back { break }; try await Task.sleep(for: .milliseconds(20)) }
            model.photoFormat = .heif
            model.photoResolution = .standard
            model.hdr = true
            try await Task.sleep(for: .milliseconds(300))
            var photo: CapturedPhoto?
            let done = expectation(description: "system HDR HEIF")
            let old = camera.onCaptureCompleted
            camera.onCaptureCompleted = { photo = $0; done.fulfill() }
            defer { camera.onCaptureCompleted = old }
            model.takePhoto()
            await fulfillment(of: [done], timeout: 30)
            let captured = try XCTUnwrap(photo, camera.message ?? "系统 HDR 未出片")
            let data = try XCTUnwrap(captured.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let depth = props[kCGImagePropertyDepth as String] as? Int ?? -1
            print("REAR-SYSTEM-HDR resources=\(captured.resources.count) depth=\(depth) message=\(camera.message ?? "")")
            XCTAssertEqual(captured.resources.count, 1, "普通 HEIF+HDR 不应附带 DNG")
            HDRImageAssertions.assertHDR(source, "后置系统 HDR")
        }
    }

    @MainActor func testFrontSystemHDRCapturesWithoutRaw() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.setCaptureKind(.photo)
            model.flipCamera()
            for _ in 0..<300 { if camera.ready && model.currentPosition == .front { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(model.currentPosition, .front)
            model.photoFormat = .heif
            model.photoResolution = .standard
            model.border = false
            model.hdr = true
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(model.hdr, "普通 HEIF 的系统 HDR 不应因前置无 RAW 被关闭")
            model.takePhoto()
            for _ in 0..<600 { if camera.pendingPhotoCount == 0 && !camera.shutterBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
            for _ in 0..<300 { if model.library.pendingSaveCount == 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
            let message = camera.message ?? ""
            print("FRONT-SYSTEM-HDR message=\(message) hdr=\(model.hdr) format=\(model.photoFormat.rawValue)")
            XCTAssertFalse(message.contains("不支持 RAW"), "前置系统 HDR 不应请求 RAW")
            XCTAssertTrue(model.hdr)
        }
    }

    @MainActor func testPhotoToVideoSwitchCancelsPendingPhotoWithoutTimeout() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.dropFinalPhotoCallbackForTesting = true
            camera.nativeCaptureTimeoutForTesting = 1.0
            defer {
                camera.dropFinalPhotoCallbackForTesting = false
                camera.nativeCaptureTimeoutForTesting = nil
            }
            model.setCaptureKind(.photo)
            model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
            camera.capture(flashMode: .off, options: model.photoOptions)
            XCTAssertGreaterThan(camera.pendingPhotoCount, 0)
            try await Task.sleep(for: .milliseconds(150))
            model.setCaptureKind(.video)
            try await Task.sleep(for: .milliseconds(1800))
            print("MODE-CANCEL pending=\(camera.pendingPhotoCount) message=\(camera.message ?? "")")
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            XCTAssertFalse((camera.message ?? "").contains("拍照超时"),
                           "模式切换不应留下旧照片超时提示")
            model.setCaptureKind(.photo)
        }
    }

    @MainActor func testManualModeParametersRemainEditable() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.setMode(.manual)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(300))
            for item in [CameraParameter.iso, .shutter, .wb, .tint, .focus] {
                model.parameter = item
                print("MANUAL-EDITABLE item=\(item) canEdit=\(model.parameterCanEdit) exposure=\(camera.supportsExposure) wb=\(camera.supportsWB) focus=\(camera.supportsFocus) device=\(camera.activeCaptureDeviceID)")
            }
            model.parameter = .iso
            XCTAssertTrue(model.parameterCanEdit, "M 挡 ISO 不应被锁")
            model.parameter = .shutter
            XCTAssertTrue(model.parameterCanEdit, "M 挡快门不应被锁")
            model.parameter = .focus
            XCTAssertTrue(model.parameterCanEdit, "M 挡对焦不应被锁")
            model.parameter = .iso
            model.editableParameterBinding.wrappedValue = 400
            for _ in 0..<300 {
                if camera.activeCaptureDeviceID != "com.apple.avfoundation.avcapturedevice.built-in_video:7" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(1200))
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            print("MANUAL-APPLY device=\(camera.activeCaptureDeviceID) modelISO=\(model.iso) readings=\(String(describing: camera.readings?.iso)) iso=\(state?.iso ?? -1) custom=\(state?.engineCustom ?? false) exposure=\(String(describing: state?.exposureMode))")
            XCTAssertNotEqual(camera.activeCaptureDeviceID, "com.apple.avfoundation.avcapturedevice.built-in_video:7", "启用 ISO 后应切物理镜头")
            XCTAssertEqual(state?.engineCustom, true)
            XCTAssertEqual(state?.iso ?? 0, 400, accuracy: 20)
        }
    }

    @MainActor func testSmartCaptureSwitchesBetweenPresets() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.toggleSmartCaptureMode()
            XCTAssertTrue(model.smartCaptureEnabled)
            model.togglePortraitMode()
            for _ in 0..<200 { if !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.smartCaptureEnabled, "切到人像应自动退出智拍")
            let portrait = model.portraitModeEnabled
            model.toggleSmartCaptureMode()
            for _ in 0..<200 { if !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(model.smartCaptureEnabled)
            XCTAssertFalse(model.portraitModeEnabled, "开启智拍应关闭人像")
            model.toggleNightMode()
            for _ in 0..<200 { if !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.smartCaptureEnabled, "切到夜景应自动退出智拍")
            XCTAssertEqual(model.portraitModeEnabled, false)
            print("SMART-SWITCH portraitWas=\(portrait) finalSmart=\(model.smartCaptureEnabled) night=\(model.nightModeEnabled) portrait=\(model.portraitModeEnabled)")
        }
    }

    @MainActor func test48MPOnlyAvailableInManualAndFallsBackInAuto() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.setMode(.auto)
            for _ in 0..<200 { if camera.ready && model.mode == .auto { break }; try await Task.sleep(for: .milliseconds(20)) }
            if camera.availableResolutions.contains(.high) {
                XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 必须禁用")
            }
            model.setMode(.manual)
            for _ in 0..<200 { if camera.ready && model.mode == .manual { break }; try await Task.sleep(for: .milliseconds(20)) }
            if camera.availableResolutions.contains(.high) {
                XCTAssertTrue(model.canSelectPhotoResolution(.high), "M 挡 48MP 应可用")
                model.photoResolution = .high
                for _ in 0..<300 { if model.photoResolution == .high && camera.ready && !camera.highResolutionPhotoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(model.photoResolution, .high)
                model.setMode(.auto)
                for _ in 0..<300 { if model.mode == .auto && model.photoResolution == .standard { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(model.photoResolution, .standard, "M 挡 48MP 切回 A 挡必须回落 12MP")
            }
            print("HIGH-RES-MODE-A-DISABLED available=\(camera.availableResolutions.contains(.high)) final=\(model.photoResolution) mode=\(model.mode.rawValue)")
        }
    }

    @MainActor func testNightModeKeepsNormalZoomAndAboveEightFallsBack() async throws {
        try await withCamera { model in
            let camera = model.camera
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(model.zoomRange.upperBound, camera.continuousZoomRange.upperBound, accuracy: 0.01)
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            camera.setContinuousZoom(12)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            for _ in 0..<200 { if camera.ready && abs(camera.currentZoom - 12) < 0.1 { break }; try await Task.sleep(for: .milliseconds(20)) }
            let result = try await self.capture(camera, format: .heif)
            let independent = result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true
            print("NIGHT-ABOVE-8 zoom=\(camera.currentZoom) range=\(model.zoomRange) independent=\(independent)")
            XCTAssertFalse(independent, "8× 以上应回退普通夜景")
            XCTAssertLessThanOrEqual(camera.currentZoom, model.zoomRange.upperBound + 0.01)
        }
    }

    @MainActor func testNightModeAndLensSwitchStress() async throws {
        try await withCamera { model in
            let camera = model.camera
            for index in 0..<12 {
                model.toggleNightMode()
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                let zoom: CGFloat = [0.5, 1, 2, 4][index % 4]
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                model.setMode(index.isMultiple(of: 2) ? .auto : .manual)
                for _ in 0..<250 { if camera.ready && abs(camera.currentZoom - zoom) < 0.06 && !camera.capturing { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(camera.ready, "第 \(index + 1) 次切换后相机未 ready")
                XCTAssertEqual(camera.pendingPhotoCount, 0)
                print("NIGHT-SWITCH-STRESS index=\(index) night=\(model.nightModeEnabled) zoom=\(camera.currentZoom) ready=\(camera.ready) mode=\(model.mode.rawValue)")
            }
        }
    }

    @MainActor func testIndependentNightBackgroundDuringCaptureRecovers() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.5, iso: 3200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            camera.setContinuousZoom(2)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            var options = PhotoOptions(format: .heif); options.nightMode = true; options.shootingType = "夜景"
            camera.capture(flashMode: .off, options: options)
            try await Task.sleep(for: .milliseconds(500))
            model.setCameraActive(false)
            for _ in 0..<300 { if camera.pendingPhotoCount == 0 && !camera.capturing { break }; try await Task.sleep(for: .milliseconds(20)) }
            model.setCameraActive(true)
            for _ in 0..<600 { if camera.ready && camera.preview != nil && !camera.capturing { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(camera.ready, "退后台后重新进入相机未恢复")
            XCTAssertEqual(camera.pendingPhotoCount, 0)
            print("INDEPENDENT-NIGHT-BACKGROUND ready=\(camera.ready) pending=\(camera.pendingPhotoCount) capturing=\(camera.capturing)")
        }
    }

    @MainActor func testIndependentNightFiveConsecutive48mmCaptures() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            camera.setContinuousZoom(2)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - 2) < 0.03 { break }; try await Task.sleep(for: .milliseconds(20)) }
            for index in 0..<5 {
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                let independent = result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true
                print("INDEPENDENT-NIGHT-FIVE index=\(index) final=\(width)x\(height) independent=\(independent) zoom=\(camera.currentZoom)")
                XCTAssertTrue(independent); XCTAssertGreaterThanOrEqual(width * height, 11_000_000)
                XCTAssertEqual(camera.currentZoom, 2, accuracy: 0.05)
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy && camera.ready }
            }
        }
    }

    @MainActor func testIndependentNightUltraWideHalfToOne() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for zoom in [CGFloat(0.5), CGFloat(0.75), CGFloat(0.99)] {
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - zoom) < 0.03 { break }; try await Task.sleep(for: .milliseconds(20)) }
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                let independent = result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true
                let sourceSize = result.diagnostics?.rows.first { $0.title == "夜景源尺寸" }?.value ?? "none"
                print("INDEPENDENT-NIGHT-UW zoom=\(zoom) source=\(sourceSize) final=\(width)x\(height) independent=\(independent) currentZoom=\(camera.currentZoom)")
                XCTAssertTrue(independent)
                XCTAssertGreaterThanOrEqual(width * height, 11_000_000)
                XCTAssertEqual(camera.currentZoom, zoom, accuracy: 0.05)
            }
        }
    }

    @MainActor func testIndependentNightTele4To8mm46() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for zoom in [CGFloat(4), CGFloat(6), CGFloat(8)] {
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - zoom) < 0.05 { break }; try await Task.sleep(for: .milliseconds(20)) }
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                let independent = result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true
                let sourceSize = result.diagnostics?.rows.first { $0.title == "夜景源尺寸" }?.value ?? "none"
                let mergedSize = result.diagnostics?.rows.first { $0.title == "夜景融合尺寸" }?.value ?? "none"
                print("INDEPENDENT-NIGHT-TELE zoom=\(zoom) source=\(sourceSize) merged=\(mergedSize) final=\(width)x\(height) independent=\(independent) currentZoom=\(camera.currentZoom)")
                XCTAssertTrue(independent)
                XCTAssertGreaterThanOrEqual(width * height, 11_000_000)
                XCTAssertEqual(camera.currentZoom, zoom, accuracy: 0.1)
            }
        }
    }

    @MainActor func testIndependentNightRepeatedFocalStability() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.forceNightEnvironmentTriggeredForTesting(true)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for (index, zoom) in [CGFloat(1), CGFloat(28.0 / 24.0), CGFloat(2)].enumerated() {
                model.forceNightEnvironmentTriggeredForTesting(true)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - zoom) < 0.03 { break }; try await Task.sleep(for: .milliseconds(20)) }
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                let independent = result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true
                let crop = result.diagnostics?.rows.first { $0.title == "夜景边缘裁切" }?.value ?? "none"
                let sourceSize = result.diagnostics?.rows.first { $0.title == "夜景源尺寸" }?.value ?? "none"
                let mergedSize = result.diagnostics?.rows.first { $0.title == "夜景融合尺寸" }?.value ?? "none"
                let resources = result.resources.compactMap { resource -> String? in
                    guard let src = CGImageSourceCreateWithData(resource.data as CFData, nil),
                          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                          let w = p[kCGImagePropertyPixelWidth as String] as? Int,
                          let h = p[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
                    return "\(w)x\(h)"
                }
                print("INDEPENDENT-NIGHT-REPEAT index=\(index) zoom=\(zoom) final=\(width)x\(height) source=\(sourceSize) merged=\(mergedSize) resources=\(resources) independent=\(independent) crop=\(crop) currentZoom=\(camera.currentZoom)")
                XCTAssertTrue(independent, "第 \(index + 1) 次应走独立夜景")
                XCTAssertGreaterThanOrEqual(width * height, 11_000_000)
                XCTAssertEqual(camera.currentZoom, zoom, accuracy: 0.05)
                try await self.wait { camera.pendingPhotoCount == 0 && !camera.shutterBusy }
            }
        }
    }

    @MainActor func testIndependentNightRouteAt24And28mm() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.forceNightEnvironmentTriggeredForTesting(true)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for zoom in [CGFloat(1), CGFloat(28.0 / 24.0)] {
                camera.setContinuousZoom(zoom)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - zoom) < 0.02 { break }; try await Task.sleep(for: .milliseconds(20)) }
                let result = try await self.capture(camera, format: .heif)
                let data = try XCTUnwrap(result.resources.first?.data)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
                let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
                print("INDEPENDENT-NIGHT-FOCAL zoom=\(zoom) final=\(width)x\(height) line=\(result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } ?? false)")
                XCTAssertGreaterThanOrEqual(width * height, 11_000_000)
                XCTAssertTrue(result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true)
            }
        }
    }

    @MainActor func testIndependentNightRouteAt48mmProduces12MP() async throws {
        try await withCamera { model in
            let camera = model.camera
            camera.nightAutomaticExposureForTesting = .init(seconds: 0.125, iso: 200)
            model.toggleNightMode()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            model.forceNightEnvironmentTriggeredForTesting(true)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
            model.selectFocalLength(main)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            camera.setContinuousZoom(2)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            for _ in 0..<150 { if camera.ready && abs(camera.currentZoom - 2) < 0.02 { break }; try await Task.sleep(for: .milliseconds(20)) }
            let result = try await self.capture(camera, format: .heif)
            let data = try XCTUnwrap(result.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
            let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
            print("INDEPENDENT-NIGHT-RESULT final=\(width)x\(height) zoom=\(camera.currentZoom) diagnostics=\(result.diagnostics?.rows.map(\.title) ?? [])")
            XCTAssertGreaterThanOrEqual(width * height, 11_000_000, "48mm 独立夜景应保留至少约 6MP 真实像素")
            XCTAssertEqual(camera.currentZoom, 2, accuracy: 0.05)
            XCTAssertTrue(result.diagnostics?.rows.contains { $0.title == "夜景独立采集" } == true)
        }
    }

    @MainActor private func capture(_ camera: CameraEngine, format: PhotoFileFormat) async throws -> CapturedPhoto {
        let done = expectation(description: "Adaptive night completes once")
        var result: CapturedPhoto?
        camera.onCaptureCompleted = { result = $0; done.fulfill() }
        var options = PhotoOptions(format: format); options.nightMode = true; options.shootingType = "夜景"
        camera.capture(flashMode: .off, options: options)
        await fulfillment(of: [done], timeout: 45)
        return try XCTUnwrap(result, camera.message ?? "No adaptive night result")
    }

    @MainActor private func withCamera(_ action: (CameraViewModel) async throws -> Void) async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let oldCallback = camera.onCaptureCompleted
        let tracing = camera.photoPhaseTracingForTesting
        camera.photoPhaseTracingForTesting = true
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let audit = SessionRuntimeErrorAudit()
        let pending = model.library.pendingSaveCount
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCallback; camera.onNightBatchSubmittedForTesting = nil
            camera.onNightSourceForTesting = nil
            camera.photoPhaseTracingForTesting = tracing
            camera.nightAutomaticExposureForTesting = nil
            camera.nightExposureIndexForTesting = nil; camera.nightMotionForTesting = nil
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
            XCTAssertEqual(model.library.pendingSaveCount, pending)
            audit.finish()
        }
        model.setCameraActive(true)
        try await wait { camera.ready && camera.preview != nil }
        model.setCaptureKind(.photo); model.setMode(.auto)
        model.photoFormat = .jpeg; model.photoResolution = .standard
        model.flashMode = .off; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        if model.currentPosition != .back { model.flipCamera() }
        try await wait { model.currentPosition == .back && camera.ready }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        model.selectFocalLength(main)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait { camera.ready && camera.selectedLens == main.id }
        camera.updateLook(CaptureLook())
        try await action(model)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Adaptive night did not settle")
        throw NSError(domain: "NightAdaptiveTest", code: 1)
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    #endif
}

private struct NightPreviewPhysicalHost:View {
    @ObservedObject var model:CameraViewModel
    @ObservedObject var camera:CameraEngine
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(model:model).viewfinderContent(controlAngle:0)
                CameraView(model:model).fixedCameraControls(width:geometry.size.width)
            }
        }
    }
}
