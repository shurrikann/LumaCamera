import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

final class MainFocalPresetPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testRepeatedMainCameraTapsCycle24_28_35mmWithoutChangingAnchorOrFreezingFrames() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldMode = model.mode, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.001 })
        camera.selectLens(wide)
        for _ in 0..<150 { if camera.ready && abs(camera.currentZoom-1)<0.01 { break }; try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertEqual(model.focalButtonTitle(for:wide),"24mm")
        for index in 0..<6 {
            let previous = camera.preview
            model.selectFocalLength(wide)
            let expected: CGFloat = [28.0 / 24.0, 35.0 / 24.0, 1][index % 3]
            for _ in 0..<150 {
                if camera.ready, camera.selectedLens == wide.id, abs(camera.currentZoom-expected)<0.01,
                   camera.preview != nil, camera.preview !== previous { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertEqual(camera.currentZoom,expected,accuracy:0.01)
            XCTAssertEqual(model.focalButtonTitle(for:wide),["28mm", "35mm", "24mm"][index % 3])
            XCTAssertEqual(camera.selectedLens,wide.id)
            XCTAssertNotNil(camera.preview); XCTAssertTrue(camera.preview !== previous)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            XCTAssertTrue(try XCTUnwrap(state).virtual)
        }
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let physical = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
        XCTAssertFalse(try XCTUnwrap(physical).virtual)
    }

    @MainActor func testManualModeTapsCycle24_28_35mmWithoutLive() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldMode = model.mode, oldFormat = model.photoFormat, oldResolution = model.photoResolution
        let oldHDR = model.hdr, oldLive = model.livePhotoEnabled
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            if model.livePhotoEnabled != oldLive, model.livePhotoAvailable { model.toggleLivePhoto() }
            model.photoFormat = oldFormat; model.photoResolution = oldResolution; model.hdr = oldHDR
            model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.setMode(.manual); model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        camera.selectLens(wide)
        for _ in 0..<150 { if camera.ready && abs(camera.currentZoom-1)<0.01 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.livePhotoEnabled)
        XCTAssertEqual(model.focalButtonTitle(for:wide), "24mm")
        for index in 0..<6 {
            let expected: CGFloat = [28.0/24.0, 35.0/24.0, 1][index % 3]
            model.selectFocalLength(wide)
            for _ in 0..<200 {
                if camera.ready, camera.selectedLens == wide.id, abs(camera.currentZoom-expected)<0.01 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(camera.currentZoom, expected, accuracy: 0.01)
            XCTAssertEqual(model.focalButtonTitle(for:wide), ["28mm", "35mm", "24mm"][index % 3])
            XCTAssertEqual(camera.selectedLens, wide.id)
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0) } }
            XCTAssertFalse(try XCTUnwrap(state).virtual, "M 挡 24/28/35mm 不能切到虚拟多摄")
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        }
    }
    #endif
}
