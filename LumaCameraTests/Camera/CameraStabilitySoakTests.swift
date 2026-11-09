import AVFoundation
import UIKit
import XCTest
@testable import LumaCamera

final class CameraStabilitySoakTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testPhotoVideoFrontTrackingDualLifecycleSoak() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label:String, timeout:Double=25, _ predicate:()->Bool) async throws {
            let end=CACurrentMediaTime()+timeout
            while CACurrentMediaTime()<end { if predicate(){return}; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" message="+(camera.message ?? "nil")+" kind=\(model.captureKind)"); throw CancellationError()
        }
        func photoReady() async throws {
            try await wait("照片路线") { camera.ready && model.captureKind == .photo && !camera.videoConfiguring && !model.captureKindSwitching }
        }
        func videoReady() async throws {
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"视频路线",timeout:25)
        }
        model.setCameraActive(true)
        try await wait("启动") { camera.ready }
        model.setCaptureKind(.photo)
        try await photoReady()

        for cycle in 0..<12 {
            let began = CACurrentMediaTime()
            model.setCaptureKind(.video)
            try await videoReady()
            model.selectVideoRatio(cycle.isMultiple(of: 2) ? .ratio4x3 : .ratio16x9)
            try await wait("视频比例") { camera.ready && !camera.videoConfiguring }
            if model.currentPosition == .front { model.flipCamera(); try await wait("后置") { camera.ready && model.currentPosition == .back } }
            if cycle.isMultiple(of: 2) {
                if model.currentPosition != .front { model.flipCamera(); try await wait("前置") { camera.ready && model.currentPosition == .front } }
                model.toggleFrontVideoCentering()
                try await wait("追踪开") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
                model.toggleFrontVideoCentering()
                try await wait("追踪关") { !camera.frontVideoCenteringEnabled && !camera.frontVideoCenteringPreparing }
            }
            model.setCaptureKind(.photo)
            try await photoReady()
            if cycle.isMultiple(of: 2) {
                model.setCaptureKind(.video)
                try await videoReady()
                model.toggleDualCapture()
                try await wait("双拍") { camera.dualCaptureEnabled && !camera.dualCapturePreparing }
                if !camera.dualCaptureMainIsFront {
                    model.swapDualCaptureCameras()
                    try await wait("前置主画面") { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
                }
                try await wait("双拍就绪") { camera.ready && !camera.videoConfiguring && !camera.dualCapturePreparing }
                model.toggleFrontVideoCentering()
                try await wait("双拍追踪") { camera.frontVideoCenteringActive && !camera.frontVideoCenteringPreparing }
                model.swapDualCaptureCameras()
                try await wait("小窗") { !camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
                model.swapDualCaptureCameras()
                try await wait("主画面") { camera.dualCaptureMainIsFront && !camera.dualCapturePreparing }
                model.toggleDualCapture()
                try await wait("退双拍") { !camera.dualCaptureEnabled && !camera.dualCapturePreparing && camera.ready }
                model.setCaptureKind(.photo)
                try await photoReady()
            }
            if cycle.isMultiple(of: 3) {
                model.setCameraActive(false)
                try await wait("停止") { !camera.ready }
                try await Task.sleep(for: .milliseconds(350))
                model.setCameraActive(true)
                try await wait("恢复") { camera.ready }
            }
            XCTAssertNil(camera.message, "cycle \(cycle) 不应报错")
            print("CAMERA-SOAK cycle=\(cycle) seconds=\(CACurrentMediaTime()-began) kind=\(model.captureKind) front=\(model.currentPosition == .front) dual=\(camera.dualCaptureEnabled)")
        }
    }
    #endif
}
