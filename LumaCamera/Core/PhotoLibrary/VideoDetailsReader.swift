import AVFoundation

/// Reads track metadata, never decodes video frames or loads the entire movie.
enum VideoDetailsReader {
    static func read(_ asset: AVAsset, filename: String?, date: Date?, location: PhotoLocation?,
                     badges: VideoCaptureBadges? = nil) async throws -> PhotoDetails {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw CocoaError(.fileReadCorruptFile) }
        async let naturalSize = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let frameRate = track.load(.nominalFrameRate)
        async let rate = track.load(.estimatedDataRate)
        async let descriptions = track.load(.formatDescriptions)
        async let duration = asset.load(.duration)
        let size = try await naturalSize.applying(transform)
        let fps = try await frameRate
        let bits = try await rate
        let formats = try await descriptions
        let seconds = try await duration.seconds
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var camera: String?
        var capturedAt = date
        var snapshot: [PhotoInfoRow] = []
        for item in metadata {
            if item.commonKey == .commonKeyModel { camera = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyCreationDate,
               let value = try? await item.load(.stringValue) { capturedAt = ISO8601DateFormatter().date(from: value) }
            if item.commonKey == .commonKeyDescription, let value = try? await item.load(.stringValue), value.hasPrefix(VideoFileMetadata.prefix),
               let data = String(value.dropFirst(VideoFileMetadata.prefix.count)).data(using: .utf8) {
                snapshot = (try? JSONDecoder().decode([PhotoInfoRow].self, from: data)) ?? []
            }
        }
        let codec = formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "未记录"
        let ext = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let log = ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String
        let color: String
        if log == kCVImageBufferLogTransferFunction_AppleLog as String { color = "Apple Log" }
        else if #available(iOS 26, *), log == kCVImageBufferLogTransferFunction_AppleLog2 as String { color = "Apple Log 2" }
        else if transfer?.contains("2084") == true || transfer?.contains("HLG") == true { color = "HDR" }
        else if primaries?.contains("P3") == true { color = "Display P3" }
        else if primaries?.contains("709") == true { color = "SDR · BT.709" }
        else if primaries != nil { color = "SDR · " + (primaries ?? "") }
        else { color = "未记录" }
        var rows: [PhotoInfoRow] = [
            .init(title: "相机", value: camera ?? "未记录相机型号"),
            .init(title: "文件名称", value: filename ?? (asset as? AVURLAsset)?.url.lastPathComponent ?? "未知文件名"),
            .init(title: "输出尺寸", value: "\(Int(abs(size.width).rounded())) × \(Int(abs(size.height).rounded()))"),
            .init(title: "帧率", value: fps.isFinite ? String(format: "%.2f fps", fps) : "未记录"),
            .init(title: "时长", value: seconds.isFinite ? String(format: "%.2f 秒", seconds) : "未记录"),
            .init(title: "输出格式", value: codec),
            .init(title: "码率", value: bits.isFinite ? String(format: "%.2f Mbps", bits / 1_000_000) : "未记录"),
            .init(title: "色彩空间", value: color)
        ]
        if let depth = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber {
            rows.append(.init(title: "位深", value: "\(depth.intValue)-bit"))
        }
        if let url = (asset as? AVURLAsset)?.url,
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            rows.append(.init(title: "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audio.first {
            let formats = try await audioTrack.load(.formatDescriptions)
            if let format = formats.first, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                rows.append(.init(title: "音频", value: "\(codecName(stream.mFormatID)) · \(stream.mChannelsPerFrame) 声道 · \(Int(stream.mSampleRate)) Hz"))
            } else { rows.append(.init(title: "音频", value: "有音轨")) }
        } else { rows.append(.init(title: "音频", value: "无音轨")) }
        for row in filterRows(for: badges) where !rows.contains(where: { $0.title == row.title }) {
            rows.append(row)
        }
        rows.append(contentsOf: snapshot)
        return PhotoDetails(rows: rows, location: location, capturedAt: capturedAt)
    }


    /// Adds human-readable filter/LUT information that is stored alongside the
    /// Photos asset rather than in the movie container itself.
    static func filterRows(for badges: VideoCaptureBadges?) -> [PhotoInfoRow] {
        guard let badges else { return [] }
        var rows: [PhotoInfoRow] = []
        if let id = badges.filmStyleID, id != FilmStyle.original.rawValue,
           let style = FilmStyle(rawValue: id) {
            rows.append(.init(title: "滤镜", value: style.title))
            if let intensity = badges.filterIntensity, intensity.isFinite {
                rows.append(.init(title: "滤镜浓度", value: "\(Int((min(max(intensity, 0), 1) * 100).rounded()))%"))
            }
            if let adjustments = badges.filterAdjustments, !adjustments.summary.isEmpty {
                rows.append(.init(title: "滤镜调整", value: adjustments.summary))
            }
        } else if badges.hasFilter {
            rows.append(.init(title: "滤镜", value: "已应用"))
        }
        if let id = badges.logLUTID,
           let preset = LogLUTCubeRepository.presets().first(where: { $0.id == id }) {
            rows.append(.init(title: "Log LUT", value: preset.displayName))
            rows.append(.init(title: "LUT 写入", value: "已烧录到画面"))
        }
        return rows
    }

    static func codecName(_ value: FourCharCode) -> String {
        switch value {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444 XQ"
        case kCMVideoCodecType_AppleProResRAW: return "ProRes RAW"
        case kCMVideoCodecType_AppleProResRAWHQ: return "ProRes RAW HQ"
        case kAudioFormatMPEG4AAC: return "AAC"
        default:
            return String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "未知编码"
        }
    }
}
