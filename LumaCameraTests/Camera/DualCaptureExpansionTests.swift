import XCTest
import AVFoundation
import CoreImage
import UIKit
import SwiftUI
@testable import LumaCamera

final class DualCaptureExpansionTests: XCTestCase {
    func testCatalogAndInsetCoordinateRules() throws {
        let values = DualCapturePolicy.validatedSettings
        XCTAssertEqual(values.count, 25)
        XCTAssertFalse(values.contains { $0.frameRate == .fps120 || $0.colorSpace.isLog || $0.colorSpace == .hdr || $0.isRAW })
        XCTAssertFalse(values.contains { $0.resolution == .uhd4K && $0.frameRate.rawValue > 30 })
        for ratio in VideoRatio.aspectOptions { for turns in 0..<4 {
            let original = DualCaptureInsetLayout.initial
            let moved = DualCaptureInsetLayout.translated(original, displayTranslation: CGSize(width: 0.01, height: 0.01),
                ratio: ratio.frameRatio.portraitRatio, turns: turns)
            let a = DualCaptureInsetLayout.displayRect(original, ratio: ratio.frameRatio.portraitRatio, turns: turns)
            let b = DualCaptureInsetLayout.displayRect(moved, ratio: ratio.frameRatio.portraitRatio, turns: turns)
            XCTAssertEqual(b.minX - a.minX, 0.01, accuracy: 0.00001)
            XCTAssertEqual(b.minY - a.minY, 0.01, accuracy: 0.00001)
        } }
        for x in [-100.0, 0, 0.5, 100] { for y in [-100.0, 0, 0.5, 100] {
            let rect = DualCaptureInsetLayout.clamped(CGRect(x: x, y: y, width: 0.28, height: 0.28))
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
        } }
    }

