import UIKit
import XCTest
@testable import LumaCamera

@MainActor final class CaptureCompletionOwnershipPhysicalTests:XCTestCase {
    func testAcceptedCaptureKeepsItsCallbackAndFailureCompletesOnce() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let callback=camera.onCaptureCompleted,idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer {
            camera.dropFinalPhotoCallbackForTesting=false;camera.nativeCaptureTimeoutForTesting=nil
            camera.replayAndClearDroppedPhotoFinalForTesting();camera.onCaptureCompleted=callback
            model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1200 { if predicate(){return};try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? ""));throw CancellationError()
        }
        model.setCameraActive(true);try await wait("ready"){camera.ready && camera.canCapture()}
        var original=0,replacement=0,failures=0
        camera.onCaptureCompleted={if $0 != nil {original+=1}}
        camera.capture(flashMode:.off,options:PhotoOptions(format:.jpeg))
        camera.onCaptureCompleted={_ in replacement+=1}
        try await wait("original callback"){original==1 && camera.pendingPhotoCount==0}
        XCTAssertEqual(replacement,0)
        camera.nativeCaptureTimeoutForTesting=4;camera.dropFinalPhotoCallbackForTesting=true
        camera.onCaptureCompleted={if $0 == nil {failures+=1}}
        camera.capture(flashMode:.off,options:PhotoOptions(format:.heif))
        camera.onCaptureCompleted={_ in replacement+=1}
        try await wait("failure callback"){failures==1 && camera.pendingPhotoCount==0}
        camera.replayAndClearDroppedPhotoFinalForTesting()
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertEqual(failures,1);XCTAssertEqual(replacement,0)
        print("CAPTURE-CALLBACK original=\(original) failed=\(failures) replacement=\(replacement) replayDuplicate=false noPhotosWrites=true")
    }
}
