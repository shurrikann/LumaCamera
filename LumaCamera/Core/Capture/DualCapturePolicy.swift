import AVFoundation
import CoreGraphics

/// 只开放2026-10-26真机录制/解码过的组合，再与当前设备公开格式求交集。
/// 高帧率只提高后置采集率，前置小窗最多30帧；不把单摄HDR/Log/RAW能力当作双拍支持。
enum DualCapturePolicy {
    static var validatedSettings: [VideoCaptureSettings] {
        var values: [VideoCaptureSettings] = []
        for resolution in VideoResolution.allCases {
            for rate in [VideoFrameRate.fps24, .fps25, .fps30] {
                values.append(VideoCaptureSettings(resolution: resolution, frameRate: rate))
            }
            if resolution != .uhd4K {
                for rate in [VideoFrameRate.fps50, .fps60] {
                    values.append(VideoCaptureSettings(resolution: resolution, frameRate: rate))
                }
            }
            values.append(VideoCaptureSettings(resolution: resolution, colorSpace: .p3))
        }
        for color in [VideoColorSpace.sdr, .p3] {
            values.append(VideoCaptureSettings(colorSpace: color, codec: .h264))
        }
        for specification in [ProResSpecification.proxy, .lt, .standard, .hq, .four4, .four4xq] {
            values.append(VideoCaptureSettings(codec: .proRes, proRes: specification))
        }
        values.append(VideoCaptureSettings(resolution: .uhd4K, codec: .proRes, proRes: .hq))
        return values
    }

    static func matches(_ lhs: VideoCaptureSettings, _ rhs: VideoCaptureSettings) -> Bool {
        lhs.resolution == rhs.resolution && lhs.frameRate == rhs.frameRate && lhs.colorSpace == rhs.colorSpace
            && lhs.codec == rhs.codec && (lhs.codec != .proRes || lhs.proRes == rhs.proRes)
            && lhs.captureFrameRate == nil && rhs.captureFrameRate == nil
    }

    static func configuration(for settings: VideoCaptureSettings, frontWide: Bool) -> DualCaptureSource.Configuration? {
        guard validatedSettings.contains(where: { matches($0, settings) }), settings.hardwareEncoderAvailable,
              let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              hasFormat(rear, size: settings.resolution.dimensions, fps: settings.frameRate.rawValue, color: settings.colorSpace) else { return nil }
        let rate = min(30, settings.frameRate.rawValue)
        // 方形前置格式保留足够的小窗像素和更低压力成本，标准/广角用同一官方路由的倍率切换。
        for (type, size) in [(AVCaptureDevice.DeviceType.builtInUltraWideCamera, CGSize(width: 1280, height: 1280)),
                             (.builtInWideAngleCamera, CGSize(width: 1280, height: 720))] {
            if let front = AVCaptureDevice.default(type, for: .video, position: .front),
               hasFormat(front, size: size, fps: rate, color: settings.colorSpace) {
                return .init(settings: settings, frontSize: size, frontType: type,
                             frontZoom: frontWide ? 1 : 1.6, frontFrameRate: Int32(rate))
            }
        }
        return nil
    }
    private static func hasFormat(_ device: AVCaptureDevice, size: CGSize, fps: Int, color: VideoColorSpace) -> Bool {
        guard let space = color.captureColorSpace else { return false }
        return device.formats.contains {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.isMultiCamSupported && d.width == Int32(size.width) && d.height == Int32(size.height)
                && CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && $0.supportedColorSpaces.contains(space)
                && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
        }
    }
    static func supportedSettings() -> [VideoCaptureSettings] {
        validatedSettings.filter { configuration(for: $0, frontWide: false) != nil }
    }
}

