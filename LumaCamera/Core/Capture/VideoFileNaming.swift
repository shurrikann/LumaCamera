import Foundation

/// Human-readable movie filename:
/// LumaVideo_20261110_162530_4K60_HEVC_AppleLog2.mov
enum VideoFileNaming {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static func filename(for settings: VideoCaptureSettings, timeLapse: Bool = false,
                         cinematic: Bool = false, date: Date = Date()) -> String {
        let rate = settings.captureFrameRate?.rawValue ?? settings.frameRate.rawValue
        var parts = [
            "LumaVideo",
            timestampFormatter.string(from: date),
            "\(settings.resolution.title)\(rate)",
            codecToken(settings),
            colorToken(settings.colorSpace)
        ]
        if timeLapse { parts.append("Timelapse") }
        if cinematic { parts.append("Cinematic") }
        return parts.joined(separator: "_") + ".mov"
    }

    static func temporaryURL(for settings: VideoCaptureSettings, timeLapse: Bool = false,
                             cinematic: Bool = false, date: Date = Date(),
                             directory: URL = FileManager.default.temporaryDirectory) -> URL {
        let base = filename(for: settings, timeLapse: timeLapse, cinematic: cinematic, date: date)
        let stem = (base as NSString).deletingPathExtension
        var url = directory.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)_\(index).mov")
            index += 1
        }
        return url
    }

    private static func colorToken(_ color: VideoColorSpace) -> String {
        switch color {
        case .sdr: return "SDR"
        case .p3: return "P3"
        case .hdr: return "HDR"
        case .appleLog: return "AppleLog"
        case .appleLog2: return "AppleLog2"
        }
    }

    private static func codecToken(_ settings: VideoCaptureSettings) -> String {
        switch settings.codec {
        case .hevc: return "HEVC"
        case .h264: return "H264"
        case .proRes:
            if settings.isRAW { return settings.proRes == .rawHQ ? "ProResRAWHQ" : "ProResRAW" }
            return "ProRes"
        }
    }
}
