import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class FrontVideoSwitchingSoakTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testFrontVideoTrackingDualSwitchingSoak() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }

        func wait(_ label: String, timeout: Double = 20, _ predicate: () -> Bool) async throws {
            let end = CACurrentMediaTime() + timeout
            while CACurrentMediaTime() < end {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail(label + " message=\(camera.message ?? "nil") kind=\(model.captureKind) dual=\(camera.dualCaptureEnabled) preparing=\(camera.dualCapturePreparing) mainFront=\(camera.dualCaptureMainIsFront) tracking=\(camera.frontVideoCenteringActive)/\(camera.frontVideoCenteringPreparing) ready=\(camera.ready) configuring=\(camera.videoConfiguring)"); throw CancellationError()
        }

        model.setCameraActive(true)
        try await wait("启动") { camera.ready && camera.preview != nil }
        model.setCaptureKind(.video)
        try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置视频") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }

        var cycleDurations: [Double] = []
        for cycle in 0..<3 {
            let began = CACurrentMediaTime()
            try await wait("视频待机-\(cycle)") { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing }
            XCTAssertEqual(model.captureKind, .video)
            XCTAssertNil(camera.message)

            if !(model.frontVideoCenteringRequested && camera.frontVideoCenteringActive) {
                model.toggleFrontVideoCentering()
                try await wait("追踪开启-\(cycle)") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
            }
            XCTAssertTrue(model.frontVideoCenteringRequested)

            model.toggleDualCapture()
            try await wait("双拍开启-\(cycle)") { camera.dualCaptureEnabled && !camera.dualCapturePreparing }
            if !camera.dualCaptureMainIsFront {
                model.swapDualCaptureCameras()
                try await wait("前置主画面-\(cycle)") { camera.dualCaptureMainIsFront }
            }
            try await wait("双拍追踪保留-\(cycle)") { camera.frontVideoCenteringEnabled && camera.frontVideoCenteringActive }
            XCTAssertEqual(model.captureKind, .video)
            XCTAssertNil(camera.message, "双拍开启不应退出/报错")

            model.swapDualCaptureCameras()
            try await wait("切副画面-\(cycle)") { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
            try await wait("小窗追踪-\(cycle)") { camera.frontVideoCenteringActive }
            XCTAssertFalse(model.frontVideoCenteringVisible)

            print("SOAK-PRE-SWAP-BACK cycle=\(cycle) mainFront=\(camera.dualCaptureMainIsFront) preparing=\(camera.dualCapturePreparing) enabled=\(camera.dualCaptureEnabled) tracking=\(camera.frontVideoCenteringActive) msg=\(camera.message ?? "nil")")
            model.swapDualCaptureCameras()
            try await wait("切回主画面-\(cycle)") { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
            XCTAssertTrue(model.frontVideoCenteringVisible)
            XCTAssertTrue(camera.frontVideoCenteringActive)
            try await wait("关闭追踪前稳定-\(cycle)") { !camera.frontVideoCenteringPreparing && camera.ready && !camera.dualCapturePreparing }
            print("SOAK-PRE-CLOSE cycle=\(cycle) requested=\(model.frontVideoCenteringRequested) enabled=\(camera.frontVideoCenteringEnabled) active=\(camera.frontVideoCenteringActive) preparing=\(camera.frontVideoCenteringPreparing) mainFront=\(camera.dualCaptureMainIsFront) dual=\(camera.dualCaptureEnabled)")
            model.toggleFrontVideoCentering()
            try await wait("关闭追踪-\(cycle)") { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }

            model.toggleDualCapture()
            try await wait("退出双拍-\(cycle)") { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }
            XCTAssertEqual(model.captureKind, .video)
            XCTAssertNil(camera.message)
            cycleDurations.append(CACurrentMediaTime() - began)
        }
        print("FRONT-VIDEO-SWITCH-SOAK cycles=\(cycleDurations.count) durations=\(cycleDurations) finalKind=\(model.captureKind) message=\(camera.message ?? "nil")")
    }
    #endif
}
