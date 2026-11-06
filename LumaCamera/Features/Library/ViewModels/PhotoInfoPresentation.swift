import Foundation

struct PhotoInfoPresentation {
    let details: PhotoDetails
    var isVideo = false
    private func value(_ title: String) -> String? { details.rows.first { $0.title == title }?.value }
    var dateText: String {
        guard let date = details.capturedAt ?? details.captureParameters?.capturedAt else { return value("拍摄时间") ?? "拍摄时间未知" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }
    var camera: String { value("相机") ?? details.captureParameters?.cameraModel ?? "未知相机" }
    var filename: String { value("文件名称") ?? "未知文件名" }
    var dimensionsAndSize: String { [value("输出尺寸"), value("文件大小")].compactMap { $0 }.joined(separator: " · ") }
    var parameterItems: [PhotoInfoRow] {
        if isVideo {
            return ["帧率", "时长", "输出格式", "码率"].map { .init(title: $0, value: value($0) ?? "—") }
        }
        let p = details.captureParameters
        return [
            .init(title: "快门", value: value("快门") ?? p?.exposureSeconds.map { CameraNumericText.shutter($0) } ?? "—"),
            .init(title: "ISO", value: value("ISO").map { "ISO " + $0 } ?? p?.iso.map { "ISO " + CameraNumericText.integer($0) } ?? "ISO —"),
            .init(title: "EV", value: (p?.exifExposureBiasEV ?? p?.requestedExposureBiasEV).map { String(format: "EV %+.1f", $0) } ?? value("成片曝光补偿").map { "EV " + $0.replacingOccurrences(of: " EV", with: "") } ?? "EV —"),
            .init(title: "焦距", value: (p?.equivalentFocalLengthMM ?? p?.focalLengthMM).map { String(format: "%.0fMM", $0) } ?? (value("35mm 等效焦距") ?? value("实际焦距"))?.replacingOccurrences(of: " mm", with: "MM") ?? "— MM"),
            .init(title: "光圈", value: p?.aperture.map { String(format: "f%.2f", $0) } ?? value("光圈")?.replacingOccurrences(of: "/", with: "") ?? "f—"),
            .init(title: "格式", value: value("输出格式") ?? "—"),
            .init(title: "拍摄类型", value: value("拍摄类型") ?? p?.shootingType ?? "—")]
    }
    var additionalRows: [PhotoInfoRow] {
        var primary: Set<String> = ["保存状态", "像素设置", "拍摄时间", "相机", "文件名称", "文件大小", "输出尺寸", "ISO", "快门", "光圈", "35mm 等效焦距", "输出格式", "拍摄类型"]
        if isVideo { primary.formUnion(["帧率", "时长", "码率"]) }
        return details.rows.filter { !primary.contains($0.title) }
    }
}
