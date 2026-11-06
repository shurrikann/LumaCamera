import Combine
import Foundation

#if canImport(DockKit)
import DockKit

/// Controls Apple's system tracking on a connected DockKit-compatible stand.
/// Subject detection and motion vectors are handled by DockKit; the app doesn't
/// run a parallel vision loop or the accessory vendor's private tracking SDK.
/// 通过系统 DockKit 管理兼容云台；主体识别与运动控制由系统完成。
@MainActor
final class DockKitTrackingController: ObservableObject {
    @Published private(set) var accessoryConnected = false
    @Published private(set) var trackingEnabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let manager = DockAccessoryManager.shared
    private var accessory: DockAccessory?
    private var stateTask: Task<Void, Never>?
    private var accessoryCommandTask: Task<Void, Never>?
    private var pendingTrackingRequest: (enabled: Bool, reportFailure: Bool)?

    func startMonitoring() {
        guard stateTask == nil else { return }
        trackingEnabled = manager.isSystemTrackingEnabled
        stateTask = Task { @MainActor [weak self] in
            do {
                let stateChanges = try DockAccessoryManager.shared.accessoryStateChanges
                for await change in stateChanges {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    let connected = change.state == .docked && change.accessory != nil
                    self.accessoryConnected = connected
                    self.accessory = connected ? change.accessory : nil
                    self.trackingEnabled = self.manager.isSystemTrackingEnabled
                    if !connected, self.trackingEnabled {
                        await self.applyTracking(false, reportFailure: false)
                    }
                }
            } catch {
                // Accessory discovery is opportunistic. A missing accessory or a
                // temporarily unavailable stream should not interrupt camera use.
                guard let self, !Task.isCancelled else { return }
                self.accessoryConnected = false
            }
        }
    }

    func toggleTracking() {
        setTrackingEnabled(!trackingEnabled, reportFailure: true)
    }

    func stopTracking() {
        setTrackingEnabled(false)
    }

    /// Use DockKit's public subject-selection API after a user taps the live preview.
    func selectSubject(at unitPoint: CGPoint) {
        guard trackingEnabled, accessory != nil,
              unitPoint.x.isFinite, unitPoint.y.isFinite,
              (0...1).contains(unitPoint.x), (0...1).contains(unitPoint.y) else { return }
        enqueueAccessoryCommand { accessory in
            // 清除前一个框选区域，再按官方 API 选择用户点中的检测主体。
            try await accessory.setRegionOfInterest(CGRect(x: 0, y: 0, width: 1, height: 1))
            try await accessory.selectSubject(at: unitPoint)
        } onFailure: { "无法选择该位置的追踪主体：\($0.localizedDescription)" }
    }

    /// Limit DockKit's search to the normalized rectangle drawn by the user.
    func setRegionOfInterest(_ unitRect: CGRect) {
        guard trackingEnabled, accessory != nil,
              unitRect.origin.x.isFinite, unitRect.origin.y.isFinite,
              unitRect.width.isFinite, unitRect.height.isFinite,
              unitRect.minX >= 0, unitRect.minY >= 0,
              unitRect.maxX <= 1, unitRect.maxY <= 1,
              unitRect.width > 0, unitRect.height > 0 else { return }
        enqueueAccessoryCommand { accessory in
            try await accessory.setRegionOfInterest(unitRect)
        } onFailure: { "无法设置云台追踪区域：\($0.localizedDescription)" }
    }

    /// Serialize tap and ROI requests so fast gestures cannot reorder DockKit commands.
    private func enqueueAccessoryCommand(_ command: @escaping (DockAccessory) async throws -> Void,
                                         onFailure: @escaping (Error) -> String) {
        guard let accessory else { return }
        let previous = accessoryCommandTask
        accessoryCommandTask = Task { @MainActor [weak self, accessory] in
            await previous?.value
            do {
                try await command(accessory)
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = onFailure(error)
            }
        }
    }

