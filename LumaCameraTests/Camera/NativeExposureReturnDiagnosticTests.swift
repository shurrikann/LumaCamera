import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

/// 独立原生会话对照：不经过应用的预览/滤镜/读数发布，记录长曝光退出后的真实缓冲交付。
final class NativeExposureReturnDiagnosticTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testNativeOneSecondExposureReturnWithoutAppPipeline() async throws {
        try await runNative(restart:false)
    }
    @MainActor func testNativeSessionRestartAfterOneSecondExposure() async throws {
        try await runNative(restart:true)
    }
    @MainActor private func runNative(restart:Bool) async throws {
        // setCameraActive的停机提交位于下一主队列事务；必须等原引擎真正停止，不能仅等一次队列栅栏。
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back))
        let probe = NativeExposureReturnProbe(device:device)
        let queue = DispatchQueue(label:"test.native.exposure.configuration")
        defer { queue.sync {
            if let original = probe.originalHDR {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    if device.automaticallyAdjustsVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false }
                    device.isVideoHDREnabled = original.enabled && device.activeFormat.isVideoHDRSupported
                    device.automaticallyAdjustsVideoHDREnabled = original.automatic
                } catch { XCTFail("原生对照未恢复HDR配置：\(error)") }
            }
            probe.session.stopRunning()
        } }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            queue.async {
                let device = probe.device
                do {
                    probe.session.beginConfiguration(); probe.session.sessionPreset = .photo
                    probe.session.addInput(try AVCaptureDeviceInput(device:device))
                    probe.session.addOutput(probe.photos)
                    probe.video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                    probe.video.alwaysDiscardsLateVideoFrames = true
                    probe.video.setSampleBufferDelegate(probe,queue:probe.sampleQueue)
                    probe.session.addOutput(probe.video); probe.session.commitConfiguration()
                    probe.session.startRunning()
                    try device.lockForConfiguration()
                    probe.originalHDR = (device.automaticallyAdjustsVideoHDREnabled,device.isVideoHDREnabled)
                    // 整组对照始终关闭流HDR，排除返回时HDR重配；不改变照片HDR或添加曝光模拟。
                    if device.automaticallyAdjustsVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false }
                    if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
                    device.unlockForConfiguration()
                    c.resume()
                } catch { c.resume(throwing:error) }
            }
        }
        try XCTSkipUnless(device.isExposureModeSupported(.custom) && device.activeFormat.maxExposureDuration.seconds>=0.99,
                          "默认原生格式没有一秒手动曝光能力，不能冒充相同条件")
        print("NATIVE-EXPOSURE format=\(device.activeFormat) maxSeconds=\(device.activeFormat.maxExposureDuration.seconds)")
        try await Task.sleep(for:.seconds(1))
        for sample in 0..<3 {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                queue.async {
                    let device = probe.device
                    do {
                        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(duration:CMTime(seconds:1,preferredTimescale:1_000_000),
                            iso:min(max(100,device.activeFormat.minISO),device.activeFormat.maxISO),completionHandler:nil)
                        c.resume()
                    } catch { c.resume(throwing:error) }
                }
            }
            try await Task.sleep(for:.milliseconds(3200+sample*250))
            let start = CACurrentMediaTime()
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                queue.async {
                    let device = probe.device
                    do {
                        if restart { probe.session.stopRunning() }
                        do {
                            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                            device.exposureMode = .continuousAutoExposure
                            device.activeVideoMinFrameDuration = .invalid
                            device.activeVideoMaxFrameDuration = .invalid
                        }
                        if restart { probe.session.startRunning() }
                        c.resume()
                    } catch { c.resume(throwing:error) }
                }
            }
            let callSeconds = CACurrentMediaTime()-start
            try await Task.sleep(for:.seconds(4))
            let rows = probe.snapshot().filter { $0.host>=start }
            XCTAssertGreaterThan(rows.count,0,"原生会话必须恢复出帧；不把原生恢复很晚导致窗口样本少误判为无帧")
            guard !rows.isEmpty else { throw CancellationError() }
            let firstAuto = rows.first { $0.mode == AVCaptureDevice.ExposureMode.continuousAutoExposure.rawValue && $0.exposure<0.125 }
            XCTAssertNotNil(firstAuto)
            let points = [start]+rows.map(\.host)
            let maxGap = zip(points,points.dropFirst()).map { $1-$0 }.max() ?? -1
            print("NATIVE-EXPOSURE restart=\(restart) sample=\(sample) callSeconds=\(callSeconds) firstShortPropertyOnBuffer=\((firstAuto?.host ?? start)-start) maxDeliveryGap=\(maxGap) bufferCount=\(rows.count) firstRows=\(rows.prefix(8).map { String(format:"%.3f/%.3f/%.3f/%.3f",$0.host-start,$0.pts,$0.exposure,$0.luma) })")
        }
    }
    #endif
}

// 会话和设备写入仅配置队列；帧回调只读取设备，rows通过lock跨队列访问。
private final class NativeExposureReturnProbe:NSObject,AVCaptureVideoDataOutputSampleBufferDelegate,@unchecked Sendable {
    struct Row { let host:Double,pts:Double,exposure:Double,luma:Double; let mode:Int }
    let device:AVCaptureDevice
    let session = AVCaptureSession(), photos = AVCapturePhotoOutput(), video = AVCaptureVideoDataOutput()
    let sampleQueue = DispatchQueue(label:"test.native.exposure.buffers")
    var originalHDR:(automatic:Bool,enabled:Bool)? // configuration queue only
    private let lock = NSLock()
    private var rows = [Row]()
    init(device:AVCaptureDevice) { self.device = device }
    func snapshot()->[Row] { lock.lock(); defer { lock.unlock() }; return rows }
    func captureOutput(_ output:AVCaptureOutput,didOutput buffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(image,.readOnly)
        var sum = 0.0
        if let base = CVPixelBufferGetBaseAddress(image) {
            let bytes = base.assumingMemoryBound(to:UInt8.self)
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image)
            for y in 0..<16 { for x in 0..<16 {
                let i = ((y*height/16)+height/32)*stride+((x*width/16)+width/32)*4
                sum += (0.0722*Double(bytes[i])+0.7152*Double(bytes[i+1])+0.2126*Double(bytes[i+2]))/255
            } }
        }
        CVPixelBufferUnlockBaseAddress(image,.readOnly)
        let row = Row(host:CACurrentMediaTime(),pts:CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                      exposure:device.exposureDuration.seconds,luma:sum/256,mode:device.exposureMode.rawValue)
        lock.lock(); rows.append(row); if rows.count>1500 { rows.removeFirst(300) }; lock.unlock()
    }
}
