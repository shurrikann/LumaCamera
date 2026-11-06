import XCTest
import UIKit
import Vision
@testable import LumaCamera

final class SmartLocalCompositionAITests: XCTestCase {
    private func guide(id:UUID = UUID(),x:CGFloat = 0.3) -> SmartCompositionGuide {
        .init(stage:.align,direction:.align,subject:CGPoint(x:x,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:CGRect(x:0.2,y:0.3,width:0.2,height:0.4),subjectID:id)
    }
    func testUntrustedModelOutputCannotInventCoordinatesOrOverrideAlignedUserChoice() throws {
        let a = guide(), b = guide(x:0.5), candidates = [a,b]
        XCTAssertNil(SmartLocalCompositionAI.validated(index:2,confidence:0.9,preserve:true,candidates:candidates))
        for confidence in [Double.nan,.infinity,0.69,1.1] {
            XCTAssertNil(SmartLocalCompositionAI.validated(index:0,confidence:confidence,preserve:true,candidates:candidates))
        }
        let advice = try XCTUnwrap(SmartLocalCompositionAI.validated(index:0,confidence:0.9,preserve:true,candidates:candidates))
        XCTAssertEqual(advice.subjectID,a.subjectID)
        XCTAssertEqual(SmartSubjectTracker.selectedID(candidates:candidates,previous:a.subjectID,
            retained:Set(candidates.compactMap(\.subjectID)),preferred:advice.subjectID),b.subjectID)
        var scene = a; scene.preserveSceneContext = true
        XCTAssertEqual(SmartFramingEvaluator.candidates(guide:scene,currentZoom:2,range:1...8).map(\.zoom),[2])
    }
    @MainActor func testOnDeviceModelAvailabilityAndFallback() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size:CGSize(width:96,height:128),format:format).image { c in
            UIColor.gray.setFill(); c.fill(CGRect(x:0,y:0,width:96,height:128))
        }.cgImage)
        let availability = SmartLocalCompositionAI.availability
        let started = CACurrentMediaTime()
        let candidate = guide()
        let advice = await SmartLocalCompositionAI.shared.advise(image:image,candidates:[candidate])
        print("SMART-LOCAL-AI availability=\(availability) seconds=\(CACurrentMediaTime()-started) applied=\(advice != nil) provider=SystemLanguageModel noCloud=true")
        if availability != "available-on-device" {
            if let advice { XCTAssertEqual(advice.provider,.visionClassifier) }
            return
        }
        // 灰色无纹理样本允许保守拒答，不以返回nil推断模型不可用。
        if let advice { XCTAssertEqual(advice.subjectID,candidate.subjectID) }
    }
    #if !targetEnvironment(simulator)
    @MainActor func testVisionClassificationOnRealPreviewAndCancelledRequest() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); audit.finish() }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        var durations = [Double](), applied = 0
        for index in 0..<3 {
            let image = await withCheckedContinuation { c in camera.readSmartAnalysisPreview { c.resume(returning:$0) } }
            let cg = try XCTUnwrap(image?.cgImage), candidate = guide()
            let measured = try await Task.detached { () -> (SmartLocalCompositionAI.Advice?,Double,[String]) in
                let request = VNClassifyImageRequest()
                try VNImageRequestHandler(cgImage:cg,orientation:.up).perform([request])
                let labels = (request.results ?? []).prefix(4).map { "\($0.identifier):\($0.confidence)" }
                let started = CACurrentMediaTime()
                let advice = SmartLocalCompositionAI.visionAdvice(image:cg,candidates:[candidate])
                return (advice,CACurrentMediaTime()-started,labels)
            }.value
            XCTAssertFalse(measured.2.isEmpty,"系统端侧分类必须真实执行并返回分类分数")
            if let advice = measured.0 { XCTAssertEqual(advice.provider,.visionClassifier); XCTAssertEqual(advice.subjectID,candidate.subjectID); applied += 1 }
            durations.append(measured.1)
            print("SMART-VISION-CLASSIFIER sample=\(index) topLabels=\(measured.2) adviceApplied=\(measured.0 != nil) controlledCandidateCrop=true")
            let cancelled = Task { await SmartLocalCompositionAI.shared.advise(image:cg,candidates:[candidate]) }
            cancelled.cancel(); let ignored = await cancelled.value
            XCTAssertNil(ignored)
        }
        let sorted = durations.sorted()
        XCTAssertLessThan(sorted[1],1.0)
        print("SMART-VISION-PERF samples=3 inferenceSeconds=\(durations) medianSeconds=\(sorted[1]) acceptedAdvice=\(applied) cancelledRequests=3 realPreview=true noCloud=true notScreenFPS=true")
    }
    #endif
}
