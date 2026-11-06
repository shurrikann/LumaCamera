import XCTest
import Foundation
@testable import LumaCamera

final class SmartCapturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRecordedRealPreviewSubjectContinuity() throws {
        let url = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("SmartVisibilityReference.png")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"本次临时预览回放未准备")
        defer { try? FileManager.default.removeItem(at:url) }
        let image = try XCTUnwrap(UIImage(contentsOfFile:url.path)),cg = try XCTUnwrap(image.cgImage)
        let result = SmartCaptureAnalyzer.analyze(image:image,readings:nil,activeSubmode:nil)
        print("SMART-RECORDED-DIAG \(result.candidates.map { $0.subjectRect }) admitted=\(result.candidates.count)")
        XCTAssertFalse(result.candidates.isEmpty,"记录画面包含完整主体，不能把删光点位当作稳定性修正")
        let tracker = SmartSubjectTracker()
        var missing = 0,identities = Set<UUID>()
        for i in 0..<24 {
            let value = tracker.update(image:cg,candidates:result.candidates,context:"recorded-preview",at:Double(i)/15)
            print("SMART-RECORDED-TRACK sample=\(i) retained=\(value.retainedCount) displayed=\(value.candidates.count) object=\(value.objectTrackedCount) appearance=\(value.appearanceVerifiedCount)")
            if let id = value.selected?.subjectID { identities.insert(id) } else { missing += 1 }
        }
        XCTAssertEqual(missing,0);XCTAssertEqual(identities.count,1)
    }

    /// 静态回放真实预览，分开定位提名/结构筛选/纹理复核；不要求用户配合移动。
    @MainActor func testRealPreviewNominationAndStaticTrackingDiagnostic() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(),camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setSmartCaptureForTesting(false);model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(20)) }
        model.setMode(.manual)
        try await Task.sleep(for:.seconds(1))
        let neutral:UIImage? = await withCheckedContinuation { c in camera.readSmartAnalysisPreview { c.resume(returning:$0) } }
        let image = try XCTUnwrap(neutral.flatMap { SmartCaptureAnalyzer.visibleImage($0,aspect:model.ratio.portraitRatio) })
        let cg = try XCTUnwrap(image.cgImage)
        let result = SmartCaptureAnalyzer.analyze(image:image,readings:camera.readings,activeSubmode:nil)
        print("SMART-STRUCTURE-DIAG \(result.candidates.map { $0.subjectRect }) admitted=\(result.candidates.count)")
        let tracker = SmartSubjectTracker()
        for i in 0..<12 {
            let value = tracker.update(image:cg,candidates:result.candidates,context:"static-preview",at:Double(i)/15)
            print("SMART-STATIC-DIAG sample=\(i) retained=\(value.retainedCount) displayed=\(value.candidates.count) verified=\(value.candidates.filter(\.trackingVerified).count) objectTracked=\(value.objectTrackedCount) appearance=\(value.appearanceVerifiedCount)")
        }
        let a = XCTAttachment(image:image);a.name = "Smart-neutral-static-diagnostic";a.lifetime = .keepAlways;add(a)
    }

    /// 现场效果单列：只统计未对齐阶段，不能把完成后按设计隐藏当成跟踪漏检。
    @MainActor func testLiveUnalignedStructureRecommendationVisibility() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(),camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled,audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setSmartCaptureForTesting(false);model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle;audit.finish()
        }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setMode(.manual)
        for _ in 0..<400 { if camera.ready && model.focalTransitionImage == nil { break };try await Task.sleep(for:.milliseconds(20)) }
        model.setSmartCaptureForTesting(true);model.resetSmartTrackingSamplesForTesting()
        var eligible = 0,visible = 0,missing = 0,identityChanges = 0,lastID:UUID?,seenIDs = Set<UUID>()
        var longestMissing = 0.0,missingSince:Double?
        let start = CACurrentMediaTime()
        for _ in 0..<60 {
            try await Task.sleep(for:.milliseconds(200))
            guard !model.smartAlignmentLatched,!model.smartFramingInProgress,!model.smartFramingComplete,
                  model.smartTrackingSamplesForTesting.last?.recommendationsAllowed == true else { continue }
            eligible += 1
            if let guide = model.smartDisplayedCompositionGuide {
                visible += 1
                var ids = Set(model.smartCompositionCandidates.compactMap(\.subjectID))
                if let id = guide.subjectID { ids.insert(id) }
                if !seenIDs.isEmpty { identityChanges += ids.subtracting(seenIDs).count }
                seenIDs.formUnion(ids)
                lastID = guide.subjectID
                if let since = missingSince { longestMissing = max(longestMissing,CACurrentMediaTime()-since);missingSince = nil }
            } else {
                missing += 1
                // 只在已经出现过候选后计时，不能把首次检测等待当成闪灭。
                if lastID != nil && missingSince == nil { missingSince = CACurrentMediaTime() }
            }
        }
        if let since = missingSince { longestMissing = max(longestMissing,CACurrentMediaTime()-since) }
        let samples = model.smartTrackingSamplesForTesting
        let intervals = zip(samples,samples.dropFirst()).map { $1.publishedAt-$0.publishedAt }.sorted()
        let costs = samples.map(\.processingSeconds).sorted()
        print("SMART-VISIBILITY-LIVE seconds=\(CACurrentMediaTime()-start) eligiblePolls=\(eligible) visiblePolls=\(visible) missingPolls=\(missing) identityChanges=\(identityChanges) longestObservedGap=\(longestMissing) analysisSamples=\(samples.count) heldSamples=\(samples.filter { $0.displayedCandidates>0 && $0.verifiedCandidates==0 }.count) objectTrackedSamples=\(samples.filter { $0.objectTrackedCandidates>0 }.count) appearanceVerifiedSamples=\(samples.filter { $0.appearanceVerifiedCandidates>0 }.count) processingMedian=\(costs.isEmpty ? 0:costs[costs.count/2]) publicationMedian=\(intervals.isEmpty ? 0:intervals[intervals.count/2]); 200ms polling, not screen FPS")
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where:\.isKeyWindow))
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image);attachment.name = "Smart-structure-live-end";attachment.lifetime = .keepAlways;add(attachment)
        try XCTSkipUnless(visible >= 5,"现场没有足够未对齐的结构候选，不能算推荐点稳定性验收")
        XCTAssertEqual(identityChanges,0,"固定现场未对齐主体不应反复改成新的推荐身份")
        XCTAssertLessThanOrEqual(longestMissing,0.45,"固定现场出现连续多个200ms观察窗口无点，需保留失败继续定位")
        XCTAssertEqual(camera.pendingPhotoCount,0)
        // 长期目标离开时消失是正确行为；不以“不许消失”掩盖真实跟踪丢失。
    }

    @MainActor func testLiveTrackingCadenceDismissalAndRepeatedPopupCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.toolbarPanel = nil; model.setSmartCaptureForTesting(false); model.setCameraActive(false); audit.finish() }
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail("智拍真机状态未就绪：\(camera.message ?? "none")"); throw CancellationError()
        }
        model.setCameraActive(true)
        try await wait { camera.ready && camera.preview != nil }
        model.setMode(.manual)
        try await wait { camera.ready && model.mode == .manual }
        model.setSmartCaptureForTesting(true); model.resetSmartTrackingSamplesForTesting()
        try await Task.sleep(for:.seconds(4))
        var rangePositions = [Double](), rangeTimes = Set<Double>()
        for _ in 0..<8 {
            let reading = try XCTUnwrap(camera.readings)
            let position = try XCTUnwrap(reading.recommendationFocusPosition)
            XCTAssertTrue(position.isFinite && (0...1).contains(position))
            XCTAssertFalse(try XCTUnwrap(reading.recommendationFocusDeviceID).isEmpty)
            rangePositions.append(position)
            rangeTimes.insert(try XCTUnwrap(reading.sampleHostTime))
            try await Task.sleep(for:.milliseconds(450))
        }
        XCTAssertGreaterThan(rangeTimes.count,1,"必须收到真实新样本，不能把同一读数重复计为稳定")
        print("SMART-RANGE-LIVE samples=8 uniqueSampleTimes=\(rangeTimes.count) activePrimaryPositions=\(rangePositions) notMeasuredDistance=true")
        let samples = model.smartTrackingSamplesForTesting
        XCTAssertGreaterThanOrEqual(samples.count,12)
        let intervals = zip(samples,samples.dropFirst()).map { $1.publishedAt-$0.publishedAt }.sorted()
        let trackOnly = samples.filter { !$0.detectedScene }.map(\.processingSeconds).sorted()
        XCTAssertFalse(trackOnly.isEmpty)
        if !trackOnly.isEmpty, !intervals.isEmpty {
            print("SMART-LIVE samples=\(samples.count) verifiedSamples=\(samples.filter { $0.verifiedCandidates > 0 }.count) detectionSamples=\(samples.filter(\.detectedScene).count) medianPublicationInterval=\(intervals[intervals.count/2]) trackingMedianSeconds=\(trackOnly[trackOnly.count/2]) maxRequestToPublicationSeconds=\(samples.map(\.requestToPublication).max() ?? 0) actualCamera=true notScreenFPS=true")
        }
        let beforeDismissal = model.smartTrackingSamplesForTesting.count
        model.dismissSmartSuggestion()
        try await Task.sleep(for:.milliseconds(550))
        XCTAssertGreaterThan(model.smartTrackingSamplesForTesting.count,beforeDismissal,"关闭参数建议不能暂停物体跟踪两秒")
        for _ in 0..<12 {
            model.toolbarPanel = .format
            try await Task.sleep(for:.milliseconds(90))
            XCTAssertNil(model.smartCompositionGuide); XCTAssertTrue(model.smartCompositionCandidates.isEmpty)
            model.toolbarPanel = nil
            try await Task.sleep(for:.milliseconds(90))
        }
        model.setSmartCaptureForTesting(false)
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertNil(model.smartCompositionGuide); XCTAssertTrue(model.smartCompositionCandidates.isEmpty)
        XCTAssertFalse(model.smartFramingInProgress); XCTAssertFalse(camera.capturing)
        print("SMART-LIVE-STABILITY popupCycles=12 suggestionDismissKeepsTracking=true disabledClearsGuide=true noPhotosWrites=true")
    }

    @MainActor
    func testRealPreviewAnalysisPerformanceAndStability() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        defer {
            model.setSmartCaptureForTesting(false)
            model.setCameraActive(false)
        }
        model.setCameraActive(true)
        for _ in 0..<750 {
            if camera.ready, camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(camera.ready, camera.message ?? "相机未就绪")
        XCTAssertNotNil(camera.preview)

        model.setSmartCaptureForTesting(true)
        var durations: [Double] = []
        var analyzed = 0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(180))
            guard let image = camera.preview else { continue }
            let start = CFAbsoluteTimeGetCurrent()
            let result = SmartCaptureAnalyzer.analyze(image: image, readings: camera.readings,
                                                       activeSubmode: nil)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            durations.append(elapsed)
            analyzed += 1
            _ = result.composition
        }
        XCTAssertEqual(analyzed, 12)
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "SMART-PERF samples=%d median=%.1fms p95=%.1fms max=%.1fms",
                     analyzed, median, p95, sorted.last ?? 0))
        XCTAssertLessThan(median, 250, "真实预览分析中位耗时过高")
        XCTAssertLessThan(p95, 400, "真实预览分析 p95 过高")
        XCTAssertTrue(model.smartCaptureEnabled)
        XCTAssertFalse(camera.capturing)
    }
    #endif
}
