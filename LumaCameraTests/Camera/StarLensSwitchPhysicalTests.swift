import AVFoundation
import XCTest
@testable import LumaCamera

final class StarLensSwitchPhysicalTests: XCTestCase {
    @MainActor func testPhotoEngineSwitchesWideToPhysicalTele() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实相机")
        #else
        guard AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil else {
            XCTFail("没有物理长焦")
            return
        }
        let engine = AstroPhotoEngine()
        defer { engine.stop() }
        engine.start()
        let wide = await wait { engine.session.isRunning && engine.activeDeviceType == .builtInWideAngleCamera }
        XCTAssertTrue(wide, "主摄会话未启动")
        print("LENS-SWITCH before=\(String(describing: engine.activeDeviceType)) running=\(engine.session.isRunning)")

        engine.switchLens(to: .builtInTelephotoCamera)
        let tele = await wait(timeout: 15) {
            engine.activeDeviceType == .builtInTelephotoCamera && engine.session.isRunning
        }
        print("LENS-SWITCH after=\(String(describing: engine.activeDeviceType)) running=\(engine.session.isRunning)")
        XCTAssertTrue(tele, "切换长焦后会话未恢复")
        #endif
    }

    @MainActor private func wait(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }

    @MainActor func testTrailsAndTimelapseSwitchToTele() async throws {
        guard AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil else {
            XCTFail("没有物理长焦"); return
        }
        let trails = AstroTrailsEngine()
        defer { trails.stop() }
        trails.start()
        let trailsWide = await wait { trails.session.isRunning && trails.activeDeviceType == .builtInWideAngleCamera }
        XCTAssertTrue(trailsWide)
        trails.switchLens(to: .builtInTelephotoCamera)
        let trailsTele = await wait(timeout: 15) { trails.activeDeviceType == .builtInTelephotoCamera && trails.session.isRunning }
        XCTAssertTrue(trailsTele, "星轨长焦切换失败")
        print("LENS-SWITCH trails=\(String(describing: trails.activeDeviceType))")
        trails.stop()

        let timelapse = AstroTimelapseEngine()
        defer { timelapse.stop() }
        timelapse.start()
        let timelapseWide = await wait { timelapse.session.isRunning && timelapse.activeDeviceType == .builtInWideAngleCamera }
        XCTAssertTrue(timelapseWide)
        timelapse.switchLens(to: .builtInTelephotoCamera)
        let timelapseTele = await wait(timeout: 15) { timelapse.activeDeviceType == .builtInTelephotoCamera && timelapse.session.isRunning }
        XCTAssertTrue(timelapseTele, "延时长焦切换失败")
        print("LENS-SWITCH timelapse=\(String(describing: timelapse.activeDeviceType))")
    }
}
