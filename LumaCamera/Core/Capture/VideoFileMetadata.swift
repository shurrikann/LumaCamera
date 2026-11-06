import AVFoundation

enum VideoFileMetadata {
    static let prefix = "LumaVideoCapture:"
    static func items(device: AVCaptureDevice, model: String, location: PhotoLocation?, mode: String, bias: Double,
                      zoom: Double, ratio: String, copyright: String?, colorSpace: VideoColorSpace = .sdr,
                      bakedLogFilterName: String? = nil, timeLapsePreset: TimeLapsePreset? = nil,
                      slowMotionCaptureFrameRate: VideoFrameRate? = nil,
                      playbackFrameRate: VideoFrameRate = .fps30,
                      cinematicVideo: Bool = false, dualCapture: Bool = false, virtualAperture: Double? = nil, centerStage: Bool = false) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = value as NSString
            item.extendedLanguageTag = "und"; return item
        }
        let primary = device.activePrimaryConstituent ?? device
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        var rows = [PhotoInfoRow(title: "录制开始模式", value: mode),
                    .init(title: "录制开始镜头", value: primary.localizedName)]
        if device.iso.isFinite { rows.append(.init(title: "录制开始 ISO", value: CameraNumericText.integer(Double(device.iso)))) }
        if seconds.isFinite && seconds > 0 { rows.append(.init(title: "录制开始快门", value: CameraNumericText.shutter(seconds))) }
        if bias.isFinite { rows.append(.init(title: "录制开始 EV", value: String(format: "%+.1f", bias))) }
        if zoom.isFinite { rows.append(.init(title: "录制开始倍率", value: String(format: "%.2f×", zoom))) }
        if primary.lensAperture.isFinite { rows.append(.init(title: "光圈", value: String(format: "f/%.2f", primary.lensAperture))) }
        if let gains = WhiteBalanceSafety.validated(device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain) {
            let values = device.temperatureAndTintValues(for: gains)
            if values.temperature.isFinite { rows.append(.init(title: "录制开始白平衡", value: String(format: "%.0f K", values.temperature))) }
            if values.tint.isFinite { rows.append(.init(title: "录制开始色调", value: String(format: "%+.1f", values.tint))) }
        }
        rows.append(.init(title: "画面比例", value: ratio))
        if let timeLapsePreset {
            rows.append(.init(title: "拍摄类型", value: "延时摄影"))
            rows.append(.init(title: "采样间隔", value: "\(timeLapsePreset.intervalDescription)取一帧"))
        }
        if let slowMotionCaptureFrameRate {
            rows.append(.init(title: "拍摄类型", value: "慢动作"))
            rows.append(.init(title: "采集帧率", value: "\(slowMotionCaptureFrameRate.rawValue) fps"))
            rows.append(.init(title: "回放帧率", value: "\(playbackFrameRate.rawValue) fps"))
        }
        if dualCapture {
            rows.append(.init(title: "拍摄类型", value: "同步双拍（前后画中画）"))
            rows.append(.init(title: "双拍镜头", value: "后置主摄 + 前置；录制中可交换主副画面"))
        }
        if centerStage { rows.append(.init(title: "人物居中", value: "系统Center Stage已开启")) }
        if let virtualAperture {
            rows.append(.init(title: "拍摄类型", value: "虚拟光圈（星芒已合成）"))
            rows.append(.init(title: "虚拟光圈", value: VirtualApertureRenderer.label(virtualAperture)))
        }
        if cinematicVideo { rows.append(.init(title: "拍摄类型", value: "电影模式（景深已合成）")) }
        if colorSpace.isLog, let bakedLogFilterName { rows.append(.init(title: "滤镜", value: bakedLogFilterName)) }
        if let copyright, !copyright.isEmpty { rows.append(.init(title: "版权署名", value: copyright)) }
        rows.append(.init(title: "参数说明", value: "以上为录制开始时的快照，自动曝光及镜头可能随拍摄变化。"))
        var items = [item(.commonIdentifierMake, "Apple"), item(.commonIdentifierModel, model),
                     item(.commonIdentifierCreationDate, ISO8601DateFormatter().string(from: Date()))]
        if let copyright, !copyright.isEmpty { items.append(item(.commonIdentifierCopyrights, copyright)) }
        if let data = try? JSONEncoder().encode(rows), let json = String(data: data, encoding: .utf8) {
            items.append(item(.commonIdentifierDescription, prefix + json))
        }
        if let location, location.isValid {
            items.append(item(.quickTimeMetadataLocationISO6709, String(format: "%+08.4f%+09.4f/", locale: Locale(identifier: "en_US_POSIX"), location.latitude, location.longitude)))
        }
        return items
    }
}
