import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

final class IndependentNightCaptureTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testIndependentSessionCaptures48MPFrames() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let main = try XCTUnwrap(camera.lenses.first {
            $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
        })
        model.setCameraActive(false)
        for _ in 0..<300 {
            let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
            if !running && !camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let night = IndependentNightCapture()
        let result: IndependentNightCapture.Result = try await withCheckedThrowingContinuation { c in
            night.capture(device: main.device, exposureSeconds: 0.125, iso: 200) { result in
                c.resume(with: result)
            }
        }
        XCTAssertGreaterThanOrEqual(result.frames.count, 4)
        if let frame = result.frames.first,
           let source = CGImageSourceCreateWithData(frame as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            print("INDEPENDENT-NIGHT-DECODE cg=\(image.width)x\(image.height) props=\(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) ?? [:] as CFDictionary)")
        }
        print("INDEPENDENT-NIGHT frames=\(result.frames.count) dimensions=\(result.dimensions.width)x\(result.dimensions.height)")
        XCTAssertGreaterThanOrEqual(Int(result.dimensions.width) * Int(result.dimensions.height), 40_000_000)
    }
    @MainActor func testIndependentNightProfilesProduceDeclaredFrames() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera })
        model.setCameraActive(false)
        for _ in 0..<300 {
            let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
            if !running && !camera.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for profile in IndependentNightProfile.allCases {
            XCTAssertFalse(profile.exposureOffsets.contains { $0 > 0 }, "夜景方案不能增加曝光")
            let night = IndependentNightCapture()
            let result: IndependentNightCapture.Result = try await withCheckedThrowingContinuation { c in
                night.capture(device: main.device, exposureSeconds: 0.125, iso: 200, profile: profile) { c.resume(with: $0) }
            }
            XCTAssertEqual(result.frames.count, profile.exposureOffsets.count)
            if let frame = result.frames.first,
               let source = CGImageSourceCreateWithData(frame as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                XCTAssertGreaterThanOrEqual(image.width * image.height, 40_000_000)
            }
            print("INDEPENDENT-NIGHT-PROFILE name=\(profile.rawValue) frames=\(result.frames.count) dims=\(result.dimensions.width)x\(result.dimensions.height)")
        }
    }
    #endif
}

final class IndependentNightProfileContractTests: XCTestCase {
    func testProfileFrameCountsAndNoPositiveOffsets() {
        let expected: [IndependentNightProfile: (frames: Int, offsets: [Double])] = [
            .standard: (3, [0, 0, 0]),
            .balanced: (4, [0, 0, 0, -1]),
            .denoise: (5, [0, 0, 0, 0, 0]),
            .highlight: (5, [0, 0, 0, -1, -2])
        ]
        for profile in IndependentNightProfile.allCases {
            let contract = expected[profile]
            XCTAssertEqual(profile.exposureOffsets.count, contract?.frames)
            XCTAssertEqual(profile.exposureOffsets, contract?.offsets)
            XCTAssertLessThanOrEqual(profile.exposureOffsets.count, 5)
            XCTAssertFalse(profile.exposureOffsets.contains { $0 > 0 }, "禁止增加曝光补偿")
        }
    }
}
