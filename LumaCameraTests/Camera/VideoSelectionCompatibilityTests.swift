import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

@MainActor final class VideoSelectionCompatibilityTests: XCTestCase {
    func testPresetsUseExactCaptureRateAndCinematicZoomRange() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let runtime = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish() }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<1500 {
                if camera.ready && !camera.videoBusy && !camera.videoConfiguring && !model.isPreparingSubmode { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail(camera.message ?? "视频未就绪"); throw CancellationError()
        }
        model.setCameraActive(true); try await settle()
        model.setCaptureKind(.video); model.setMode(.manual); try await settle()
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.001 })
        camera.selectLens(main); model.videoResolution = .hd1080; model.videoFrameRate = .fps30; try await settle()
        model.toggleSlowMotionMode(); try await settle(); XCTAssertTrue(model.slowMotionEnabled)
        model.selectVideoFrameRate(.fps240); try await settle()
        XCTAssertEqual(camera.videoSettings.captureFrameRate,.fps240)
        XCTAssertFalse(model.videoResolutionOptions.contains(.uhd4K))
        model.selectVideoResolution(.uhd4K); try await settle()
        XCTAssertEqual(model.videoResolution,.hd1080); XCTAssertEqual(camera.videoSettings.captureFrameRate,.fps240)
        model.selectVideoFrameRate(.fps120); try await settle()
        XCTAssertTrue(model.videoResolutionOptions.contains(.uhd4K))
        XCTAssertTrue(model.videoColorSpaceOptions.contains(.sdr))
        model.selectVideoResolution(.uhd4K); try await settle()
        XCTAssertEqual(camera.videoSettings.captureFrameRate,.fps120)
        XCTAssertTrue(model.displayedFocalLenses.allSatisfy { $0.device.uniqueID == main.device.uniqueID })
        model.toggleSlowMotionMode(); try await settle()
        model.videoResolution = .uhd4K; model.videoFrameRate = .fps30; try await settle()
        model.toggleCinematicVideoMode(); try await settle(); XCTAssertTrue(model.cinematicVideoEnabled)
        XCTAssertFalse(model.displayedFocalLenses.isEmpty)
        XCTAssertTrue(model.displayedFocalLenses.allSatisfy { $0.displayZoom >= 1 && $0.displayZoom <= 3 })
        model.selectVideoFrameRate(.fps24); try await settle()
        XCTAssertFalse(model.videoResolutionOptions.contains(.hd1080))
        model.selectVideoResolution(.hd1080); try await settle()
        XCTAssertEqual(model.videoResolution,.uhd4K); XCTAssertEqual(model.videoFrameRate,.fps24)
        model.selectVideoFrameRate(.fps30); model.selectVideoResolution(.hd1080); try await settle()
        XCTAssertEqual(model.videoResolution,.hd1080); XCTAssertEqual(model.videoFrameRate,.fps30)
        model.toggleCinematicVideoMode(); try await settle()
        model.toggleTimeLapseMode(); try await settle(); XCTAssertTrue(model.timeLapseEnabled)
        for preset in TimeLapsePreset.allCases {
            model.selectTimeLapsePreset(preset)
            let lensID = camera.selectedLens, resolution = model.videoResolution, rate = model.videoFrameRate
            XCTAssertFalse(model.videoResolutionOptions.isEmpty); XCTAssertFalse(model.displayedFocalLenses.isEmpty)
            XCTAssertEqual(camera.selectedLens,lensID); XCTAssertEqual(model.videoResolution,resolution); XCTAssertEqual(model.videoFrameRate,rate)
        }
        model.toggleTimeLapseMode(); try await settle()
        XCTAssertFalse(model.timeLapseEnabled); XCTAssertFalse(camera.videoBusy)
        print("VIDEO-SELECTION presets=slowMotion240/120,cinematic24/30,timeLapse5 exactCombinationPreserved=true")
    }

    func testPhysicalLensAndSpecificationFilteringPreservesSelectionAndAdaptiveLayout() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let runtime = SessionRuntimeErrorAudit()
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("视频就绪") { camera.ready && !camera.videoConfiguring && !camera.videoBusy && !model.isPreparingSubmode }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready }
        let start = CACurrentMediaTime()
        model.setCaptureKind(.video); model.setMode(.manual)
        try await settle()
        try await wait("镜头能力表") { !camera.videoSelectionCapabilities.isEmpty }
        print("VIDEO-SELECTION coldEntryAndCapabilitySeconds=\(CACurrentMediaTime()-start) rows=\(camera.videoSelectionCapabilities.count)")
        let rear = camera.lenses.filter { $0.device.position == .back }
        let main = try XCTUnwrap(rear.first { abs($0.displayZoom-1)<0.001 })
        let ultra = try XCTUnwrap(rear.first { abs($0.displayZoom-0.5)<0.001 })
        let tele = try XCTUnwrap(rear.first { abs($0.displayZoom-4)<0.001 })
        model.videoResolution = .uhd4K; model.videoFrameRate = .fps60; model.videoColorSpace = .sdr
        camera.selectLens(main); try await settle()
        XCTAssertTrue(model.videoFrameRateOptions.contains(.fps120))
        model.selectVideoFrameRate(.fps120); try await settle()
        let compatible = model.displayedFocalLenses
        XCTAssertFalse(compatible.contains { $0.id == ultra.id || $0.id == tele.id })
        XCTAssertTrue(compatible.contains { $0.id == main.id })
        for lens in [ultra,tele] { model.selectFocalLength(lens) }
        try await settle()
        XCTAssertEqual(camera.selectedLens,main.id); XCTAssertEqual(camera.videoSettings.frameRate,.fps120)
        XCTAssertEqual(camera.videoSettings.resolution,.uhd4K)
        model.selectVideoFrameRate(.fps60); try await settle()
        XCTAssertTrue(model.displayedFocalLenses.contains { $0.id == ultra.id })
        XCTAssertTrue(model.displayedFocalLenses.contains { $0.id == tele.id })
        for lens in [ultra,tele,main,tele,ultra,main] {
            model.selectFocalLength(lens); try await settle()
            XCTAssertEqual(camera.selectedLens,lens.id)
            XCTAssertEqual(camera.videoSettings.resolution,.uhd4K); XCTAssertEqual(camera.videoSettings.frameRate,.fps60)
            if lens.id != main.id {
                XCTAssertFalse(model.videoFrameRateOptions.contains(.fps120))
                model.selectVideoFrameRate(.fps120); try await settle()
                XCTAssertEqual(camera.selectedLens,lens.id); XCTAssertEqual(model.videoFrameRate,.fps60)
            }
        }
        model.setMode(.auto); try await settle()
        // 在A挡明确选主摄，再核对规格和实际采集周期。
        model.selectFocalLength(main); try await settle()
        XCTAssertEqual(camera.selectedLens,main.id)
        model.selectVideoFrameRate(.fps120); try await settle()
        XCTAssertEqual(camera.videoSettings.resolution,.uhd4K); XCTAssertEqual(camera.videoSettings.frameRate,.fps120)
        XCTAssertTrue(model.displayedFocalLenses.allSatisfy { $0.device.uniqueID == main.device.uniqueID })
        model.selectFocalLength(ultra); try await settle()
        XCTAssertNotEqual(camera.selectedLens,ultra.id)
        let actualPeriod = await withCheckedContinuation { c in
            camera.videoFormatStateForTesting { _, minimum, _, _ in c.resume(returning:minimum) }
        }
        XCTAssertEqual(actualPeriod,1.0/120,accuracy:0.0001)
        model.selectVideoFrameRate(.fps60); model.setMode(.manual); try await settle()
        // Read-only recomputation must remain cheap and must not enumerate device formats per view update.
        var samples = [Double]()
        for _ in 0..<100 {
            let t = CACurrentMediaTime()
            for _ in 0..<10 {
                XCTAssertFalse(model.displayedFocalLenses.isEmpty)
                XCTAssertFalse(model.videoResolutionOptions.isEmpty)
                XCTAssertFalse(model.videoFrameRateOptions.isEmpty)
                _ = model.videoColorSpaceOptions; _ = model.videoCodecOptions
            }
            samples.append((CACurrentMediaTime()-t)/10)
        }
        samples.sort()
        print("VIDEO-SELECTION querySets=1000 medianSeconds=\(samples[50]) p95Seconds=\(samples[95]) maxSeconds=\(samples.last!)")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        var layouts = 0
        for lens in [main,ultra] {
            model.selectFocalLength(lens); try await settle()
            model.toolbarPanel = .videoFormat
            for width in [CGFloat(304),window.bounds.width-16] {
                host.rootView = AnyView(VStack {
                    CameraView(model:model).toolbarOptionsPanel(availableWidth:width)
                    Spacer()
                }.preferredColorScheme(.dark).background(Color.black))
                try await Task.sleep(for:.milliseconds(300))
                let panel = try XCTUnwrap(model.captureButtonFramesForTesting["videoOptionsPanel"])
                XCTAssertLessThanOrEqual(panel.width,width+1)
                for resolution in model.videoResolutionOptions {
                    let frame = try XCTUnwrap(model.captureButtonFramesForTesting["videoResolution.\(resolution.rawValue)"])
                    XCTAssertEqual(frame.width,70,accuracy:0.5); XCTAssertEqual(frame.height,32,accuracy:0.5)
                    XCTAssertTrue(panel.insetBy(dx:-1,dy:-1).contains(frame))
                }
                for rate in model.videoFrameRateOptions {
                    let frame = try XCTUnwrap(model.captureButtonFramesForTesting["videoRate.\(rate.rawValue)"])
                    XCTAssertEqual(frame.width,(width-32-40)/6,accuracy:0.5)
                    XCTAssertTrue(panel.insetBy(dx:-1,dy:-1).contains(frame))
                }
                print("VIDEO-SELECTION-LAYOUT focal=\(lens.displayZoom) available=\(width) panel=\(panel.size)")
                let a = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) })
                a.name = "Filtered-video-options-\(lens.displayZoom)-\(Int(width))"; a.lifetime = .keepAlways; add(a)
                layouts += 1
            }
        }
        host.rootView = AnyView(CameraView(model:model).environment(\.scenePhase,.active))
        try await Task.sleep(for:.milliseconds(400)); model.setCameraActive(true); try await settle()
        for ratio in VideoRatio.aspectOptions {
            model.selectVideoRatio(ratio); try await settle()
            for angle in [0.0,90.0] {
                host.rootView = AnyView(CameraView(model:model).environment(\.scenePhase,.active).environment(\.captureControlAngle,angle))
                try await Task.sleep(for:.milliseconds(250))
                let tools = try XCTUnwrap(model.captureButtonFramesForTesting["tools"])
                let mode = try XCTUnwrap(model.captureButtonFramesForTesting["mode"])
                for panel in [CameraToolbarPanel.videoFormat,.videoColor,.videoCodec,.videoRatio] {
                    model.toggleToolbarPanel(panel); try await Task.sleep(for:.milliseconds(250))
                    XCTAssertEqual(model.captureButtonFramesForTesting["tools"],tools)
                    XCTAssertEqual(model.captureButtonFramesForTesting["mode"],mode)
                    model.closePopups()
                }
                layouts += 1
            }
        }
        model.closePopups()
        // Rapid repeated changes followed by cancel/back must settle with the last selection.
        for _ in 0..<30 {
            model.selectVideoFrameRate(.fps30); model.selectVideoFrameRate(.fps60)
            model.toggleToolbarPanel(.videoFormat); model.closePopups()
        }
        try await settle(); XCTAssertNil(model.toolbarPanel)
        XCTAssertEqual(camera.videoSettings.frameRate,.fps60)
        model.setCameraActive(false); model.setCameraActive(true); try await settle()
        XCTAssertNil(model.toolbarPanel)
        runtime.finish()
        print("VIDEO-SELECTION stabilityRapidPairs=30 layoutCases=\(layouts) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) noPhotosWrites=true")
    }
}
