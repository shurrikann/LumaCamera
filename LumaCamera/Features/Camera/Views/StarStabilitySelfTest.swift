#if DEBUG
import AVFoundation
import SwiftUI

@MainActor
enum StarStabilitySelfTest {
    static func run(model: CameraViewModel) async {
        guard ProcessInfo.processInfo.arguments.contains("--star-stability-test") else { return }
        print("STABILITY start footprint=\(footprintMB())MB")
        model.setCameraActive(false)
        try? await Task.sleep(for: .milliseconds(700))
        var passed = 0, failed = 0
        func record(_ name: String, _ ok: Bool, _ started: Date) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("STABILITY \(name) \(ok ? "PASS" : "FAIL") \(ms)ms footprint=\(footprintMB())MB")
            if ok { passed += 1 } else { failed += 1 }
        }

        let photo = AstroPhotoEngine()
        photo.start()
        _ = await wait { photo.session.isRunning }
        for index in 1...3 {
            let started = Date()
            photo.frameCount = 3
            photo.manualSettings.isoAutomatic = index == 3
            photo.manualSettings.exposureBiasAutomatic = index == 3
            photo.begin()
            _ = await wait { !photo.isCapturing && (photo.result != nil || photo.error != nil) }
            record("photo-run-\(index)", photo.result != nil && photo.error == nil, started)
            try? await Task.sleep(for: .milliseconds(350))
        }

        let startedCancel = Date()
        photo.frameCount = 60
        photo.begin()
        try? await Task.sleep(for: .milliseconds(700))
        photo.cancel()
        let cancelled = await wait { !photo.isCapturing }
        let startedRetry = Date()
        photo.frameCount = 3
        photo.begin()
        _ = await wait { !photo.isCapturing && (photo.result != nil || photo.error != nil) }
        record("photo-cancel-and-retry", cancelled && photo.result != nil && photo.error == nil, startedCancel)
        print("STABILITY photo-retry \(photo.result != nil ? "PASS" : "FAIL") \(Int(Date().timeIntervalSince(startedRetry) * 1000))ms")
        photo.stop()
        try? await Task.sleep(for: .milliseconds(500))

        let trails = AstroTrailsEngine()
        trails.start()
        _ = await wait { trails.session.isRunning }
        for index in 1...2 {
            let started = Date()
            trails.captureDurationSeconds = 2
            trails.autoSaveOnFinish = false
            trails.begin()
            _ = await wait { !trails.isCapturing && (trails.result != nil || trails.error != nil) }
            record("trails-run-\(index)", trails.result != nil && trails.error == nil, started)
            try? await Task.sleep(for: .milliseconds(350))
        }
        trails.stop()
        try? await Task.sleep(for: .milliseconds(500))

        let timelapse = AstroTimelapseEngine()
        timelapse.start()
        _ = await wait { timelapse.session.isRunning }
        for index in 1...3 {
            let started = Date()
            timelapse.intervalSeconds = 5
            timelapse.durationMinutes = nil
            timelapse.begin()
            _ = await wait { timelapse.capturedFrames >= 2 || timelapse.error != nil }
            let ok = timelapse.error == nil && timelapse.capturedFrames >= 2
            timelapse.finishVerification()
            _ = await wait { !timelapse.isFinishing }
            record("timelapse-run-\(index)", ok && timelapse.error == nil, started)
            try? await Task.sleep(for: .milliseconds(350))
        }
        timelapse.stop()
        try? await Task.sleep(for: .milliseconds(500))

        let switcher = AstroPhotoEngine()
        switcher.start()
        _ = await wait { switcher.session.isRunning }
        let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil
        let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if ultra { types.append(.builtInUltraWideCamera) }
        if tele { types.append(.builtInTelephotoCamera) }
        if ultra { types.append(.builtInUltraWideCamera) }
        types.append(.builtInWideAngleCamera)
        for (index, type) in types.enumerated() {
            let started = Date()
            switcher.switchLens(to: type)
            let ok = await wait(timeout: 10) {
                switcher.session.isRunning && switcher.activeDeviceType == type
            }
            record("lens-switch-\(index)-\(type.rawValue)", ok, started)
            try? await Task.sleep(for: .milliseconds(250))
        }
        switcher.stop()
        try? await Task.sleep(for: .milliseconds(500))

        print("STABILITY SUMMARY passed=\(passed) failed=\(failed) footprint=\(footprintMB())MB")
        print("STABILITY done")
    }

    private static func wait(timeout: TimeInterval = 25, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }

    private static func footprintMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
#endif
