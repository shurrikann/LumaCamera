import XCTest
import SwiftUI
import UIKit
import AVFoundation
@testable import LumaCamera

@MainActor final class VideoApertureEntryPhysicalTests: XCTestCase {
    func testVideoVerticalEntryLayoutHoldAutoHideRecordingAndExit() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // 复用真实App相机树；另建共享model的完整CameraView会互相触发离页停机。
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow && !$0.isHidden })
        let callback = camera.onVideoRecorded
        var result: Result<URL, Error>?
        camera.onVideoRecorded = { result = $0 }
        defer {
            camera.onVideoRecorded = callback; model.dismissDepthControls(); model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; audit.finish()
            if case let .success(url)? = result { try? FileManager.default.removeItem(at: url) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("相机") { camera.ready }
        model.setCaptureKind(.video); try await wait("视频") { camera.ready && !camera.videoConfiguring }
        model.toggleVirtualAperture()
        try await wait("虚拟光圈") { model.virtualApertureEnabled && camera.ready && !model.isPreparingSubmode }
        var toggleDurations = [Double]()
        for ratio in VideoRatio.aspectOptions {
            model.selectVideoRatio(ratio)
            try await wait("比例") { camera.ready && !camera.videoConfiguring }
            try await wait("入口布局") { model.captureButtonFramesForTesting["videoVirtualApertureButton"] != nil }
            let before = try XCTUnwrap(model.captureButtonFramesForTesting["videoVirtualApertureButton"])
            let began = CACurrentMediaTime()
            model.toggleVirtualApertureSlider()
            XCTAssertTrue(model.virtualApertureSliderVisible, "视频模式必须允许展开")
            try await wait("竖向滑块") { model.captureButtonFramesForTesting["videoVirtualApertureSlider"] != nil }
            toggleDurations.append(CACurrentMediaTime() - began)
            try await Task.sleep(for: .milliseconds(250))
            let slider = try XCTUnwrap(model.captureButtonFramesForTesting["videoVirtualApertureSlider"])
            let button = try XCTUnwrap(model.captureButtonFramesForTesting["videoVirtualApertureButton"])
            XCTAssertGreaterThan(slider.height, slider.width)
            XCTAssertLessThan(slider.maxY, button.minY)
            XCTAssertEqual(before.midY, button.midY, accuracy: 1)
            XCTAssertEqual(before.midX, button.midX, accuracy: 1)
            XCTAssertNotNil(window.hitTest(CGPoint(x: button.midX, y: button.midY), with: nil))
            model.toggleVirtualApertureSlider(); XCTAssertFalse(model.virtualApertureSliderVisible)
        }
        model.toggleVirtualApertureSlider(); model.setDepthControlEditing(true)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertTrue(model.virtualApertureSliderVisible, "持续持有超过3秒不收起")
        for step in 0..<60 { model.virtualAperturePosition = Double(step) / 59 }
        model.setDepthControlEditing(false)
        try await Task.sleep(for: .milliseconds(1800)); model.noteSliderInteraction()
        try await Task.sleep(for: .milliseconds(1800)); XCTAssertTrue(model.virtualApertureSliderVisible)
        try await wait("空闲自动关闭") { !model.virtualApertureSliderVisible }
        for _ in 0..<10 { model.toggleVirtualApertureSlider(); model.dismissDepthControls() }
        model.toggleVideoRecording(); try await wait("录制") { camera.videoRecording }
        model.toggleVirtualApertureSlider(); XCTAssertTrue(model.virtualApertureSliderVisible)
        model.virtualAperturePosition = 0.4
        try await Task.sleep(for: .milliseconds(500))
        camera.stopVideoRecording(); try await wait("停止") { result != nil && !camera.videoBusy }
        _ = try XCTUnwrap(result).get()
        model.setCaptureKind(.photo)
        try await wait("回退照片") { camera.ready && !camera.videoConfiguring }
        XCTAssertFalse(model.virtualApertureSliderVisible)
        print("VIDEO-APERTURE-ENTRY ratios=\(toggleDurations.count) maxOpenLayoutSeconds=\(toggleDurations.max() ?? -1) rapidToggles=10 parameterUpdates=60 hold=3.2 idleReset=true recording=true")
    }
}
