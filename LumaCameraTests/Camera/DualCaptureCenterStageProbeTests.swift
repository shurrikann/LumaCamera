import AVFoundation
import XCTest
@testable import LumaCamera

final class DualCaptureCenterStageProbeTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testProbeCenterStageWhileDualCaptureEnabled() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); audit.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }
        model.toggleDualCapture()
        try await wait("双拍") { camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        let info = await withCheckedContinuation { c in camera.probeDualCaptureCenterStageForTesting { c.resume(returning: $0) } }
        print("DUAL-CENTERSTAGE-PROBE \(info)")
        XCTAssertEqual(info["dual"], "true")
        XCTAssertEqual(info["supported"], "true", "双拍前置格式必须报告 CenterStage 能力，才可能继续验证")
        XCTAssertEqual(info["active"], "true", "系统在双拍中没有真正进入 CenterStage")
    }
    #endif
    @MainActor func testProductCanEnableAndDisableCenterStageDuringDualCapture() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); audit.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }
        model.toggleDualCapture()
        try await wait("双拍") { camera.ready && camera.dualCaptureEnabled && !camera.dualCapturePreparing }
        if !camera.dualCaptureMainIsFront {
            model.swapDualCaptureCameras()
            try await wait("前置主画面") { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
        }
        XCTAssertTrue(camera.dualCaptureMainIsFront)
        XCTAssertTrue(model.frontVideoCenteringVisible)
        model.toggleFrontVideoCentering()
        try await wait("双拍开启人物追踪") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        XCTAssertTrue(camera.frontVideoCenteringEnabled)
        // 前置切到小窗后追踪应继续，只是不再显示设置入口。
        model.swapDualCaptureCameras()
        try await wait("前置小窗") { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
        try await wait("小窗继续追踪") { camera.frontVideoCenteringActive && camera.frontVideoCenteringEnabled }
        XCTAssertFalse(model.frontVideoCenteringVisible)
        model.swapDualCaptureCameras()
        try await wait("回前置主画面") { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
        XCTAssertTrue(camera.frontVideoCenteringActive)
        print("DUAL-CENTERSTAGE-PRODUCT enabled=true insetPersists=true")
        model.toggleFrontVideoCentering()
        try await wait("双拍关闭人物追踪") { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        XCTAssertFalse(model.frontVideoCenteringRequested)
        print("DUAL-CENTERSTAGE-PRODUCT enabled=false")
    }

    @MainActor func testTrackingEnabledInNormalFrontVideoSurvivesDualCaptureEntry() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); audit.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        if model.currentPosition != .front { model.flipCamera() }
        try await wait("前置") { camera.ready && model.currentPosition == .front && !camera.videoConfiguring }
        model.toggleFrontVideoCentering()
        try await wait("普通前置追踪") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
        model.toggleDualCapture()
        try await wait("双拍承接追踪") {
            camera.dualCaptureEnabled && !camera.dualCapturePreparing
                && camera.frontVideoCenteringEnabled && camera.frontVideoCenteringActive
        }
        print("DUAL-CENTERSTAGE-PRODUCT entryPreservesTracking=true")
        model.toggleDualCapture()
        try await wait("退出双拍") { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }
        XCTAssertFalse(model.frontVideoCenteringRequested)
    }

}
