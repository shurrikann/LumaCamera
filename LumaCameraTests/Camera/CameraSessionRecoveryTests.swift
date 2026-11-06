import AVFoundation
import XCTest
import UIKit
@testable import LumaCamera

final class CameraSessionRecoveryTests: XCTestCase {
    @MainActor func testTemporaryInterruptionIsSilentAndEndedCannotRestartStoppedCamera() async throws {
        let camera = CameraEngine()
        #if !targetEnvironment(simulator)
        throw XCTSkip("Use the shared visible engine for physical recovery tests")
        #else
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("Session interruption recovery requires the simulator app to be foreground-active")
        }
        camera.start(); defer { camera.stop() }
        for _ in 0..<100 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        camera.simulateInterruptionForTesting(ended:false)
        for _ in 0..<50 { if camera.recoveringSession { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNil(camera.message); XCTAssertTrue(camera.recoveringSession)
        camera.simulateInterruptionForTesting(ended:true)
        for _ in 0..<100 { if camera.ready && !camera.recoveringSession { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertNil(camera.message)
        camera.stop()
        camera.simulateInterruptionForTesting(ended:true)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(camera.ready); XCTAssertFalse(camera.recoveringSession); XCTAssertNil(camera.message)
        #endif
    }

    #if !targetEnvironment(simulator)
    @MainActor func testRestartAfterInterruptedFrameGateDeliversFreshPreview() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 {
            if camera.ready && camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        for _ in 0..<3 {
            let previous = camera.preview
            camera.simulateInterruptionForTesting(ended: false)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            XCTAssertFalse(camera.ready)
            // Re-entering the foreground must recover even without an ended notification.
            camera.start()
            for _ in 0..<300 {
                if camera.ready && camera.preview != nil && camera.preview !== previous { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertTrue(camera.preview !== previous)
            XCTAssertFalse(camera.recoveryFailed)
            XCTAssertNil(camera.message)
        }
    }
    @MainActor func testRuntimeRecoveryRestoresLiveFramesAndManualExposureWithoutWritingPhotos() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let mode = model.mode, oldISO = model.iso, oldShutter = model.shutter, oldManual = model.manualExposure
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            model.setMode(mode); model.iso = oldISO; model.shutter = oldShutter; model.manualExposure = oldManual; model.applyExposure()
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.manual); model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0/125); model.applyExposure()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<4 {
            let previous = camera.preview
            camera.simulateRuntimeStopForTesting()
            try await Task.sleep(for:.milliseconds(100))
            for _ in 0..<300 {
                if camera.ready && !camera.recoveringSession && camera.preview != nil && camera.preview !== previous { break }
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertTrue(camera.ready); XCTAssertFalse(camera.recoveringSession); XCTAssertFalse(camera.recoveryFailed); XCTAssertNil(camera.message)
            var state: CameraEngine.ExposureColorState?
            for _ in 0..<100 {
                state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
                if let state, abs(Double(state.iso)-400)<5, abs(state.seconds-1.0/125)<0.001 { break }
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertEqual(Double(try XCTUnwrap(state).iso),400,accuracy:5)
            XCTAssertEqual(try XCTUnwrap(state).seconds,1.0/125,accuracy:0.001)
        }
        model.setCameraActive(false); await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.simulateInterruptionForTesting(ended:true)
        try await Task.sleep(for:.milliseconds(150))
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
        XCTAssertFalse(running); XCTAssertFalse(camera.ready); XCTAssertNil(camera.message)
    }
    #endif
    /// 注入带真实 error key 的公开错误通知，只验证恢复契约，不冒充复现系统服务崩溃。
    @MainActor func testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        var durations: [Double] = []
        for code in [AVError.Code.unknown, .mediaServicesWereReset, .unknown, .mediaServicesWereReset] {
            let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12780)
            let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                userInfo: code == .unknown ? [NSUnderlyingErrorKey: underlying] : [:])
            let start = CACurrentMediaTime(), previousFrame = camera.previewFrameTimeForTesting
            camera.simulateRuntimeStopForTesting(error: error)
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<400 {
                if camera.ready && !camera.recoveringSession && camera.previewFrameTimeForTesting > previousFrame { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(camera.ready)
            XCTAssertFalse(camera.recoveryFailed)
            XCTAssertFalse(camera.recoveringSession)
            XCTAssertNil(camera.message)
            XCTAssertGreaterThan(camera.previewFrameTimeForTesting, previousFrame)
            durations.append(CACurrentMediaTime() - start)
        }
        camera.simulateRuntimeStopForTesting(error: NSError(domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue))
        model.setCameraActive(false)
        await Task.yield()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        try await Task.sleep(for: .milliseconds(500))
        let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning: $0) } }
        XCTAssertFalse(running, "退出后迟到的服务错误不能重新启动相机")
        XCTAssertFalse(camera.ready)
        print("RUNTIME-RECOVERY-INJECTED samples=\(durations.count) p50=\(durations.sorted()[durations.count / 2]) max=\(durations.max() ?? 0) fresh-frame=true noPhotosWrites=true")
    }

    @MainActor func testLateRecoveryNotificationCannotCancelQueuedForegroundStart() async throws {
        #if targetEnvironment(simulator)
        let camera=CameraEngine()
        #else
        let model=try XCTUnwrap(AppDependencies.runningAppCameraModel)
        model.setCameraActive(false)
        await Task.yield()
        let camera=model.camera
        #endif
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { camera.stop();UIApplication.shared.isIdleTimerDisabled=idle }
        camera.stop()
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for pass in 0..<4 {
            let gate=DispatchSemaphore(value:0)
            camera.pauseSessionQueueForTesting(gate)
            camera.start()
            for _ in 0..<20 { camera.simulateInterruptionForTesting(ended:true) }
            XCTAssertFalse(camera.recoveringSession,"A queued foreground start must retain its lifecycle token")
            gate.signal()
            for _ in 0..<300 { if camera.ready && camera.preview != nil { break };try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertTrue(camera.ready);XCTAssertNotNil(camera.preview);XCTAssertFalse(camera.recoveryFailed)
            print("START-RECOVERY pass=\(pass) lateNotifications=20 ready=\(camera.ready)")
            camera.stop()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
    }

}
