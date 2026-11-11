import XCTest
@testable import LumaCamera

#if !targetEnvironment(simulator)
final class SubmodeSwitchingPhysicalTests: XCTestCase {
    @MainActor func testPhotoSubmodesCanLeaveVirtualApertureRepeatedly() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.setCaptureKind(.photo)
        model.photoFormat = .heif
        model.ratio = .standard
        for _ in 0..<400 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        var failures: [String] = []
        for cycle in 0..<12 {
            if model.virtualApertureEnabled { model.toggleVirtualAperture() }
            model.camera.message = nil
            model.toggleVirtualAperture()
            try await Task.sleep(for: .milliseconds(120))
            guard model.virtualApertureEnabled else {
                failures.append("cycle=\(cycle) virtual aperture not enabled: \(model.camera.message ?? "nil")")
                continue
            }
            switch cycle % 3 {
            case 0: model.toggleSlowShutterMode()
            case 1: model.toggleBurstMode()
            default: model.togglePortraitMode()
            }
            for _ in 0..<300 {
                if !model.isPreparingSubmode && !model.camera.videoConfiguring { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let mode = cycle % 3
            let enabled = mode == 0 ? model.slowShutterEnabled : mode == 1 ? model.burstModeEnabled : model.portraitModeEnabled
            if !enabled || model.camera.message != nil {
                failures.append("cycle=\(cycle) mode=\(mode) enabled=\(enabled) message=\(model.camera.message ?? "nil")")
            }
            if model.slowShutterEnabled { model.toggleSlowShutterMode() }
            if model.burstModeEnabled { model.toggleBurstMode() }
            if model.portraitModeEnabled { model.togglePortraitMode() }
            if model.virtualApertureEnabled { model.toggleVirtualAperture() }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        model.setCameraActive(false)
    }

    @MainActor func testVideoSubmodesCanSwitchRandomly() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.setCaptureKind(.video)
        for _ in 0..<400 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        var failures: [String] = []
        let order = [0, 1, 2, 2, 0, 1, 0, 2, 1]
        for (cycle, pick) in order.enumerated() {
            model.camera.message = nil
            switch pick {
            case 0: model.toggleTimeLapseMode()
            case 1: model.toggleSlowMotionMode()
            default: model.toggleCinematicVideoMode()
            }
            let targetEnabled: () -> Bool = { pick == 0 ? model.timeLapseEnabled : pick == 1 ? model.slowMotionEnabled : model.cinematicVideoEnabled }
            for _ in 0..<600 {
                if targetEnabled() || model.camera.message != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let enabled = targetEnabled()
            if !enabled || model.camera.message != nil {
                failures.append("cycle=\(cycle) pick=\(pick) enabled=\(enabled) message=\(model.camera.message ?? "nil")")
            }
            if model.timeLapseEnabled { model.toggleTimeLapseMode() }
            if model.slowMotionEnabled { model.toggleSlowMotionMode() }
            if model.cinematicVideoEnabled { model.toggleCinematicVideoMode() }
            try await Task.sleep(for: .milliseconds(120))
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        model.setCameraActive(false)
    }

    @MainActor func testRapidRandomSubmodeTapsDoNotLeaveStaleFailure() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.setCaptureKind(.photo)
        model.photoFormat = .heif
        for _ in 0..<300 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 33) % 5) }
        for _ in 0..<40 {
            switch next() {
            case 0: model.toggleVirtualAperture()
            case 1: model.toggleSlowShutterMode()
            case 2: model.toggleBurstMode()
            case 3: model.togglePortraitMode()
            default: break
            }
            try await Task.sleep(for: .milliseconds(18))
        }
        for _ in 0..<500 {
            if !model.isPreparingSubmode && !model.camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.camera.message, "Rapid photo submode taps left stale message: \(model.camera.message ?? "")")
        model.setCameraActive(false)
    }

    @MainActor func testUnorderedPhotoVideoAndSubmodeSwitching() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.photoFormat = .heif
        model.ratio = .standard
        for _ in 0..<400 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        var seed: UInt64 = 0xD1B54A32D192ED03
        func next(_ n: UInt64) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % n) }
        var failures: [String] = []
        for step in 0..<60 {
            switch next(7) {
            case 0:
                model.requestCaptureKind(model.captureKind == .photo ? .video : .photo)
            case 1:
                if model.captureKind == .photo { model.toggleVirtualAperture() }
                else { model.toggleVirtualAperture() }
            case 2:
                if model.captureKind == .photo { model.toggleSlowShutterMode() }
                else { model.toggleSlowMotionMode() }
            case 3:
                if model.captureKind == .photo { model.toggleBurstMode() }
                else { model.toggleTimeLapseMode() }
            case 4:
                if model.captureKind == .photo { model.togglePortraitMode() }
                else { model.toggleCinematicVideoMode() }
            case 5:
                if model.captureKind == .video { model.toggleDualCapture() }
            default:
                model.requestCaptureKind(.photo)
            }
            try await Task.sleep(for: .milliseconds(next(70) + 10))
            if step % 6 == 0 {
                for _ in 0..<200 {
                    if !model.isPreparingSubmode && !model.camera.videoConfiguring && !model.captureKindSwitching { break }
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            if let message = model.camera.message, !message.isEmpty {
                failures.append("step=\(step) kind=\(model.captureKind) message=\(message)")
                model.camera.message = nil
            }
        }
        for _ in 0..<1000 {
            if model.camera.ready, !model.isPreparingSubmode, !model.camera.videoConfiguring, !model.captureKindSwitching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.camera.ready, model.camera.message ?? "camera not ready")
        XCTAssertTrue(failures.isEmpty, failures.prefix(8).joined(separator: "\n"))
        model.setCameraActive(false)
    }

    @MainActor func testCinematicThenDualCaptureDoesNotCrashOrStall() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.setCaptureKind(.video)
        for _ in 0..<400 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        model.toggleCinematicVideoMode()
        // 电影准备尚未完成时立刻切双拍，模拟乱点。
        model.toggleDualCapture()
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<600 {
            if model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive {
            model.toggleDualCapture()
            for _ in 0..<600 {
                if model.camera.dualCaptureEnabled || !model.isPreparingSubmode { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertTrue(model.camera.ready, model.camera.message ?? "camera not ready after cinematic/dual switch")
        XCTAssertNil(model.camera.message)
        model.setCameraActive(false)
    }

    @MainActor func testDualFrontMainKeepsFrontVideoCenteringEntry() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        model.setCaptureKind(.video)
        for _ in 0..<400 {
            if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.camera.ready)
        guard model.dualCaptureAvailable else {
            throw XCTSkip("当前设备不支持双拍")
        }
        model.toggleDualCapture()
        for _ in 0..<600 {
            if model.camera.dualCaptureEnabled && !model.camera.dualCapturePreparing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.camera.dualCaptureEnabled)
        if !model.camera.dualCaptureMainIsFront { model.swapDualCaptureCameras() }
        for _ in 0..<600 {
            if model.camera.dualCaptureMainIsFront && model.camera.frontVideoCenteringAvailable { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.camera.dualCaptureMainIsFront)
        XCTAssertTrue(model.camera.frontVideoCenteringAvailable)
        XCTAssertTrue(model.frontVideoCenteringVisible)
        model.setCameraActive(false)
    }

    @MainActor func testDualCaptureToCinematicDoesNotCrash() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        for _ in 0..<400 { if model.camera.ready && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(25)) }
        model.setCaptureKind(.video)
        for _ in 0..<500 { if model.camera.ready && !model.camera.videoConfiguring && !model.captureKindSwitching { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard model.dualCaptureAvailable else { throw XCTSkip("dual unavailable") }
        model.toggleDualCapture()
        for _ in 0..<700 { if model.camera.dualCaptureEnabled && !model.camera.dualCapturePreparing { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.camera.dualCaptureEnabled, model.camera.message ?? "")
        model.toggleCinematicVideoMode()
        for _ in 0..<900 { if model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.cinematicVideoEnabled, model.camera.message ?? "")
        XCTAssertTrue(model.camera.cinematicVideoCaptureActive, model.camera.message ?? "")
        model.setCameraActive(false)
    }

    @MainActor func testRepeatedDualCinematicSwitchKeepsCinematic() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        for _ in 0..<400 { if model.camera.ready && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(25)) }
        model.setCaptureKind(.video)
        for _ in 0..<500 { if model.camera.ready && !model.camera.videoConfiguring && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard model.dualCaptureAvailable else { throw XCTSkip("dual unavailable") }
        for cycle in 0..<4 {
            if !model.camera.dualCaptureEnabled {
                model.toggleDualCapture()
                for _ in 0..<700 { if model.camera.dualCaptureEnabled && !model.camera.dualCapturePreparing { break }; try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(model.camera.dualCaptureEnabled, "cycle=\(cycle) dual on: \(model.camera.message ?? "")")
            }
            model.toggleCinematicVideoMode()
            for _ in 0..<800 {
                if model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive && !model.isPreparingSubmode { break }
                if model.camera.message != nil && !model.cinematicVideoEnabled { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.cinematicVideoEnabled && model.camera.cinematicVideoCaptureActive,
                          "cycle=\(cycle) cinematic not active: \(model.camera.message ?? "nil")")
            model.toggleCinematicVideoMode()
            for _ in 0..<500 { if !model.cinematicVideoEnabled && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.cinematicVideoEnabled, "cycle=\(cycle) cinematic did not turn off")
        }
        model.setCameraActive(false)
    }
}
#endif