/// 合成与触摸共用归一化坐标；拖动只改窗口位置，不重建会话、不改变按钮布局。
enum DualCaptureInsetLayout {
    static let initial = CGRect(x: 0.68, y: 0.22, width: 0.28, height: 0.28)
    static func clamped(_ rect: CGRect) -> CGRect {
        let margin: CGFloat = 0.01
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return initial }
        let size = CGSize(width: min(rect.width, 0.8), height: min(rect.height, 0.8))
        return CGRect(x: min(max(rect.minX, margin), 1 - size.width - margin),
                      y: min(max(rect.minY, margin), 1 - size.height - margin), width: size.width, height: size.height)
    }
    /// 横幅保持16:9实际像素比例；归一化高度需乘主画面宽高比，不能直接交换归一化宽高。
    static func resized(_ rect: CGRect, landscape: Bool, ratio: CGFloat) -> CGRect {
        let size = landscape ? CGSize(width: 0.42, height: 0.42 * ratio / (16.0 / 9)) : initial.size
        // 已贴边时以对应边为锚点；保持中心缩小时会把窗口带离边缘，来回切换后留下明显空隙。
        let margin: CGFloat = 0.01, tolerance: CGFloat = 0.0001
        let x: CGFloat
        if abs(rect.minX - margin) <= tolerance { x = margin }
        else if abs(rect.maxX - (1 - margin)) <= tolerance { x = 1 - margin - size.width }
        else { x = rect.midX - size.width / 2 }
        let y: CGFloat
        if abs(rect.minY - margin) <= tolerance { y = margin }
        else if abs(rect.maxY - (1 - margin)) <= tolerance { y = 1 - margin - size.height }
        else { y = rect.midY - size.height / 2 }
        return clamped(CGRect(x: x, y: y, width: size.width, height: size.height))
    }
    /// 在显示坐标中选离拖动目标最近的合法位置，再映回合成坐标；枚举障碍边界，避免逐像素搜索。
    static func avoiding(_ rect: CGRect, ratio: CGFloat, turns: Int, obstacles: [CGRect]) -> CGRect {
        let display = displayRect(rect, ratio: ratio, turns: turns)
        let margin: CGFloat = 0.01
        let maxX = 1 - margin - display.width, maxY = 1 - margin - display.height
        guard maxX >= margin, maxY >= margin else { return clamped(rect) }
        var xs = [min(max(display.minX, margin), maxX), margin, maxX]
        var ys = [min(max(display.minY, margin), maxY), margin, maxY]
        for obstacle in obstacles {
            xs += [obstacle.minX - display.width, obstacle.maxX]
            ys += [obstacle.minY - display.height, obstacle.maxY]
        }
        var best: CGRect?, distance = CGFloat.infinity
        for x in xs where x >= margin && x <= maxX {
            for y in ys where y >= margin && y <= maxY {
                let candidate = CGRect(origin: CGPoint(x: x, y: y), size: display.size)
                guard !obstacles.contains(where: { $0.intersects(candidate.insetBy(dx: 0.000001, dy: 0.000001)) }) else { continue }
                let d = pow(x - display.minX, 2) + pow(y - display.minY, 2)
                if d < distance { best = candidate; distance = d }
            }
        }
        guard let best else { return clamped(rect) }
        return translated(rect, displayTranslation: CGSize(width: best.minX - display.minX, height: best.minY - display.minY), ratio: ratio, turns: turns)
    }
    private static func previewCrop(ratio: CGFloat, turns: Int) -> CGRect {
        let rotated = abs(turns % 2) == 1 ? 1 / ratio : ratio
        let width = min(1, ratio / rotated), height = min(1, rotated / ratio)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
    static func displayRect(_ rect: CGRect, ratio: CGFloat, turns: Int) -> CGRect {
        let crop = previewCrop(ratio: ratio, turns: turns)
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map {
            let p = PreviewRotation.sourcePoint($0, quarterTurns: -turns)
            return CGPoint(x: (p.x - crop.minX) / crop.width, y: (p.y - crop.minY) / crop.height)
        }
        return CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                      width: points.map(\.x).max()! - points.map(\.x).min()!, height: points.map(\.y).max()! - points.map(\.y).min()!)
    }
    static func translated(_ rect: CGRect, displayTranslation: CGSize, ratio: CGFloat, turns: Int) -> CGRect {
        let crop = previewCrop(ratio: ratio, turns: turns)
        let a = PreviewRotation.sourcePoint(.zero, quarterTurns: turns)
        let b = PreviewRotation.sourcePoint(CGPoint(x: displayTranslation.width * crop.width, y: displayTranslation.height * crop.height), quarterTurns: turns)
        return clamped(rect.offsetBy(dx: b.x - a.x, dy: b.y - a.y))
    }
}
