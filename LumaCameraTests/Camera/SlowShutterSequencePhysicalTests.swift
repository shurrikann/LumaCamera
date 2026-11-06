import XCTest
import UIKit
import AVFoundation
import ImageIO
import SwiftUI
@testable import LumaCamera

/// 真机慢门端到端回归：使用独立内存相册替身，绝不向用户 Photos 写入样片。
final class SlowShutterSequencePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRealAccumulationPreviewAndCancelOnPhysicalViewfinder() async throws {
        try await withCamera { model,service in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let prior = scene.windows.first { $0.isKeyWindow }
            let host = UIHostingController(rootView:SlowAccumulationPhysicalHost(model:model,camera:model.camera))
            let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
            try await self.prepare(model,preset:.silkyWater,manual:false)
            var revisions = [Int](), captured = false
            let subscription = model.$slowShutterAccumulationPreview.sink { state in
                guard let state,!state.isFinal else { return }
                revisions.append(state.revision)
                if state.revision>1 && !captured {
                    captured = true
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                        guard model.slowShutterAccumulationPreview?.id == state.id else { return }
                        let a = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) })
                        a.name = "SlowShutter-Real-Accumulation"; a.lifetime = .keepAlways; self.add(a)
                    }
                }
            }
            defer { subscription.cancel() }
            try await self.complete(model,service:service,preset:.silkyWater)
            XCTAssertGreaterThan(revisions.filter { $0>0 }.count,3)
            try await self.wait(5,"成片后累积预览未清理",model) { model.slowShutterAccumulationPreview == nil }
            let count = service.photos.count
            model.takePhoto()
            try await self.wait(20,"下一次慢门预览未出现",model) { (model.slowShutterAccumulationPreview?.revision ?? 0)>0 }
            model.setCameraActive(false)
            XCTAssertNil(model.slowShutterAccumulationPreview)
            try await self.wait(20,"取消未释放",model) { model.camera.pendingPhotoCount == 0 && model.slowShutterSequenceProgress == nil }
            XCTAssertEqual(service.photos.count,count)
            print("SLOW-ACCUMULATION-PHYSICAL intermediateUpdates=\(revisions.count) realComposite=true cancelClears=true noPhotosWrites=true")
        }
    }
    @MainActor func testSlowShutterPreviewAndFallbackResumeRepeatedly() async throws {
        try await withCamera { model, service in
            defer { model.camera.slowShutterManualBracketDisabledForTesting = false }
            model.toggleSlowShutterMode(); model.setMode(.manual)
            model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0 / 15)
            model.applyExposure(); model.selectSlowShutterDuration(.s1)
            try await self.wait(15, "慢门预览未就绪", model) { model.camera.ready && model.camera.preview != nil }
            for fallback in [false, true, false, true] {
                model.camera.slowShutterManualBracketDisabledForTesting = fallback
                await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait(15, "慢门曝光读数未就绪", model) {
                    model.camera.ready && !model.isPreparingSubmode && model.camera.readings?.validated != nil
                }
                let count = service.photos.count
                model.camera.resetPreviewPublicationTimesForTesting()
                let started = CACurrentMediaTime()
                model.takePhoto()
                try await self.wait(30, "慢门预览回归未完成", model) {
                    service.photos.count == count + 1 && !model.slowShutterComposing
                        && model.camera.pendingPhotoCount == 0 && !model.camera.shutterBusy
                }
                XCTAssertFalse(model.camera.nightPreviewHoldForTesting)
                let last = model.camera.previewFrameTimeForTesting
                let restoreStarted = CACurrentMediaTime()
                try await self.wait(10, "慢门后预览没有恢复", model) { model.camera.previewFrameTimeForTesting > last }
                let times = model.camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= started }
                // 无独立静态包围时，既有策略保留有效画面以遮住临时曝光帧；
                // 该路径检查恢复后的新帧，不能要求保留期间仍连续发布。
                XCTAssertGreaterThan(times.count, fallback ? 0 : 2)
                // 包括首张发布前的保留区间，否则回退路径仅在恢复后发布几张时会低估停顿。
                let boundedTimes = [started] + times + [CACurrentMediaTime()]
                let maxGap = zip(boundedTimes, boundedTimes.dropFirst()).map { $1 - $0 }.max() ?? 0
                print("SLOW-PREVIEW fallback=\(fallback) publications=\(times.count) maxGapSeconds=\(maxGap) resumeSeconds=\(CACurrentMediaTime() - restoreStarted) noPhotosWrites=true")
            }
            try await self.wait(15, "取消前读数未就绪", model) { model.camera.readings?.validated != nil }
            let saved = service.photos.count
            model.selectSlowShutterDuration(.infinite); model.takePhoto()
            try await self.wait(15, "回退曝光未进入预览保护", model) { model.camera.nightPreviewHoldForTesting }
            model.setCameraActive(false)
            try await self.wait(20, "退出后预览保护未释放", model) {
                !model.camera.nightPreviewHoldForTesting && model.camera.pendingPhotoCount == 0
                    && model.slowShutterSequenceProgress == nil
            }
            XCTAssertEqual(service.photos.count, saved)
            let stoppedFrame = model.camera.previewFrameTimeForTesting
            model.setCameraActive(true)
            try await self.wait(15, "取消返回后取景未恢复", model) {
                model.camera.ready && model.camera.previewFrameTimeForTesting > stoppedFrame
            }
            print("SLOW-PREVIEW-STABILITY completed=4 fallbackExit=1 returnedLive=true cancelledPhotos=0")
        }
    }

    @MainActor func testCancelFromIntermediatePublicationCannotReviveSequenceOrPublishLatePreview() async throws {
        try await withCamera { model,service in
            try await self.prepare(model,preset:.silkyWater,manual:false)
            let saved=service.photos.count
            var cancelled=false,late=0
            let subscription=model.$slowShutterAccumulationPreview.sink { value in
                guard let value,value.revision>0,!value.isFinal else {return}
                if cancelled {late+=1;return}
                cancelled=true;model.setCameraActive(false)
            }
            defer{subscription.cancel()}
            model.takePhoto()
            try await self.wait(20,"首个累积画面未触发取消",model){cancelled}
            try await self.wait(20,"取消后序列被旧回调恢复",model){model.camera.pendingPhotoCount == 0 && model.slowShutterSequenceProgress == nil && !model.slowShutterComposing}
            try await Task.sleep(for:.milliseconds(800))
            XCTAssertNil(model.slowShutterAccumulationPreview)
            XCTAssertEqual(late,0);XCTAssertEqual(service.photos.count,saved)
            model.setCameraActive(true)
            try await self.wait(15,"取消后取景未恢复",model){model.camera.ready && model.camera.preview != nil}
            print("SLOW-PREVIEW-REENTRANT-CANCEL latePublications=\(late) savedPhotos=0 returnedLive=true")
        }
    }

    /// 无预设M挡的快快门和∞取消必须实际收片，不能仅验证UI范围。
    @MainActor func testGenericManualDurationAndInfiniteCancellation() async throws {
        try await withCamera { model, service in
            model.camera.photoPhaseTracingForTesting = true
            defer { model.camera.photoPhaseTracingForTesting = false }
            model.toggleSlowShutterMode(); model.setMode(.manual)
            model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
            model.applyExposure(); model.selectSlowShutterDuration(.s1)
            try await self.wait(15,"M挡未就绪",model) { model.camera.ready && !model.camera.shutterBusy }
            XCTAssertNil(model.selectedSlowShutterPreset)
            model.takePhoto()
            try await self.wait(30,"M挡通用合成没有出片",model) { service.photos.count == 1 && !model.slowShutterComposing }
            let photo = try XCTUnwrap(service.photos.first)
            XCTAssertEqual(photo.diagnostics?.parameters?.mode,"M")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
            XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? NSNumber).doubleValue,1.0/125,accuracy:0.00005)
            model.selectSlowShutterDuration(.infinite); model.takePhoto()
            try await self.wait(20,"无限慢门没有实际源帧",model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 3 }
            model.toggleSlowShutterMode()
            try await self.wait(20,"无限慢门取消未清理",model) { model.slowShutterSequenceProgress == nil && !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            XCTAssertEqual(service.photos.count,1)
            print("SLOW-GENERIC manualExposure=200,1/125 finite=1 infiniteCancel=1 noPhotosWrites=true")
        }
    }

    @MainActor func testManualLightTrailsAndWaterCompleteWithMetadata() async throws {
        try await withCamera { model, service in
            for preset in [SlowShutterPreset.lightTrails, .silkyWater] {
                try await self.prepare(model, preset: preset, manual: true)
                try await self.complete(model, service: service, preset: preset)
            }
        }
    }

    @MainActor func testManualMotionBlurCompletesWithShortSourceExposures() async throws {
        try await withCamera { model, service in
            try await self.prepare(model, preset: .motionBlur, manual: true)
            try await self.complete(model, service: service, preset: .motionBlur)
        }
    }

    /// 同设备交替比较旧路径和新路径；完整源帧、编码尺寸与元数据检查共用 complete。
    @MainActor func testManualBracketSpeedComparisonAndRepeatedCapture() async throws {
        try await withCamera { model, service in
            model.camera.photoPhaseTracingForTesting = true
            defer {
                model.camera.slowShutterManualBracketDisabledForTesting = false
                model.camera.photoPhaseTracingForTesting = false
            }
            for preset in [SlowShutterPreset.lightTrails, .silkyWater, .motionBlur] {
                var baseline: [Double] = [], optimized: [Double] = []
                for index in 0..<4 {
                    let oldPath = index == 0
                    model.camera.slowShutterManualBracketDisabledForTesting = oldPath
                    try await self.prepare(model, preset: preset, manual: true)
                    let seconds = try await self.complete(model, service: service, preset: preset)
                    if oldPath { baseline.append(seconds) } else { optimized.append(seconds) }
                }
                print("SLOW-SPEED preset=\(preset.rawValue) baseline=\(baseline) optimized=\(optimized)")
                // 大幅回退才失败，避免温度与系统调度抖动造成毫秒级脆弱断言。
                // 固定采样持续时间后，不能再要求总耗时严格小于旧路径；只检查明显回退。
                XCTAssertLessThan(optimized.reduce(0, +) / Double(optimized.count), baseline[0]+max(2,baseline[0]*0.3))
            }
        }
    }

    @MainActor func testPanningLatencyWithAndWithoutPreviewAssist() async throws {
        try await withCamera { model, service in
            defer { model.camera.setPreviewExposureAssist(false) }
            for assist in [false,true] {
                try await self.prepare(model,preset:.panning,manual:true)
                model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
                model.applyExposure(); model.camera.setPreviewExposureAssist(assist)
                let elapsed = try await self.complete(model,service:service,preset:.panning)
                print("SLOW-PANNING-SPEED assist=\(assist) sequenceSeconds=\(elapsed)")
            }
        }
    }

    @MainActor func testAutomaticNewPresetsPreserveModeAndValidateMeteredExposure() async throws {
        try await withCamera { model, service in
            for preset in [SlowShutterPreset.motionBlur, .starTrails] {
                try await self.prepare(model, preset: preset, manual: false)
                let reading = try XCTUnwrap(model.camera.readings?.validated)
                let plan = AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:reading.iso,meteredSeconds:reading.seconds,
                    hardwareISO:model.camera.isoRange,hardwareShutter:model.camera.shutterRange)
                let targetISO = plan?.iso ?? -1
                if plan == nil {
                    model.takePhoto()
                    try await Task.sleep(for: .milliseconds(300))
                    XCTAssertNil(model.slowShutterSequenceProgress)
                    XCTAssertTrue(service.photos.isEmpty)
                    XCTAssertTrue(model.camera.message?.contains("曝光") == true)
                    print("SLOW-NEW-AUTO preset=\(preset.rawValue) rejected-out-of-exposure-range targetISO=\(targetISO)")
                    model.camera.message = nil
                } else if preset == .motionBlur {
                    try await self.complete(model, service: service, preset: preset)
                } else {
                    model.takePhoto()
                    try await self.wait(50, "A 挡星轨未收到首批帧", model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 3 }
                    model.takePhoto()
                    try await self.wait(30, "A 挡星轨提前结束未完成", model) { !service.photos.isEmpty && !model.slowShutterComposing }
                    XCTAssertEqual(service.photos.last?.diagnostics?.parameters?.mode, "A")
                    service.photos.removeAll()
                }
                XCTAssertEqual(model.mode, .auto)
                XCTAssertFalse(model.manualExposure)
            }
        }
    }

    @MainActor func testStarTrailsFull120FrameStreamingSequence() async throws {
        try await withCamera { model, service in
            try await self.prepare(model, preset: .starTrails, manual: true)
            try await self.complete(model, service: service, preset: .starTrails)
        }
    }

    @MainActor func testStarTrailsEarlyFinishCancellationAndRepeatedSelection() async throws {
        try await withCamera { model, service in
            try await self.prepare(model, preset: .starTrails, manual: true)
            let sourceCallback = model.camera.onSlowShutterSourceFrame
            var lastSource: SlowShutterSourceFrame?
            model.camera.onSlowShutterSourceFrame = { frame in
                if let frame { lastSource = frame }
                sourceCallback?(frame)
            }
            defer { model.camera.onSlowShutterSourceFrame = sourceCallback }
            model.takePhoto()
            try await self.wait(60, "星轨首批帧未完成", model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 3 }
            XCTAssertEqual(model.retainedSlowShutterSourcesForTesting, 1)
            let accepted = model.slowShutterSequenceProgress!.completed
            model.takePhoto()
            try await self.wait(30, "提前结束星轨未保存结果", model) { service.photos.count == 1 && !model.slowShutterComposing }
            let row = service.photos.last?.diagnostics?.rows.first { $0.title == "慢门合成" }?.value ?? ""
            XCTAssertTrue(row.contains("星轨"))
            // 若正在合并源帧，结束操作等待它入账，因此允许比点击时多一张。
            XCTAssertTrue(row.contains("\(accepted) 帧") || row.contains("\(accepted + 1) 帧"))
            service.photos.removeAll()
            try await self.wait(20, "提前结束后快门未释放", model) { !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            model.takePhoto()
            try await self.wait(40, "取消验证未获得源帧", model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 1 }
            model.toggleSlowShutterMode()
            try await self.wait(20, "取消后未恢复", model) { !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(service.photos.isEmpty, "取消不得保存迟到的合成结果")
            XCTAssertNil(model.slowShutterSequenceProgress)
            XCTAssertFalse(model.slowShutterComposing)
            let stale = try XCTUnwrap(lastSource)
            try await self.prepare(model, preset: .motionBlur, manual: true)
            model.takePhoto()
            model.camera.onSlowShutterSourceFrame?(stale)
            XCTAssertEqual(model.slowShutterSequenceProgress?.completed, 0,
                "取消星轨的迟到源帧不能混入新建动态模糊序列")
            XCTAssertNil(model.camera.message)
            model.toggleSlowShutterMode()
            try await self.wait(20, "首帧期间取消后未释放相机", model) { !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(service.photos.isEmpty)
            for _ in 0..<3 {
                model.toggleSlowShutterMode()
                model.selectSlowShutterPreset(.starTrails)
                model.selectSlowShutterPreset(.motionBlur)
                model.toggleSlowShutterMode()
            }
            XCTAssertFalse(model.slowShutterEnabled)
        }
    }

    @MainActor func testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure() async throws {
        try await withCamera { model, service in
            for preset in [SlowShutterPreset.lightTrails, .silkyWater] {
                try await self.prepare(model, preset: preset, manual: false)
                let reading = try XCTUnwrap(model.camera.readings?.validated)
                let target = reading.iso * reading.seconds
                print("SLOW-AUTO-METER preset=\(preset.rawValue) ISO=\(reading.iso) seconds=\(reading.seconds) targetISO=\(target) allowed=\(model.slowShutterISORange)")
                if AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:reading.iso,meteredSeconds:reading.seconds,
                    hardwareISO:model.camera.isoRange,hardwareShutter:model.camera.shutterRange) != nil {
                    try await self.complete(model, service: service, preset: preset)
                } else {
                    let count = service.photos.count
                    model.takePhoto()
                    try await Task.sleep(for: .milliseconds(300))
                    XCTAssertNil(model.slowShutterSequenceProgress)
                    XCTAssertFalse(model.slowShutterComposing)
                    XCTAssertEqual(service.photos.count, count)
                    XCTAssertTrue(model.camera.message?.contains("曝光") == true)
                    print("SLOW-AUTO-REJECT preset=\(preset.rawValue) full-sequence-not-measured")
                    model.camera.message = nil
                }
                XCTAssertEqual(model.mode, .auto)
                XCTAssertFalse(model.manualExposure)
            }
        }
    }

    @MainActor func testAutomaticSequencesWithMeteredExposureCompensation() async throws {
        try await withCamera { model, service in
            for preset in [SlowShutterPreset.lightTrails, .silkyWater] {
                try await self.prepare(model, preset: preset, manual: false)
                // 在真实暗光下用公开 EV 控制把目标 ISO 调到中间值，不伪造测光读数。
                let reading = try XCTUnwrap(model.camera.readings?.validated)
                let metered = reading.iso * reading.seconds
                model.ev = min(max(model.ev + log2(100 / max(metered, 0.001)), -4), 4)
                model.applyExposure()
                try await Task.sleep(for: .seconds(3))
                let deadline = CACurrentMediaTime() + 8
                var exposureAvailable = false
                repeat {
                    if let r = model.camera.readings?.validated {
                        exposureAvailable = AdaptiveSlowShutterExposurePolicy.plan(preset:preset,meteredISO:r.iso,meteredSeconds:r.seconds,
                            hardwareISO:model.camera.isoRange,hardwareShutter:model.camera.shutterRange) != nil
                    }
                    if !exposureAvailable { try await Task.sleep(for: .milliseconds(50)) }
                } while !exposureAvailable && CACurrentMediaTime() < deadline
                guard exposureAvailable else {
                    // A 挡完整序列需要真实暗光；不能伪造测光、放宽 ISO 或缩短源曝光来使测试通过。
                    throw XCTSkip("真实环境曝光仍超出 \(preset.rawValue) 的范围，未执行 A 挡完整序列；范围外拒绝由独立用例检查。")
                }
                print("SLOW-AUTO-COMPENSATION EV=\(model.ev) readings=\(String(describing: model.camera.readings))")
                try await self.complete(model, service: service, preset: preset)
                XCTAssertEqual(model.mode, .auto)
                XCTAssertFalse(model.manualExposure)
            }
        }
    }

    // 保留历史方法名供既有定向列表使用；摇拍现已升级多帧，按新语义验收曝光和真实融合帧数。
    @MainActor func testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence() async throws {
        try await withCamera { model, service in
            try await self.prepare(model,preset:.panning,manual:true)
            model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
            model.applyExposure()
            try await self.complete(model,service:service,preset:.panning)
        }
    }

    @MainActor func testEarlyFinishCancellationAndRepeatedSelectionRecover() async throws {
        try await withCamera { model, service in
            model.camera.photoPhaseTracingForTesting = true
            defer { model.camera.photoPhaseTracingForTesting = false }
            try await self.prepare(model, preset: .lightTrails, manual: true)
            let before = service.photos.count
            model.takePhoto()
            try await self.wait(30, "首帧未返回", model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 2 }
            let completedFrames = model.slowShutterSequenceProgress?.completed ?? 0
            let expectedFrames = completedFrames + ((model.camera.shutterBusy || model.camera.pendingPhotoCount > 0) ? 1 : 0)
            model.takePhoto()
            // 提前结束等待正在出片的一帧，随后只保存真实收到的帧，不中断原生曝光。
            try await self.wait(30, "提前结束没有完成合成", model) { service.photos.count == before + 1 && !model.slowShutterComposing }
            XCTAssertNil(model.slowShutterSequenceProgress)
            let photo = try XCTUnwrap(service.photos.last)
            XCTAssertEqual(photo.diagnostics?.rows.first { $0.title == "慢门合成" }?.value, "光轨 · \(expectedFrames) 帧")
            print("SLOW-EARLY rows=\(String(describing: photo.diagnostics?.rows))")
            try await self.wait(15, "提前结束后相机忙碌未恢复", model) { !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            let saved = service.photos.count
            model.takePhoto()
            try await self.wait(15, "取消测试未进入序列", model) { model.slowShutterSequenceProgress != nil }
            model.setCameraActive(false)
            try await Task.sleep(for: .seconds(2))
            XCTAssertNil(model.slowShutterSequenceProgress)
            XCTAssertFalse(model.slowShutterComposing)
            XCTAssertEqual(service.photos.count, saved)
            model.setCameraActive(true)
            try await self.wait(20, "取消后重开相机没有恢复", model) { model.camera.ready && !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
            // 提前结束后立即关闭模式，等待原生帧或后台合成的任务都不得交付保存。
            if !model.slowShutterEnabled { model.toggleSlowShutterMode() }
            if model.selectedSlowShutterPreset != .lightTrails { model.selectSlowShutterPreset(.lightTrails) }
            model.takePhoto()
            try await self.wait(30, "合成取消测试没有首帧", model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 1 }
            model.takePhoto()
            XCTAssertTrue(model.slowShutterComposing || model.slowShutterSequenceProgress != nil)
            model.toggleSlowShutterMode()
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(model.slowShutterComposing)
            XCTAssertNil(model.slowShutterSequenceProgress)
            XCTAssertEqual(service.photos.count, saved)
            for _ in 0..<10 {
                if model.slowShutterEnabled { model.toggleSlowShutterMode() }
                model.toggleSlowShutterMode()
                model.selectSlowShutterPreset(.motionBlur)
                model.selectSlowShutterPreset(.panning)
                model.toggleSlowShutterMode()
            }
            XCTAssertNil(model.selectedSlowShutterPreset)
            XCTAssertNil(model.slowShutterSequenceProgress)
            XCTAssertFalse(model.slowShutterComposing)
            XCTAssertEqual(service.photos.count, saved)
            print("SLOW-RECOVERY early=1 cancel-in-flight=1 cancel-pending-finish=1 rapid-cycles=10 saves=\(service.photos.count)")
        }
    }

    @MainActor func testAdaptiveWaterAutomaticAndManualRestoration() async throws {
        try await withCamera { model,service in
            model.camera.photoPhaseTracingForTesting = true
            try await self.prepare(model,preset:.silkyWater,manual:false)
            let readings = try XCTUnwrap(model.camera.readings?.validated)
            print("WATER-ENVIRONMENT ISO=\(readings.iso) seconds=\(readings.seconds) exposure=\(readings.iso*readings.seconds)")
            try await self.complete(model,service:service,preset:.silkyWater)
            try await self.prepare(model,preset:.silkyWater,manual:true)
            model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
            model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 8
            model.applyExposure(); model.applyWhiteBalance()
            await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
            try await self.complete(model,service:service,preset:.silkyWater)
            XCTAssertEqual(model.iso,200); XCTAssertEqual(model.shutter,log2(1.0/125),accuracy:0.001)
            XCTAssertEqual(model.wb,5200); XCTAssertEqual(model.whiteBalanceTint,8)
        }
    }
    @MainActor func testAdaptiveWaterEarlyFinishCancelAndRestart() async throws {
        try await withCamera { model,service in
            for index in 0..<2 {
                try await self.prepare(model,preset:.silkyWater,manual:false)
                let saved = service.photos.count
                model.takePhoto()
                try await self.wait(20,"流水首帧未到达",model) { (model.slowShutterSequenceProgress?.completed ?? 0) >= 2 }
                if index == 0 {
                    model.takePhoto()
                    try await self.wait(20,"流水提前结束未完成",model) { service.photos.count > saved && !model.slowShutterComposing }
                } else {
                    model.toggleSlowShutterMode()
                    try await self.wait(20,"流水取消未清空",model) { model.slowShutterSequenceProgress == nil && !model.slowShutterComposing && model.camera.pendingPhotoCount == 0 }
                    XCTAssertEqual(service.photos.count,saved)
                }
                XCTAssertFalse(model.manualExposure)
                XCTAssertEqual(model.mode,.auto)
            }
        }
    }

    @MainActor func testAdaptiveWaterSceneExposureWithJPEG() async throws {
        try await withCamera { model,service in
            try await self.prepare(model,preset:.silkyWater,manual:false)
            model.photoFormat = .jpeg
            let readings = try XCTUnwrap(model.camera.readings?.validated)
            print("WATER-ENVIRONMENT ISO=\(readings.iso) seconds=\(readings.seconds) exposure=\(readings.iso*readings.seconds) format=JPEG")
            try await self.complete(model,service:service,preset:.silkyWater)
        }
    }

    @MainActor func testAdaptiveOtherPresetsAutomaticFullSequences() async throws {
        try await withCamera { model,service in
            for preset in [SlowShutterPreset.lightTrails,.motionBlur,.panning] {
                try await self.prepare(model,preset:preset,manual:false)
                print("ADAPTIVE-PRESET meter preset=\(preset.rawValue) values=\(String(describing:model.camera.readings))")
                try await self.complete(model,service:service,preset:preset)
                XCTAssertFalse(model.manualExposure); XCTAssertEqual(model.mode,.auto)
            }
        }
    }

    @MainActor func testAdaptiveStarTrailsFullDuration() async throws {
        try await withCamera { model,service in
            try await self.prepare(model,preset:.starTrails,manual:false)
            try await self.complete(model,service:service,preset:.starTrails)
            XCTAssertFalse(model.manualExposure); XCTAssertEqual(model.mode,.auto)
        }
    }

    @MainActor func testAdaptiveOtherPresetsManualEarlyFinishAndCancellation() async throws {
        try await withCamera { model,service in
            for preset in [SlowShutterPreset.lightTrails,.motionBlur,.panning] {
                try await self.prepare(model,preset:preset,manual:true)
                model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
                model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 8
                model.applyExposure(); model.applyWhiteBalance()
                try await self.complete(model,service:service,preset:preset)
                XCTAssertEqual(model.iso,200); XCTAssertEqual(model.shutter,log2(1.0/125),accuracy:0.0001)
                XCTAssertEqual(model.wb,5200); XCTAssertEqual(model.whiteBalanceTint,8)
            }
            try await self.prepare(model,preset:.starTrails,manual:true)
            var saved = service.photos.count
            model.takePhoto()
            try await self.wait(20,"星轨提前结束没有源帧",model) { (model.slowShutterSequenceProgress?.completed ?? 0)>=2 }
            let lockedExposure = (model.iso,model.shutter)
            model.selectSlowShutterPreset(.panning)
            XCTAssertEqual(model.selectedSlowShutterPreset,.starTrails,"序列中点击别的预设不能改写本次曝光")
            XCTAssertEqual(model.iso,lockedExposure.0); XCTAssertEqual(model.shutter,lockedExposure.1)
            model.takePhoto()
            try await self.wait(20,"星轨提前结束未保存",model) { service.photos.count>saved && !model.slowShutterComposing }
            saved = service.photos.count
            model.takePhoto()
            try await self.wait(20,"星轨取消没有进入采集",model) { model.slowShutterSequenceProgress != nil }
            model.toggleSlowShutterMode()
            try await self.wait(20,"星轨取消没有清空",model) { model.slowShutterSequenceProgress == nil && !model.slowShutterComposing && model.camera.pendingPhotoCount == 0 }
            XCTAssertEqual(service.photos.count,saved)
            for _ in 0..<10 {
                model.toggleSlowShutterMode(); model.selectSlowShutterPreset(.panning)
                model.selectSlowShutterPreset(.starTrails); model.toggleSlowShutterMode()
            }
            XCTAssertNil(model.selectedSlowShutterPreset)
            print("ADAPTIVE-RECOVERY manualPresets=3 starEarly=1 starCancel=1 rapidCycles=10 noSystemPhotos=true")
        }
    }

    @MainActor private func prepare(_ model: CameraViewModel, preset: SlowShutterPreset, manual: Bool) async throws {
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        model.setMode(manual ? .manual : .auto)
        model.photoFormat = preset == .silkyWater ? .heif : .jpeg
        model.ratio = .standard
        model.photoResolution = .standard
        model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.timerSeconds = 0
        model.flashMode = .off
        await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
        let routeTime = model.camera.previewFrameTimeForTesting
        try await wait(15, "预设前路线未稳定", model) {
            model.camera.ready && !model.camera.shutterBusy && !model.isPreparingSubmode
                && model.camera.previewFrameTimeForTesting > routeTime
        }
        model.toggleSlowShutterMode()
        try await wait(15, "慢门模式未准备好", model) { model.camera.ready && model.slowShutterEnabled }
        model.selectSlowShutterPreset(preset)
        XCTAssertEqual(model.selectedSlowShutterPreset, preset)
        let drained = expectation(description: "相机会话队列完成当前设置")
        model.camera.afterPendingSessionTasks { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 20)
        try await Task.sleep(for: .seconds(1))
        try await wait(15, "预设曝光未就绪", model) { model.camera.ready && !model.camera.shutterBusy && model.camera.readings?.validated != nil }
        model.camera.message = nil
    }

    @MainActor @discardableResult private func complete(_ model: CameraViewModel, service: SlowShutterMemoryLibrary, preset: SlowShutterPreset) async throws -> Double {
        var previewSamples = [(Double,Int,CGSize)]()
        let previewSubscription = model.$slowShutterAccumulationPreview.sink { value in
            if let value,value.revision>0,!value.isFinal { previewSamples.append((CACurrentMediaTime(),value.revision,value.image.size)) }
        }
        defer { previewSubscription.cancel() }
        let saved = service.photos.count
        let mode = model.mode, exposure = model.manualExposure, wb = model.manualWB, focus = model.manualFocus
        let baseline = footprint()
        var peak = baseline
        var lastLoggedFrame = -1
        let started = CACurrentMediaTime()
        let sourceCallback = model.camera.onSlowShutterSourceFrame
        var sourceExposures: [Double] = []
        var sourceTimes: [Double] = []
        var sourceISOs: [Double] = []
        var previousPreviewTime: Double?
        var maximumPreviewPublicationGap = 0.0
        model.camera.onSlowShutterSourceFrame = { frame in
            if let exif = frame?.image.properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let seconds = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                sourceExposures.append(seconds)
                sourceTimes.append(CACurrentMediaTime() - started)
                if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso = values.first {
                    sourceISOs.append(iso.doubleValue)
                }
            }
            sourceCallback?(frame)
        }
        defer { model.camera.onSlowShutterSourceFrame = sourceCallback }
        model.takePhoto()
        let expectedISO = model.iso
        let expectedExposure = pow(2,model.shutter)
        XCTAssertNotNil(model.slowShutterSequenceProgress, model.camera.message ?? "未开始序列")
        try await wait((preset.sequenceSpec?.captureDuration ?? 10)+60, "完整慢门序列未保存", model) {
            if let latest = model.camera.previewPublicationTimesForTestingSnapshot.last, latest >= started,
               latest != previousPreviewTime {
                if let previousPreviewTime { maximumPreviewPublicationGap = max(maximumPreviewPublicationGap, latest - previousPreviewTime) }
                previousPreviewTime = latest
            }
            if preset.usesStreamingComposition {
                XCTAssertLessThanOrEqual(model.retainedSlowShutterSourcesForTesting, 1,
                    "长序列不能随拍摄帧数保留全部解码源图")
            }
            peak = max(peak, self.footprint())
            let completed = model.slowShutterSequenceProgress?.completed ?? 0
            if completed != lastLoggedFrame && completed.isMultiple(of: 10) {
                lastLoggedFrame = completed
                print("SLOW-PROGRESS preset=\(preset.rawValue) frames=\(completed) retainedSources=\(model.retainedSlowShutterSourcesForTesting) hostFootprintMB=\(Double(self.footprint()) / 1048576)")
            }
            let failed = model.camera.message != nil && model.slowShutterSequenceProgress == nil
                && !model.slowShutterComposing && service.photos.count == saved
            return failed || (service.photos.count > saved && !model.slowShutterComposing && model.slowShutterSequenceProgress == nil)
        }
        let elapsed = CACurrentMediaTime() - started
        XCTAssertGreaterThanOrEqual(previewSamples.count,2,"完整序列应显示真实中间合成")
        for sample in previewSamples { XCTAssertLessThanOrEqual(max(sample.2.width,sample.2.height),901) }
        let gaps = zip(previewSamples,previewSamples.dropFirst()).map { $1.0-$0.0 }
        if let minimum = gaps.min() { XCTAssertGreaterThanOrEqual(minimum,0.42,"预览更新应节流，避免每源帧重绘") }
        print("SLOW-ACCUMULATION preset=\(preset.rawValue) previews=\(previewSamples.count) minPublicationInterval=\(gaps.min() ?? 0) final=\(model.slowShutterAccumulationPreview?.isFinal == true)")
        guard service.photos.count > saved else {
            XCTFail(model.camera.message ?? "没有合成输出")
            throw NSError(domain:"SlowShutterCaptureFailure",code:1)
        }
        let spec = try XCTUnwrap(preset.sequenceSpec).applying(model.slowShutterDuration)
        XCTAssertGreaterThanOrEqual(sourceExposures.count,spec.minimumFrames)
        XCTAssertLessThanOrEqual(sourceExposures.count,spec.frameCount)
        if sourceExposures.count < spec.frameCount {
            XCTAssertGreaterThanOrEqual((sourceTimes.last ?? 0)-(sourceTimes.first ?? 0),(spec.captureDuration ?? 0)-0.05)
        }
        for seconds in sourceExposures { XCTAssertEqual(seconds,expectedExposure,accuracy:max(0.00005,expectedExposure*0.02)) }
        XCTAssertEqual(sourceISOs.count, sourceExposures.count)
        if mode == .manual || preset.sequenceSpec != nil {
            for iso in sourceISOs { XCTAssertEqual(iso, expectedISO, accuracy: max(2, expectedISO * 0.02)) }
        }
        print("SLOW-PHASE-TIMES preset=\(preset.rawValue) sourceSeconds=\(sourceTimes) finalEncodeSeconds=\(elapsed - (sourceTimes.last ?? 0)) ISO=\(sourceISOs) previewPublicationMaxGap=\(maximumPreviewPublicationGap)")
        print("SLOW-SOURCE-EXPOSURES preset=\(preset.rawValue) seconds=\(sourceExposures)")
        let photo = try XCTUnwrap(service.photos.last)
        let data = try XCTUnwrap(photo.resources.first?.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(metadata[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(metadata[kCGImagePropertyPixelHeight as String] as? Int)
        XCTAssertGreaterThan(width * height, 11_000_000)
        let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double), expectedExposure, accuracy: max(0.00005,expectedExposure*0.02), "实际首帧必须使用计划曝光，不能用预览曝光冒充")
        XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings as String])
        XCTAssertNotNil(exif[kCGImagePropertyExifFocalLength as String])
        XCTAssertNotNil(photo.diagnostics?.parameters)
        let row = photo.diagnostics?.rows.first { $0.title == "慢门合成" }?.value
        XCTAssertEqual(photo.diagnostics?.parameters?.mode, mode == .auto ? "A" : "M")
        if preset.sequenceSpec?.blend == .subjectAlignedAverage || preset.sequenceSpec?.blend == .handheldAlignedAverage || preset.sequenceSpec?.blend == .handheldAlignedLighten {
            let method = photo.diagnostics?.rows.first { $0.title == "合成方式" }?.value
            let rejected = Int(photo.diagnostics?.rows.first { $0.title == "对齐剔除" }?.value
                .split(separator: " ").first ?? "0") ?? 0
            let effective = method?.contains("单帧") == true ? 1 : sourceExposures.count - rejected
            XCTAssertTrue(row?.contains("\(effective) 帧") == true)
            XCTAssertEqual(photo.diagnostics?.rows.first { $0.title == "实际采集" }?.value,"\(sourceExposures.count) 帧")
        } else { XCTAssertTrue(row?.contains("\(sourceExposures.count) 帧") == true) }
        XCTAssertEqual(model.mode, mode)
        XCTAssertEqual(model.manualExposure, exposure)
        XCTAssertEqual(model.manualWB, wb)
        XCTAssertEqual(model.manualFocus, focus)
        try await wait(15, "合成后相机仍忙碌", model) { model.camera.ready && !model.camera.shutterBusy && model.camera.pendingPhotoCount == 0 }
        print("SLOW-FULL preset=\(preset.rawValue) mode=\(mode) seconds=\(elapsed) baselineMB=\(Double(baseline)/1048576) peakMB=\(Double(peak)/1048576) size=\(width)x\(height) EXIF=\(exif) row=\(row ?? "missing") thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        service.photos.removeAll() // 不让上一张的编码资源影响下一组内存样本。
        return elapsed
    }

    @MainActor private func withCamera(_ run: (CameraViewModel, SlowShutterMemoryLibrary) async throws -> Void) async throws {
        let runtimeAudit = SessionRuntimeErrorAudit()
        defer { runtimeAudit.finish() }
        let visible = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        visible.setCameraActive(false)
        await Task.yield()
        for _ in 0..<200 {
            let running = await withCheckedContinuation { c in visible.camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
            if !running && !visible.camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await withCheckedContinuation { c in visible.camera.afterPendingSessionTasks { c.resume() } }
        let service = SlowShutterMemoryLibrary()
        let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: service,
            filterSettings: FilterSettingsStore(defaults: nil), preferencesStore: CapturePreferencesStore(defaults: nil))
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdle
        }
        model.setCameraActive(true)
        try await wait(20, "诊断相机没有出帧", model) { model.camera.ready && model.camera.preview != nil }
        if let main = model.camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 }) {
            model.camera.selectLens(main)
        }
        let drained = expectation(description: "相机会话队列完成当前设置")
        model.camera.afterPendingSessionTasks { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 20)
        try await wait(20, "主摄没有就绪", model) { model.camera.ready && !model.camera.shutterBusy }
        func stopAndDrain() async {
            model.setCameraActive(false)
            await Task.yield()
            for _ in 0..<300 {
                let running = await withCheckedContinuation { c in model.camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
                if !running && !model.camera.ready { break }
                try? await Task.sleep(for:.milliseconds(20))
            }
        }
        do {
            try await run(model,service)
            XCTAssertEqual(model.library.pendingSaveCount,0)
            await stopAndDrain()
        } catch {
            await stopAndDrain()
            throw error
        }
    }

    @MainActor private func wait(_ seconds: Double, _ message: String, _ model: CameraViewModel, until predicate: () -> Bool) async throws {
        let end = CACurrentMediaTime() + seconds
        while !predicate(), CACurrentMediaTime() < end { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else {
            XCTFail("\(message); message=\(model.camera.message ?? "none") progress=\(String(describing: model.slowShutterSequenceProgress))")
            throw NSError(domain: "SlowShutterPhysicalTest", code: 1)
        }
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    #endif
}

/// 仅记录真实合成文件与回调，隔离系统相册写入、删除和权限弹窗。
private struct SlowAccumulationPhysicalHost:View {
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

private final class SlowShutterMemoryLibrary: PhotoLibraryService, PhotoBrowserService {
    var photos: [CapturedPhoto] = []
    var onLibraryChange: (() -> Void)?
    func canReloadSavedPhoto(id: String) -> Bool { false }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success(UUID().uuidString)) }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) {
        photos.append(photo)
        completion(.success(UUID().uuidString))
    }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { PhotoImageRequest(cancel: {}) }
}
