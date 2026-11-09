import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class FrontAspectFOVDiagnosticTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testDiagnoseFrontPhotoVsVideoFourThreeFormats() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label:String, timeout:Double=20, _ predicate:()->Bool) async throws {
            let end=CACurrentMediaTime()+timeout
            while CACurrentMediaTime()<end { if predicate(){return}; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "nil")); throw CancellationError()
        }
        func state(_ tag:String) async {
            var format=""
            await withCheckedContinuation { c in camera.videoFormatStateForTesting { n,_,_,_ in format=n; c.resume() } }
            let exposure = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            print("FRONT-FOV tag=\(tag) format=\(format) zoom=\(exposure?.physicalZoomFactor ?? -1) selected=\(camera.selectedLens) kind=\(model.captureKind) ratio=\(model.ratio.rawValue) photoRatio=\(model.videoRatio.rawValue) landscape=\(camera.frontPhotoLandscapeEnabled) stab=\(model.preferences.videoStabilization.rawValue)")
        }
        model.setCameraActive(true); try await wait("启动"){camera.ready}
        model.setCaptureKind(.photo); if model.currentPosition != .front { model.flipCamera() }
        try await wait("照片前置"){camera.ready && model.currentPosition == .front && !camera.videoConfiguring}
        model.ratio = .standard
        if let wide = camera.lenses.first(where:{ $0.device.position == .front && $0.frontFraming == .wide }) { model.selectFocalLength(wide) }
        try await wait("照片宽幅4:3"){camera.ready && !camera.capturing}
        await state("photo-4:3")
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"视频前置4:3",timeout:20)
        model.selectVideoRatio(.ratio4x3)
        try await wait("视频4:3"){camera.ready && !camera.videoConfiguring}
        await state("video-4:3")
        model.videoResolution = .uhd4K
        try await wait("视频4K4:3"){camera.ready && !camera.videoConfiguring && camera.videoSettings.resolution == .uhd4K}
        await state("video-4K-4:3")
    }
    #endif
}
