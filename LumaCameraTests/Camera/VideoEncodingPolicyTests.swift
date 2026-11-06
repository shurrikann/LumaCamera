import AVFoundation
import XCTest
@testable import LumaCamera

final class VideoEncodingPolicyTests: XCTestCase {
    func testRAWConfigurationNeverQueriesSystemMetadataBeforeWhiteBalanceLocks() {
        var queries = 0
        for _ in 0..<20 {
            for mode in [AVCaptureDevice.WhiteBalanceMode.autoWhiteBalance, .continuousAutoWhiteBalance] {
                XCTAssertThrowsError(try RAWVideoWriterConfiguration.read(whiteBalanceMode: mode,
                    videoSettings: { queries += 1; return [:] },
                    metadata: { queries += 1; return [] }))
            }
        }
        XCTAssertEqual(queries, 0, "Do not enter AVFoundation's exception-throwing RAW metadata API before locking")
    }

    func testRAWConfigurationPreservesRecommendedSettingsAndMetadataInOrder() throws {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataMake
        item.value = "Apple" as NSString
        var queries: [String] = []
        let configuration = try RAWVideoWriterConfiguration.read(whiteBalanceMode: .locked,
            videoSettings: { queries.append("settings"); return [AVVideoWidthKey: 4224] },
            metadata: { queries.append("metadata"); return [item] })
        XCTAssertEqual(queries, ["settings", "metadata"])
        XCTAssertEqual(configuration.videoSettings[AVVideoWidthKey] as? Int, 4224)
        XCTAssertTrue(configuration.metadata.first === item)
    }

    func testRAWConfigurationDoesNotQueryMetadataForRejectedDestination() {
        var queriedMetadata = false
        XCTAssertThrowsError(try RAWVideoWriterConfiguration.read(whiteBalanceMode: .locked,
            videoSettings: { nil }, metadata: { queriedMetadata = true; return [] }))
        XCTAssertFalse(queriedMetadata)
    }

    func testVideoWhiteBalanceLockIsOptInExceptForRAWRequirements() {
        XCTAssertFalse(VideoWhiteBalancePolicy.requiresLocking(isRAW: false, userPreference: false))
        XCTAssertTrue(VideoWhiteBalancePolicy.requiresLocking(isRAW: false, userPreference: true))
        XCTAssertTrue(VideoWhiteBalancePolicy.requiresLocking(isRAW: true, userPreference: false))
        XCTAssertTrue(VideoWhiteBalancePolicy.requiresLocking(isRAW: true, userPreference: true))
    }

    func testExternalRecordingAccessCanBeReleasedAtWriterCompletionAndOnlyOnce() {
        var stopCount = 0
        let access = ExternalVideoStorage.RecordingAccess { stopCount += 1 }

        access.stop()
        access.stop()

        XCTAssertEqual(stopCount, 1, "Finishing the writer must relinquish its external URL scope exactly once")
    }

    func testExternalRecordingAccessReleasesScopeWhenRecorderSetupFails() {
        var stopCount = 0
        do {
            let access: ExternalVideoStorage.RecordingAccess? = ExternalVideoStorage.RecordingAccess {
                stopCount += 1
            }
            XCTAssertNotNil(access)
        }

        XCTAssertEqual(stopCount, 1, "An untransferred destination must not leak its security scope")
    }

    func testStorageRejectsUnknownSpaceDisconnectionAndSystemWarnings() {
        XCTAssertTrue(ExternalVideoStorage.eligible(connected: true, freeBytes: 5_000_000_000, recommended: true))
        XCTAssertFalse(ExternalVideoStorage.eligible(connected: false, freeBytes: 5_000_000_000, recommended: true))
        XCTAssertFalse(ExternalVideoStorage.eligible(connected: true, freeBytes: -1, recommended: true))
        XCTAssertFalse(ExternalVideoStorage.eligible(connected: true, freeBytes: 2_000_000_000, recommended: true))
        XCTAssertFalse(ExternalVideoStorage.eligible(connected: true, freeBytes: 5_000_000_000, recommended: false))
    }

    func testBitratePresetAppliesOnlyToHEVCAndH264() {
        let presets: [VideoBitratePreset] = [.systemDefault, .low, .medium, .high]
        for preset in presets {
            let hevc = VideoCaptureSettings(codec: .hevc, bitratePreset: preset)
            let h264 = VideoCaptureSettings(codec: .h264, bitratePreset: preset)
            let proRes = VideoCaptureSettings(codec: .proRes, proRes: .hq, bitratePreset: preset)
            XCTAssertEqual(hevc.writerAverageBitRate, preset == .systemDefault ? nil : hevc.bitRate)
            XCTAssertEqual(h264.writerAverageBitRate, preset == .systemDefault ? nil : h264.bitRate)
            XCTAssertNil(proRes.writerAverageBitRate)
            XCTAssertEqual(proRes.bitRate, VideoCaptureSettings(codec: .proRes, proRes: .hq).bitRate)
        }
    }

    func testH264FallsBackToSDRWithoutDiscardingCodec() throws {
        let hdr = VideoCaptureSettings(colorSpace: .hdr, codec: .h264)
        let resolved = try XCTUnwrap(VideoCaptureSettings.resolved(hdr, supported: [.init(), .init(colorSpace: .hdr)]))
        XCTAssertEqual(resolved.codec, .h264); XCTAssertEqual(resolved.colorSpace, .sdr)
        XCTAssertFalse(resolved.isRAW)
        XCTAssertTrue(VideoCaptureSettings(codec: .proRes, proRes: .raw).isRAW)
        XCTAssertGreaterThan(VideoCaptureSettings(codec: .proRes).bitRate, VideoCaptureSettings().bitRate)
    }

    func testExternalRAWCapacityShowsSpaceAndApproximateRemainingTime() throws {
        let info = try XCTUnwrap(RecordingCapacity.info(videoBitsPerSecond: 500_000_000,
            externalCapacity: .init(freeBytes: 5_000_000_000, totalBytes: 10_000_000_000)))
        XCTAssertTrue(info.isExternal)
        XCTAssertTrue(info.isEstimated)
        XCTAssertEqual(info.usedPercent, 50)
        XCTAssertEqual(info.freeText, "5GB / 10GB")
        XCTAssertEqual(info.timeText, "00:01:16")
    }
}
