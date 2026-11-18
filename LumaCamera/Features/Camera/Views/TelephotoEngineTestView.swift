import AVFoundation
import SwiftUI

/// Runs the real star engines against the physical telephoto camera. Nothing is
/// written to Photos; the RAW/trails results stay in memory and the timed 4K
/// writer is finalized then deleted.
struct TelephotoEngineTestView: View {
    @StateObject private var photo = AstroPhotoEngine(deviceType: .builtInTelephotoCamera)
    @StateObject private var trails = AstroTrailsEngine(deviceType: .builtInTelephotoCamera)
    @StateObject private var timelapse = AstroTimelapseEngine(deviceType: .builtInTelephotoCamera)

    @State private var busy = false
    @State private var current = "准备"
    @State private var results: [String: String] = [:]
    @State private var cancelled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("使用物理 4 倍长焦实际运行三种星空引擎，不读取格式表。")
                    .font(.footnote).foregroundStyle(.secondary)

                testRow("星空照片 RAW 多帧", status: photo.status, result: results["photo"]) { run(.photo) }
                testRow("星轨多帧融合", status: trails.status, result: results["trails"]) { run(.trails) }
                testRow("星空延时 4K", status: timelapse.status, result: results["timelapse"]) { run(.timelapse) }

                Button("依次测试三项") { runAll() }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent).disabled(busy)

                Text(current).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("长焦星空实测")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { cancelled = true; stopAll() }
    }

    private func testRow(_ title: String, status: String, result: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("测试", action: action).buttonStyle(.bordered).disabled(busy)
            }
            Text(status).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let result {
                Text(result).font(.caption.weight(.semibold))
                    .foregroundStyle(result.contains("失败") ? .red : AppTheme.accent)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private enum Mode { case photo, trails, timelapse }
    private func run(_ mode: Mode) {
        guard !busy else { return }
        cancelled = false
        Task { @MainActor in await perform(mode) }
    }

    private func runAll() {
        guard !busy else { return }
        cancelled = false
        Task { @MainActor in
            await perform(.photo)
            guard !cancelled else { return }
            await perform(.trails)
            guard !cancelled else { return }
            await perform(.timelapse)
        }
    }

    @MainActor private func perform(_ mode: Mode) async {
        guard AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil else {
            current = "没有物理长焦镜头，已取消测试"
            return
        }
        busy = true
        current = "准备长焦会话"
        stopAll()
        defer { stopAll(); busy = false }
        switch mode {
        case .photo:
            photo.start()
            guard await wait({ photo.session.isRunning }, timeout: 8) else { results["photo"] = "失败：长焦会话未启动"; return }
            photo.frameCount = 3
            photo.manualSettings.fusionExposureSeconds = 1
            photo.begin()
            guard await wait({ !photo.isCapturing && (photo.result != nil || photo.error != nil) }, timeout: 30) else { results["photo"] = "失败：RAW 采集超时"; return }
            if let result = photo.result {
                results["photo"] = "通过：\(Int(result.size.width * result.scale))×\(Int(result.size.height * result.scale))"
            } else { results["photo"] = "失败：\(photo.error ?? photo.status)" }
        case .trails:
            trails.start()
            guard await wait({ trails.session.isRunning }, timeout: 8) else { results["trails"] = "失败：长焦会话未启动"; return }
            trails.manualSettings.fusionExposureSeconds = 3
            trails.captureDurationSeconds = 3
            trails.autoSaveOnFinish = false
            trails.begin()
            guard await wait({ !trails.isCapturing && (trails.result != nil || trails.error != nil) }, timeout: 30) else { results["trails"] = "失败：融合采集超时"; return }
            if let result = trails.result {
                results["trails"] = "通过：3 秒融合 · \(Int(result.size.width * result.scale))×\(Int(result.size.height * result.scale))"
            } else { results["trails"] = "失败：\(trails.error ?? trails.status)" }
        case .timelapse:
            timelapse.start()
            guard await wait({ timelapse.session.isRunning }, timeout: 8) else { results["timelapse"] = "失败：长焦会话未启动"; return }
            timelapse.manualSettings.fusionExposureSeconds = 1
            timelapse.intervalSeconds = 1
            timelapse.begin()
            guard await wait({ timelapse.capturedFrames >= 2 || timelapse.error != nil }, timeout: 30) else { results["timelapse"] = "失败：4K 采帧超时"; return }
            if timelapse.error != nil { results["timelapse"] = "失败：\(timelapse.error!)"; return }
            timelapse.finishVerification()
            _ = await wait({ !timelapse.isFinishing }, timeout: 15)
            results["timelapse"] = timelapse.error == nil ? "通过：4K 2 帧封装" : "失败：\(timelapse.error!)"
        }
        current = "完成"
    }

    @MainActor private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }

    private func stopAll() {
        photo.stop()
        trails.stop()
        timelapse.stop()
    }
}
