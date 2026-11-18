#if DEBUG
import AVFoundation
import SwiftUI

@MainActor
enum UltraWideStarSelfTest {
    static func run(model: CameraViewModel) async {
        guard ProcessInfo.processInfo.arguments.contains("--uw-star-self-test") else { return }
        guard AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil else {
            print("UW-SELF no ultra-wide device"); return
        }
        print("UW-SELF started")
        model.setCameraActive(false)
        try? await Task.sleep(for: .milliseconds(600))

        let photo = AstroPhotoEngine(deviceType: .builtInUltraWideCamera)
        photo.start()
        _ = await wait { photo.session.isRunning }
        photo.frameCount = 3
        photo.begin()
        _ = await wait { !photo.isCapturing && (photo.result != nil || photo.error != nil) }
        if let result = photo.result {
            print("UW-SELF photo \(Int(result.size.width * result.scale))x\(Int(result.size.height * result.scale))")
        } else { print("UW-SELF photo failed \(photo.error ?? photo.status)") }
        photo.stop()
        try? await Task.sleep(for: .milliseconds(500))

        let trails = AstroTrailsEngine(deviceType: .builtInUltraWideCamera)
        trails.start()
        _ = await wait { trails.session.isRunning }
        trails.captureDurationSeconds = 3
        trails.autoSaveOnFinish = false
        trails.begin()
        _ = await wait { !trails.isCapturing && (trails.result != nil || trails.error != nil) }
        if let result = trails.result {
            print("UW-SELF trails \(Int(result.size.width * result.scale))x\(Int(result.size.height * result.scale))")
        } else { print("UW-SELF trails failed \(trails.error ?? trails.status)") }
        trails.stop()
        try? await Task.sleep(for: .milliseconds(500))

        let timelapse = AstroTimelapseEngine(deviceType: .builtInUltraWideCamera)
        timelapse.start()
        _ = await wait { timelapse.session.isRunning }
        timelapse.intervalSeconds = 5
        timelapse.durationMinutes = nil
        timelapse.begin()
        _ = await wait { timelapse.capturedFrames >= 2 || timelapse.error != nil }
        timelapse.finishVerification()
        _ = await wait { !timelapse.isFinishing }
        print("UW-SELF timelapse frames=\(timelapse.capturedFrames) status=\(timelapse.status) error=\(timelapse.error ?? "none")")
        timelapse.stop()
        print("UW-SELF done")
    }

    private static func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }
}
#endif
