import XCTest
import AVFoundation
@testable import LumaCamera

#if !targetEnvironment(simulator)
final class SubmodeRoundTripFocalLatencyTests: XCTestCase {
    @MainActor func testPortraitCinematicRoundTripThenFocalSwitch() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true)
        for _ in 0..<500 {
            if camera.ready && !camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(camera.ready)
        model.setCaptureKind(.photo)
        for _ in 0..<500 {
            if camera.ready && !camera.videoConfiguring && !model.captureKindSwitching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard camera.supportsPortraitCapture else { throw XCTSkip("portrait unsupported") }
        let baseline = try await measure(model: model, camera: camera, label: "baseline")
        print(baseline)
        model.togglePortraitMode()
        for _ in 0..<500 {
            if model.portraitModeEnabled && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.portraitModeEnabled, camera.message ?? "")
        model.setCaptureKind(.video)
        for _ in 0..<500 {
            if camera.ready && !camera.videoConfiguring && !model.captureKindSwitching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.toggleCinematicVideoMode()
        for _ in 0..<600 {
            if model.cinematicVideoEnabled && camera.cinematicVideoCaptureActive && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.cinematicVideoEnabled, camera.message ?? "")
        model.setCaptureKind(.photo)
        for _ in 0..<700 {
            if camera.ready && !camera.videoConfiguring && !model.captureKindSwitching && !model.isPreparingSubmode { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.captureKind, .photo, camera.message ?? "")
        XCTAssertTrue(camera.ready, camera.message ?? "")
        for round in 0..<3 {
            let result = try await measure(model: model, camera: camera, label: "roundtrip\(round)")
            print(result)
            XCTAssertTrue(result.contains("done=-1") == false, result)
        }
        model.setCameraActive(false)
    }

    @MainActor private func measure(model: CameraViewModel, camera: CameraEngine, label: String) async throws -> String {
        let focal = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 2) < 0.01 })
        let other = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom - 1) < 0.01 })
        if camera.selectedLens == focal.id { model.selectFocalLength(other) }
        for _ in 0..<300 { if model.focalTransitionImage == nil && !camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(5)) }
        let startFrame = camera.previewFrameTimeForTesting
        let start = CACurrentMediaTime()
        var maxMainGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = CACurrentMediaTime(); maxMainGap = max(maxMainGap, now - last); last = now
            }
        }
        model.selectFocalLength(focal)
        var selectedAt: Double?, frameAt: Double?, doneAt: Double?
        for _ in 0..<700 {
            let now = CACurrentMediaTime()
            if selectedAt == nil, camera.selectedLens == focal.id { selectedAt = now }
            if frameAt == nil, camera.previewFrameTimeForTesting > startFrame { frameAt = now }
            if selectedAt != nil, frameAt != nil, model.focalTransitionImage == nil, !camera.videoConfiguring, camera.ready { doneAt = now; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        heartbeat.cancel()
        return "FOCAL-ROUNDTRIP label=\(label) select=\(selectedAt.map { $0 - start } ?? -1) frame=\(frameAt.map { $0 - start } ?? -1) done=\(doneAt.map { $0 - start } ?? -1) maxMainGap=\(maxMainGap) selected=\(camera.selectedLens == focal.id) message=\(camera.message ?? "nil")"
    }

    @MainActor func testFocalAfterMultipleSubmodeRoundTrips() async throws {
        struct Case { let name: String; let photo: (CameraViewModel) -> Void; let video: (CameraViewModel) -> Void; let videoEnabled: (CameraViewModel) -> Bool }
        let cases: [Case] = [
            Case(name: "portrait-cinematic", photo: { $0.togglePortraitMode() }, video: { $0.toggleCinematicVideoMode() },
                 videoEnabled: { $0.cinematicVideoEnabled }),
            Case(name: "slowShutter-slowMotion", photo: { $0.toggleSlowShutterMode() }, video: { $0.toggleSlowMotionMode() },
                 videoEnabled: { $0.slowMotionEnabled }),
            Case(name: "burst-timeLapse", photo: { $0.toggleBurstMode() }, video: { $0.toggleTimeLapseMode() },
                 videoEnabled: { $0.timeLapseEnabled }),
            Case(name: "portrait-slowMotion", photo: { $0.togglePortraitMode() }, video: { $0.toggleSlowMotionMode() },
                 videoEnabled: { $0.slowMotionEnabled }),
            Case(name: "slowShutter-cinematic", photo: { $0.toggleSlowShutterMode() }, video: { $0.toggleCinematicVideoMode() },
                 videoEnabled: { $0.cinematicVideoEnabled }),
            Case(name: "burst-dual", photo: { $0.toggleBurstMode() }, video: { $0.toggleDualCapture() },
                 videoEnabled: { $0.camera.dualCaptureEnabled }),
            Case(name: "virtualAperture-both", photo: { $0.toggleVirtualAperture() }, video: { $0.toggleVirtualAperture() },
                 videoEnabled: { $0.virtualApertureEnabled }),
        ]
        var results: [String] = []
        for item in cases {
            let model = try await FullDeviceRegressionFixture.makeFreshModel()
            model.setCameraActive(true)
            for _ in 0..<500 { if model.camera.ready && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
            guard model.camera.ready else { results.append("FOCAL-MATRIX \(item.name) SKIP cameraNotReady"); continue }
            model.setCaptureKind(.photo)
            for _ in 0..<500 { if model.camera.ready && !model.captureKindSwitching && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
            if item.name == "portrait-cinematic" || item.name == "portrait-slowMotion" {
                guard model.camera.supportsPortraitCapture else { results.append("FOCAL-MATRIX \(item.name) SKIP portrait"); model.setCameraActive(false); continue }
            }
            item.photo(model)
            for _ in 0..<500 { if !model.isPreparingSubmode && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
            model.setCaptureKind(.video)
            for _ in 0..<600 { if model.captureKind == .video && model.camera.ready && !model.captureKindSwitching && !model.camera.videoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
            if item.name.contains("cinematic") && model.camera.cinematicVideoSettings.isEmpty {
                results.append("FOCAL-MATRIX \(item.name) SKIP cinematic kind=\(model.captureKind) ready=\(model.camera.ready) cinematic=\(model.camera.cinematicVideoSettings.count) supported=\(model.camera.supportedVideoSettings.count) message=\(model.camera.message ?? "nil")"); model.setCaptureKind(.photo); model.setCameraActive(false); continue
            }
            if item.name.contains("slowMotion") && model.camera.slowMotionVideoSettings.isEmpty {
                results.append("FOCAL-MATRIX \(item.name) SKIP slowMotion kind=\(model.captureKind) ready=\(model.camera.ready) slow=\(model.camera.slowMotionVideoSettings.count) supported=\(model.camera.supportedVideoSettings.count) message=\(model.camera.message ?? "nil")"); model.setCaptureKind(.photo); model.setCameraActive(false); continue
            }
            if item.name.contains("dual") && !model.dualCaptureAvailable {
                results.append("FOCAL-MATRIX \(item.name) SKIP dual"); model.setCaptureKind(.photo); model.setCameraActive(false); continue
            }
            item.video(model)
            for _ in 0..<700 { if item.videoEnabled(model) && !model.isPreparingSubmode && !model.camera.videoConfiguring && !model.camera.dualCapturePreparing { break }; try await Task.sleep(for: .milliseconds(20)) }
            let entered = item.videoEnabled(model)
            model.setCaptureKind(.photo)
            for _ in 0..<900 { if model.captureKind == .photo && model.camera.ready && !model.captureKindSwitching && !model.camera.videoConfiguring && !model.camera.dualCapturePreparing && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
            if !entered {
                results.append("FOCAL-MATRIX \(item.name) VIDEO_NOT_ENTERED message=\(model.camera.message ?? "nil")")
            } else if model.captureKind != .photo || !model.camera.ready {
                results.append("FOCAL-MATRIX \(item.name) PHOTO_NOT_RESTORED message=\(model.camera.message ?? "nil")")
            } else {
                for attempt in 0..<2 {
                    let line = try await measure(model: model, camera: model.camera, label: "\(item.name)-\(attempt)")
                    results.append(line)
                }
            }
            model.setCameraActive(false)
            try await Task.sleep(for: .milliseconds(200))
        }
        let summary = results.joined(separator: "\n")
        print(summary)
        XCTAssertFalse(results.isEmpty)
        XCTAssertFalse(results.contains { $0.contains("PHOTO_NOT_RESTORED") || $0.contains("done=-1") }, summary)
    }
}
#endif
