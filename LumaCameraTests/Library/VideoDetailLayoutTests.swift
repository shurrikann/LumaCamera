import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class VideoDetailLayoutTests: XCTestCase {
    @MainActor func testLiveSelectionMovesThreeSecondsAndRestoresVideoTrim() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        for seconds in [1, 16] {
            let url = try await makeVideo(seconds: seconds)
            defer { try? FileManager.default.removeItem(at: url) }
            let photo = LibraryPhoto(id: "live-range-\(seconds)", date: Date(), hasFilter: false,
                                     isVideo: true, duration: Double(seconds),
                                     videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
            let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
            defer { editor.cancel() }
            for _ in 0..<200 {
                if !editor.loading { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(editor.loading)
            XCTAssertFalse(editor.isToolPanelPresented)
            editor.selectTool(.trim)
            XCTAssertTrue(editor.isToolPanelPresented)
            editor.selectTool(.trim)
            XCTAssertFalse(editor.isToolPanelPresented)
            editor.setTrimStart(0.2)
            let previous = (editor.trimStart, editor.trimEnd)
            for _ in 0..<20 {
                editor.toggleLivePhotoSelection()
                XCTAssertEqual(editor.selectedTrimDuration, min(3, Double(seconds)), accuracy: 0.001)
                XCTAssertEqual(editor.livePhotoDurationLabel, seconds == 1 ? "1s" : "3s")
                editor.moveLivePhotoSelection(to: 100)
                XCTAssertEqual(editor.trimEnd, Double(seconds), accuracy: 0.05)
                editor.moveLivePhotoSelection(to: -100)
                XCTAssertEqual(editor.trimStart, 0)
                editor.setTrimEnd(Double(seconds))
                XCTAssertEqual(editor.selectedTrimDuration, min(3, Double(seconds)), accuracy: 0.001)
                editor.toggleLivePhotoSelection()
                XCTAssertEqual(editor.trimStart, previous.0)
                XCTAssertEqual(editor.trimEnd, previous.1)
            }
            editor.toggleLivePhotoSelection()
            var samples: [Double] = []
            for _ in 0..<3 {
                let began = ProcessInfo.processInfo.systemUptime
                for step in 0..<20 { editor.moveLivePhotoSelection(to: Double(step) * 0.2) }
                editor.finishTrimDrag()
                try await waitForTrimPreview(editor, near: editor.trimStart)
                samples.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
            let attachment = XCTAttachment(string: "sourceSeconds=\(seconds) bursts=3 eventsPerBurst=20 settleMs=\(samples)")
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThan(samples.max() ?? .infinity, 1500)
            editor.resetTrim()
            XCTAssertFalse(editor.isSelectingLivePhoto)
            XCTAssertEqual(editor.trimStart, 0)
            XCTAssertEqual(editor.trimEnd, editor.duration)
            editor.cancel()
            XCTAssertFalse(editor.isSeekingTrimPreview)
        }
    }

    @MainActor func testLivePanelPresentationRepeatedlyAndCaptureLayout() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo(seconds: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        let photo = LibraryPhoto(id: "live-layout", date: Date(), hasFilter: false, isVideo: true, duration: 16,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        let host = UIHostingController(rootView: VideoEditorView(model: editor))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { editor.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<200 {
            if !editor.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for shown in [false, true] {
            if shown { editor.selectTool(.trim); editor.toggleLivePhotoSelection() }
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = shown ? "Live selected panel" : "Editor initially collapsed"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for _ in 0..<20 {
            withAnimation(.easeInOut(duration: 0.1)) { editor.selectTool(.trim) }
            try await Task.sleep(for: .milliseconds(30))
            withAnimation(.easeInOut(duration: 0.1)) { editor.selectTool(.trim) }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(editor.isToolPanelPresented)
        XCTAssertEqual(editor.selectedTrimDuration, 3, accuracy: 0.001)
    }

    @MainActor func testSDRVideoFilterPopupUsesBottomPanelAndDialPad() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let photo = LibraryPhoto(id: "video-filter-popup", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        editor.selectTool(.filters)
        editor.style = .leicaM9
        let filters = FilterPickerViewModel()
        filters.showStrength = true
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VideoFilterPopup(model: editor, filters: filters, onClose: {})
            .frame(width: 390, height: 620))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<50 {
            if editor.captureButtonFramesForTesting["video.filter.popup"] != nil,
               editor.filterDialPadFrameForTesting.height > 200 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let popup = try XCTUnwrap(editor.captureButtonFramesForTesting["video.filter.popup"])
        XCTAssertGreaterThan(popup.height, 300)
        XCTAssertGreaterThan(editor.filterDialPadFrameForTesting.height, 200,
                             "SDR视频滤镜参数应复用调色盘")
        XCTAssertTrue(editor.filterDialControlsEnabled)
        let pair = editor.filterParameterPairBinding(.temperature, .tint)
        pair.wrappedValue = CGPoint(x: 21, y: 12)
        XCTAssertEqual(pair.wrappedValue, CGPoint(x: 21, y: 12))
        editor.filterParameterBinding(.strength).wrappedValue = 42
        XCTAssertEqual(editor.intensity, 0.42, accuracy: 0.001)
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: shot)
        attachment.name = "Video-SDR-Filter-Dial"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testVideoFilterDialAndToolPopupsKeepPreviewStable() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let photo = LibraryPhoto(id: "video-dial", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        let host = UIHostingController(rootView: VideoEditorView(model: editor))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { editor.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<150 {
            if !editor.loading, editor.captureButtonFramesForTesting["preview"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(editor.loading)
        let preview = try XCTUnwrap(editor.captureButtonFramesForTesting["preview"])
        var timings: [Double] = []
        for _ in 0..<3 {
            for tool in editor.availableTools.filter({ $0 != .adjustments }) {
                let key = "tool." + tool.title
                let before = try XCTUnwrap(editor.captureButtonFramesForTesting[key])
                editor.captureButtonFramesForTesting["panel"] = nil
                let start = CACurrentMediaTime()
                editor.selectTool(tool)
                for _ in 0..<100 {
                    if editor.captureButtonFramesForTesting["panel"] != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                timings.append((CACurrentMediaTime() - start) * 1000)
                if tool == .filters, !editor.isLogVideo {
                    for _ in 0..<100 {
                        if editor.captureButtonFramesForTesting["video.filter.popup"] != nil { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let popup = try XCTUnwrap(editor.captureButtonFramesForTesting["video.filter.popup"])
                    XCTAssertGreaterThan(popup.width, before.width)
                    XCTAssertGreaterThanOrEqual(popup.maxY, before.maxY)
                    XCTAssertEqual(editor.captureButtonFramesForTesting["preview"], preview)
                    XCTAssertEqual(editor.captureButtonFramesForTesting[key], before)
                    try await Task.sleep(for: .milliseconds(220))
                    let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: shot)
                    attachment.name = "Video-SDR-Filter-Bottom"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    editor.closeToolPanel()
                    continue
                }
                let panel = try XCTUnwrap(editor.captureButtonFramesForTesting["panel"])
                XCTAssertEqual(panel.maxY, before.minY - 8, accuracy: 1)
                XCTAssertEqual(editor.captureButtonFramesForTesting["preview"], preview)
                XCTAssertEqual(editor.captureButtonFramesForTesting[key], before)
                if tool == .adjustments {
                    XCTAssertGreaterThan(editor.filterDialPadFrameForTesting.height, 160)
                    let pair = editor.filterParameterPairBinding(.temperature, .tint)
                    pair.wrappedValue = CGPoint(x: 21, y: 12)
                    XCTAssertEqual(pair.wrappedValue, CGPoint(x: 21, y: 12))
                    editor.presentFilterNumericInput(.temperature)
                    editor.filterNumericDraft = "32"
                    editor.dismissFilterNumericInput()
                    XCTAssertEqual(editor.value(for: .temperature), 21)
                    editor.presentFilterNumericInput(.temperature)
                    editor.filterNumericDraft = "32"
                    editor.confirmFilterNumericInput()
                    XCTAssertEqual(editor.value(for: .temperature), 32)
                    editor.closeToolPanel()
                    pair.wrappedValue = CGPoint(x: 8, y: 4)
                    XCTAssertEqual(editor.value(for: .temperature), 32)
                    XCTAssertFalse(editor.isToolPanelPresented)
                }
            }
        }
        print("VIDEO-TOOL-LAYOUT samples=\(timings.count) firstLayoutMs=\(timings)")
        // 视频宿主首次展开 SDR 滤镜底部面板包含 AVPlayer/缩略图布局；
        // 目前实测约 1.1–1.25s，不能用拍照页的 500ms 预算。
        XCTAssertLessThan(timings.max() ?? .infinity, 1500)
    }

    @MainActor func testVideoSavePopupIsBottomGlassPanel() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let photo = LibraryPhoto(id: "video-save-popup", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VideoEditorView(model: editor, initialSaveChoicePresented: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<100 {
            if editor.captureButtonFramesForTesting["video.save.popup"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let popup = try XCTUnwrap(editor.captureButtonFramesForTesting["video.save.popup"])
        XCTAssertGreaterThan(popup.width, 300)
        XCTAssertGreaterThan(popup.height, 150)
        XCTAssertGreaterThan(popup.maxY, window.bounds.height - 80)
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: shot)
        attachment.name = "Video-Save-Bottom"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLogVideoFilterPopupUsesBottomPanelAndCategories() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let photo = LibraryPhoto(id: "video-log-filter-popup", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: "LOG", hasFilter: false, colorSpace: .appleLog))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(editor.isLogVideo)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VideoEditorView(model: editor))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        editor.selectTool(.filters)
        for _ in 0..<100 {
            if editor.captureButtonFramesForTesting["video.logFilter.popup"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let popup = try XCTUnwrap(editor.captureButtonFramesForTesting["video.logFilter.popup"])
        XCTAssertGreaterThan(popup.width, 300)
        XCTAssertGreaterThan(popup.maxY, window.bounds.height - 80)
        XCTAssertTrue(editor.logLUTOptions.contains { $0.id == editor.selectedLogLUTID })
        for _ in 0..<150 {
            if editor.logLUTThumbnails.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(editor.logLUTThumbnails.count, 4, "Log LUT 卡应加载缩略图")
        editor.selectLogLUTCategory(.favorites)
        XCTAssertTrue(editor.logLUTOptions.allSatisfy { editor.logLUTFavorites.contains($0.id) })
        editor.selectLogLUTCategory(.all)
        try await Task.sleep(for: .milliseconds(500))
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: shot)
        attachment.name = "Video-Log-Filter-Bottom"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLiveFilterAdjustmentsReuseOnePreviewComposition() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let photo = LibraryPhoto(id: "video-live-preview", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        editor.selectTool(.filters)
        editor.style = .leicaM9
        for _ in 0..<100 {
            if editor.previewCompositionBuildCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.previewCompositionBuildCount, 1)
        for value in stride(from: 0.2, through: 0.9, by: 0.1) {
            editor.intensity = value
            editor.filterParameterBinding(.temperature).wrappedValue = value * 30
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(editor.previewCompositionBuildCount, 1, "拖动参数不能逐值重建视频合成")
        XCTAssertNil(editor.message)
    }

    @MainActor func testPausedFilterEditingShowsImmediatePreviewOverlay() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let photo = LibraryPhoto(id: "video-live-overlay", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        editor.selectTool(.filters)
        editor.style = .leicaM9
        editor.setFilterParameterEditing(true)
        editor.filterParameterBinding(.temperature).wrappedValue = 28
        for _ in 0..<100 {
            if editor.liveFilterPreview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(editor.liveFilterPreview, "暂停拖动滤镜参数时应立即显示当前帧预览")
        editor.setFilterParameterEditing(false)
        for _ in 0..<30 {
            if editor.liveFilterPreview == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(editor.liveFilterPreview, "结束拖动后应回到播放器合成帧")
    }

    @MainActor func testVideoEditorLivePreviewReactsToGrainSize() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let photo = LibraryPhoto(id: "video-grain-preview", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        editor.selectTool(.filters)
        editor.style = .leicaM9
        editor.setFilterParameterEditing(true)
        editor.filterParameterBinding(.grainSize).wrappedValue = 0
        for _ in 0..<100 { if editor.liveFilterPreview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let before = try XCTUnwrap(editor.liveFilterPreview?.pngData())
        editor.filterParameterBinding(.grainSize).wrappedValue = 90
        var after: Data?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            let candidate = editor.liveFilterPreview?.pngData()
            if let candidate, candidate != before { after = candidate; break }
        }
        XCTAssertNotNil(after, "颗粒大小变化必须反映到视频编辑实时预览")
        editor.setFilterParameterEditing(false)
    }

    @MainActor func testPausedGrainPreviewChangesPhaseInsteadOfLookingLikeMask() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let photo = LibraryPhoto(id: "video-grain-animation", date: Date(), hasFilter: false, isVideo: true, duration: 1,
                                 videoBadges: VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr))
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<150 { if !editor.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        editor.selectTool(.filters)
        editor.style = .leicaM9
        editor.setFilterParameterEditing(true)
        editor.filterParameterBinding(.grainSize).wrappedValue = 90
        for _ in 0..<100 {
            if editor.liveFilterPreview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let first = try XCTUnwrap(editor.liveFilterPreview?.pngData())
        var changed = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(40))
            if editor.liveFilterPreview?.pngData() != first { changed = true; break }
        }
        XCTAssertTrue(changed, "暂停颗粒预览必须逐帧变化，不能固定成蒙版")
        editor.setFilterParameterEditing(false)
    }

    @MainActor func testDraggingTrimHandlesSeeksThePreviewToEachCutPoint() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let badges = VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr)
        let photo = LibraryPhoto(id: "trim-preview-seek-test", date: Date(), hasFilter: false,
                                 isVideo: true, duration: 1, videoBadges: badges)
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: url), photo: photo, library: app.library)
        defer { editor.cancel() }

        for _ in 0..<100 {
            if !editor.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(editor.loading)
        XCTAssertEqual(editor.duration, 1, accuracy: 0.05)

        editor.setTrimStart(0.25)
        try await waitForTrimPreview(editor, near: 0.25)
        XCTAssertEqual(editor.player.currentTime().seconds, 0.25, accuracy: 0.12)
        XCTAssertEqual(editor.playheadTime, 0.25, accuracy: 0.12)

        editor.setTrimEnd(0.8)
        try await waitForTrimPreview(editor, near: 0.8)
        XCTAssertEqual(editor.player.currentTime().seconds, 0.8, accuracy: 0.12)
        editor.finishTrimDrag()
        XCTAssertEqual(editor.playerItem.forwardPlaybackEndTime.seconds, 0.8, accuracy: 0.001)

        var settleMilliseconds: [Double] = []
        var coalescedSeekCount = 0
        for sample in 0..<3 {
            let requestsBefore = editor.trimPreviewSeekRequestCount
            let began = ProcessInfo.processInfo.systemUptime
            for update in 0..<20 {
                editor.setTrimEnd(0.75 + Double(sample) * 0.04 + Double(update) * 0.0025)
            }
            let finalPoint = editor.trimEnd
            try await waitForTrimPreview(editor, near: finalPoint)
            settleMilliseconds.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
            let requestCount = editor.trimPreviewSeekRequestCount - requestsBefore
            coalescedSeekCount += requestCount
            XCTAssertLessThan(requestCount, 20, "A 20-event drag burst should coalesce player seeks")
            editor.finishTrimDrag()
        }
        XCTAssertLessThan(settleMilliseconds.max() ?? .infinity, 1_500,
                          "Rapid trim updates should settle promptly on a local video asset")
        XCTAssertEqual(editor.player.currentTime().seconds, editor.trimEnd, accuracy: 0.12,
                       "Rapid handle updates should settle on the latest trim point")
        let meanSettle = settleMilliseconds.reduce(0, +) / Double(settleMilliseconds.count)
        let report = "bursts=3 updatesPerBurst=20 seekRequests=\(coalescedSeekCount) meanSettleMs=\(String(format: "%.1f", meanSettle)) maxSettleMs=\(String(format: "%.1f", settleMilliseconds.max() ?? 0))"
        let metricsAttachment = XCTAttachment(string: report)
        metricsAttachment.name = "Trim preview seek coalescing metrics"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)
    }

    @MainActor func testEditedVideoCanBeExportedAsAStandaloneFilesCopy() async throws {
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let sourceURL = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let badges = VideoCaptureBadges(logLabel: nil, hasFilter: false, colorSpace: .sdr)
        let photo = LibraryPhoto(id: "video-files-export-test", date: Date(), isVideo: true,
                                 duration: 1, videoBadges: badges)
        let editor = VideoEditorViewModel(asset: AVURLAsset(url: sourceURL), photo: photo, library: app.library)
        defer { editor.cancel() }
        for _ in 0..<100 {
            if !editor.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(editor.loading)
        editor.setTrimStart(0.1)
        editor.setTrimEnd(0.8)

        let exportedURL = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            editor.exportToFiles { continuation.resume(returning: $0) }
        }
        let outputURL = try XCTUnwrap(exportedURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        XCTAssertNotEqual(outputURL, sourceURL, "Files export must preserve the original video.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertTrue(app.library.beginEditing(), "The export path must release the library editing lock before presenting Files.")
        app.library.endEditing()
    }

    @MainActor func testVideoEditorCanOpenFromFullscreenCoverWithStoredFilter() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let badges = VideoCaptureBadges(logLabel: nil, hasFilter: true, colorSpace: .sdr,
                                        filmStyleID: FilmStyle.food.rawValue, filterIntensity: 0.8)
        let photo = LibraryPhoto(id: "video-editor-entry-test", date: Date(), hasFilter: true,
                                 isVideo: true, duration: 1, videoBadges: badges)
        let host = UIHostingController(rootView: VideoEditorPresentationHarness(asset: asset, photo: photo, library: model.library))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        for _ in 0..<100 {
            if host.presentedViewController != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(host.presentedViewController, "The video editor full-screen presentation must open")
        // Allow AVAsset duration loading, Core Image composition creation, player setup,
        // and asynchronous filter thumbnail preparation to complete while the view is live.
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(host.presentedViewController?.isBeingDismissed == false)
    }

    @MainActor func testVideoPlaybackRotatesWithoutMovingHeaderOrActions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let photo = LibraryPhoto(id: "layout-video", date: Date(timeIntervalSince1970: 1_792_339_200),
                                 isAstroCapture: true, hasFilter: true, isVideo: true, duration: 3661, logLabel: "LOG2")
        // Inject a real temporary video; never request Photos permission or start the camera.
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        var frames: [String: CGRect] = [:]
        var samples: [Double] = []
        for width in [CGFloat(320), CGFloat(402)] {
            var baseline: [String: CGRect] = [:]
            for angle in [0.0, 90, -90, 180, 0] {
                let view = SystemVideoView(model: model.gallery, photo: photo, onCamera: {},
                                           playbackAssetForTesting: asset, onLayoutForTesting: { frames = $0 })
                host.rootView = AnyView(view.environment(\.videoPlaybackAngle, angle)
                    .environment(\.captureControlAngle, 0).preferredColorScheme(.dark)
                    .frame(width: width).frame(maxWidth: .infinity).background(Color.black))
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(320))
                // Wait for the actual rotated geometry, not just the first layout pass of an animation.
                for _ in 0..<50 {
                    let bar = frames["playback"] ?? .zero
                    let sideways = abs(sin(angle * .pi / 180)) > 0.5
                    if bar.width > 0, (bar.height > bar.width) == sideways { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .milliseconds(80))
                let back = try XCTUnwrap(frames["back"]), title = try XCTUnwrap(frames["title"])
                let actions = try XCTUnwrap(frames["actions"]), media = try XCTUnwrap(frames["media"])
                let bar = try XCTUnwrap(frames["playback"]), badges = try XCTUnwrap(frames["badges"])
                XCTAssertEqual(back.midY, title.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(media.minY, back.maxY)
                XCTAssertLessThanOrEqual(media.maxY, actions.minY)
                XCTAssertTrue(media.insetBy(dx: -1, dy: -1).contains(bar), "\(angle) \(media) \(bar)")
                XCTAssertTrue(media.insetBy(dx: -1, dy: -1).contains(badges))
                let r = angle * .pi / 180
                let dx = badges.midX - bar.midX, dy = badges.midY - bar.midY
                let localX = dx * cos(r) + dy * sin(r)
                let localY = -dx * sin(r) + dy * cos(r)
                let barWidth = abs(cos(r)) * bar.width + abs(sin(r)) * bar.height
                let badgeWidth = abs(cos(r)) * badges.width + abs(sin(r)) * badges.height
                XCTAssertLessThan(localY, -10, "Badges must stay above the bar in its own orientation")
                XCTAssertEqual(localX + badgeWidth / 2, barWidth / 2, accuracy: 1)
                if baseline.isEmpty { baseline = frames }
                for key in ["back", "title", "actions"] {
                    XCTAssertEqual(frames[key], baseline[key], "Fixed control moved at \(angle): \(key)")
                }
                let layer = try XCTUnwrap(playerLayer(in: host.view))
                XCTAssertEqual(layer.videoGravity, .resizeAspect)
                for _ in 0..<50 {
                    if !layer.videoRect.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertGreaterThan(layer.videoRect.height, 0)
                XCTAssertEqual(layer.videoRect.width / max(1, layer.videoRect.height), 160.0 / 90.0, accuracy: 0.02)
                XCTAssertTrue(layer.bounds.insetBy(dx: -1, dy: -1).contains(layer.videoRect))
                let start = CACurrentMediaTime()
                attach(window, "Video-Playback-\(Int(width))-\(Int(angle))")
                samples.append(CACurrentMediaTime() - start)
            }
        }
        // Rapid direction changes, then dismiss the hosting view to exercise player cancellation.
        for i in 0..<40 {
            host.rootView = AnyView(SystemVideoView(model: model.gallery, photo: photo, onCamera: {},
                playbackAssetForTesting: asset).environment(\.videoPlaybackAngle, i.isMultiple(of: 2) ? 90 : -90))
            try await Task.sleep(for: .milliseconds(10))
        }
        host.rootView = AnyView(Color.black)
        try await Task.sleep(for: .milliseconds(250))
        let metrics = "Video layout: \(samples.count) snapshots, mean \(samples.reduce(0,+) / Double(samples.count))s, max \(samples.max() ?? 0)s; 40 rapid orientation changes + dismissal. Snapshot cost is not display FPS or camera performance."
        let attachment = XCTAttachment(string: metrics); attachment.name = "Video-detail-layout-metrics"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testVideoInfoPopupAnchorsAboveItsButton() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let app = AppDependencies.makeCameraModel(automaticallySave: false)
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let photo = LibraryPhoto(id: "video-info-anchor", date: Date(), hasFilter: false, isVideo: true, duration: 1)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var frames: [String: CGRect] = [:]
        for width in [CGFloat(320), 402] {
            for open in [false, true, false, true, false] {
                let view = SystemVideoView(model: app.gallery, photo: photo, onCamera: {},
                                           playbackAssetForTesting: asset, onLayoutForTesting: { frames = $0 },
                                           infoVisibleForTesting: open)
                host.rootView = AnyView(view.frame(width: width).frame(maxWidth: .infinity))
                for _ in 0..<100 {
                    if frames["info"] != nil, (frames["infoPanel"] != nil) == open { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if open {
                    let button = try XCTUnwrap(frames["info"])
                    let panel = try XCTUnwrap(frames["infoPanel"])
                    XCTAssertEqual(panel.maxY, button.minY - 8, accuracy: 1)
                    XCTAssertLessThanOrEqual(panel.width, width - 16)
                    XCTAssertGreaterThan(panel.height, 200)
                } else {
                    XCTAssertNil(frames["infoPanel"])
                }
            }
        }
    }

    @MainActor private func playerLayer(in view: UIView) -> AVPlayerLayer? {
        if let layer = view.layer as? AVPlayerLayer { return layer }
        return view.subviews.lazy.compactMap { self.playerLayer(in: $0) }.first
    }

    private func makeVideo(seconds: Int = 1) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoDetail-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<(30 * seconds) {
            for _ in 0..<200 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<90 { for x in 0..<160 {
                let p = y * stride + x * 4
                bytes[p] = 255; bytes[p + 1] = x < 80 ? 230 : 30
                bytes[p + 2] = y < 45 ? 180 : 40; bytes[p + 3] = x >= 80 ? 220 : 40
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    @MainActor func testLevelStaysInsideAllPhotoAndVideoRatioPreviews() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.level = true
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idle }
        var layouts = 0
        let began = CACurrentMediaTime()
        for kind in [CameraViewModel.CaptureKind.photo, .video] {
            model.setCaptureKind(kind)
            let ratios = kind == .photo ? FrameRatio.allCases : VideoRatio.allCases.map(\.frameRatio)
            for ratio in ratios {
                model.ratio = ratio
                for angle in [0.0, 90, -90, 180] {
                    host.rootView = AnyView(CameraViewfinderTestHost(model: model, camera: model.camera).environment(\.captureControlAngle, angle).ignoresSafeArea())
                    try await Task.sleep(for: .milliseconds(260))
                    let preview = model.previewFrameForTesting.insetBy(dx: -1, dy: -1)
                    let level = model.levelFrameForTesting
                    XCTAssertGreaterThan(max(level.width, level.height), 90)
                    XCTAssertTrue(preview.contains(level), "Level outside preview \(kind) \(ratio) \(angle) \(preview) \(level)")
                    if ratio == .cinema, angle == 90 { attach(window, "Level-239-\(kind)") }
                    layouts += 1
                }
            }
        }
        print("LEVEL-LAYOUTS count=\(layouts) elapsed=\(CACurrentMediaTime()-began); includes animation waits, not FPS")
    }

    @MainActor func testVideoInfoAndLandscapeLevelFitCompactAndRegularScreens() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let details = PhotoDetails(rows: [
            .init(title: "相机", value: "iPhone"), .init(title: "文件名称", value: "LumaVideo-01234567-89AB-CDEF.mov"),
            .init(title: "输出尺寸", value: "2160 × 3840"), .init(title: "文件大小", value: "128 MB"),
            .init(title: "帧率", value: "119.88 fps"), .init(title: "时长", value: "12.34 秒"),
            .init(title: "输出格式", value: "HEVC"), .init(title: "码率", value: "192.00 Mbps"),
            .init(title: "音频", value: "AAC · 2 声道 · 48000 Hz"), .init(title: "色彩空间", value: "SDR · BT.709")
        ], capturedAt: Date(timeIntervalSince1970: 1_792_339_200))
        for width in [CGFloat(320), CGFloat(402)] {
            host.rootView = AnyView(VStack {
                Spacer()
                PhotoInfoPanel(details: details, isVideo: true, onClose: {})
                    .frame(width: width - 12, height: 390)
            }.preferredColorScheme(.dark).frame(maxWidth: .infinity).background(Color.black))
            try await Task.sleep(for: .milliseconds(250))
            attach(window, "Video-Info-\(Int(width))")
        }
        for (angle, roll) in [(0.0, 0.0), (90.0, -Double.pi / 2), (-90.0, Double.pi / 2), (180.0, Double.pi)] {
            host.rootView = AnyView(VStack(spacing: 50) {
                Text("水平仪").foregroundStyle(.white)
                CameraLevelIndicator(roll: roll).frame(width: 160, height: 160)
                CameraLevelIndicator(roll: roll + 0.15).frame(width: 160, height: 160)
            }.environment(\.captureControlAngle, angle).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black))
            try await Task.sleep(for: .milliseconds(250))
            attach(window, "Camera-Level-\(Int(angle))")
        }
        XCTAssertEqual(PhotoInfoPresentation(details: details, isVideo: true).parameterItems.count, 4)
    }

    @MainActor private func attach(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func waitForTrimPreview(_ editor: VideoEditorViewModel, near target: Double) async throws {
        for _ in 0..<100 {
            let current = editor.player.currentTime().seconds
            if !editor.isSeekingTrimPreview, current.isFinite, abs(current - target) <= 0.12 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Player did not settle close to trim point \(target); current time is \(editor.player.currentTime().seconds)")
    }
}

private struct VideoEditorPresentationHarness: View {
    let asset: AVAsset
    let photo: LibraryPhoto
    let library: PhotoLibraryViewModel
    @State private var presented = true

    var body: some View {
        Color.black.fullScreenCover(isPresented: $presented) {
            VideoEditorView(asset: asset, photo: photo, library: library)
        }
    }
}
