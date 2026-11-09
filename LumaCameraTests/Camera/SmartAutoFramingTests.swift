import XCTest
import UIKit
import SwiftUI
import ImageIO
@testable import LumaCamera

final class SmartAutoFramingTests:XCTestCase {
    private func guide(x:CGFloat = 0.5,height:CGFloat = 0.2,kind:SmartCompositionGuide.SubjectKind = .salient,id:UUID? = nil) -> SmartCompositionGuide {
        SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:x,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectRect:CGRect(x:x-0.05,y:0.5-height/2,width:0.1,height:height),subjectKind:kind,subjectID:id)
    }
    func testStableAlignmentAndJitterDoNotRepeatZoom() {
        var gate = SmartAutoFramingGate()
        XCTAssertFalse(gate.update(guide(),at:0)); XCTAssertFalse(gate.update(guide(),at:0.6))
        XCTAssertTrue(gate.update(guide(),at:0.8)); gate.finish()
        for i in 0..<100 { XCTAssertFalse(gate.update(guide(x:i%2 == 0 ? 0.49 : 0.51),at:1+Double(i)/10)) }
        XCTAssertTrue(gate.completed)
    }
    func testEarlyVisualAlignmentDoesNotShortenAutomaticFramingDwell() {
        var gate = SmartAutoFramingGate()
        XCTAssertFalse(gate.update(guide(),at:0)); XCTAssertFalse(gate.alignmentConfirmed)
        XCTAssertFalse(gate.update(guide(),at:0.17)); XCTAssertFalse(gate.alignmentConfirmed)
        XCTAssertFalse(gate.update(guide(),at:0.18)); XCTAssertTrue(gate.alignmentConfirmed)
        XCTAssertFalse(gate.update(guide(),at:0.74))
        XCTAssertTrue(gate.update(guide(),at:0.75))
        gate.interrupt(); XCTAssertFalse(gate.alignmentConfirmed)
    }
    func testMovingSubjectAndCancellationRestartDwell() {
        var gate = SmartAutoFramingGate()
        XCTAssertFalse(gate.update(guide(),at:0)); XCTAssertFalse(gate.update(guide(x:0.6),at:0.7))
        XCTAssertFalse(gate.update(guide(),at:0.8)); XCTAssertFalse(gate.update(guide(),at:1.4))
        gate.interrupt(); XCTAssertFalse(gate.update(guide(),at:1.6)); XCTAssertTrue(gate.update(guide(),at:2.4))
    }
    func testLeavingSubjectAllowsNextSceneAfterGrace() {
        var gate = SmartAutoFramingGate(); gate.finish()
        XCTAssertFalse(gate.update(nil,at:0)); XCTAssertFalse(gate.update(nil,at:0.2)); XCTAssertTrue(gate.completed)
        XCTAssertFalse(gate.update(nil,at:0.4)); XCTAssertTrue(gate.completed)
        XCTAssertFalse(gate.update(guide(x:0.62),at:0.5)); XCTAssertFalse(gate.completed)
        XCTAssertFalse(gate.update(guide(),at:1.7)); XCTAssertTrue(gate.update(guide(),at:2.5))
    }
    func testMovingAwayRearmsSameSubjectAndReturningCanAlignAgain() {
        var gate = SmartAutoFramingGate()
        gate.finish()
        for i in 0..<20 { XCTAssertFalse(gate.update(guide(x:i%2 == 0 ? 0.49 : 0.51),at:Double(i)/30)) }
        XCTAssertTrue(gate.completed)
        XCTAssertFalse(gate.update(guide(x:0.62),at:0.7))
        XCTAssertFalse(gate.update(guide(x:0.62),at:0.95))
        XCTAssertFalse(gate.completed,"明显移开应重新显示推荐点")
        XCTAssertFalse(gate.update(guide(),at:1.0))
        XCTAssertTrue(gate.update(guide(),at:1.8))
    }
    func testOwnZoomGraceDoesNotPreventLaterSceneLossRearming() {
        var gate = SmartAutoFramingGate(); gate.finish()
        for i in 0..<7 { XCTAssertFalse(gate.update(nil,at:Double(i)/10)) }
        XCTAssertTrue(gate.completed,"自身变焦重提名不能立刻重复执行")
        XCTAssertFalse(gate.update(guide(),at:0.7))
        XCTAssertFalse(gate.update(nil,at:1))
        XCTAssertFalse(gate.update(nil,at:1.4)); XCTAssertTrue(gate.completed)
        XCTAssertFalse(gate.update(guide(x:0.62),at:1.5)); XCTAssertFalse(gate.completed)
        XCTAssertFalse(gate.update(guide(),at:1.6)); XCTAssertTrue(gate.update(guide(),at:2.4))
    }
    func testPredictedMarkerCannotTriggerAutomaticFraming() {
        var gate = SmartAutoFramingGate()
        XCTAssertFalse(gate.update(guide(), at: 0))
        var predicted = guide(); predicted.trackingVerified = false
        for i in 1...20 { XCTAssertFalse(gate.update(predicted, at: Double(i) * 0.1)) }
        XCTAssertFalse(gate.update(guide(), at: 2.1))
        XCTAssertFalse(gate.update(guide(), at: 2.7))
        XCTAssertTrue(gate.update(guide(), at: 2.9))
    }
    func testHandheldAlignmentSurvivesBriefMissesWithoutCountingThemAsConfirmed() {
        var gate = SmartAutoFramingGate(), fired = false
        for i in 0..<30 {
            var g = guide(x:0.48+CGFloat(i%20)*0.002)
            g.trackingVerified = i%4 != 3
            let shouldFrame = gate.update(g,at:Double(i)/15)
            if !g.trackingVerified { XCTAssertFalse(shouldFrame) }
            if shouldFrame { XCTAssertFalse(fired); fired = true; gate.finish() }
        }
        XCTAssertTrue(fired,"圈内手持轻微漂移和单帧漏检不能永远无法对齐")
    }
    func testBriefBoundaryExcursionPausesAndLongLossRestartsAlignment() {
        var gate = SmartAutoFramingGate()
        XCTAssertFalse(gate.update(guide(),at:0))
        XCTAssertFalse(gate.update(guide(),at:0.4))
        XCTAssertFalse(gate.update(guide(x:0.553),at:0.6))
        XCTAssertFalse(gate.update(guide(),at:0.7))
        XCTAssertTrue(gate.update(guide(),at:0.9))
        gate.reset()
        XCTAssertFalse(gate.update(guide(),at:0))
        XCTAssertFalse(gate.update(nil,at:0.5))
        XCTAssertFalse(gate.update(guide(),at:0.8))
        XCTAssertFalse(gate.update(guide(),at:1.4))
        XCTAssertTrue(gate.update(guide(),at:1.6))
    }
    func testRelativeZoomAndSubjectMargins() {
        XCTAssertEqual(SmartFramingRecommendation.make(subjectHeight:0.21,currentZoom:2,maxZoom:8)?.cropScale,0.5)
        XCTAssertNil(SmartFramingRecommendation.make(subjectHeight:0.7,currentZoom:4,maxZoom:8))
        for kind:SmartCompositionGuide.SubjectKind in [.face,.person,.group,.salient] {
            let g = guide(kind:kind), choices = SmartFramingEvaluator.candidates(guide:g,currentZoom:2,range:0.5...8)
            XCTAssertFalse(choices.isEmpty); XCTAssertLessThanOrEqual(choices.count,4)
            for choice in choices {
                XCTAssertEqual(choice.cropScale,2/choice.zoom,accuracy:0.0001)
                let s = choice.cropScale
                XCTAssertTrue(CGRect(x:(1-s)/2,y:(1-s)/2,width:s,height:s).contains(g.subjectRect))
                XCTAssertGreaterThanOrEqual(choice.zoom,2); XCTAssertLessThanOrEqual(choice.zoom,8)
            }
        }
    }
    func testAlignmentTextHonorsDwell() {
        var stabilizer = SmartCompositionStabilizer(), a = guide(); a = SmartCompositionGuide(stage:.align,direction:.align,subject:a.subject,target:a.target,text:"先对准中心")
        _ = stabilizer.update(a,at:0)
        XCTAssertEqual(stabilizer.update(guide(),at:0.01)?.text,"先对准中心")
        XCTAssertEqual(stabilizer.update(guide(),at:0.5)?.text,"已对准中心")
    }
    func testAlignmentUsesDrawnCircleRadiusAcrossRatios() {
        for aspect:CGFloat in [0.75,1,2.0/3,9.0/16,0.5,1/2.39,24.0/65,4.0/3] {
            var g = guide()
            g.imageAspect = aspect
            // 垂直位移按短边换算，点必须真的进入绘制圆圈才算对齐。
            let normalizedRadius = SmartCompositionGuide.alignmentRadius*min(1,aspect)
            g = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5+normalizedRadius*1.1),target:g.target,text:"先对准中心",imageAspect:aspect)
            XCTAssertGreaterThan(g.alignmentDistance,SmartCompositionGuide.alignmentRadius)
            g = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5+normalizedRadius*0.9),target:g.target,text:"已对准中心",imageAspect:aspect)
            XCTAssertLessThan(g.alignmentDistance,SmartCompositionGuide.alignmentRadius)
        }
    }
    @MainActor func testVisibleAnalysisCropsAllSupportedRatios() {
        let source = UIGraphicsImageRenderer(size:CGSize(width:900,height:1200)).image { c in UIColor.gray.setFill(); c.fill(CGRect(x:0,y:0,width:900,height:1200)) }
        for ratio in FrameRatio.allCases { for landscape in [false,true] {
            let aspect = landscape ? 1/ratio.portraitRatio : ratio.portraitRatio
            let image = SmartCaptureAnalyzer.visibleImage(source,aspect:aspect)
            XCTAssertNotNil(image)
            XCTAssertEqual(image!.size.width/image!.size.height,aspect,accuracy:0.01)
            XCTAssertLessThanOrEqual(max(image!.size.width,image!.size.height),769)
        } }
    }
    #if !targetEnvironment(simulator)
    @MainActor func testSmartFocusWaitsForAlignmentAndReleasesToNormalControls() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.smartAnalysisOverrideForTesting = false; model.smartFramingEvaluatorForTesting = nil; model.setSmartCaptureForTesting(false); model.setCameraActive(false); audit.finish() }
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail("智拍单次对焦状态未就绪"); throw CancellationError()
        }
        func hardware() async throws -> CameraEngine.SmartCaptureHardwareState {
            let value = await withCheckedContinuation { c in camera.smartCaptureHardwareStateForTesting { c.resume(returning:$0) } }
            return try XCTUnwrap(value)
        }
        model.setCameraActive(true); try await wait { camera.ready && camera.preview != nil }
        model.setMode(.manual); model.manualFocus = false; camera.setFocus(position:nil)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await wait { camera.ready && model.mode == .manual }
        for _ in 0..<100 {
            model.setSmartCaptureForTesting(true)
            if model.smartCaptureEnabled { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(model.smartCaptureEnabled,"硬件模式切换后实际开启智拍再注入候选")
        model.smartAnalysisOverrideForTesting = true
        let initial = try await hardware(), started = CACurrentMediaTime(), id = UUID()
        var target = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.30,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectRect:CGRect(x:0.30,y:0.3,width:0.4,height:0.4),subjectID:id)
        for _ in 0..<6 {
            model.injectSmartTrackingForTesting(.init(selected:target,candidates:[target]))
            try await Task.sleep(for:.milliseconds(66))
        }
        XCTAssertFalse(camera.smartFocusHolding)
        let beforeAlignment = try await hardware()
        XCTAssertEqual(beforeAlignment.smartFocusRequests,initial.smartFocusRequests,"未对齐不得先发起额外AF")
        model.smartFramingEvaluatorForTesting = { _,_,_,_,_ in .init(recommendation:nil,scores:[]) }
        target = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectRect:target.subjectRect,subjectID:id)
        model.injectSmartTrackingForTesting(.init(selected:target,candidates:[target]))
        try await Task.sleep(for:.milliseconds(800))
        model.injectSmartTrackingForTesting(.init(selected:target,candidates:[target]))
        try await wait { model.smartFramingComplete && !model.smartFramingInProgress }
        XCTAssertTrue(camera.smartFocusHolding)
        model.restoreDeviceParametersForTesting()
        var settled = false
        let acquisitionStarted = CACurrentMediaTime()
        // 真实AF可因当前纹理/焦距超过两秒；等待实际结束，之后仍严格核对保持窗口。
        for _ in 0..<500 {
            let state = try await hardware()
            if state.focusMode == .locked && !state.adjustingFocus { settled = true; break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(settled,"首次AF结束后应保持焦点，不能持续来回搜索")
        print("SMART-FOCUS-ACQUISITION observedWaitSeconds=\(CACurrentMediaTime()-acquisitionStarted) settled=\(settled) boundedTimeoutSeconds=10")
        var states = [CameraEngine.SmartCaptureHardwareState]()
        for _ in 0..<12 {
            let state = try await hardware(); states.append(state)
            XCTAssertEqual(state.focusMode,.locked,"智拍保持不能被参数恢复重新拉回持续AF")
            XCTAssertEqual(state.smartFocusRequests,initial.smartFocusRequests+1,"稳定候选不能逐帧重新对焦")
            model.injectSmartTrackingForTesting(.init(selected:target,candidates:[target]))
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(states.suffix(6).allSatisfy { !$0.adjustingFocus },"最终观察窗口不能继续扫描")
        let positions = states.map(\.lensPosition)
        XCTAssertLessThanOrEqual((positions.max() ?? 0)-(positions.min() ?? 0),0.005,
                                 "以实际镜头位置确认不再远近拉扯，不把锁定后的迟到状态标志当作运动")
        let held = try await hardware()
        // 对齐后的中心点按当前传感器映射仍为中心，原未对齐预AF已取消。
        XCTAssertEqual(held.focusPoint.x,0.5,accuracy:0.02); XCTAssertEqual(held.focusPoint.y,0.5,accuracy:0.02)
        model.setSmartCaptureForTesting(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let disabled = try await hardware()
        XCTAssertFalse(camera.smartFocusHolding); XCTAssertEqual(disabled.focusMode,.continuousAutoFocus)
        camera.focus(at:CGPoint(x:0.5,y:0.5),smartSingleShot:true)
        camera.setFocus(position:0.4)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let manual = try await hardware()
        XCTAssertFalse(camera.smartFocusHolding); XCTAssertEqual(manual.focusMode,.locked)
        camera.focus(at:CGPoint(x:0.5,y:0.5))
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let tapped = try await hardware()
        XCTAssertEqual(tapped.focusMode,.continuousAutoFocus)
        print("SMART-FOCUS-HOLD samples=12 elapsedSeconds=\(CACurrentMediaTime()-started) modes=\(states.map { $0.focusMode.rawValue }) lensPositions=\(states.map(\.lensPosition)) scanStates=\(states.map(\.adjustingFocus)) oneShotRequests=1 interiorPoint=\(held.focusPoint) disableRestoresContinuous=true manualOverride=true ordinaryTapContinuous=true controlledTarget=true noPhotosWrites=true")
    }

    @MainActor func testManualAlignmentOfAnotherVisibleCandidateRearmsCompletedRound() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.smartAnalysisOverrideForTesting = false; model.smartFramingEvaluatorForTesting = nil; model.setSmartCaptureForTesting(false); model.setCameraActive(false); audit.finish() }
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail("M挡多候选未重新触发"); throw CancellationError()
        }
        model.setCameraActive(true); try await wait { camera.ready && camera.preview != nil }
        model.setMode(.manual); try await wait { camera.ready && model.mode == .manual }
        model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
        model.smartFramingEvaluatorForTesting = { _,_,_,_,_ in .init(recommendation:nil,scores:[]) }
        let a = UUID(), b = UUID(), initialCount = model.smartAutoFramingCountForTesting
        model.injectSmartTrackingForTesting(.init(selected:nil,candidates:[guide(x:0.7,id:b)]))
        XCTAssertEqual(model.smartDisplayedCompositionGuide?.subjectID,b,"主选目标短暂漏检不能隐藏其他仍有效的推荐点")
        model.injectSmartCandidatesForTesting([guide(id:a),guide(x:0.7,id:b)])
        try await Task.sleep(for:.milliseconds(800))
        model.injectSmartCandidatesForTesting([guide(id:a),guide(x:0.7,id:b)])
        try await wait { model.smartFramingComplete && model.smartFramingFeedbackVisible }
        model.injectSmartCandidatesForTesting([guide(x:0.59,id:a),guide(id:b)])
        // 新目标必须先保持稳定，不能单帧抢走当前白点。
        XCTAssertEqual(model.smartCompositionGuide?.subjectID,a)
        try await Task.sleep(for:.milliseconds(700))
        model.injectSmartCandidatesForTesting([guide(x:0.59,id:a),guide(id:b)])
        XCTAssertEqual(model.smartCompositionGuide?.subjectID,b)
        XCTAssertFalse(model.smartFramingComplete); XCTAssertFalse(model.smartFramingFeedbackVisible)
        XCTAssertEqual(model.smartCompositionCandidates.count,2)
        try await Task.sleep(for:.milliseconds(800))
        model.injectSmartCandidatesForTesting([guide(x:0.59,id:a),guide(id:b)])
        try await wait { model.smartFramingComplete && model.smartFramingFeedbackVisible }
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialCount+2)
        print("SMART-M-MULTI completedRounds=2 switchedAlignedCandidate=true candidatesRedisplayed=2 noPhotosWrites=true controlledGuides=true")
    }
    @MainActor func testManualSmartFramingFocusExposureAndMoveAwayReturn() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), oldCallback = camera.onCaptureCompleted
        defer {
            model.toolbarPanel = nil; camera.onCaptureCompleted = oldCallback; model.smartAnalysisOverrideForTesting = false
            model.smartFramingEvaluatorForTesting = nil; model.setSmartCaptureForTesting(false)
            model.setCameraActive(false); audit.finish()
        }
        func wait(_ text:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(text+" \(camera.message ?? "none")"); throw CancellationError()
        }
        func hardware() async throws -> CameraEngine.SmartCaptureHardwareState {
            let state = await withCheckedContinuation { c in camera.smartCaptureHardwareStateForTesting { c.resume(returning:$0) } }
            return try XCTUnwrap(state)
        }
        model.setCameraActive(true); try await wait("初始取景",{ camera.ready && camera.preview != nil })
        model.setMode(.manual); model.photoFormat = .jpeg; model.photoResolution = .standard
        model.hdr = false; model.smoothPreview = false
        model.manualExposure = true; model.iso = 200; model.shutter = log2(1.0/125)
        model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 6
        model.applyExposure(); model.applyWhiteBalance()
        try await wait("M挡就绪",{ camera.ready && model.mode == .manual })
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for:.milliseconds(400))
        // 会话队列完成不代表传感器已应用；先确认真实M挡参数及WB稳定再取比较基线。
        var stableParameterSamples = 0
        var previousParameters:CameraEngine.SmartCaptureHardwareState?
        for _ in 0..<100 {
            let current = try await hardware()
            if current.customExposure, abs(current.iso-200)<4, abs(current.seconds-1.0/125)<0.00005,
               let previousParameters,
               abs(current.whiteBalanceGains.redGain-previousParameters.whiteBalanceGains.redGain)<0.01,
               abs(current.whiteBalanceGains.blueGain-previousParameters.whiteBalanceGains.blueGain)<0.01 {
                stableParameterSamples += 1
            } else { stableParameterSamples = 0 }
            previousParameters = current
            if stableParameterSamples >= 3 { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(stableParameterSamples,3,"传感器实际M挡参数未稳定")
        model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
        var times = [Double](), zooms = [CGFloat]()
        let initialActionCount = model.smartAutoFramingCountForTesting
        for index in 0..<3 {
            if index > 0 {
                XCTAssertFalse(model.smartFramingComplete); XCTAssertFalse(model.smartFramingFeedbackVisible)
                XCTAssertNotNil(model.smartDisplayedCompositionGuide,"拍完同场景无需挪开就应重新显示点")
            }
            model.manualFocus = true; model.focus = 0.4; camera.setFocus(position:0.4)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let before = try await hardware(), initialZoom = camera.currentZoom
            XCTAssertTrue(before.customExposure)
            model.smartFramingEvaluatorForTesting = { _,_,zoom,range,_ in
                index == 0 ? .init(recommendation:nil,scores:[]) :
                    .init(recommendation:.init(zoom:min(range.upperBound,zoom*1.15),cropScale:1/1.15),scores:[0.1,0.3])
            }
            let started = CACurrentMediaTime()
            model.injectSmartCompositionForTesting(guide())
            try await Task.sleep(for:.milliseconds(800)); model.injectSmartCompositionForTesting(guide())
            try await wait("M挡对齐未完成",{ model.smartFramingComplete && model.smartFramingFeedbackVisible && !model.smartFramingInProgress })
            times.append(CACurrentMediaTime()-started); zooms.append(camera.currentZoom)
            if index == 0 {
                let renderer = ImageRenderer(content:CameraView(model:model).smartCompositionGuideOverlay(guide())
                    .frame(width:240,height:320).background(.black))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage), cg = try XCTUnwrap(image.cgImage)
                var pixels = [UInt8](repeating:0,count:cg.width*cg.height*4)
                let bitmap = try XCTUnwrap(CGContext(data:&pixels,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
                let center = (cg.height/2*cg.width+cg.width/2)*4
                let ring = (cg.height/2*cg.width+cg.width/2+Int(CGFloat(min(cg.width,cg.height))*0.05))*4
                XCTAssertGreaterThan(Int(pixels[ring])-Int(pixels[ring+1]),50,"M挡完成时仍有短暂橙色圆圈反馈")
                XCTAssertLessThan(Int(pixels[center]),30,"完成后不再重新显示实心推荐点")
                let attachment = XCTAttachment(image:image); attachment.name = "Smart-M-completion-feedback"; attachment.lifetime = .keepAlways; add(attachment)
            }
            XCTAssertEqual(model.mode,.manual); XCTAssertTrue(model.manualExposure); XCTAssertTrue(model.manualWB)
            XCTAssertEqual(model.iso,200); XCTAssertEqual(pow(2,model.shutter),1.0/125,accuracy:0.000001)
            XCTAssertEqual(model.wb,5200); XCTAssertEqual(model.whiteBalanceTint,6); XCTAssertFalse(model.manualFocus)
            if index == 0 { XCTAssertEqual(camera.currentZoom,initialZoom,accuracy:0.001) }
            else { XCTAssertGreaterThan(camera.currentZoom,initialZoom) }
            let after = try await hardware()
            XCTAssertTrue(after.customExposure); XCTAssertNotEqual(after.focusMode,.continuousAutoFocus)
            XCTAssertTrue(camera.smartFocusHolding)
            XCTAssertEqual(after.smartFocusRequests,before.smartFocusRequests+1)
            XCTAssertEqual(after.focusPoint.x,0.5,accuracy:0.02); XCTAssertEqual(after.focusPoint.y,0.5,accuracy:0.02)
            XCTAssertEqual(after.iso,before.iso,accuracy:4); XCTAssertEqual(after.seconds,before.seconds,accuracy:0.00005)
            XCTAssertEqual(after.whiteBalanceGains.redGain,before.whiteBalanceGains.redGain,accuracy:0.03)
            XCTAssertEqual(after.whiteBalanceGains.blueGain,before.whiteBalanceGains.blueGain,accuracy:0.03)
            let captured = expectation(description:"M智拍后真实JPEG")
            var photo:CapturedPhoto?
            camera.onCaptureCompleted = { photo = $0; captured.fulfill() }
            let revisionBeforeShot = camera.deliveredPhotoRevision
            camera.capture(flashMode:.off,options:model.photoOptions)
            await fulfillment(of:[captured],timeout:30)
            let data = try XCTUnwrap(photo?.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
            XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime as String] as? Double),1.0/125,accuracy:0.00005)
            XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue),200,accuracy:4)
            XCTAssertEqual((exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue,1)
            try await wait("拍摄后未就绪",{ camera.ready && !camera.shutterBusy && camera.pendingPhotoCount == 0 })
            XCTAssertEqual(camera.deliveredPhotoRevision,revisionBeforeShot+1)
            XCTAssertFalse(model.smartFramingComplete); XCTAssertFalse(model.smartFramingFeedbackVisible)
            XCTAssertNotNil(model.smartDisplayedCompositionGuide)
            print("SMART-M-FILE sample=\(index) zoom=\(camera.currentZoom) ISO=\(String(describing:exif[kCGImagePropertyExifISOSpeedRatings as String])) seconds=\(String(describing:exif[kCGImagePropertyExifExposureTime as String])) AFMode=\(after.focusMode.rawValue) oneShotHold=\(camera.smartFocusHolding) hardwareExposurePreserved=true WBPreserved=true")
        }
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialActionCount+3)
        model.setSmartCaptureForTesting(false); model.setSmartCaptureForTesting(true)
        model.manualFocus = true; camera.setFocus(position:0.4)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let cancelledZoom = camera.currentZoom
        model.smartFramingEvaluatorForTesting = { _,_,zoom,range,_ in
            Thread.sleep(forTimeInterval:0.3)
            return .init(recommendation:.init(zoom:min(range.upperBound,zoom*1.3),cropScale:1/1.3),scores:[0.1,0.3])
        }
        model.injectSmartCompositionForTesting(guide())
        try await Task.sleep(for:.milliseconds(800)); model.injectSmartCompositionForTesting(guide())
        model.toolbarPanel = .format
        try await Task.sleep(for:.milliseconds(600))
        XCTAssertFalse(model.smartFramingInProgress); XCTAssertTrue(model.manualFocus)
        XCTAssertEqual(camera.currentZoom,cancelledZoom); XCTAssertEqual(model.mode,.manual)
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialActionCount+3)
        print("SMART-M-PERF samples=3 alignmentToFeedbackSeconds=\(times) zooms=\(zooms) sameScenePhotoRearms=3 realFiles=3 noPhotosWrites=true controlledGuidesAndScores=true")
    }

    @MainActor func testEmptyAestheticScoresStillFocusAndShowCompletionWithoutZoom() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer {
            model.smartAnalysisOverrideForTesting = false; model.smartFramingEvaluatorForTesting = nil
            model.setSmartCaptureForTesting(false); model.setCameraActive(false); audit.finish()
        }
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<750 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail("无评分对焦/完成反馈未出现：\(camera.message ?? "none")"); throw CancellationError()
        }
        model.setCameraActive(true); try await wait { camera.ready && camera.preview != nil }
        model.setMode(.auto); model.photoFormat = .jpeg; model.photoResolution = .standard
        try await wait { camera.ready && model.mode == .auto }
        var durations = [Double]()
        for _ in 0..<3 {
            model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
            model.smartFramingEvaluatorForTesting = { _,_,_,_,_ in .init(recommendation:nil,scores:[]) }
            let zoom = camera.currentZoom, started = CACurrentMediaTime(), count = model.smartAutoFramingCountForTesting
            model.injectSmartCompositionForTesting(guide())
            try await Task.sleep(for:.milliseconds(800)); model.injectSmartCompositionForTesting(guide())
            try await wait { model.smartFramingComplete && model.smartFramingFeedbackVisible && !model.smartFramingInProgress }
            durations.append(CACurrentMediaTime()-started)
            XCTAssertEqual(camera.currentZoom,zoom,accuracy:0.001)
            XCTAssertEqual(model.smartAutoFramingCountForTesting,count+1)
            for _ in 0..<20 { model.injectSmartCompositionForTesting(guide()) }
            XCTAssertEqual(model.smartAutoFramingCountForTesting,count+1)
            model.setSmartCaptureForTesting(false)
            XCTAssertFalse(model.smartFramingComplete); XCTAssertFalse(model.smartFramingFeedbackVisible)
        }
        print("SMART-EMPTY-SCORES samples=3 alignmentToFeedbackSeconds=\(durations) zoomUnchanged=true repeatedAlignedFrames=60 noPhotosWrites=true")
    }

    @MainActor func testAutomaticHardwareFramingOnceAndCancelPendingWork() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let initialCount=model.smartAutoFramingCountForTesting
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let audit = SessionRuntimeErrorAudit()
        defer { model.smartAnalysisOverrideForTesting = false; model.smartFramingEvaluatorForTesting = nil; model.setSmartCaptureForTesting(false); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ text:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(text+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("相机",{ camera.ready && camera.preview != nil })
        model.setMode(.auto); model.photoFormat = .jpeg; model.photoResolution = .standard
        model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
        model.smartFramingEvaluatorForTesting = { _,_,zoom,range,_ in .init(recommendation:.init(zoom:min(range.upperBound,zoom*1.2),cropScale:1/1.2),scores:[0.1,0.3]) }
        model.injectSmartCompositionForTesting(guide()); try await Task.sleep(for:.milliseconds(800)); model.injectSmartCompositionForTesting(guide())
        try await wait("自动取景完成",{ model.smartFramingComplete && !model.smartFramingInProgress })
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialCount+1)
        let zoom = camera.currentZoom
        for _ in 0..<30 { model.injectSmartCompositionForTesting(guide()) }
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialCount+1); XCTAssertEqual(camera.currentZoom,zoom)
        // 同一批候选评分未完成时打开弹窗，结果必须失效，不能再改倍率或焦点。
        model.setSmartCaptureForTesting(false); model.setSmartCaptureForTesting(true)
        model.smartFramingEvaluatorForTesting = { _,_,zoom,range,work in
            Thread.sleep(forTimeInterval:0.3)
            return .init(recommendation:.init(zoom:min(range.upperBound,zoom*1.2),cropScale:1/1.2),scores:[0.1,0.3])
        }
        model.injectSmartCompositionForTesting(guide()); try await Task.sleep(for:.milliseconds(800)); model.injectSmartCompositionForTesting(guide())
        model.toolbarPanel = .format
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertFalse(model.smartFramingInProgress); XCTAssertEqual(camera.currentZoom,zoom)
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialCount+1)
        model.toolbarPanel = nil; model.setMode(.manual)
        try await wait("M挡就绪",{ camera.ready && model.mode == .manual })
        model.injectSmartCompositionForTesting(guide()); try await Task.sleep(for:.milliseconds(850)); model.injectSmartCompositionForTesting(guide())
        try await wait("M挡自动取景完成",{ model.smartFramingComplete && !model.smartFramingInProgress })
        XCTAssertEqual(model.smartAutoFramingCountForTesting,initialCount+2)
        model.setCameraActive(false); XCTAssertFalse(camera.capturing)
        print("SMART-AUTO stability: initialCount=\(initialCount) completedDelta=\(model.smartAutoFramingCountForTesting-initialCount) repeatedAlignedFrames=30 popupCancel=true manualFramingEnabled=true noMediaSaved=true")
    }
    @MainActor func testBacklitPortraitWithoutBlurTracksAutomaticOrigin() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.smartAnalysisOverrideForTesting = false; model.setSmartCaptureForTesting(false)
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); model.setMode(.auto); model.photoFormat = .heif; model.photoResolution = .standard; model.hdr = false
        model.setSmartCaptureForTesting(true); model.smartAnalysisOverrideForTesting = true
        model.injectSmartSuggestionForTesting(.init(kind:.backlit,title:"人像 · +0.7 EV",actionTitle:"应用",parameters:.init(mode:.portrait,evDelta:0.7)))
        model.applySmartSuggestion()
        for _ in 0..<500 { if model.portraitModeEnabled && !model.isPreparingSubmode { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.portraitModeEnabled); XCTAssertTrue(model.smartPortraitAutoForTesting)
        model.togglePortraitMode(); XCTAssertFalse(model.smartPortraitAutoForTesting)
        XCTAssertFalse(model.portraitModeEnabled)
        print("SMART-PORTRAIT backlitNoBlurOrigin=true manualToggleClearsOrigin=true noCapture=true")
    }
    /// 需要用户按圆环提示对准主体；只回调一张临时成片，不写系统相册。
    @MainActor func testRealSceneGuideAutomaticFramingAndCapture() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // Fixture返回正式App正在显示的同一个model；再挂第二个CameraView会触发旧页onDisappear停机。
        let window = try XCTUnwrap(scene.windows.first(where:\.isKeyWindow))
        defer {
            model.setSmartCaptureForTesting(false); model.setCameraActive(false); camera.onCaptureCompleted = callback
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        guard camera.ready else { XCTFail(camera.message ?? "相机未就绪"); throw CancellationError() }
        model.setMode(.auto); model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        model.setSmartCaptureForTesting(true)
        var guides = 0, observations:[String] = []
        let initial = camera.currentZoom, start = CACurrentMediaTime()
        for i in 0..<100 {
            if let guide = model.smartCompositionGuide {
                guides += 1
                if i%4 == 0 { observations.append("candidates=\(model.smartCompositionCandidates.count) id=\(String(describing:guide.subjectID)) \(guide.subjectKind) rect=\(guide.subjectRect) center=\(guide.subject) text=\(guide.text)") }
            }
            if model.smartFramingComplete && !model.smartFramingInProgress { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        print("SMART-REAL guides=\(guides) automaticActions=\(model.smartAutoFramingCountForTesting) initialZoom=\(initial) finalZoom=\(camera.currentZoom) seconds=\(CACurrentMediaTime()-start) observations=\(observations)")
        guard model.smartFramingComplete else {
            let attachment = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }); attachment.name = "Smart-guide-not-aligned"; attachment.lifetime = .keepAlways; add(attachment)
            throw XCTSkip("未获得可靠且稳定对齐的主体，不能冒充真实场景自动取景成功")
        }
        let attachment = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }); attachment.name = "Smart-auto-framing-complete"; attachment.lifetime = .keepAlways; add(attachment)
        var photo:CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0 }
        camera.capture(flashMode:.off,options:model.photoOptions)
        for _ in 0..<1000 { if photo != nil && camera.pendingPhotoCount == 0 { break }; try await Task.sleep(for:.milliseconds(20)) }
        let shot = try XCTUnwrap(photo), data = try XCTUnwrap(shot.resources.first?.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        print("SMART-REAL output=\(properties[kCGImagePropertyPixelWidth as String] ?? 0)x\(properties[kCGImagePropertyPixelHeight as String] ?? 0) focal35mm=\(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] ?? 0) noPhotosWrite=true")
        XCTAssertEqual(camera.pendingPhotoCount,0)
        let result = XCTAttachment(image:shot.preview); result.name = "Smart-auto-framing-actual-photo"; result.lifetime = .keepAlways; add(result)
    }
    @MainActor func testActualVisionCandidateScoringPerformanceAndCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        let image = try XCTUnwrap(camera.preview)
        let source = try XCTUnwrap(SmartCaptureAnalyzer.visibleImage(image,aspect:0.75))
        var durations:[Double] = [], count = 0
        for _ in 0..<3 {
            let start = CACurrentMediaTime()
            let result = await Task.detached { SmartFramingEvaluator.evaluate(image:source,guide:self.guide(),currentZoom:1,range:1...4,work:SmartFramingWork()) }.value
            durations.append(CACurrentMediaTime()-start); count += result.scores.count
        }
        let work = SmartFramingWork(); work.cancel()
        let cancelled = SmartFramingEvaluator.evaluate(image:source,guide:guide(),currentZoom:1,range:1...4,work:work)
        XCTAssertTrue(cancelled.scores.isEmpty); XCTAssertNil(cancelled.recommendation)
        XCTAssertGreaterThan(count,0,"不能把未执行Vision评分当作成功")
        print("SMART-AESTHETICS samples=3 candidateScores=\(count) seconds=\(durations) preCancelledNoWork=true; not display FPS or aesthetic accuracy")
    }
    #endif
}
