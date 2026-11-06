import AVFoundation
import XCTest
@testable import LumaCamera

final class CaptureStatePersistenceTests: XCTestCase {
    /// 停在 M 挡冷启动也应记住 A 挡的预设与自定义时长；旧存档仍可解码。
    @MainActor func testSlowShutterAutomaticPresetSurvivesManualRecreation() throws {
        let name = "SlowShutterAutomaticMemory-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        var state = SavedCaptureState()
        state.mode = "M"; state.photoMode = "M"; state.slowShutter = true
        state.slowShutterDuration = SlowShutterDuration.s1.rawValue
        state.slowShutterAutomaticPreset = SlowShutterPreset.lightTrails.rawValue
        state.slowShutterAutomaticDuration = SlowShutterDuration.s30.rawValue
        store.saveCaptureState(state)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertEqual(model.mode, .manual); XCTAssertTrue(model.slowShutterEnabled)
        XCTAssertNil(model.selectedSlowShutterPreset); XCTAssertEqual(model.slowShutterDuration, .s1)
        model.setMode(.auto)
        XCTAssertEqual(model.selectedSlowShutterPreset, .lightTrails)
        XCTAssertEqual(model.slowShutterDuration, .s30)
        model.flushCaptureSettings()
        XCTAssertEqual(store.loadCaptureState()?.slowShutterAutomaticPreset, SlowShutterPreset.lightTrails.rawValue)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "slowShutterAutomaticPreset")
        object.removeValue(forKey: "slowShutterAutomaticDuration")
        XCTAssertNoThrow(try JSONDecoder().decode(SavedCaptureState.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    /// 用户取消预设后的自定义延时组合，重开不能重新套用人流预设。
    @MainActor func testCustomTimeLapseWithoutPresetSurvivesRecreation() throws {
        let name = "CustomTimeLapse-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        var state = SavedCaptureState()
        state.video = true; state.timeLapseEnabled = true; state.timeLapsePreset = nil
        state.timeLapseInterval = TimeLapseInterval.s5.rawValue
        state.timeLapseFrameCount = TimeLapseFrameCount.f60.rawValue
        store.saveCaptureState(state)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertTrue(model.timeLapseEnabled)
        XCTAssertNil(model.selectedTimeLapsePreset)
        XCTAssertEqual(model.timeLapseInterval, .s5)
        XCTAssertEqual(model.timeLapseFrameCount, .f60)
        model.flushCaptureSettings()
        XCTAssertNil(store.loadCaptureState()?.timeLapsePreset)
    }

    @MainActor func testDualCapturePreferenceRoundTripAndLegacyDefault() throws {
        let name = "DualCapturePreferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        var state = SavedCaptureState(); state.video = true; state.dualCaptureEnabled = true
        store.saveCaptureState(state)
        XCTAssertEqual(store.loadCaptureState()?.dualCaptureEnabled, true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "dualCaptureEnabled")
        let legacy = try JSONDecoder().decode(SavedCaptureState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.dualCaptureEnabled)
    }

    /// 停在照片冷启动也不能丢失视频挡位；旧存档继续按原视频 mode 迁移。
    @MainActor func testIndependentVideoModePersistsWhilePhotoIsSelected() throws {
        let name = "IndependentModes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        model.setCaptureKind(.video); model.setMode(.manual)
        model.setCaptureKind(.photo)
        XCTAssertEqual(model.mode, .auto)
        model.flushCaptureSettings()
        XCTAssertEqual(store.loadCaptureState()?.videoMode, "M")
        let restored = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        restored.setCaptureKind(.video)
        XCTAssertEqual(restored.mode, .manual)
        restored.setCaptureKind(.photo)
        XCTAssertEqual(restored.mode, .auto)
        var legacy = SavedCaptureState(); legacy.video = true; legacy.mode = "M"
        store.saveCaptureState(legacy)
        let migrated = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        migrated.setCaptureKind(.photo); migrated.setCaptureKind(.video)
        XCTAssertEqual(migrated.mode, .manual)
    }

    /// 冷启动停在视频后返回照片，不能丢失视频帧周期限制之前的长快门与手动标志。
    @MainActor func testPhotoManualExposureSurvivesVideoClampAndModelRecreation() throws {
        let name = "PhotoManualAcrossVideo-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        model.setMode(.manual)
        model.manualExposure = true; model.iso = 200; model.shutter = log2(0.5)
        model.setCaptureKind(.video); model.setMode(.manual)
        model.shutter = log2(1.0 / 30)
        model.flushCaptureSettings()
        let restored = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertEqual(restored.shutter, log2(1.0 / 30), accuracy: 0.0001)
        restored.setCaptureKind(.photo)
        XCTAssertEqual(restored.mode, .manual)
        XCTAssertTrue(restored.manualExposure)
        XCTAssertEqual(restored.iso, 200)
        XCTAssertEqual(restored.shutter, log2(0.5), accuracy: 0.0001)
    }

    @MainActor func testAllCaptureChoicesAndManualFlagsSurviveModelRecreation() throws {
        let name = "CaptureState-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        model.setMode(.manual)
        model.manualExposure = true; model.manualWB = true; model.manualFocus = true
        model.iso = 900; model.shutter = -8; model.wb = 6200; model.whiteBalanceTint = 25; model.focus = 0.72; model.ev = -1.2
        model.photoFormat = .heifPro; model.photoResolution = .standard; model.hdr = true
        model.ratio = .cinema; model.flashMode = .auto; model.tone = .natural
        model.style = .leicaM9; model.intensity = 0.94; model.filterAdjustments[.saturation] = 30
        model.grid = false; model.level = false; model.showHistogram = true; model.focusPeaking = true; model.timerSeconds = 3
        model.showsAudioMeter = true; model.showsRecordingCapacity = true
        model.rotatePreview(); model.toolPage = 1
        model.preferences.copyright = "Test Author"
        model.setCaptureKind(.video); model.setMode(.manual)
        model.videoResolution = .uhd4K; model.videoFrameRate = .fps60; model.videoRatio = .wide
        model.videoColorSpace = .p3; model.videoCodec = .proRes; model.proResSpecification = .standard
        model.flushCaptureSettings()
        let stored = try XCTUnwrap(store.loadCaptureState())
        let restored = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertEqual(restored.captureKind, .video); XCTAssertEqual(restored.mode, .manual)
        XCTAssertTrue(restored.manualExposure); XCTAssertTrue(restored.manualWB); XCTAssertTrue(restored.manualFocus)
        XCTAssertEqual(restored.iso, 900); XCTAssertEqual(restored.shutter, -8)
        XCTAssertEqual(restored.wb, 6200); XCTAssertEqual(restored.whiteBalanceTint, 25); XCTAssertEqual(restored.focus, 0.72)
        XCTAssertEqual(restored.ev, -1.2); XCTAssertEqual(restored.photoFormat, .heifPro); XCTAssertEqual(restored.photoResolution, .standard)
        XCTAssertEqual(restored.style, .leicaM9); XCTAssertEqual(restored.intensity, 0.94)
        XCTAssertEqual(restored.filterAdjustments, model.filterAdjustments)
        XCTAssertEqual(restored.videoResolution, .uhd4K); XCTAssertEqual(restored.videoFrameRate, .fps60)
        XCTAssertEqual(restored.videoRatio, .wide); XCTAssertEqual(restored.videoColorSpace, .p3)
        XCTAssertEqual(restored.videoCodec, .proRes); XCTAssertEqual(restored.proResSpecification, .standard)
        XCTAssertFalse(restored.grid); XCTAssertFalse(restored.level); XCTAssertTrue(restored.showHistogram); XCTAssertTrue(restored.focusPeaking)
        XCTAssertTrue(restored.showsAudioMeter); XCTAssertTrue(restored.showsRecordingCapacity)
        XCTAssertEqual(restored.previewQuarterTurns, 1); XCTAssertEqual(restored.toolPage, 1)
        XCTAssertFalse(restored.camera.videoRecording); XCTAssertNil(restored.panel); XCTAssertNil(restored.toolbarPanel)
        XCTAssertEqual(store.loadCaptureState(), stored, "Startup cannot overwrite saved framing before hardware restoration")
        restored.setCaptureKind(.photo)
        XCTAssertEqual(restored.mode, .manual); XCTAssertEqual(restored.ratio, .cinema)
    }

    @MainActor func testDisabledUsesRequestedPhotoAndVideoDefaultsAndRetainsPreferences() throws {
        let name = "CaptureDefaults-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        var prefs = CapturePreferences(); prefs.saveCaptureSettings = false
        prefs.recordLocation = true; prefs.copyright = "Keep Me"; prefs.silentShutter = true
        store.save(prefs)
        var stale = SavedCaptureState(); stale.video = true; stale.mode = "M"; stale.photoFormat = "HEIF Pro"
        stale.videoCodec = "ProRes"; stale.videoFrameRate = 120; stale.live = true
        store.saveCaptureState(stale)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertNil(store.loadCaptureState())
        XCTAssertEqual(model.captureKind, .photo); XCTAssertEqual(model.mode, .auto)
        XCTAssertEqual(model.photoFormat, .jpeg); XCTAssertEqual(model.ratio, .standard)
        XCTAssertEqual(model.flashMode, .off); XCTAssertFalse(model.livePhotoEnabled); XCTAssertFalse(model.hdr)
        XCTAssertEqual(model.style, .original); XCTAssertTrue(model.filterAdjustments.isNeutral)
        XCTAssertFalse(model.manualExposure); XCTAssertFalse(model.manualWB); XCTAssertFalse(model.manualFocus)
        XCTAssertEqual(model.videoResolution, .hd1080); XCTAssertEqual(model.videoFrameRate, .fps30)
        XCTAssertEqual(model.videoRatio, .ratio16x9); XCTAssertEqual(model.videoColorSpace, .sdr); XCTAssertEqual(model.videoCodec, .hevc)
        XCTAssertTrue(model.preferences.recordLocation); XCTAssertEqual(model.preferences.copyright, "Keep Me"); XCTAssertTrue(model.preferences.silentShutter)
        model.setCaptureKind(.video)
        XCTAssertEqual(model.mode, .auto); XCTAssertEqual(model.ratio, .wide)
        model.videoFrameRate = .fps60; model.setMode(.manual); model.style = .leicaM9
        model.flushCaptureSettings()
        XCTAssertNil(store.loadCaptureState())
        // Enabling records the state at that moment, not stale state from before disabling.
        model.preferences.saveCaptureSettings = true
        XCTAssertEqual(store.loadCaptureState()?.videoFrameRate, 60)
        XCTAssertEqual(store.loadCaptureState()?.mode, "M")
        model.preferences.saveCaptureSettings = false
        XCTAssertNil(store.loadCaptureState())
    }

    @MainActor func testVideoOpenGateChoicePersistsAndLegacyRatioMigrates() throws {
        let name = "CaptureOpenGate-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        var preferences = CapturePreferences(); preferences.saveCaptureSettings = true
        store.save(preferences)

        var state = SavedCaptureState()
        state.video = true; state.videoRatio = "1:1"; state.videoOpenGate = true
        store.saveCaptureState(state)
        let restored = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertEqual(restored.captureKind, .video)
        XCTAssertEqual(restored.videoRatio, .square)
        XCTAssertTrue(restored.videoOpenGateEnabled)

        state.videoRatio = "Open Gate"; state.videoOpenGate = nil
        store.saveCaptureState(state)
        let migrated = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        XCTAssertEqual(migrated.videoRatio, .ratio4x3)
        XCTAssertTrue(migrated.videoOpenGateEnabled)
    }

    @MainActor func testCorruptAndFutureStatesAreIgnoredAndBurstUpdatesFlushLatest() async throws {
        let name = "CaptureStress-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CapturePreferencesStore(defaults: defaults)
        defaults.set(Data("invalid".utf8), forKey: "capture.state.v1")
        XCTAssertNil(store.loadCaptureState())
        var future = SavedCaptureState(); future.version = 999; store.saveCaptureState(future)
        XCTAssertNil(store.loadCaptureState())
        store.clearCaptureState()
        let model = AppDependencies.makeCameraModel(automaticallySave: false, preferencesStore: store)
        let start = CACurrentMediaTime()
        for i in 0..<200 {
            model.iso = Double(100 + i); model.ev = Double(i % 11) / 10
            model.grid.toggle(); model.showsAudioMeter.toggle()
        }
        model.flushCaptureSettings()
        XCTAssertEqual(store.loadCaptureState()?.manual.iso, 299)
        XCTAssertEqual(store.loadCaptureState()?.manual.ev, model.ev)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.loadCaptureState()?.manual.iso, 299)
        model.preferences.saveCaptureSettings = false
        model.iso = 800
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(store.loadCaptureState(), "A cancelled delayed write cannot resurrect a disabled snapshot")
        print("CAPTURE-STATE-STRESS changes=800 elapsed=\(CACurrentMediaTime()-start); includes two 350ms cancellation waits, not frame rate")
    }
    @MainActor func test48MPRemembersAutomaticExposureWithoutChangingWBOrFocusFlags() throws {
        let name=UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let store=CapturePreferencesStore(defaults:defaults)
        let model=AppDependencies.makeCameraModel(automaticallySave:false,preferencesStore:store)
        model.setMode(.manual);model.manualExposure=true;model.manualWB=true;model.manualFocus=true
        model.photoResolution = .high
        model.flushCaptureSettings()
        let restored=AppDependencies.makeCameraModel(automaticallySave:false,preferencesStore:store)
        XCTAssertEqual(restored.photoResolution,.high)
        XCTAssertFalse(restored.manualExposure)
        XCTAssertTrue(restored.manualWB);XCTAssertTrue(restored.manualFocus)
    }

}
