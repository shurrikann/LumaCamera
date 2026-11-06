import AVFoundation
import Combine

/// Uses Apple's camera-storage discovery; arbitrary file-provider folders do not
/// qualify as RAW capture destinations. No access prompt without a connected disk.
final class ExternalVideoStorage: ObservableObject {
    /// 在写入期间持有 AVFoundation 提供的安全作用域，并在完成文件后、通知界面前释放。
    final class RecordingAccess {
        private let lock = NSLock()
        private var active = true
        private let stopHandler: () -> Void

        init(stopHandler: @escaping () -> Void) {
            self.stopHandler = stopHandler
        }

        convenience init?(url: URL) {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            self.init(stopHandler: { url.stopAccessingSecurityScopedResource() })
        }

        func stop() {
            lock.lock()
            let shouldStop = active
            active = false
            lock.unlock()
            if shouldStop { stopHandler() }
        }

        deinit { stop() }
    }

    struct RecordingDestination {
        let url: URL
        let access: RecordingAccess
    }

    struct CapacitySnapshot: Equatable {
        let freeBytes: Int64
        let totalBytes: Int64
    }

    static let shared = ExternalVideoStorage()
    @Published private(set) var available = false
    private let discovery = AVExternalStorageDeviceDiscoverySession.shared
    private var observation: NSKeyValueObservation?
    private var requesting = false

    private init() {
        observation = discovery?.observe(\.externalStorageDevices, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private static func suitable(_ device: AVExternalStorageDevice) -> Bool {
        let recommended: Bool
        if #available(iOS 27, *) { recommended = device.reasonsNotRecommendedForCaptureUse.isEmpty }
        else { recommended = !device.isNotRecommendedForCaptureUse }
        return eligible(connected: device.isConnected, freeBytes: device.freeSize, recommended: recommended)
    }

    static func eligible(connected: Bool, freeBytes: Int, recommended: Bool) -> Bool {
        connected && freeBytes > 2_000_000_000 && recommended
    }

    var isEligibleNow: Bool {
        AVExternalStorageDevice.authorizationStatus == .authorized && discovery?.externalStorageDevices.contains(where: Self.suitable) == true
    }

    /// Reads the authorized capture drive's real free and total space for the recording HUD.
    var capacitySnapshot: CapacitySnapshot? {
        guard AVExternalStorageDevice.authorizationStatus == .authorized,
              let device = discovery?.externalStorageDevices.first(where: Self.suitable),
              device.freeSize > 0, device.totalSize > 0 else { return nil }
        return CapacitySnapshot(freeBytes: Int64(device.freeSize), totalBytes: Int64(device.totalSize))
    }

    func refresh() {
        let suitable = discovery?.externalStorageDevices.contains(where: Self.suitable) == true
        available = suitable && AVExternalStorageDevice.authorizationStatus == .authorized
        if suitable, AVExternalStorageDevice.authorizationStatus == .notDetermined, !requesting {
            requesting = true
            AVExternalStorageDevice.requestAccess { [weak self] _ in
                DispatchQueue.main.async { self?.requesting = false; self?.refresh() }
            }
        }
    }

    func openDestination() throws -> RecordingDestination {
        guard AVExternalStorageDevice.authorizationStatus == .authorized,
              let device = discovery?.externalStorageDevices.first(where: Self.suitable),
              let url = try device.nextAvailableURLs(withPathExtensions: ["mov"]).first,
              let access = RecordingAccess(url: url) else {
            throw MovieRecorder.RecorderError.cannotStart("请连接已授权且符合拍摄要求的外接存储。")
        }
        return RecordingDestination(url: url, access: access)
    }
}
