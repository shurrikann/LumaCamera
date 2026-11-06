import AVFoundation
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class VideoWorkflowTests: XCTestCase {
    func testSlowMotionSchedulerRetimes120FPSCaptureAndRejectsInvalidTime() throws {
        var scheduler = try XCTUnwrap(SlowMotionFrameScheduler(playbackFrameRate: 30, captureFrameRate: 120))
        let origin = CMTime(seconds: 12, preferredTimescale: 600)
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(scheduler.outputPresentationTime(for: origin))), 12, accuracy: 0.0001)
        XCTAssertNil(scheduler.outputPresentationTime(for: origin), "重复媒体时间戳不能写入慢动作时间轴")

        var finalTime = origin
        for index in 1...120 {
            let source = CMTime(value: Int64(12 * 120 + index), timescale: 120)
            finalTime = try XCTUnwrap(scheduler.outputPresentationTime(for: source))
        }
        XCTAssertEqual(scheduler.acceptedFrameCount, 121)
        XCTAssertEqual(CMTimeGetSeconds(finalTime), 12 + 120.0 / 30.0, accuracy: 0.0001)
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime.invalid))
        XCTAssertNil(SlowMotionFrameScheduler(playbackFrameRate: 120, captureFrameRate: 120))
    }

    func testSlowMotionPolicyOnlyAllowsSupportedNormalVideoCombinations() {
        XCTAssertTrue(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: false))
        XCTAssertTrue(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps24, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: false), "24 fps 可作为慢动作回放帧率")
        XCTAssertTrue(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps60, captureFrameRate: .fps120,
            codec: .h264, colorSpace: .p3, isRAW: false, openGate: false))
        XCTAssertTrue(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps120, captureFrameRate: .fps240,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: false))
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps120, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: false))
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: nil,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: false))
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps120,
            codec: .proRes, colorSpace: .sdr, isRAW: false, openGate: false))
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .hdr, isRAW: false, openGate: false), "1080p HDR 不开放慢动作")
        XCTAssertTrue(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps24, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .hdr, isRAW: false, openGate: false, resolution: .uhd4K),
            "4K HDR 120 采集可按 24 fps 回放")
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps240,
            codec: .hevc, colorSpace: .hdr, isRAW: false, openGate: false, resolution: .uhd4K),
            "HDR 慢动作只开放 120 fps 采集")
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .sdr, isRAW: true, openGate: false))
        XCTAssertFalse(SlowMotionCapturePolicy.isSupported(playbackFrameRate: .fps30, captureFrameRate: .fps120,
            codec: .hevc, colorSpace: .sdr, isRAW: false, openGate: true))
        XCTAssertEqual(SlowMotionCapturePolicy.playbackSpeed(playbackFrameRate: .fps30), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SlowMotionCapturePolicy.playbackSpeed(playbackFrameRate: .fps30, captureFrameRate: .fps240), 0.125, accuracy: 0.0001)
    }

    func testSlowMotionPickerShowsCaptureFormatsAndKeepsPlaybackRateSeparate() {
        let playback = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps24, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps60, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps24, colorSpace: .hdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30, colorSpace: .hdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps60, colorSpace: .hdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps120, colorSpace: .hdr)
        ]
        let capture = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps240, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps120, colorSpace: .hdr)
        ]
        let slowMotion = VideoSubmodeSettingsPolicy.slowMotionPlaybackSettings(from: playback, captureRates: capture)

        XCTAssertEqual(SlowMotionCapturePickerPolicy.resolutions(captureFormats: capture,
            playbackSettings: slowMotion, colorSpace: .hdr, codec: .hevc), [.uhd4K])
        XCTAssertEqual(SlowMotionCapturePickerPolicy.captureRates(for: .uhd4K,
            captureFormats: capture, playbackSettings: slowMotion, colorSpace: .hdr, codec: .hevc), [.fps120])
        XCTAssertTrue(slowMotion.contains {
            $0.resolution == .uhd4K && $0.frameRate == .fps24 && $0.captureFrameRate == .fps120
        }, "24 fps 作为回放速度仍有效，但不作为慢动作采集选项显示")
        XCTAssertFalse(SlowMotionCapturePickerPolicy.captureRates(for: .uhd4K,
            captureFormats: capture, playbackSettings: slowMotion, colorSpace: .hdr, codec: .h264).contains(.fps120))
    }

    func testCinematicPolicyAndAutomaticSubmodeSpecificationSelection() {
        XCTAssertTrue(CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: true, codec: .hevc,
            isRAW: false, openGate: false, timeLapse: false, slowMotion: false))
        XCTAssertFalse(CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: false, codec: .hevc,
            isRAW: false, openGate: false, timeLapse: false, slowMotion: false))
        XCTAssertFalse(CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: true, codec: .proRes,
            isRAW: false, openGate: false, timeLapse: false, slowMotion: false))
        XCTAssertFalse(CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: true, codec: .hevc,
            isRAW: false, openGate: true, timeLapse: false, slowMotion: false))
        XCTAssertFalse(CinematicVideoCapturePolicy.isSupported(hasCinematicFormat: true, codec: .hevc,
            isRAW: false, openGate: false, timeLapse: true, slowMotion: false))

        let supported = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30, colorSpace: .p3)
        ]
        let captureRates = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps240, colorSpace: .sdr)
        ]
        let slowMotion = VideoSubmodeSettingsPolicy.slowMotionPlaybackSettings(from: supported, captureRates: captureRates)
        XCTAssertEqual(slowMotion.map(\.frameRate), [.fps30, .fps120])
        XCTAssertTrue(slowMotion.allSatisfy { $0.captureFrameRate == .fps240 }, "有 240 fps 时应优先用最高采集率")

        let requested = VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps60, colorSpace: .p3)
        XCTAssertEqual(VideoSubmodeSettingsPolicy.closestSupported(supported, to: requested), supported[2],
                       "不兼容时应优先保留可用色彩空间和分辨率，再选最近帧率")
    }

    func testVideoSubmodeFallsBackToTheNearestSafeDefaultAndPreservesValidChoice() {
        let fallbackCandidates = [
            VideoCaptureSettings(resolution: .hd720, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps24, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30, colorSpace: .p3)
        ]
        let incompatible = VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps60, colorSpace: .sdr)
        XCTAssertEqual(VideoSubmodeSettingsPolicy.compatibleSettings(fallbackCandidates, preserving: incompatible),
                       fallbackCandidates[1], "没有精确兼容规格时应优先采用 1080p SDR 附近的安全规格。")

        let requested = VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30, colorSpace: .p3)
        XCTAssertEqual(VideoSubmodeSettingsPolicy.compatibleSettings(fallbackCandidates, preserving: requested), requested,
                       "当前设置仍兼容时应原样保留。")
        XCTAssertNil(VideoSubmodeSettingsPolicy.compatibleSettings([], preserving: requested),
                     "没有支持路线时不得虚构兼容规格。")
    }

    @MainActor func testCinematicResolutionAndFrameRateCanBeSelectedAsApplePairs() {
        XCTAssertTrue(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .hd1080, frameRate: .fps30))
        XCTAssertTrue(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .uhd4K, frameRate: .fps24))
        XCTAssertTrue(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .uhd4K, frameRate: .fps30))
        XCTAssertTrue(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .hd1080, frameRate: .fps60))
        XCTAssertTrue(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .uhd4K, frameRate: .fps60))
        XCTAssertFalse(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .hd1080, frameRate: .fps24))
        XCTAssertFalse(CinematicVideoCapturePolicy.isDocumentedSpecification(resolution: .uhd4K, frameRate: .fps25))

        let cinematic = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps24, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .uhd4K, frameRate: .fps30, colorSpace: .sdr)
        ]
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.installVideoCapabilitiesForTesting(ordinary: cinematic, cinematic: cinematic)
        model.setCaptureKind(.video)
        model.toggleCinematicVideoMode()

        XCTAssertTrue(model.cinematicVideoEnabled)
        XCTAssertTrue(model.supportsVideoResolution(.uhd4K))
        model.selectVideoResolution(.uhd4K)
        XCTAssertEqual(model.videoResolution, .uhd4K)
        XCTAssertEqual(model.videoFrameRate, .fps30)
        XCTAssertTrue(model.supportsVideoFrameRate(.fps24))

        model.selectVideoFrameRate(.fps24)
        XCTAssertEqual(model.videoResolution, .uhd4K)
        XCTAssertEqual(model.videoFrameRate, .fps24)
        XCTAssertFalse(model.supportsVideoFrameRate(.fps25))

        model.selectVideoResolution(.hd1080)
        XCTAssertEqual(model.videoResolution, .uhd4K, "24 fps 下隐藏不兼容的 1080p，不自动改帧率")
        XCTAssertEqual(model.videoFrameRate, .fps24)
        model.selectVideoFrameRate(.fps30)
        model.selectVideoResolution(.hd1080)
        XCTAssertEqual(model.videoResolution, .hd1080)
        XCTAssertEqual(model.videoFrameRate, .fps30,
                       "先选兼容的 30 fps 后才允许切换 1080p")
    }

    func testVideoLensCapabilitiesExposeOnlyTheRequestedSubmodeRoutes() {
        let normal = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)
        let highRate = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr)
        let gate = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)
        let cinematic = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)
        let capabilities = VideoLensCaptureCapabilities(ordinary: [normal, highRate], slowMotionCaptureRates: [highRate],
                                                         openGate: [gate], cinematic: [cinematic])

        XCTAssertEqual(capabilities.settings(for: .timeLapse, openGateEnabled: true), [gate])
        XCTAssertEqual(capabilities.settings(for: .timeLapse, openGateEnabled: false), [normal, highRate])
        let slowMotionSettings = capabilities.settings(for: .slowMotion, openGateEnabled: false)
        XCTAssertEqual(slowMotionSettings.map(\.frameRate), [.fps30],
                       "慢动作只应保留低于采集帧率的回放规格。")
        XCTAssertEqual(slowMotionSettings.map(\.captureFrameRate), [.fps120],
                       "慢动作规格应记录用于该回放规格的实际采集帧率。")
        XCTAssertEqual(capabilities.settings(for: .cinematic, openGateEnabled: false), [cinematic])
    }

    func testSubmodeFocalChoicesOnlyIncludeLensesSupportingTheSelectedVideoSettings() {
        let selected = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)
        let otherRate = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps60, colorSpace: .sdr)
        let otherColor = VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .p3)
        let routes = [
            VideoSubmodeCaptureRoute(lensID: "wide", settings: [selected, otherRate]),
            VideoSubmodeCaptureRoute(lensID: "telephoto", settings: [otherRate]),
            VideoSubmodeCaptureRoute(lensID: "front", settings: [otherColor])
        ]

        XCTAssertEqual(VideoSubmodeSettingsPolicy.compatibleLensIDs(in: routes, matching: selected), ["wide"],
                       "子模式启用后只开放能按当前规格录制的镜头。")
    }

    @MainActor func testVideoSubmodeSwitchesAreExclusiveAndKeepOnlySupportedSettings() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let ordinary = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps24, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps60, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps120, colorSpace: .sdr)
        ]
        let cinematic = [VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)]
        model.camera.installVideoCapabilitiesForTesting(ordinary: ordinary, cinematic: cinematic)
        model.setCaptureKind(.video)

        model.videoResolution = .uhd4K
        model.videoFrameRate = .fps60
        model.toggleSlowMotionMode()
        XCTAssertTrue(model.slowMotionEnabled)
        XCTAssertEqual(model.videoResolution, .hd1080)
        XCTAssertEqual(model.videoFrameRate, .fps60)
        XCTAssertFalse(model.supportsVideoFrameRate(.fps25), "激活慢动作时不支持的播放规格应在设置页禁用")

        model.toggleCinematicVideoMode()
        XCTAssertTrue(model.cinematicVideoEnabled)
        XCTAssertFalse(model.slowMotionEnabled)
        XCTAssertEqual(model.videoFrameRate, .fps30, "电影模式应自动切到相机声明的兼容格式")

        model.toggleTimeLapseMode()
        XCTAssertTrue(model.timeLapseEnabled)
        XCTAssertFalse(model.cinematicVideoEnabled)
        XCTAssertFalse(model.slowMotionEnabled)

        for index in 0..<60 {
            switch index % 3 {
            case 0: model.toggleTimeLapseMode()
            case 1: model.toggleSlowMotionMode()
            default: model.toggleCinematicVideoMode()
            }
            let activeModes = [model.timeLapseEnabled, model.slowMotionEnabled, model.cinematicVideoEnabled].filter { $0 }.count
            XCTAssertLessThanOrEqual(activeModes, 1, "快速切换后视频子模式仍必须互斥")
        }
        model.setCaptureKind(.photo)
        XCTAssertFalse(model.timeLapseEnabled)
        XCTAssertFalse(model.slowMotionEnabled)
        XCTAssertFalse(model.cinematicVideoEnabled)
    }

    func testSlowMotionSchedulerThroughputAndRepeatedStartStopState() throws {
        var roundTimes: [Double] = []
        for _ in 0..<5 {
            var scheduler = try XCTUnwrap(SlowMotionFrameScheduler(playbackFrameRate: 30, captureFrameRate: 120))
            let start = CACurrentMediaTime()
            for index in 0..<10_000 {
                _ = scheduler.outputPresentationTime(for: CMTime(value: Int64(index), timescale: 120))
            }
            roundTimes.append(CACurrentMediaTime() - start)
            XCTAssertEqual(scheduler.acceptedFrameCount, 10_000)
        }
        let mean = roundTimes.reduce(0, +) / Double(roundTimes.count)
        let evidence = XCTAttachment(string: "scheduler=10,000 input timestamps per round; rounds=\(roundTimes.count); mean=\(mean)s max=\(roundTimes.max() ?? 0)s; timestamp mapping only, not camera FPS, encoder throughput, or thermal behavior")
        evidence.name = "slow-motion-scheduler-throughput"
        evidence.lifetime = .keepAlways
        add(evidence)
        print("SLOW-MOTION-SCHEDULER samples=10000 rounds=\(roundTimes.count) mean=\(mean) max=\(roundTimes.max() ?? 0)")

        // 多轮快速启停都必须从新的媒体时间原点开始，不继承上轮的帧数。
        for _ in 0..<20 {
            var next = try XCTUnwrap(SlowMotionFrameScheduler(playbackFrameRate: 24, captureFrameRate: 120))
            let first = CMTime(seconds: 40, preferredTimescale: 600)
            XCTAssertEqual(next.outputPresentationTime(for: first), first)
            XCTAssertEqual(next.acceptedFrameCount, 1)
        }
    }

    @MainActor func testTimeLapsePresetsSchedulerAndModeStability() throws {
        XCTAssertEqual(TimeLapsePreset.allCases.map(\.intervalSeconds), [1, 3, 5, 10, 15])
        var scheduler = try XCTUnwrap(TimeLapseFrameScheduler(intervalSeconds: 0.5, frameRate: 30))
        let origin = CMTime(seconds: 100, preferredTimescale: 600)
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(scheduler.outputPresentationTime(for: origin))), 100, accuracy: 0.0001)
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime(seconds: 100.2, preferredTimescale: 600)))
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime(seconds: 100.49, preferredTimescale: 600)))
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(scheduler.outputPresentationTime(
            for: CMTime(seconds: 100.5, preferredTimescale: 600)))), 100 + 1.0 / 30, accuracy: 0.0001)
        XCTAssertNil(scheduler.outputPresentationTime(for: CMTime(seconds: 100.4, preferredTimescale: 600)),
                     "非递增的输入时间戳不能重新进入成片时间轴")
        XCTAssertEqual(scheduler.acceptedFrameCount, 2)

        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let videoSpecs = [
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps24, colorSpace: .sdr),
            VideoCaptureSettings(resolution: .hd1080, frameRate: .fps30, colorSpace: .sdr)
        ]
        model.camera.installVideoCapabilitiesForTesting(ordinary: videoSpecs, cinematic: [])
        model.setCaptureKind(.video)
        XCTAssertFalse(model.timeLapseEnabled)
        model.toggleTimeLapseMode()
        XCTAssertTrue(model.timeLapseEnabled)
        XCTAssertEqual(model.selectedTimeLapsePreset, .traffic)
        model.selectTimeLapsePreset(.nightSky)
        XCTAssertEqual(model.selectedTimeLapsePreset, .nightSky)

        // 重复开关后模式状态必须与最后一次操作一致，且切回照片会退出延时模式。
        for _ in 0..<20 { model.toggleTimeLapseMode() }
        XCTAssertTrue(model.timeLapseEnabled)
        model.videoCodec = .proRes
        model.proResSpecification = .raw
        XCTAssertFalse(model.timeLapseEnabled, "RAW 路径不能重排帧时间戳时应自动关闭延时模式")
        XCTAssertTrue(model.rawVideoSelected)
        model.setCaptureKind(.photo)
        XCTAssertFalse(model.timeLapseEnabled)
    }

    func testTimeLapseSchedulerThroughput() throws {
        var roundTimes: [Double] = []
        for _ in 0..<5 {
            var scheduler = try XCTUnwrap(TimeLapseFrameScheduler(intervalSeconds: 0.5, frameRate: 30))
            let start = CACurrentMediaTime()
            for index in 0..<10_000 {
                _ = scheduler.outputPresentationTime(for: CMTime(value: Int64(index), timescale: 30))
            }
            roundTimes.append(CACurrentMediaTime() - start)
            XCTAssertGreaterThan(scheduler.acceptedFrameCount, 0)
        }
        let mean = roundTimes.reduce(0, +) / Double(roundTimes.count)
        let evidence = XCTAttachment(string: "scheduler=10,000 input timestamps per round; rounds=\(roundTimes.count); mean=\(mean)s max=\(roundTimes.max() ?? 0)s; CPU scheduler only, not camera throughput or encoded movie FPS")
        evidence.name = "time-lapse-scheduler-throughput"
        evidence.lifetime = .keepAlways
        add(evidence)
        print("TIME-LAPSE-SCHEDULER samples=10000 rounds=\(roundTimes.count) mean=\(mean) max=\(roundTimes.max() ?? 0)")
    }

    @MainActor func testTimeLapsePresetBarMatchesFocalBarAndSurvivesRapidChanges() async throws {
        // 延时预设位于色彩空间弹窗，底部焦段保持固定。
        try await PresetToolbarChecks.timeLapse(test: self)
    }

    @MainActor func testPhotoFilterLookAndEditsAreAvailableOnlyForSDRAndP3Video() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .leicaM9
        model.intensity = 0.93
        var edits = FilterAdjustments(); edits[.temperature] = 28; edits[.grainSize] = 16
        model.filterAdjustments = edits
        model.setCaptureKind(.video)

        for colorSpace in [VideoColorSpace.sdr, .p3] {
            model.videoColorSpace = colorSpace
            XCTAssertTrue(model.filterControlsEnabled)
            XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9)
            XCTAssertEqual(model.effectiveCaptureLook.intensity, 0.93, accuracy: 0.0001)
            XCTAssertEqual(model.effectiveCaptureLook.adjustments, edits)
        }
        model.videoColorSpace = .hdr
        XCTAssertFalse(model.filterControlsEnabled)
        XCTAssertFalse(model.logVideoLUTControlsEnabled)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original)
        XCTAssertTrue(model.effectiveCaptureLook.adjustments.isNeutral)
        for colorSpace in [VideoColorSpace.appleLog, .appleLog2] {
            model.videoColorSpace = colorSpace
            XCTAssertTrue(model.filterControlsEnabled)
            XCTAssertTrue(model.logVideoLUTControlsEnabled)
            XCTAssertFalse(model.videoFiltersEnabled)
            XCTAssertEqual(model.effectiveCaptureLook.style, .original)
            XCTAssertTrue(model.effectiveCaptureLook.adjustments.isNeutral)
        }
        model.videoCodec = .proRes
        model.proResSpecification = .raw
        model.videoColorSpace = .sdr
        XCTAssertFalse(model.filterControlsEnabled)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original)
    }

    @MainActor func testFrameRateChoicesHaveThirtySelectedByDefault() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertFalse(model.showsRecordingCapacity)
        XCTAssertFalse(model.showsAudioMeter)
        model.showsRecordingCapacity = true
        model.showsAudioMeter = true
        XCTAssertTrue(model.showsRecordingCapacity)
        XCTAssertTrue(model.showsAudioMeter)
        XCTAssertEqual(VideoFrameRate.allCases.map(\.rawValue), [24, 25, 30, 50, 60, 120])
        XCTAssertEqual(model.videoFrameRate, .fps30)
        XCTAssertEqual(model.videoFrameRateText, "30")
        for rate in VideoFrameRate.allCases {
            model.videoFrameRate = rate
            XCTAssertEqual(model.videoFrameRateText, String(rate.rawValue))
        }
    }

    #if targetEnvironment(simulator)
    @MainActor func testFailedVideoStartDoesNotRunClockAndSavingBlocksShutter() async throws {
        let service = VideoSavingStub()
        let model = AppDependencies.makeCameraModel(automaticallySave: false, photoService: service)
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<100 { if model.camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.video)
        model.toggleVideoRecording() // Simulator has no real recording graph.
        for _ in 0..<100 { if !model.camera.videoBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.camera.videoRecording)
        XCTAssertEqual(model.videoElapsed, 0)
        XCTAssertTrue(model.videoShutterEnabled)
        model.library.saveVideo(at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"))
        XCTAssertTrue(model.videoShutterBusy)
        XCTAssertFalse(model.videoShutterEnabled)
        service.completion?(.failure(PhotoLibraryError.writeDenied))
        XCTAssertFalse(model.videoShutterBusy)
        XCTAssertTrue(model.videoShutterEnabled)
    }
    #else
    @MainActor func testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let callback = camera.onVideoRecorded
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var results: [Result<URL, Error>] = []
        camera.onVideoRecorded = { results.append($0) }
        let pendingSaves = model.library.pendingSaveCount
        defer {
            // 失败收尾也不让诊断片段落入正式相册回调。
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                    camera.onVideoRecorded = callback
                }
                camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            for result in results { if case .success(let url) = result { try? FileManager.default.removeItem(at: url) } }
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }

        func waitFor(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail(label + ": " + (camera.message ?? "状态未就绪"))
            throw NSError(domain: "VideoLifecycleTest", code: 1)
        }
        func resume() async throws {
            let requestedAt = CACurrentMediaTime()
            model.setCameraActive(true)
            // ready 可能先于异步启动返回；必须等实际恢复后的新预览帧。
            try await waitFor("恢复新帧") { camera.ready && camera.previewFrameTimeForTesting > requestedAt }
        }
        func checkFile(_ url: URL, minimumFrames: Int) async throws {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration).seconds
            XCTAssertTrue(duration.isFinite && duration > 0)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(max(size.width,size.height),1920)
            XCTAssertEqual(min(size.width,size.height),1080)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0, lastPTS = -Double.infinity
            while let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                XCTAssertTrue(pts.isFinite); XCTAssertGreaterThan(pts,lastPTS)
                lastPTS = pts; frames += 1
            }
            XCTAssertEqual(reader.status,.completed)
            XCTAssertGreaterThanOrEqual(frames,minimumFrames)
            print("VIDEO-LIFECYCLE-FILE frames=\(frames) duration=\(duration) size=\(size)")
        }

        var modeTimes: [Double] = [], finishTimes: [Double] = [], resumeTimes: [Double] = []
        for round in 0..<3 {
            try await resume()
            model.setCaptureKind(.photo)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let before = await withCheckedContinuation { c in camera.videoRouteStateForTesting { _, _, count in c.resume(returning: count) } }
            let gate = DispatchSemaphore(value: 0)
            camera.pauseSessionQueueForTesting(gate)
            let began = CACurrentMediaTime()
            for index in 0..<100 { model.setCaptureKind(index.isMultiple(of: 2) ? .photo : .video) }
            gate.signal()
            let state = await withCheckedContinuation { c in camera.videoRouteStateForTesting { c.resume(returning: ($0, $1, $2)) } }
            XCTAssertTrue(state.0); XCTAssertTrue(state.1)
            XCTAssertLessThanOrEqual(state.2 - before,1,"过期请求不能各自重配会话")
            modeTimes.append(CACurrentMediaTime()-began)
            print("VIDEO-MODE-STRESS round=\(round) requests=100 configurations=\(state.2-before) completion=\(modeTimes.last!)")
            model.setMode(round == 1 ? .manual : .auto)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await waitFor("录像就绪") { model.videoShutterEnabled }
            let count = results.count
            model.toggleVideoRecording()
            try await waitFor("录像启动") { camera.videoRecording }
            try await waitFor("计时开始") { model.videoElapsed > 0 }
            try await Task.sleep(for: .milliseconds(500))
            let stoppedAt = model.videoElapsed, stopTime = CACurrentMediaTime()
            model.setCameraActive(false)
            camera.stopVideoRecording(); camera.stopVideoRecording()
            XCTAssertFalse(camera.videoRecording)
            try await waitFor("退出录制收尾") { results.count > count }
            finishTimes.append(CACurrentMediaTime()-stopTime)
            XCTAssertEqual(results.count,count+1,"重复停止只交付一次")
            let url = try results[count].get()
            try await checkFile(url,minimumFrames:2)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(results.count,count+1)
            XCTAssertFalse(camera.videoBusy); XCTAssertFalse(camera.videoRecording)
            XCTAssertEqual(model.videoElapsed,stoppedAt,accuracy:0.02)
            let running = await withCheckedContinuation { c in camera.actualSessionRunningForTesting { c.resume(returning:$0) } }
            XCTAssertFalse(running,"生命周期退出必须实际停机会话")
            print("VIDEO-CLOCK-AFTER-STOP round=\(round) delta=\(model.videoElapsed-stoppedAt) finish=\(finishTimes.last!)")

            let resumeStarted = CACurrentMediaTime()
            try await resume()
            resumeTimes.append(CACurrentMediaTime()-resumeStarted)
            try await waitFor("恢复后快门") { model.videoShutterEnabled }
            let cancelCount = results.count
            model.toggleVideoRecording()
            camera.stopVideoRecording(); camera.stopVideoRecording()
            try await waitFor("首帧前取消收尾") { results.count > cancelCount && !camera.videoBusy }
            XCTAssertEqual(results.count,cancelCount+1)
            switch results[cancelCount] {
            case .success(let url): try await checkFile(url,minimumFrames:1)
            case .failure(let error): XCTAssertTrue(error is CancellationError,"立即取消应明确返回取消：\(error)")
            }
            XCTAssertFalse(camera.videoRecording); XCTAssertEqual(model.videoElapsed,0)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(results.count,cancelCount+1,"取消后迟到回调不能重复交付")
            XCTAssertEqual(model.library.pendingSaveCount,pendingSaves)
        }
        print("VIDEO-LIFECYCLE-SUMMARY rounds=3 requests=300 callbacks=\(results.count) modeTimes=\(modeTimes) finishTimes=\(finishTimes) resumeTimes=\(resumeTimes)")
    }

    @MainActor func testImmediateCancelDuringWhiteBalanceStartupCompletesExactlyOnce() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let audit = SessionRuntimeErrorAudit()
        defer { audit.finish() }
        let callback = camera.onVideoRecorded
        let oldPreferences = model.preferences
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var results: [Result<URL,Error>] = []
        camera.onVideoRecorded = { results.append($0) }
        defer {
            if camera.videoBusy {
                camera.onVideoRecorded = { result in
                    if case .success(let url) = result { try? FileManager.default.removeItem(at:url) }
                    camera.onVideoRecorded = callback
                }
                camera.stopVideoRecording()
            } else { camera.onVideoRecorded = callback }
            model.preferences = oldPreferences
            for result in results { if case .success(let url) = result { try? FileManager.default.removeItem(at:url) } }
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.preferences.lockVideoWhiteBalance = true
        model.setCameraActive(true); model.setCaptureKind(.video)
        for _ in 0..<400 { if model.videoShutterEnabled { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.videoShutterEnabled)
        let previousWB = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0?.whiteBalanceMode) } }
        XCTAssertNotNil(previousWB)
        for round in 0..<3 {
            let count = results.count, began = CACurrentMediaTime()
            model.toggleVideoRecording()
            camera.stopVideoRecording(); camera.stopVideoRecording()
            for _ in 0..<400 { if results.count > count && !camera.videoBusy { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertEqual(results.count,count+1,"白平衡锁定等待期间取消也必须结束一次")
            XCTAssertFalse(camera.videoBusy); XCTAssertFalse(camera.videoRecording)
            XCTAssertEqual(model.videoElapsed,0)
            guard results.count > count else { return }
            if case .failure(let error) = results[count] { XCTAssertTrue(error is CancellationError) }
            let elapsed = CACurrentMediaTime()-began
            let restoredWB = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0?.whiteBalanceMode) } }
            XCTAssertEqual(restoredWB,previousWB)
            try await Task.sleep(for:.milliseconds(200))
            XCTAssertEqual(results.count,count+1)
            print("VIDEO-WB-START-CANCEL round=\(round) completion=\(elapsed) callbacks=\(results.count)")
        }
        // 取消后的新请求仍可真实录制，旧白平衡回调不得重新创建旧写入器或清掉新状态。
        let count = results.count
        model.toggleVideoRecording()
        for _ in 0..<400 { if camera.videoRecording { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.videoRecording)
        try await Task.sleep(for:.milliseconds(350))
        camera.stopVideoRecording()
        for _ in 0..<400 { if results.count > count && !camera.videoBusy { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(results.count,count+1)
        let url = try XCTUnwrap(results.last).get()
        let asset = AVURLAsset(url:url)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertGreaterThan(frames,1); XCTAssertEqual(reader.status,.completed)
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(results.count,count+1)
        let finalWB = await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning:$0?.whiteBalanceMode) } }
        XCTAssertEqual(finalWB,previousWB)
        print("VIDEO-WB-START-RECOVER callbacks=\(results.count) decodedFrames=\(frames)")
    }
    #endif
}

private struct TimeLapseControlsHost: View {
    @ObservedObject var model: CameraViewModel
    let width: CGFloat

    var body: some View {
        CameraView(model: model).fixedCameraControls(width: width)
            .preferredColorScheme(.dark).background(Color.black).ignoresSafeArea()
    }
}

private final class VideoSavingStub: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var completion: ((Result<String, Error>) -> Void)?
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.denied) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest { completion(nil, nil); return PhotoImageRequest(cancel: {}) }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.failure(PhotoLibraryError.writeDenied)) }
    func saveVideo(at url: URL, completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.failure(PhotoLibraryError.readDenied)) }
}