    @MainActor func testInsetNativeGestureConfigurationAndDispatch() async throws {
        var swaps = 0, changes: [CGSize] = []
        let surface = DualCaptureInsetSurface(rect: DualCaptureInsetLayout.initial,
            previewSize: CGSize(width: 400, height: 600), onMove: { _, delta in changes.append(delta) }, onSwap: { swaps += 1 })
        let host = UIHostingController(rootView: surface.frame(width: 112, height: 168))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        func find(_ view: UIView) -> DualCaptureInsetSurface.InsetView? {
            if let match = view as? DualCaptureInsetSurface.InsetView { return match }
            return view.subviews.compactMap { find($0) }.first
        }
        let view = try XCTUnwrap(find(host.view))
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        XCTAssertEqual(Set(taps.map(\.numberOfTapsRequired)), Set([1, 2]))
        XCTAssertEqual((view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }.count, 1)
        let coordinator = surface.makeCoordinator()
        final class Tap: UITapGestureRecognizer { override var state: UIGestureRecognizer.State { get { .ended } set {} } }
        final class Pan: UIPanGestureRecognizer {
            override var state: UIGestureRecognizer.State { get { .changed } set {} }
            override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 40, y: -60) }
        }
        coordinator.singleTap(Tap()); XCTAssertEqual(swaps, 0)
        coordinator.doubleTap(Tap()); XCTAssertEqual(swaps, 1)
        for _ in 0..<100 { coordinator.pan(Pan()) }
        XCTAssertEqual(changes.count, 100); XCTAssertEqual(changes.last?.width ?? 0, 0.1, accuracy: 0.00001)
        XCTAssertEqual(changes.last?.height ?? 0, -0.1, accuracy: 0.00001)
    }

    #if !targetEnvironment(simulator)
    @MainActor func testMovedInsetCompositePixelsAcrossAllRatios() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let queue = DispatchQueue(label: "DualInset-PixelTest")
        let source = try DualCaptureSource(frameQueue: queue, ratio: .wide, audio: false)
        defer { source.release() }
        let context = CIContext(options: [.cacheIntermediates: false])
        func solid(_ color: CIColor) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let result = try XCTUnwrap(buffer)
            context.render(CIImage(color: color), to: result, bounds: CGRect(x: 0, y: 0, width: 256, height: 256), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return result
        }
        let rear = try solid(CIColor(red: 1, green: 0, blue: 0)), front = try solid(CIColor(red: 0, green: 0, blue: 1))
        var samples = 0
        for ratio in VideoRatio.aspectOptions {
            source.setRatio(ratio.frameRatio)
            for landscape in [false, true] {
            for origin in [CGPoint(x: 0.01, y: 0.01), CGPoint(x: 0.71, y: 0.71), CGPoint(x: 0.35, y: 0.4)] {
                try autoreleasepool {
                    let rect = DualCaptureInsetLayout.resized(CGRect(origin: origin, size: DualCaptureInsetLayout.initial.size), landscape: landscape, ratio: ratio.frameRatio.portraitRatio)
                    source.setInsetRect(rect)
                    let frame = try XCTUnwrap(source.compositeForTesting(back: rear, front: front, time: CMTime(value: Int64(samples), timescale: 30)))
                    let image = CIImage(cvPixelBuffer: try XCTUnwrap(CMSampleBufferGetImageBuffer(frame)))
                    let x = rect.midX * image.extent.width, y = (1 - rect.midY) * image.extent.height
                    var pixel = [UInt8](repeating: 0, count: 4)
                    pixel.withUnsafeMutableBytes { memory in context.render(image, toBitmap: memory.baseAddress!, rowBytes: 4,
                        bounds: CGRect(x: x.rounded(), y: y.rounded(), width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
                    XCTAssertGreaterThan(pixel[2], 220); XCTAssertLessThan(pixel[0], 30)
                    samples += 1
                }
            }
        }
        }
        print("DUAL-INSET-PIXELS samples=\(samples) ratios=5")
    }
    #endif

    #if !targetEnvironment(simulator)
    @MainActor func testExpandedPickerRecordsRealFilesAndRestoresOrdinarySettings() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit(), callback = camera.onVideoRecorded
        UIApplication.shared.isIdleTimerDisabled = true
        var files: [URL] = []
        defer { camera.onVideoRecorded = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish(); files.forEach { try? FileManager.default.removeItem(at: $0) } }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 18
            while CACurrentMediaTime() < end { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        let front = try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .standard })
        model.selectFocalLength(front); try await wait("前置") { camera.ready && model.currentPosition == .front }
        model.videoFrameRate = .fps60
        try await wait("保存普通规格") { !camera.videoConfiguring }
        model.toggleDualCapture(); try await wait("双拍") { camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        XCTAssertEqual(model.videoFrameRate, .fps60)
        XCTAssertTrue(model.supportsVideoFrameRate(.fps50)); XCTAssertFalse(model.supportsVideoFrameRate(.fps120))
        XCTAssertTrue(model.supportsVideoRatio(.cinema)); XCTAssertFalse(model.supportsVideoOpenGate)
        let supported = camera.dualCaptureSupportedSettings
        XCTAssertEqual(supported.count, 25)
        for (index, setting) in supported.enumerated() {
            let began = CACurrentMediaTime()
            // 通过现有界面的公开属性提交整套目标，后端必须按最后一次请求收敛，不能静默回到1080p30。
            model.videoResolution = setting.resolution; model.videoFrameRate = setting.frameRate
            model.videoColorSpace = setting.colorSpace; model.videoCodec = setting.codec; model.proResSpecification = setting.proRes
            try await wait("双拍规格未应用") { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing
                && DualCapturePolicy.matches(camera.videoSettings, setting) }
            let ratio = VideoRatio.aspectOptions[index % VideoRatio.aspectOptions.count]
            model.selectVideoRatio(ratio)
            try await wait("比例") { !camera.videoConfiguring && camera.ready }
            if index % 2 == 0 { model.selectFocalLength(try XCTUnwrap(camera.lenses.first { $0.device.position == .front && $0.frontFraming == .wide })) }
            else { model.selectFocalLength(front) }
            let old = camera.previewFrameTimeForTesting
            try await wait("前置画幅新帧") { camera.previewFrameTimeForTesting > old }
            let startRect = camera.dualCaptureInsetRect
            model.moveDualCaptureInset(from: startRect, translation: CGSize(width: index % 2 == 0 ? -0.5 : 0.5, height: 0.1))
            var result: Result<URL, Error>?
            camera.onVideoRecorded = { result = $0 }
            model.toggleVideoRecording()
            try await wait("开始录像") { camera.videoRecording }
            try await Task.sleep(for: .milliseconds(550))
            // 实际录像中持续移动；最后一次请求必须写入合成队列。
            for step in 0..<20 {
                model.moveDualCaptureInset(from: DualCaptureInsetLayout.initial, translation: CGSize(width: -Double(step) / 80, height: Double(step) / 100))
            }
            model.swapDualCaptureCameras(); model.swapDualCaptureCameras()
            try await Task.sleep(for: .milliseconds(200))
            camera.stopVideoRecording(); try await wait("结束录像") { result != nil && !camera.videoBusy }
            let url = try XCTUnwrap(result).get(); files.append(url)
            let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first), size = try await track.load(.naturalSize), duration = try await asset.load(.duration)
            XCTAssertEqual(min(size.width, size.height) / max(size.width, size.height), ratio.frameRatio.portraitRatio, accuracy: 0.003)
            let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0
            while autoreleasepool(invoking: { output.copyNextSampleBuffer() != nil }) { count += 1 }
            XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(count, 5)
            let state: [String: String] = await withCheckedContinuation { c in camera.dualCaptureStateForTesting { c.resume(returning: $0) } }
            XCTAssertEqual(state["ordinaryRunning"], "false")
            XCTAssertEqual(Double(state["insetX"] ?? "") ?? -1, camera.dualCaptureInsetRect.minX, accuracy: 0.001)
            XCTAssertLessThanOrEqual(Double(state["frontFPS"] ?? "") ?? 100, 30.1)
            print("DUAL-EXPANDED index=\(index) res=\(setting.resolution.title) fps=\(setting.frameRate.rawValue) color=\(setting.colorSpace.rawValue) codec=\(setting.codec.rawValue) prores=\(setting.proRes.rawValue) ratio=\(ratio.rawValue) frames=\(count) duration=\(duration.seconds) size=\(size) wall=\(CACurrentMediaTime()-began)")
        }
        model.toggleDualCapture(); try await wait("恢复普通视频") { !camera.dualCaptureEnabled && camera.ready && !camera.videoConfiguring }
        XCTAssertEqual(model.videoFrameRate, .fps60); XCTAssertEqual(model.videoCodec, .hevc)
    }
    #endif
}
