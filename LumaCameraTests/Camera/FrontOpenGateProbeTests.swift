import AVFoundation
import XCTest
@testable import LumaCamera

final class FrontOpenGateProbeTests: XCTestCase {
    func testProbeFrontNativeOpenGateFormats() throws {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front).devices
        for device in devices {
            let supported = VideoCaptureSettings.openGateSupported(by: device)
            let formats = device.formats.compactMap { format -> String? in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let aspect = Double(max(d.width, d.height)) / Double(min(d.width, d.height))
                guard OpenGateCapability.supportsNativeVideoDimensions(width: Int(d.width), height: Int(d.height)) else { return nil }
                return "\(d.width)x\(d.height) aspect=\(String(format:"%.3f",aspect)) rates=\(format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator:",")) colors=\(format.supportedColorSpaces.count)"
            }
            print("FRONT-OPEN-GATE device=\(device.deviceType.rawValue) id=\(device.uniqueID) formats=\(formats.count) openSpecs=\(supported.count) native=\(formats)")
        }
    }
    @MainActor func testFrontVideoOpenGateAvailability() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); audit.finish() }
        func wait(_ label:String, timeout:Double = 20, _ predicate:() -> Bool) async throws {
            let end = CACurrentMediaTime()+timeout
            while CACurrentMediaTime()<end { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "nil")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"前置 Open Gate",timeout:20)
        model.selectVideoRatio(.ratio4x3)
        try await wait("4:3 就绪") { camera.ready && !camera.videoConfiguring }
        let supports = model.supportsVideoOpenGate
        print("FRONT-OPEN-GATE-APP supports=\(supports) ratio=\(model.videoRatio.rawValue) openSpecs=\(camera.openGateVideoSettings.count) message=\(camera.message ?? "nil")")
        guard supports else { throw XCTSkip("前置在当前 4:3 规格不提供 Open Gate") }
        model.setVideoOpenGateEnabled(true)
        try await wait("Open Gate 生效") { model.videoOpenGateEnabled && !camera.videoConfiguring }
        var name = ""
        await withCheckedContinuation { c in camera.videoFormatStateForTesting { n,_,_,_ in name=n; c.resume() } }
        print("FRONT-OPEN-GATE-APP format=\(name) enabled=\(model.videoOpenGateEnabled) message=\(camera.message ?? "nil")")
        XCTAssertFalse(name.isEmpty)
        model.setVideoOpenGateEnabled(false)
    }

}
