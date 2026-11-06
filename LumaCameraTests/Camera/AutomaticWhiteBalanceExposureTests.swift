import XCTest
import Combine
import AVFoundation
import UIKit
import CoreImage
@testable import LumaCamera

final class AutomaticWhiteBalanceExposureTests: XCTestCase {
    @MainActor
    func testAutomaticWhiteBalanceRemainsAutomaticDuringManualISOSweep() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical white-balance hardware")
        #else
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.stop(); UIApplication.shared.isIdleTimerDisabled = idle }
        let started = expectation(description: "Camera ready")
        let token = camera.$ready.filter { $0 }.first().sink { _ in started.fulfill() }
        camera.start(); await fulfillment(of: [started], timeout: 15); token.cancel()
        model.setMode(.manual)
        let drained = expectation(description: "Physical manual camera ready")
        camera.afterPendingSessionTasks { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 15)
        model.manualWB = false; model.applyWhiteBalance()
        model.manualExposure = true
        model.shutter = log2(1.0 / 125)
        for iso in [100.0, 400, 1600, camera.isoRange.upperBound / 2, camera.isoRange.upperBound, 100] {
            model.iso = min(max(iso, camera.isoRange.lowerBound), camera.isoRange.upperBound)
            model.applyExposure()
            // setExposureModeCustom is asynchronous in hardware. Wait for the requested
            // exposure rather than assuming a fixed delay also covers input/HDR reconfiguration.
            for _ in 0..<30 {
                let state: CameraEngine.ExposureColorState? = await withCheckedContinuation { c in
                    camera.exposureColorState { c.resume(returning: $0) }
                }
                if let state, abs(Double(state.iso) - model.iso) <= max(2, model.iso * 0.02),
                   abs(state.seconds - 1.0 / 125) <= 0.0001 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(150))
            let read = expectation(description: "Device colour state")
            camera.exposureColorState { state in
                if let state {
                    print("AWB-ISO iso=\(state.iso) seconds=\(state.seconds) mode=\(state.whiteBalanceMode.rawValue) rgb=\(state.gains.redGain),\(state.gains.greenGain),\(state.gains.blueGain) colorSpace=\(state.colorSpace.rawValue) hdr=\(state.hdr)")
                    XCTAssertFalse(model.manualWB)
                    XCTAssertEqual(state.whiteBalanceMode, .continuousAutoWhiteBalance)
                    XCTAssertFalse(state.hdr, "Custom exposure must not use automatic video HDR highlight compression")
                    XCTAssertFalse(state.automaticHDR)
                    // 格式可用的 ISO 上限可能低于 UI 范围上限；允许硬件安全夹取到较低值。
                    let isoDelta = abs(Double(state.iso) - model.iso)
                    XCTAssertTrue(isoDelta <= max(2, model.iso * 0.02)
                                  || (Double(state.iso) <= model.iso && Double(state.iso) >= model.iso * 0.8),
                                  "ISO \(state.iso) 与请求 \(model.iso) 不一致，且不是硬件上限夹取")
                    XCTAssertEqual(state.seconds, 1.0 / 125, accuracy: 0.0001)
                    if let image = camera.preview {
                        let attachment = XCTAttachment(image: image); attachment.name = "ISO-\(Int(state.iso))"; attachment.lifetime = .keepAlways
                        self.add(attachment)
                        if let source = CIImage(image: image) {
                            let normalized = source.transformed(by: CGAffineTransform(scaleX: 32 / source.extent.width, y: 32 / source.extent.height))
                            var pixels = [Float](repeating: 0, count: 32 * 32 * 4)
                            pixels.withUnsafeMutableBytes { CIContext().render(normalized, toBitmap: $0.baseAddress!, rowBytes: 32 * 16, bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
                            let mean = (0..<3).map { channel in stride(from: channel, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / 1024 }
                            let clipped = (0..<3).map { channel in stride(from: channel, to: pixels.count, by: 4).filter { pixels[$0] >= 0.98 }.count }
                            print("AWB-PIXELS iso=\(state.iso) mean=\(mean) clippedRGB=\(clipped)")
                        }
                    }
                } else { XCTFail("No active device") }
                read.fulfill()
            }
            await fulfillment(of: [read], timeout: 5)
        }
        model.setMode(.auto)
        let restored = expectation(description: "Automatic exposure restores streaming policy")
        camera.afterPendingSessionTasks {
            camera.exposureColorState { state in
                if let state { XCTAssertTrue(state.automaticHDR) }
                else { XCTFail("Missing automatic camera") }
                restored.fulfill()
            }
        }
        await fulfillment(of: [restored], timeout: 15)
        #endif
    }
}
