@preconcurrency import AVFoundation
import XCTest
import UIKit
@testable import LumaCamera

/// 需有人物与有纹理的远背景；实际画面附件为效果验收，不能只凭模式布尔值通过。
final class CinematicEffectPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testSimulatedApertureChangesPreviewAndRecordedBackground() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Cinematic需要iOS26") }
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let observer = CinematicSubjectObserver()
        let callback = camera.onVideoRecorded, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var result: Result<URL,Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { value in
                    if case .success(let url) = value { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }; camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
            camera.cinematicApertureForTesting(nil,observer:nil) { _ in }
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label + ": " + (camera.message ?? "未就绪")); throw NSError(domain:"CinematicEffectTest",code:1)
        }
        model.setCameraActive(true)
        try await wait("相机启动") { camera.ready }
        if model.currentPosition != .back { model.flipCamera() }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.setCaptureKind(.video); model.setMode(.auto)
        model.videoResolution = .hd1080; model.videoFrameRate = .fps30
        model.videoColorSpace = .sdr; model.videoCodec = .hevc
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.toggleCinematicVideoMode()
        try await wait("系统电影管线") { model.cinematicVideoEnabled && camera.cinematicVideoCaptureActive && model.videoSubmodePreparing == nil }
        let original = await withCheckedContinuation { c in camera.cinematicApertureForTesting(nil,observer:observer) { c.resume(returning:$0) } }
        let range = try XCTUnwrap(original)
        print("CINEMATIC-EFFECT apertureRange=\(range.minimum)...\(range.maximum) default=\(range.current)")
        try await Task.sleep(for:.milliseconds(1200))
        camera.focus(at:CGPoint(x:0.5,y:0.5),lockFocus:true)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        var summaries: [String] = []
        for (label,aperture) in [("default",range.current),("strong",range.minimum),("weak",range.maximum),("strong-repeat",range.minimum)] {
            let applied = await withCheckedContinuation { c in camera.cinematicApertureForTesting(aperture,observer:observer) { c.resume(returning:$0) } }
            XCTAssertEqual(try XCTUnwrap(applied).current,aperture,accuracy:0.001)
            let changed = CACurrentMediaTime()
            try await wait("新光圈预览") { camera.previewFrameTimeForTesting > changed }
            try await Task.sleep(for:.milliseconds(600))
            let preview = try XCTUnwrap(camera.preview)
            let previewAttachment = XCTAttachment(image:preview)
            previewAttachment.name = "Cinematic-\(label)-preview"; previewAttachment.lifetime = .keepAlways; add(previewAttachment)
            result = nil
            try await wait("录制快门就绪") { model.videoShutterEnabled && !camera.videoBusy && !camera.videoConfiguring }
            model.toggleVideoRecording()
            try await wait("录制开始") { camera.videoRecording || result != nil }
            XCTAssertTrue(camera.videoRecording)
            try await Task.sleep(for:.milliseconds(700))
            camera.stopVideoRecording()
            try await wait("成片完成") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result).get()
            let asset = AVURLAsset(url:url)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first)
            let generator = AVAssetImageGenerator(asset:asset)
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at:CMTime(seconds:0.4,preferredTimescale:600))
            let attachment = XCTAttachment(image:UIImage(cgImage:frame.image))
            attachment.name = "Cinematic-\(label)-recorded"; attachment.lifetime = .keepAlways; add(attachment)
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(size,CGSize(width:1920,height:1080)); XCTAssertGreaterThan(duration,0.5)
            summaries.append("\(label) f=\(aperture) duration=\(duration) \(observer.snapshot)")
            try FileManager.default.removeItem(at:url); result = nil
        }
        let text = summaries.joined(separator:"\n")
        let attachment = XCTAttachment(string:text); attachment.name = "cinematic-effect-subjects"; attachment.lifetime = .keepAlways; add(attachment)
        print("CINEMATIC-EFFECT-SUMMARY\n\(text)")
        if observer.subjectCount == 0 {
            throw XCTSkip("当前场景系统未检出主体，虚化效果无法客观验收")
        }
    }
    #endif
}

private final class CinematicSubjectObserver: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var details = ""
    var subjectCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var snapshot: String { lock.lock(); defer { lock.unlock() }; return details }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        let subjects = metadataObjects.filter {
            if #available(iOS 27.0, *) { return $0.type != .cinematicVideoMetadata }
            return true
        }
        lock.lock(); defer { lock.unlock() }
        count = max(count,subjects.count)
        details = subjects.map { "type=\($0.type.rawValue) bounds=\($0.bounds)" }.joined(separator:";")
    }
}
