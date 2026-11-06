import XCTest
import AVFoundation
import UIKit
@testable import LumaCamera

/// 先读取公开多摄能力，再验证真实双路、合成、写入与解码；不能把格式枚举视为录制成功。
final class DualCaptureCompatibilityTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testPublicMultiCamFormatInventory() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let result = await Task.detached { () -> [[String: Any]] in
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
            let pairs = discovery.supportedMultiCamDeviceSets.map { $0.map { "\($0.position.rawValue):\($0.deviceType.rawValue)" }.sorted() }
            print("DUAL-INVENTORY pairs=\(pairs)")
            return discovery.devices.map { device in
                let formats = device.formats.filter(\.isMultiCamSupported).map { f -> [String: Any] in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    return ["width": d.width, "height": d.height, "pixel": CMFormatDescriptionGetMediaSubType(f.formatDescription),
                            "fps": f.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] },
                            "colors": f.supportedColorSpaces.map(\.rawValue), "fov": f.videoFieldOfView,
                            "dynamicRatios": f.supportedDynamicAspectRatios.map(\.rawValue)]
                }
                let sizes = Set(formats.map { "\($0["width"]!)x\($0["height"]!)" }).sorted()
                print("DUAL-INVENTORY position=\(device.position.rawValue) type=\(device.deviceType.rawValue) formats=\(formats.count) sizes=\(sizes)")
                return ["id": device.uniqueID, "position": device.position.rawValue, "type": device.deviceType.rawValue,
                        "formats": formats, "minZoom": device.minAvailableVideoZoomFactor, "maxZoom": device.maxAvailableVideoZoomFactor]
            }
        }.value
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "DualCapture-public-inventory.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(result.isEmpty)
    }
    struct Result: Codable {
        var label: String
        var stage = "not-started"
        var error: String?
        var cost: Float = 0
        var pressure: Float = 0
        var frames = 0
        var dropped = 0
        var decoded = 0
        var duration = 0.0
        var fps = 0.0
        var renderMedian = 0.0
        var maxSkew = 0.0
        var size = ""
        var rearFOV: Float = 0
        var frontFOV: Float = 0
        var frontZoom: CGFloat = 0
        var colors = ""
    }

    @MainActor private func probe(_ label: String, settings: VideoCaptureSettings, ratio: FrameRatio = .wide,
                                 frontType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera,
                                 frontSize: CGSize = CGSize(width: 1920, height: 1080), frontZoom: CGFloat = 1, frontFrameRate: Int32? = nil) async -> Result {
        let work = DispatchQueue(label: "test.dual.compat.session"), frames = DispatchQueue(label: "test.dual.compat.frames")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dual-compat-\(UUID().uuidString).mov")
        let recorded: Result = await withCheckedContinuation { continuation in
            work.async {
                var result = Result(label: label)
                var cleanup: DualCaptureSource?
                do {
                    let configuration = DualCaptureSource.Configuration(settings: settings, frontSize: frontSize,
                                                                        frontType: frontType, frontZoom: frontZoom, frontFrameRate: frontFrameRate)
                    let source = try DualCaptureSource(frameQueue: frames, ratio: ratio, audio: true, configuration: configuration)
                    cleanup = source
                    result.stage = "configured"; result.cost = source.session.hardwareCost; result.pressure = source.session.systemPressureCost
                    result.rearFOV = source.rear.activeFormat.videoFieldOfView
                    result.frontFOV = source.front.activeFormat.videoFieldOfView; result.frontZoom = source.front.videoZoomFactor
                    let recorder = try MovieRecorder(url: url, sourceSize: source.outputSize, ratio: ratio,
                        mirrored: false, includeAudio: source.includesAudio, settings: settings,
                        pixelFormat: kCVPixelFormatType_32BGRA, outputBaseSize: settings.resolution.dimensions)
                    source.onVideo = { recorder.appendVideo($0) }; source.onAudio = { recorder.appendAudio($0) }
                    try source.start()
                    let began = CACurrentMediaTime()
                    work.asyncAfter(deadline: .now() + 1.3) {
                        source.stop()
                        frames.async {
                            var finished = result
                            finished.stage = "captured"; finished.frames = source.frameCount; finished.dropped = source.droppedFrameCount
                            finished.maxSkew = source.maximumPairSkew
                            let times = source.renderDurations.sorted()
                            finished.renderMedian = times.isEmpty ? 0 : times[times.count / 2]
                            let captured = finished
                            recorder.finish { outcome in
                                work.async {
                                    var complete = captured
                                    if case .failure(let error) = outcome { complete.error = error.localizedDescription }
                                    source.release()
                                    print("DUAL-PROBE-FINISH \(label) frames=\(complete.frames) elapsed=\(CACurrentMediaTime()-began) error=\(complete.error ?? "none")")
                                    continuation.resume(returning: complete)
                                }
                            }
                        }
                    }
                } catch {
                    cleanup?.release()
                    result.error = error.localizedDescription
                    print("DUAL-PROBE-UNAVAILABLE \(label) stage=\(result.stage) cost=\(result.cost) error=\(error.localizedDescription)")
                    continuation.resume(returning: result)
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard recorded.error == nil else { return recorded }
        return await Task.detached {
            var result = recorded
            do {
                let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw NSError(domain: "DualProbeMissingTrack", code: 1) }
                let size = try await track.load(.naturalSize), duration = try await asset.load(.duration)
                let descriptions = try await track.load(.formatDescriptions)
                result.colors = descriptions.map { String(describing: CMFormatDescriptionGetExtensions($0)) }.joined(separator: ";")
                result.duration = duration.seconds; result.size = "\(Int(size.width))x\(Int(size.height))"
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? NSError(domain: "DualProbeReader", code: 2) }
                while autoreleasepool(invoking: { output.copyNextSampleBuffer() != nil }) { result.decoded += 1 }
                guard reader.status == .completed else { throw reader.error ?? NSError(domain: "DualProbeReader", code: 3) }
                result.fps = Double(result.decoded) / max(result.duration, 0.001)
                result.stage = "decoded"
            } catch { result.error = error.localizedDescription }
            print("DUAL-PROBE-RESULT \(String(data: try! JSONEncoder().encode(result), encoding: .utf8)!)")
            return result
        }.value
    }

    @MainActor func testResolutionFrameRateAndAspectMatrix() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        var results: [Result] = []
        for resolution in VideoResolution.allCases { for rate in VideoFrameRate.allCases {
            let settings = VideoCaptureSettings(resolution: resolution, frameRate: rate)
            let value = await probe("\(resolution.title)-\(rate.rawValue)-HEVC-SDR", settings: settings)
            results.append(value)
            if value.stage == "decoded" { XCTAssertGreaterThan(value.decoded, 10); XCTAssertGreaterThan(value.fps, Double(rate.rawValue) * 0.8) }
        } }
        for ratio in [FrameRatio.standard, .square, .panorama, .cinema] {
            let value = await probe("1080p30-ratio-\(ratio.rawValue)", settings: VideoCaptureSettings(), ratio: ratio)
            results.append(value); XCTAssertEqual(value.stage, "decoded", value.error ?? "")
        }
        for (size, zoom) in [(CGSize(width: 1080, height: 1920), CGFloat(1)),
                             (CGSize(width: 1920, height: 1920), CGFloat(1)),
                             (CGSize(width: 1080, height: 1920), CGFloat(1.6))] {
            results.append(await probe("frontUW-\(Int(size.width))x\(Int(size.height))-zoom\(zoom)", settings: VideoCaptureSettings(), frontType: .builtInUltraWideCamera, frontSize: size, frontZoom: zoom))
        }
        let data = try JSONEncoder().encode(results)
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "DualCapture-resolution-rate-aspect-front.json"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(results.contains { $0.stage == "decoded" && $0.label == "1080p-30-HEVC-SDR" })
    }

    @MainActor func testHighRateRearWithThirtyFrameFront() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        var values: [Result] = []
        for resolution in [VideoResolution.hd720, .hd1080] { for rate in [VideoFrameRate.fps50, .fps60] {
            for front in [AVCaptureDevice.DeviceType.builtInWideAngleCamera, .builtInUltraWideCamera] {
                let size = front == .builtInUltraWideCamera ? CGSize(width: 1080, height: 1920) : CGSize(width: 1280, height: 720)
                let result = await probe("\(resolution.title)-\(rate.rawValue)-front30-\(front.rawValue)",
                    settings: VideoCaptureSettings(resolution: resolution, frameRate: rate),
                    frontType: front, frontSize: size, frontFrameRate: 30)
                values.append(result)
                if result.stage == "decoded" { XCTAssertGreaterThan(result.fps, Double(rate.rawValue) * 0.8) }
            }
        } }
        let a = XCTAttachment(data: try JSONEncoder().encode(values), uniformTypeIdentifier: "public.json")
        a.name = "DualCapture-high-rate-front30.json"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testUltraWideWindowAt4KAndLowerCostFrontFormats() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        var results: [Result] = []
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1920), CGSize(width: 1280, height: 1280)] {
            results.append(await probe("4K30-frontUW-\(Int(size.width))x\(Int(size.height))", settings: VideoCaptureSettings(resolution: .uhd4K),
                frontType: .builtInUltraWideCamera, frontSize: size, frontFrameRate: 30))
        }
        for rate in [VideoFrameRate.fps50, .fps60] {
            results.append(await probe("1080p-\(rate.rawValue)-frontUW-1280square30", settings: VideoCaptureSettings(frameRate: rate),
                frontType: .builtInUltraWideCamera, frontSize: CGSize(width: 1280, height: 1280), frontFrameRate: 30))
        }
        results.append(await probe("4K30-P3-frontUW-1280square30", settings: VideoCaptureSettings(resolution: .uhd4K, colorSpace: .p3),
            frontType: .builtInUltraWideCamera, frontSize: CGSize(width: 1280, height: 1280), frontFrameRate: 30))
        results.append(await probe("4K30-ProResHQ-frontUW-1280square30", settings: VideoCaptureSettings(resolution: .uhd4K, codec: .proRes, proRes: .hq),
            frontType: .builtInUltraWideCamera, frontSize: CGSize(width: 1280, height: 1280), frontFrameRate: 30))
        results.append(await probe("1080p30-H264-P3", settings: VideoCaptureSettings(colorSpace: .p3, codec: .h264)))
        let a = XCTAttachment(data: try JSONEncoder().encode(results), uniformTypeIdentifier: "public.json")
        a.name = "DualCapture-frontUW-4K-and-reduced-cost.json"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testP3AndRegularCodecMatrix() async throws {
        _ = try await FullDeviceRegressionFixture.makeFreshModel()
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        var results: [Result] = []
        for resolution in VideoResolution.allCases {
            results.append(await probe("\(resolution.title)-30-HEVC-P3", settings: VideoCaptureSettings(resolution: resolution, colorSpace: .p3)))
        }
        results.append(await probe("1080p30-H264-SDR", settings: VideoCaptureSettings(codec: .h264)))
        for spec in [ProResSpecification.proxy, .lt, .standard, .hq, .four4, .four4xq] {
            results.append(await probe("1080p30-ProRes-\(spec.rawValue)", settings: VideoCaptureSettings(codec: .proRes, proRes: spec)))
        }
        let data = try JSONEncoder().encode(results)
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "DualCapture-P3-codecs.json"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(results.contains { $0.stage == "decoded" && $0.label == "1080p30-H264-SDR" })
    }
    #endif
}
