import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import LumaCamera

/// 宽高比与广角联合切换：普通、精确自定义倍率、已广角三种入口均应可逆。
final class FrontWideAspectReturnPhysicalTests:XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testAAndMWideAspectRestoresExactFramingAndPhotoMetadata() async throws {
        try await withFront { model in
            let camera = model.camera
            let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
            let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })
            var durations = [Double]()
            for mode in [CameraShootingMode.auto,.manual] {
                model.setMode(mode)
                await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                try await self.wait("A/M切换尚未完成") { camera.ready && model.focalTransitionImage == nil }
                model.manualExposure = mode == .manual; model.iso = 200; model.shutter = log2(1.0/125); model.applyExposure()
                for (lens,zoom) in [(standard,CGFloat(1)),(standard,CGFloat(1.25)),(wide,wide.displayZoom)] {
                    camera.setFrontPhotoLandscapeEnabled(false)
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    model.selectFocalLength(lens)
                    try await self.wait("入口焦段未完成切换") { camera.ready && camera.selectedLens == lens.id && model.focalTransitionImage == nil }
                    camera.setContinuousZoom(zoom)
                    await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                    try await self.waitForPhysicalZoom(camera,zoom * lens.zoomFactor / lens.displayZoom)
                    // 预先设定比较起点：标签先变不代表新的变焦缓冲已经交付。
                    for _ in 0..<3 {
                        let frame = camera.previewFrameTimeForTesting
                        try await self.wait("入口变焦未交付新帧") { camera.previewFrameTimeForTesting>frame }
                    }
                    try await self.wait("入口倍率未就绪") {
                        !camera.frontPhotoLandscapeEnabled && camera.selectedLens == lens.id && abs(camera.currentZoom-zoom)<0.002
                            && model.focalTransitionImage == nil
                    }
                    let before = try await self.capture(model)
                    let beforeFocal = try self.fileFocal(before)
                    let start = CACurrentMediaTime()
                    model.toggleFrontPhotoAspectRatio()
                    try await self.wait("未切到超广角横幅") {
                        camera.frontPhotoLandscapeEnabled && camera.selectedLens == wide.id
                            && abs(camera.currentZoom-wide.displayZoom)<0.002
                    }
                    durations.append(CACurrentMediaTime()-start)
                    let widePreview = try XCTUnwrap(camera.preview?.size)
                    XCTAssertEqual(widePreview.width/widePreview.height,4.0/3,accuracy:0.01)
                    XCTAssertEqual(camera.selectedLens,wide.id)
                    let landscape = try await self.capture(model)
                    let wideFocal = try self.fileFocal(landscape)
                    XCTAssertLessThanOrEqual(wideFocal,beforeFocal+1)
                    let returnStart = CACurrentMediaTime()
                    model.toggleFrontPhotoAspectRatio()
                    try await self.wait("未恢复原构图及倍率") {
                        !camera.frontPhotoLandscapeEnabled && camera.selectedLens == lens.id && abs(camera.currentZoom-zoom)<0.002
                    }
                    durations.append(CACurrentMediaTime()-returnStart)
                    let restoredPreview = try XCTUnwrap(camera.preview?.size)
                    XCTAssertEqual(restoredPreview.height/restoredPreview.width,4.0/3,accuracy:0.01)
                    let restored = try await self.capture(model)
                    XCTAssertEqual(try self.fileFocal(restored),beforeFocal,accuracy:1)
                    XCTAssertEqual(model.mode,mode); XCTAssertEqual(model.manualExposure,mode == .manual)
                    XCTAssertNil(model.focalTransitionImage,"宽高比切换沿用已有画幅过渡，不创建额外冻结层")
                    print("FRONT-WIDE-ASPECT mode=\(mode) entryZoom=\(zoom) wideZoom=\(wide.displayZoom) fileFocalBefore=\(beforeFocal) wide=\(wideFocal) restored=\(try self.fileFocal(restored)) previewReady=\(camera.ready)")
                }
            }
            XCTAssertEqual(durations.count,12)
            print("FRONT-WIDE-ASPECT-PERFORMANCE samples=12 requestToMatchingFrameSeconds=\(durations) temporaryPhotos=18 noSystemPhotos=true")
        }
    }

    @MainActor func testRapidTapsAndCancelReturnDoNotLosePreviousZoom() async throws {
        try await withFront { model in
            let camera = model.camera
            let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
            camera.setFrontPhotoLandscapeEnabled(false); model.selectFocalLength(standard)
            try await self.wait("标准前置未准备") { camera.ready && camera.selectedLens == standard.id && model.focalTransitionImage == nil }
            camera.setContinuousZoom(1.25)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            try await self.waitForPhysicalZoom(camera,1.25*standard.zoomFactor/standard.displayZoom)
            try await self.wait("初始倍率未准备") { !camera.frontPhotoLandscapeEnabled && abs(camera.currentZoom-1.25)<0.002 }
            for _ in 0..<10 {
                model.toggleFrontPhotoAspectRatio()
                try await Task.sleep(for:.milliseconds(20))
            }
            try await self.wait("快速偶数次点按未返回原倍率") {
                !camera.frontPhotoLandscapeEnabled && camera.selectedLens == standard.id && abs(camera.currentZoom-1.25)<0.002
            }
            let frame = camera.previewFrameTimeForTesting
            try await Task.sleep(for:.milliseconds(400))
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting,frame)
            model.toggleFrontPhotoAspectRatio(); model.setCameraActive(false)
            for _ in 0..<300 {
                let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
                if !running { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            model.setCameraActive(true)
            try await self.wait("取消后未重新准备") { camera.ready && camera.previewFrameTimeForTesting>frame }
            // 取消可能发生在请求接纳前或之后；若已接纳，第二次点击仍必须恢复原精确倍率。
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for:.milliseconds(500))
            if camera.frontPhotoLandscapeEnabled { model.toggleFrontPhotoAspectRatio() }
            try await self.wait("取消返回后原倍率丢失") {
                !camera.frontPhotoLandscapeEnabled && abs(camera.currentZoom-1.25)<0.002
            }
            print("FRONT-WIDE-ASPECT-STABILITY rapidTaps=10 cancelledReturn=true restoredZoom=1.25 noCapture=true")
        }
    }

    @MainActor func testSupportedRatiosAndSquareGuard() async throws {
        try await withFront { model in
            let camera = model.camera
            let standard = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
            camera.setFrontPhotoLandscapeEnabled(false); model.selectFocalLength(standard)
            try await self.wait("标准前置未准备") { camera.ready && camera.selectedLens == standard.id && model.focalTransitionImage == nil }
            for ratio in FrameRatio.photoOptions where ratio != .square {
                model.ratio = ratio
                let startFrame = camera.previewFrameTimeForTesting
                try await self.wait("新比例未出帧") { camera.previewFrameTimeForTesting>startFrame }
                let beforeZoom = camera.currentZoom
                model.toggleFrontPhotoAspectRatio()
                try await self.wait("比例横幅未就绪") { camera.frontPhotoLandscapeEnabled }
                let preview = try XCTUnwrap(camera.preview?.size)
                XCTAssertEqual(preview.width/preview.height,ratio.landscapeRatio,accuracy:0.015)
                let photo = try await self.capture(model)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(photo.resources.first?.data) as CFData,nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue)
                let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue)
                XCTAssertEqual(min(width,height)/max(width,height),Double(ratio.portraitRatio),accuracy:0.002)
                model.toggleFrontPhotoAspectRatio()
                try await self.wait("比例竖幅未恢复") { !camera.frontPhotoLandscapeEnabled && abs(camera.currentZoom-beforeZoom)<0.002 }
                print("FRONT-WIDE-ASPECT-RATIO ratio=\(ratio.rawValue) preview=\(preview) file=\(width)x\(height) restoredZoom=\(beforeZoom)")
            }
            model.ratio = .square
            XCTAssertFalse(model.canToggleFrontPhotoAspectRatio)
            let zoom = camera.currentZoom
            model.toggleFrontPhotoAspectRatio()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertFalse(camera.frontPhotoLandscapeEnabled); XCTAssertEqual(camera.currentZoom,zoom)
        }
    }

    @MainActor func testPendingPhotoAspectDoesNotChangeVideoLook() async throws {
        try await withFront { model in
            let camera = model.camera, frame = camera.previewFrameTimeForTesting
            model.toggleFrontPhotoAspectRatio()
            model.setCaptureKind(.video)
            try await self.wait("视频路线未完成") {
                camera.ready && !camera.videoConfiguring && !camera.frontPhotoAspectRatioSwitchAvailable && camera.previewFrameTimeForTesting>frame
            }
            try await Task.sleep(for:.milliseconds(300))
            let look = await withCheckedContinuation { c in camera.captureLookForTesting { c.resume(returning:$0) } }
            XCTAssertFalse(look.landscape,"照片画幅回调不能覆盖视频自己的look")
            let zoom = camera.currentZoom
            model.toggleFrontPhotoAspectRatio()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertEqual(camera.currentZoom,zoom,"视频中照片按钮请求必须无效")
            let videoFrame = camera.previewFrameTimeForTesting
            model.setCaptureKind(.photo)
            try await self.wait("照片路线未恢复") {
                camera.ready && !camera.videoConfiguring && model.canToggleFrontPhotoAspectRatio && camera.previewFrameTimeForTesting>videoFrame
            }
            if camera.frontPhotoLandscapeEnabled { model.toggleFrontPhotoAspectRatio() }
            try await self.wait("返回后不能退出横幅") { !camera.frontPhotoLandscapeEnabled }
            print("FRONT-WIDE-ASPECT-VIDEO pendingRequestCancelledOrAppliedBeforeSwitch=true videoLookUnchanged=true photoReturnReady=true")
        }
    }

    @MainActor private func withFront(_ action:(CameraViewModel) async throws -> Void) async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        let callback = camera.onCaptureCompleted
        let preferences = model.preferences, smooth = model.smoothPreview
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.onCaptureCompleted = callback; model.smoothPreview = smooth; model.preferences = preferences; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        model.setCameraActive(true)
        try await wait("相机未准备") { camera.ready && camera.preview != nil }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置未准备") { camera.ready && model.currentPosition == .front && model.canToggleFrontPhotoAspectRatio }
        model.photoFormat = .heif; model.hdr = false; model.ratio = .standard
        model.smoothPreview = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        camera.setFrontPhotoLandscapeEnabled(false)
        try await wait("未恢复前置竖幅") { !camera.frontPhotoLandscapeEnabled }
        try await action(model)
    }
    @MainActor private func capture(_ model:CameraViewModel) async throws -> CapturedPhoto {
        let camera = model.camera, done = expectation(description:"临时前置构图照片")
        var result:CapturedPhoto?
        camera.onCaptureCompleted = { result = $0; done.fulfill() }
        camera.capture(flashMode:.off,options:model.photoOptions)
        await fulfillment(of:[done],timeout:30)
        let photo = try XCTUnwrap(result,camera.message ?? "未返回照片")
        try await wait("拍后未清空") { !camera.shutterBusy && camera.pendingPhotoCount == 0 }
        return photo
    }
    private func fileFocal(_ photo:CapturedPhoto) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(photo.resources.first?.data) as CFData,nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
        return try XCTUnwrap((exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue)
    }
    @MainActor private func waitForPhysicalZoom(_ camera:CameraEngine,_ expected:CGFloat) async throws {
        for _ in 0..<300 {
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            if let state, abs(state.physicalZoomFactor-expected)<0.002 { return }
            try await Task.sleep(for:.milliseconds(15))
        }
        XCTFail("变焦标签已更新但真实倍率未应用，不能开始成片比较")
        throw CancellationError()
    }
    @MainActor private func wait(_ label:String,_ condition:()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(15)) }
        XCTFail(label); throw CancellationError()
    }
    #endif
}
