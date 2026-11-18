#if DEBUG
@preconcurrency import AVFoundation
import SwiftUI

/// Starts a real 4x telephoto session and checks the three star-engine formats.
struct TelephotoVerificationView: View {
    @StateObject private var verifier = TelephotoStarVerifier()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TelephotoPreview(session: verifier.session)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
                    .overlay(alignment: .topLeading) {
                        Text("4x TELE")
                            .font(.caption2.weight(.bold)).padding(6)
                            .background(.black.opacity(0.55), in: Capsule()).padding(8)
                    }

                Text(verifier.status).font(.footnote).foregroundStyle(.secondary)

                ForEach(verifier.checks) { check in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(check.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(check.supported ? "支持" : "不支持")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(check.supported ? AppTheme.accent : .red)
                        }
                        Text(check.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }

                Button("重新检测") { verifier.start() }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
            }
            .padding(16)
        }
        .navigationTitle("验证 4 倍长焦")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { verifier.start() }
        .onDisappear { verifier.stop() }
    }
}

@MainActor
final class TelephotoStarVerifier: ObservableObject {
    struct Check: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let supported: Bool
    }

    // Immutable route handles; configuration remains on the dedicated queue.
    nonisolated(unsafe) let session = AVCaptureSession()
    @Published private(set) var status = "准备长焦会话"
    @Published private(set) var checks: [Check] = []
    private let queue = DispatchQueue(label: "telephoto.star.verify", qos: .userInitiated)
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated private let deviceSlot = LockedCaptureValue<AVCaptureDevice?>(nil)
    nonisolated private var device: AVCaptureDevice? {
        get { deviceSlot.value }
        set { deviceSlot.value = newValue }
    }
    nonisolated private let runningSlot = LockedCaptureValue<Bool>(false)
    nonisolated private var running: Bool {
        get { runningSlot.value }
        set { runningSlot.value = newValue }
    }
    nonisolated private let rawDelegateSlot = LockedCaptureValue<TelephotoRawDelegate?>(nil)
    nonisolated private var rawDelegate: TelephotoRawDelegate? {
        get { rawDelegateSlot.value }
        set { rawDelegateSlot.value = newValue }
    }
    nonisolated private let latestChecksSlot = LockedCaptureValue<[Check]>([])
    nonisolated private var latestChecks: [Check] {
        get { latestChecksSlot.value }
        set { latestChecksSlot.value = newValue }
    }

    func start() {
        stop()
        checks = []
        status = "正在打开 4x 长焦"
        queue.async { [weak self] in
            guard let self else { return }
            let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            guard let tele else {
                DispatchQueue.main.async { self.status = "当前设备没有可用的长焦摄像头" }
                return
            }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                let input = try AVCaptureDeviceInput(device: tele)
                guard self.session.canAddInput(input) else { throw NSError(domain: "Telephoto", code: 1) }
                self.session.addInput(input)
                guard self.session.canAddOutput(self.photoOutput) else { throw NSError(domain: "Telephoto", code: 2) }
                self.session.addOutput(self.photoOutput)
                if let twelve = tele.formats.first(where: { format in
                    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return d.width == 4032 && d.height == 3024
                        && format.supportedMaxPhotoDimensions.contains { $0.width == 4032 && $0.height == 3024 }
                }) {
                    do {
                        try tele.lockForConfiguration()
                        tele.activeFormat = twelve
                        tele.unlockForConfiguration()
                    } catch {}
                    if let dim = twelve.supportedMaxPhotoDimensions.first(where: { $0.width == 4032 && $0.height == 3024 }) {
                        self.photoOutput.maxPhotoDimensions = dim
                    }
                }
                self.session.commitConfiguration()
                self.device = tele
                try tele.lockForConfiguration()
                let fourX = min(4, tele.maxAvailableVideoZoomFactor)
                tele.videoZoomFactor = fourX
                tele.unlockForConfiguration()
                self.session.startRunning()
                self.running = true
                // RAW pixel formats are published by the running output, not
                // synchronously by startRunning().
                self.queue.asyncAfter(deadline: .now() + 0.35) {
                    self.inspect(tele: tele, zoom: fourX)
                    self.captureRAW()
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "长焦启动失败：\(error.localizedDescription)" }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.running = false
        }
    }

    nonisolated private func inspect(tele: AVCaptureDevice, zoom: CGFloat) {
        let formats = tele.formats
        let twelve = formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width == 4032 && d.height == 3024
        }
        let twelveRAW = twelve.contains { $0.supportedMaxPhotoDimensions.contains { $0.width == 4032 && $0.height == 3024 } }
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let oneFPS = { (format: AVCaptureDevice.Format) in
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 1.001 && $0.maxFrameRate >= 1.001 }
        }
        let trails = twelve.contains { oneFPS($0) && CMTimeGetSeconds($0.maxExposureDuration) >= 0.999 }
        let fourK = formats.contains { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width == 3840 && d.height == 2160 && oneFPS(format) && CMTimeGetSeconds(format.maxExposureDuration) >= 0.999
        }
        let maxPhoto = twelve.compactMap { format in
            format.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }).map { "\($0.width)×\($0.height)" }
        }.first ?? "—"
        let result: [Check] = [
            Check(id: "device", title: "4x 长焦会话", detail: "\(tele.localizedName) · \(String(format: "%.1f", zoom))x · \(CMVideoFormatDescriptionGetDimensions(tele.activeFormat.formatDescription).width)×\(CMVideoFormatDescriptionGetDimensions(tele.activeFormat.formatDescription).height)", supported: zoom >= 3.9),
            Check(id: "photo", title: "星空照片：12MP RAW", detail: "12MP 格式 \(twelve.count) 个 · RAW \(rawTypes.count) 种 · 最大照片 \(maxPhoto)", supported: twelveRAW && !rawTypes.isEmpty),
            Check(id: "trails", title: "星轨：12MP 1fps × 1s", detail: trails ? "存在 12MP / 1fps / 1s 格式" : "缺少 12MP + 1fps + 1s 组合", supported: trails),
            Check(id: "timelapse", title: "星空延时：4K 1fps × 1s", detail: fourK ? "存在 3840×2160 / 1fps / 1s 格式" : "缺少 4K + 1fps + 1s 组合", supported: fourK)
        ]
        latestChecks = result
        DispatchQueue.main.async {
            self.status = "长焦会话运行中，正在实拍 RAW 验证"
            self.checks = result
        }
    }

    nonisolated private func captureRAW() {
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            updatePhotoCheck(detail: "没有可用的 RAW 像素格式", supported: false)
            return
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        settings.flashMode = .off
        settings.photoQualityPrioritization = .speed
        let delegate = TelephotoRawDelegate { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                let ok = width > 0 && height > 0
                self.updatePhotoCheck(detail: "实拍 RAW 成功 · \(width)×\(height) · \(data.count / 1024) KB", supported: ok)
            case .failure(let error):
                self.updatePhotoCheck(detail: "实拍 RAW 失败：\(error.localizedDescription)", supported: false)
            }
        }
        rawDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    nonisolated private func updatePhotoCheck(detail: String, supported: Bool) {
        var next = latestChecks
        if let index = next.firstIndex(where: { $0.id == "photo" }) {
            next[index] = Check(id: "photo", title: "星空照片：12MP RAW 实拍", detail: detail, supported: supported)
        }
        latestChecks = next
        DispatchQueue.main.async {
            self.checks = next
            self.status = supported ? "长焦 RAW 实拍验证通过" : "长焦 RAW 实拍验证失败"
        }
    }
}

private final class TelephotoRawDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(NSError(domain: "TelephotoRAW", code: 1)))
            return
        }
        completion(.success(data))
    }
}

private struct TelephotoPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> View {
        let view = View()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }
    func updateUIView(_ uiView: View, context: Context) {
        uiView.previewLayer.session = session
    }
}

#endif
