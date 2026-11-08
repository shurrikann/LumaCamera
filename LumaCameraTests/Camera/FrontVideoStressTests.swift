import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class FrontVideoStressTests: XCTestCase {
    #if !targetEnvironment(simulator)
    private func wait(_ label: String, timeout: Double = 25,
                      _ predicate: () -> Bool, _ camera: CameraEngine) async throws {
        let end = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < end {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(label + " message=\(camera.message ?? "nil")")
        throw CancellationError()
    }

    @MainActor func testFrontVideoTrackingDualStateStress() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }

        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "压力测试前置视频", timeout: 20)

        var cycles: [Double] = []
        for cycle in 0..<8 {
            let began = CACurrentMediaTime()
            let frameBefore = camera.previewFrameTimeForTesting

            // 交替两种进入顺序：先追踪后双拍 / 先双拍后追踪。
            let trackingFirst = cycle % 2 == 0
            if trackingFirst {
                if !camera.frontVideoCenteringActive {
                    model.toggleFrontVideoCentering()
                    try await wait("追踪先行-\(cycle)", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
                }
                model.toggleDualCapture()
                try await wait("双拍后开-\(cycle)", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
            } else {
                model.toggleDualCapture()
                try await wait("双拍先行-\(cycle)", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
                if !camera.dualCaptureMainIsFront {
                    model.swapDualCaptureCameras()
                    try await wait("前置主画面-\(cycle)", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
                }
                try await wait("双拍就绪-\(cycle)", { camera.ready && !camera.videoConfiguring }, camera)
                model.toggleFrontVideoCentering()
                try await wait("双拍内开追踪-\(cycle)", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
            }

            if !camera.dualCaptureMainIsFront {
                model.swapDualCaptureCameras()
                try await wait("确认前置主画面-\(cycle)", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
            }
            try await wait("追踪稳定-\(cycle)", { camera.frontVideoCenteringEnabled && camera.frontVideoCenteringActive }, camera)

            for round in 0..<2 {
                model.swapDualCaptureCameras()
                try await wait("小窗-\(cycle)-\(round)", { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
                try await wait("小窗追踪-\(cycle)-\(round)", { camera.frontVideoCenteringActive }, camera)
                model.swapDualCaptureCameras()
                try await wait("主画面-\(cycle)-\(round)", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
                XCTAssertTrue(camera.frontVideoCenteringActive)
            }

            if cycle % 2 == 0 {
                // 偶数轮：先在主画面关闭追踪，再退出双拍。
                try await wait("关闭追踪前就绪-\(cycle)", { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing && !camera.frontVideoCenteringPreparing }, camera)
                model.toggleFrontVideoCentering()
                try await wait("关闭追踪-\(cycle)", { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringPreparing }, camera)
                model.toggleDualCapture()
                try await wait("退出双拍-\(cycle)", { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }, camera)
            } else {
                // 奇数轮：保持追踪直接退出双拍，验证清理路径。
                model.toggleDualCapture()
                try await wait("追踪中退出双拍-\(cycle)", { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }, camera)
                XCTAssertFalse(camera.frontVideoCenteringEnabled)
                XCTAssertFalse(model.frontVideoCenteringRequested)
            }

            try await wait("视频继续出帧-\(cycle)", { camera.previewFrameTimeForTesting > frameBefore }, camera)
            XCTAssertEqual(model.captureKind, .video)
            XCTAssertNil(camera.message)
            cycles.append(CACurrentMediaTime() - began)
        }
        print("FRONT-VIDEO-STRESS cycles=\(cycles.count) durations=\(cycles) finalKind=\(model.captureKind) message=\(camera.message ?? "nil")")
    }

    @MainActor func testRapidTrackingDualAndSwapTapsDoNotExitVideo() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera, audit = SessionRuntimeErrorAudit()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }

        model.setCameraActive(true)
        try await wait("启动", { camera.ready }, camera)
        model.setCaptureKind(.video)
        if model.currentPosition != .front { model.flipCamera() }
        try await FullDeviceRegressionFixture.waitForVideoShutter(model, label: "快速点击前置视频", timeout: 20)

        // 准备一个稳定的双拍前置主画面，然后做无等待连点。
        model.toggleFrontVideoCentering()
        try await wait("追踪", { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }, camera)
        model.toggleDualCapture()
        try await wait("双拍", { camera.dualCaptureEnabled && !camera.dualCapturePreparing }, camera)
        if !camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("前置主画面", { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }, camera)
        }
        try await wait("稳定", { camera.ready && !camera.videoConfiguring }, camera)

        for _ in 0..<12 { model.toggleFrontVideoCentering() } // 多数应被 preparing 门控丢弃
        for _ in 0..<6 { model.swapDualCaptureCameras() }
        for _ in 0..<4 { model.toggleDualCapture() }
        try await Task.sleep(for: .milliseconds(2500))
        try await wait("连点后收敛", timeout: 20, {
            !camera.dualCapturePreparing && !camera.videoConfiguring && camera.ready
        }, camera)
        try await wait("连点后仍出帧", timeout: 10, {
            camera.previewFrameTimeForTesting > 0 && camera.previewFrameTimeForTesting + 5 > CACurrentMediaTime()
        }, camera)

        XCTAssertEqual(model.captureKind, .video)
        XCTAssertNil(camera.message)
        print("FRONT-VIDEO-STRESS rapidTaps kind=\(model.captureKind) dual=\(camera.dualCaptureEnabled) mainFront=\(camera.dualCaptureMainIsFront) tracking=\(camera.frontVideoCenteringActive) message=\(camera.message ?? "nil")")
    }
    #endif
}
