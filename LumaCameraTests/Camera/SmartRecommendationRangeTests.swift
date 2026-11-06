import XCTest
import QuartzCore
@testable import LumaCamera

final class SmartRecommendationRangeTests: XCTestCase {
    func testNearMacroAndStableFarRecoveryWithHysteresis() {
        var gate = SmartRecommendationRangePolicy()
        XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:0))
        XCTAssertTrue(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:0.4))
        XCTAssertTrue(gate.update(position:0.2,adjusting:false,macro:false,deviceID:"wide",sampleTime:0.8))
        XCTAssertFalse(gate.update(position:0.2,adjusting:false,macro:false,deviceID:"wide",sampleTime:1.2))
        for i in 0..<20 { XCTAssertFalse(gate.update(position:i%2 == 0 ? 0.4 : 0.47,adjusting:false,macro:false,deviceID:"wide",sampleTime:1.3+Double(i)/10)) }
        XCTAssertFalse(gate.update(position:0.8,adjusting:true,macro:false,deviceID:"wide",sampleTime:3.4))
        XCTAssertFalse(gate.update(position:0.8,adjusting:false,macro:false,deviceID:"wide",sampleTime:3.8))
        XCTAssertTrue(gate.update(position:0.8,adjusting:false,macro:false,deviceID:"wide",sampleTime:4.2))
        XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:true,deviceID:"wide",sampleTime:4.6))
    }
    func testRepeatedSampleUnknownAndNewDeviceCannotPretendConfirmedFar() {
        var gate = SmartRecommendationRangePolicy()
        XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:0))
        for _ in 0..<100 { XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:0)) }
        XCTAssertFalse(gate.update(position:.nan,adjusting:false,macro:false,deviceID:"wide",sampleTime:0.5))
        XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:1))
        XCTAssertTrue(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"wide",sampleTime:1.4))
        XCTAssertFalse(gate.update(position:0.9,adjusting:false,macro:false,deviceID:"tele",sampleTime:1.8))
        XCTAssertFalse(gate.update(position:nil,adjusting:false,macro:false,deviceID:nil,sampleTime:nil))
    }
    func testRepeatedNearFarPolicyPerformance() {
        let started = CACurrentMediaTime()
        var changes = 0
        for _ in 0..<1000 {
            var gate = SmartRecommendationRangePolicy()
            _ = gate.update(position:0.8,adjusting:false,macro:false,deviceID:"wide",sampleTime:0)
            if gate.update(position:0.8,adjusting:false,macro:false,deviceID:"wide",sampleTime:0.4) { changes += 1 }
            _ = gate.update(position:0.1,adjusting:false,macro:false,deviceID:"wide",sampleTime:0.8)
            if !gate.update(position:0.1,adjusting:false,macro:false,deviceID:"wide",sampleTime:1.2) { changes += 1 }
        }
        XCTAssertEqual(changes,2000)
        print("SMART-RANGE-PERF cycles=1000 samples=4000 seconds=\(CACurrentMediaTime()-started) purePolicy=true notDistanceInMeters=true")
    }
    @MainActor func testModelHidesNearPointsButRestoresLargeFarSceneAndCancelsPendingWork() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.smartAnalysisOverrideForTesting = false; model.smartFramingEvaluatorForTesting = nil; model.setSmartCaptureForTesting(false); model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
        func reading(_ focus:Double,_ time:Double) -> CameraReadings {
            .init(iso:200,seconds:1.0/125,kelvin:5200,focus:focus,sampleHostTime:time,
                  recommendationFocusPosition:focus,recommendationFocusDeviceID:"controlled-wide")
        }
        let id = UUID()
        let guide = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.7,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:CGRect(x:0.05,y:0.05,width:0.9,height:0.9),subjectID:id)
        model.injectSmartRangeForTesting(reading(0.2,0),macro:false)
        model.injectSmartTrackingForTesting(.init(selected:guide,candidates:[guide]),bypassRangePolicy:false)
        XCTAssertNil(model.smartDisplayedCompositionGuide)
        model.injectSmartRangeForTesting(reading(0.9,0.4),macro:false)
        model.injectSmartRangeForTesting(reading(0.9,0.8),macro:false)
        model.injectSmartTrackingForTesting(.init(selected:guide,candidates:[guide]),bypassRangePolicy:false)
        XCTAssertEqual(model.smartDisplayedCompositionGuide?.subjectID,id,"远处大建筑不能仅因框大被当成近物排除")
        let initialActions = model.smartAutoFramingCountForTesting, initialZoom = camera.currentZoom
        model.smartFramingEvaluatorForTesting = { _,_,zoom,range,_ in
            Thread.sleep(forTimeInterval:0.6)
            return .init(recommendation:.init(zoom:min(range.upperBound,zoom*1.3),cropScale:1/1.3),scores:[0.1,0.3])
        }
        let aligned = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:guide.subjectRect,subjectID:id)
        model.injectSmartTrackingForTesting(.init(selected:aligned,candidates:[aligned]),bypassRangePolicy:false)
        try await Task.sleep(for:.milliseconds(800))
        model.injectSmartTrackingForTesting(.init(selected:aligned,candidates:[aligned]),bypassRangePolicy:false)
        XCTAssertTrue(model.smartFramingInProgress)
        model.injectSmartRangeForTesting(reading(0.1,1.2),macro:false)
        model.injectSmartRangeForTesting(reading(0.1,1.6),macro:false)
        XCTAssertNil(model.smartDisplayedCompositionGuide); XCTAssertTrue(model.smartCompositionCandidates.isEmpty)
        XCTAssertFalse(model.smartFramingInProgress)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialActions)
        XCTAssertEqual(camera.currentZoom,initialZoom,"近景取消后迟到评分不能执行变焦")
        model.injectSmartRangeForTesting(reading(0.9,2),macro:false)
        model.injectSmartRangeForTesting(reading(0.9,2.4),macro:false)
        model.injectSmartTrackingForTesting(.init(selected:guide,candidates:[guide]),bypassRangePolicy:false)
        XCTAssertNotNil(model.smartDisplayedCompositionGuide)
        model.injectSmartRangeForTesting(reading(0.9,2.8),macro:true)
        XCTAssertNil(model.smartDisplayedCompositionGuide)
        print("SMART-RANGE-MODEL controlledNearFarCycles=2 largeFarBoxPreserved=true macroHides=true noPhotosWrites=true")
    }
}