    func setTrackingEnabled(_ enabled: Bool, reportFailure: Bool = false) {
        if isUpdating {
            pendingTrackingRequest = (enabled, reportFailure)
            return
        }
        guard trackingEnabled != enabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyTracking(enabled, reportFailure: reportFailure)
        }
    }

    private func applyTracking(_ enabled: Bool, reportFailure: Bool) async {
        if isUpdating {
            pendingTrackingRequest = (enabled, reportFailure)
            return
        }
        isUpdating = true
        do {
            try await manager.setSystemTrackingEnabled(enabled)
            trackingEnabled = manager.isSystemTrackingEnabled
            errorMessage = nil
        } catch {
            if reportFailure { errorMessage = error.localizedDescription }
            trackingEnabled = manager.isSystemTrackingEnabled
        }
        isUpdating = false
        if let pending = pendingTrackingRequest {
            pendingTrackingRequest = nil
            await applyTracking(pending.enabled, reportFailure: pending.reportFailure)
        }
    }
}

#else
/// 模拟器 SDK 不包含 DockKit 时使用的空实现。
/// 真机仍编译上方官方 DockKit 实现；模拟器只验证其余相机逻辑。
@MainActor
final class DockKitTrackingController: ObservableObject {
    @Published private(set) var accessoryConnected = false
    @Published private(set) var trackingEnabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    func startMonitoring() {}
    func toggleTracking() {}
    func stopTracking() { trackingEnabled = false }
    func selectSubject(at unitPoint: CGPoint) {}
    func setRegionOfInterest(_ unitRect: CGRect) {}
    func setTrackingEnabled(_ enabled: Bool, reportFailure: Bool = false) {
        // DockKit 在模拟器不可用，不能伪装成追踪已启用。
        trackingEnabled = false
        isUpdating = false
        errorMessage = nil
    }
}
#endif

/// Converts points drawn over the aspect-fill preview to DockKit's normalized video-frame coordinates.
/// 将预览上的点和框换算到 DockKit 要求的完整视频画面 0…1 坐标。
enum DockKitPreviewMapping {
    static func unitPoint(_ point: CGPoint, surfaceSize: CGSize, sourceImageSize: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, surfaceSize.width > 0, surfaceSize.height > 0,
              sourceImageSize.width > 0, sourceImageSize.height > 0 else { return nil }
        let visible = visibleUnitRect(surfaceSize: surfaceSize, sourceImageSize: sourceImageSize)
        let viewPoint = CGPoint(x: min(max(point.x / surfaceSize.width, 0), 1),
                                y: min(max(point.y / surfaceSize.height, 0), 1))
        // Aspect-fill crops the source; screen edges therefore map to the visible
        // source sub-rectangle rather than the full, off-screen image coordinates.
        return CGPoint(x: visible.minX + viewPoint.x * visible.width,
                       y: visible.minY + viewPoint.y * visible.height)
    }

    static func unitRect(_ rect: CGRect, surfaceSize: CGSize, sourceImageSize: CGSize) -> CGRect? {
        guard rect.width > 0, rect.height > 0,
              let topLeft = unitPoint(rect.origin, surfaceSize: surfaceSize, sourceImageSize: sourceImageSize),
              let bottomRight = unitPoint(CGPoint(x: rect.maxX, y: rect.maxY), surfaceSize: surfaceSize, sourceImageSize: sourceImageSize) else { return nil }
        return CGRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                      width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y))
    }

    private static func visibleUnitRect(surfaceSize: CGSize, sourceImageSize: CGSize) -> CGRect {
        let surfaceAspect = surfaceSize.width / surfaceSize.height
        let sourceAspect = sourceImageSize.width / sourceImageSize.height
        if sourceAspect > surfaceAspect {
            let visibleWidth = surfaceAspect / sourceAspect
            return CGRect(x: (1 - visibleWidth) / 2, y: 0, width: visibleWidth, height: 1)
        }
        let visibleHeight = sourceAspect / surfaceAspect
        return CGRect(x: 0, y: (1 - visibleHeight) / 2, width: 1, height: visibleHeight)
    }
}
