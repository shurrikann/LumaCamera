import XCTest
import Combine
import UIKit
@testable import LumaCamera

final class ManualPinnedZoomPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testEveryManualPresetKeepsItsPhysicalCameraAndExposureAcrossWheelRange() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setMode(.auto); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        model.setMode(.manual)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        model.manualExposure = true; model.iso = 400; model.shutter = log2(1.0 / 125); model.applyExposure()
        var frames = 0
        let token = camera.$preview.dropFirst().sink { if $0 != nil { frames += 1 } }; defer { token.cancel() }
        for anchor in [CGFloat(0.5),1,2,4,8] {
            let lens = try XCTUnwrap(camera.lenses.first(where: { $0.device.position == .back && abs($0.displayZoom-anchor) < 0.01 }))
            model.selectFocalLength(lens)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            // AVFoundation publishes custom mode before the exposure duration/ISO settle on a newly attached sensor.
            for _ in 0..<100 {
                let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
                if let state, abs(Double(state.iso)-model.iso) < 5, abs(state.seconds-pow(2,model.shutter)) < 0.001 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let settled = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
            XCTAssertEqual(Double(try XCTUnwrap(settled).iso), model.iso, accuracy: 5)
            let range = camera.continuousZoomRange
            XCTAssertEqual(range.lowerBound, anchor, accuracy: 0.01)
            XCTAssertEqual(range.upperBound, anchor * 5, accuracy: 0.01)
            for _ in 0..<2 {
                for value in [range.lowerBound, range.upperBound, (range.lowerBound + range.upperBound)/2, range.lowerBound] {
                    camera.setContinuousZoom(value)
                    try await Task.sleep(for: .milliseconds(60))
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
                    let actual = try XCTUnwrap(state)
                    XCTAssertEqual(actual.deviceID, lens.device.uniqueID, "Preset \(anchor) must never switch physical camera")
                    XCTAssertEqual(camera.selectedLens, lens.id, "Crossing a native mark must not select a different preset")
                    XCTAssertEqual(actual.physicalZoomFactor, value / (lens.displayZoom / lens.zoomFactor), accuracy: 0.01)
                    XCTAssertEqual(camera.currentZoom, value, accuracy: 0.01)
                    XCTAssertEqual(actual.exposureMode, .custom)
                    XCTAssertEqual(camera.continuousZoomRange, range)
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            let finalState = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
            XCTAssertEqual(Double(try XCTUnwrap(finalState).iso), model.iso, accuracy: 5)
            XCTAssertEqual(try XCTUnwrap(finalState).seconds, pow(2, model.shutter), accuracy: 0.001)
            print("M-PINNED-ZOOM anchor=\(anchor) range=\(range) device=\(lens.device.deviceType.rawValue)")
        }
        XCTAssertGreaterThan(frames, 20); XCTAssertTrue(camera.ready)
        model.setMode(.auto)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        XCTAssertLessThanOrEqual(camera.continuousZoomRange.lowerBound, 0.5)
    }
    @MainActor func testRapidWheelReversalsKeepFramesMovingAndApplyFinalValueForEveryPreset() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let camera = model.camera
        let oldMode = model.mode
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.endZoomDial(); model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        model.setMode(.manual)
        var frames = 0
        let token = camera.$preview.dropFirst().compactMap { $0 }.sink { _ in frames += 1 }
        defer { token.cancel() }
        for anchor in [CGFloat(0.5), 1, 2, 4, 8] {
            let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-anchor) < 0.01 })
            model.selectFocalLength(lens)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for: .milliseconds(250))
            model.beginZoomDial(at: anchor)
            let before = frames
            for index in 0..<180 {
                let translation = -CGFloat(180) * sin(CGFloat(index) * .pi / 60)
                model.dragZoomDial(translation: translation, width: 360)
                try await Task.sleep(for: .milliseconds(4))
            }
            model.finishZoomDrag()
            let expected = camera.currentZoom
            try await Task.sleep(for: .milliseconds(300))
            let state = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
            XCTAssertEqual(try XCTUnwrap(state).deviceID, lens.device.uniqueID)
            XCTAssertEqual(try XCTUnwrap(state).physicalZoomFactor, expected / (lens.displayZoom / lens.zoomFactor), accuracy: 0.01)
            XCTAssertGreaterThan(frames-before, 3, "Rapid input must not starve preview at preset \(anchor)")
            XCTAssertEqual(camera.selectedLens, lens.id)
            XCTAssertTrue(camera.ready)
            model.endZoomDial()
            print("M-RAPID-ZOOM anchor=\(anchor) events=180 frames=\(frames-before) final=\(expected)")
        }
    }
    #endif
}
