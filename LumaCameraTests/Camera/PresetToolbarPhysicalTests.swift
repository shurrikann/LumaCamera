import XCTest
import SwiftUI
import UIKit
import AVFoundation
import CoreImage
@testable import LumaCamera

private struct PresetTitleColorHost: View {
    @ObservedObject var model: CameraViewModel
    var width: CGFloat? = nil
    var body: some View { Color.black.overlay(alignment:.top){CameraView(model:model).toolStrip.padding(.top,2).background(.black)}.frame(width:width) }
}

private struct SettingsBitrateColorHost: View {
    @ObservedObject var model: CameraViewModel
    var width: CGFloat
    var body: some View { CameraView(model:model).settingsView.frame(width:width).preferredColorScheme(.dark) }
}

/// 只复用真实控件与取景，不挂载第二份相机页的生命周期。
private struct PresetToolbarHost: View {
    @ObservedObject var model: CameraViewModel
    var width:CGFloat
    var angle:Double = 0
    var reduced = false
    var generation = UUID()
    var body:some View {
        let cameraView=CameraView(model:model)
        GeometryReader { geometry in
            ZStack {
                cameraView.viewfinder
                cameraView.fixedCameraControls(width:geometry.size.width)
                VStack(spacing:0) {
                    cameraView.toolStrip.padding(.top,2)
                    Spacer(minLength:0)
                }
                .overlay(alignment:.top) {
                    if model.toolbarPanel != nil {
                        cameraView.toolbarOptionsPanel(availableWidth:width-16,reducingMotion:reduced)
                            .environment(\.captureControlAngle,0)
                            .padding(.horizontal,8).padding(.top,CameraControlLayout.toolbarHeight)
                    }
                }
            }
        }
        .id(generation).frame(width:width)
        .environment(\.captureControlAngle,angle).preferredColorScheme(.dark)
    }
}

@MainActor enum PresetToolbarChecks {
    static func wait(_ label:String,_ condition:()->Bool) async throws {
        let end=CACurrentMediaTime()+20
        while CACurrentMediaTime()<end {if condition(){return};try await Task.sleep(for:.milliseconds(20))}
        XCTFail(label);throw CancellationError()
    }
    fileprivate static func makeWindow(model:CameraViewModel) throws -> (UIWindow,UIHostingController<PresetToolbarHost>,UIWindow?) {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let prior=scene.windows.first{$0.isKeyWindow}
        let window=UIWindow(windowScene:scene)
        let host=UIHostingController(rootView:PresetToolbarHost(model:model,width:scene.screen.bounds.width))
        window.rootViewController=host;window.makeKeyAndVisible()
        return (window,host,prior)
    }
    static func frame(_ key:String,_ model:CameraViewModel) throws -> CGRect {
        try XCTUnwrap(model.captureButtonFramesForTesting[key],key)
    }
    static func shot(_ window:UIWindow,_ name:String,_ test:XCTestCase) -> Double {
        let began=CACurrentMediaTime()
        let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
        let cost=(CACurrentMediaTime()-began)*1000
        let attachment=XCTAttachment(image:image);attachment.name=name;attachment.lifetime = .keepAlways;test.add(attachment)
        return cost
    }
    static func slow(test:XCTestCase,extended:Bool) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真实相机焦段与UI需真机复测")
        #else
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        model.setCameraActive(true)
        defer {model.closePopups();model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()}
        try await wait("相机"){camera.ready && camera.preview != nil}
        model.toggleSlowShutterMode()
        try await wait("慢门"){model.slowShutterEnabled && !model.isPreparingSubmode && camera.ready}
        let (window,host,prior)=try makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        try await Task.sleep(for:.milliseconds(300))
        var layouts=0,draw=[Double](),selectionTimes=[Double]()
        let ratios=extended ? FrameRatio.photoOptions : [.standard]
        for width in [CGFloat(320),window.bounds.width] {for ratio in ratios {
            model.ratio=ratio;model.closePopups()
            host.rootView=PresetToolbarHost(model:model,width:width)
            try await Task.sleep(for:.milliseconds(250))
            let focal=try frame("lenses",model)
            model.toggleToolbarPanel(.slowShutterDuration)
            for angle in [0.0,90.0,-90.0,180.0] {
                host.rootView=PresetToolbarHost(model:model,width:width,angle:angle,reduced:angle == 180)
                try await Task.sleep(for:.milliseconds(230))
                XCTAssertNil(model.captureButtonFramesForTesting["slowShutterBarBackground"])
                let row=try frame("slowShutterPresetRow",model)
                let cells=try SlowShutterPreset.allCases.map{try frame("slowShutterPreset.\($0.rawValue)",model)}
                for cell in cells {
                    XCTAssertEqual(cell.width,cells[0].width,accuracy:0.5);XCTAssertEqual(cell.height,32,accuracy:0.5)
                    XCTAssertEqual(cell.midY,cells[0].midY,accuracy:0.5)
                    XCTAssertTrue(row.insetBy(dx:-1,dy:-1).contains(cell))
                }
                for duration in model.availableSlowShutterDurations {
                    let cell=try frame("slowShutterDuration.\(duration.rawValue)",model)
                    XCTAssertEqual(cell.width,cells[0].width,accuracy:0.5);XCTAssertEqual(cell.height,32,accuracy:0.5)
                    XCTAssertGreaterThan(cell.minY,row.maxY)
                }
                let after=try frame("lenses",model)
                XCTAssertEqual(after.midX,focal.midX,accuracy:1);XCTAssertEqual(after.midY,focal.midY,accuracy:1)
                XCTAssertEqual(model.toolbarPanel,.slowShutterDuration)
                if draw.count<20 {draw.append(shot(window,"Slow-toolbar-\(width)-\(ratio.rawValue)-\(angle)",test))}
                layouts += 1
            }
            model.closePopups()
        }}
        model.ratio = .standard
        host.rootView=PresetToolbarHost(model:model,width:window.bounds.width)
        model.toggleToolbarPanel(.slowShutterDuration)
        let previewStart=CACurrentMediaTime()
        camera.resetPreviewPublicationTimesForTesting()
        for preset in SlowShutterPreset.allCases {
            let began=CACurrentMediaTime();model.selectSlowShutterPreset(preset)
            try await Task.sleep(for:.milliseconds(240))
            selectionTimes.append(CACurrentMediaTime()-began)
            XCTAssertEqual(model.selectedSlowShutterPreset,preset)
            XCTAssertEqual(model.toolbarPanel,.slowShutterDuration)
            XCTAssertEqual(model.slowShutterDuration,preset.defaultCaptureDuration)
            let presetCell=try frame("slowShutterPreset.\(preset.rawValue)",model)
            for duration in model.availableSlowShutterDurations {
                let cell=try frame("slowShutterDuration.\(duration.rawValue)",model)
                XCTAssertEqual(cell.width,presetCell.width,accuracy:0.5)
                model.selectSlowShutterDuration(duration);XCTAssertEqual(model.slowShutterDuration,duration)
            }
        }
        let published=camera.previewPublicationTimesForTestingSnapshot.filter{$0>=previewStart}
        XCTAssertGreaterThan(published.count,5)
        print("PRESET-TOOLBAR-SLOW-PREVIEW published=\(published.count) intervalSeconds=\(CACurrentMediaTime()-previewStart) notFPS=true")
        _=shot(window,"Slow-selected-preset-and-durations",test)
        model.selectSlowShutterPreset(.starTrails)
        XCTAssertNil(model.selectedSlowShutterPreset)
        for _ in 0..<10 {model.toggleToolbarPanel(.slowShutterDuration);model.toggleToolbarPanel(.slowShutterDuration)}
        XCTAssertEqual(model.toolbarPanel,.slowShutterDuration)
        model.closePopups();model.setMode(.manual)
        try await wait("M挡"){camera.ready && !model.isPreparingSubmode}
        model.toggleToolbarPanel(.slowShutterDuration)
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertNil(model.selectedSlowShutterPreset)
        XCTAssertNil(model.captureButtonFramesForTesting["slowShutterPresetRow"])
        XCTAssertEqual(model.availableSlowShutterDurations,SlowShutterDuration.allCases)
        model.setCameraActive(false);await Task.yield();XCTAssertNil(model.toolbarPanel)
        model.setCameraActive(true);try await wait("返回"){camera.ready}
        XCTAssertNil(model.toolbarPanel)
        print("PRESET-TOOLBAR-SLOW layouts=\(layouts) presets=5 selectionObservationSeconds=\(selectionTimes) snapshots=\(draw.count) drawMS=\(draw) openClosePairs=10 noPhotosWrites=true notFPS=true")
        #endif
    }

    static func timeLapse(test:XCTestCase) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("延时顶部弹窗需真实视频能力")
        #else
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        defer {model.closePopups();model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()}
        model.setCameraActive(true);try await wait("相机"){camera.ready}
        model.setCaptureKind(.video)
        try await wait("视频"){model.videoShutterEnabled}
        model.toggleTimeLapseMode()
        try await wait("延时"){camera.ready && model.timeLapseEnabled && !model.isPreparingSubmode}
        let (window,host,prior)=try makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        var layouts=0,draw=[Double]()
        for width in [CGFloat(320),window.bounds.width] {for ratio in VideoRatio.aspectOptions {
            model.videoRatio=ratio
            try await wait("比例就绪"){camera.ready && !camera.videoConfiguring}
            model.closePopups();host.rootView=PresetToolbarHost(model:model,width:width)
            try await Task.sleep(for:.milliseconds(250))
            let focal=try frame("lenses",model)
            model.toggleToolbarPanel(.videoColor)
            for angle in [0.0,90.0,-90.0,180.0] {
                host.rootView=PresetToolbarHost(model:model,width:width,angle:angle,reduced:angle == 180)
                try await Task.sleep(for:.milliseconds(230))
                XCTAssertNil(model.captureButtonFramesForTesting["timeLapseBarBackground"])
                let cells=try TimeLapsePreset.allCases.map{try frame("timeLapsePreset.\($0.rawValue)",model)}
                let colors=try model.videoColorSpaceOptions.map{try frame("videoColor.\($0.rawValue)",model)}
                for cell in cells+colors {
                    XCTAssertEqual(cell.width,cells[0].width,accuracy:0.5);XCTAssertEqual(cell.height,32,accuracy:0.5)
                }
                for cell in cells {XCTAssertEqual(cell.midY,cells[0].midY,accuracy:0.5)}
                XCTAssertGreaterThan(cells[0].minY,try XCTUnwrap(colors.map(\.maxY).max()))
                let after=try frame("lenses",model)
                XCTAssertEqual(after.midX,focal.midX,accuracy:1);XCTAssertEqual(after.midY,focal.midY,accuracy:1)
                if draw.count<10 {draw.append(shot(window,"Timelapse-color-and-presets-\(width)-\(ratio.rawValue)-\(angle)",test))}
                layouts += 1
            }
            model.closePopups()
        }}
        // H.264只剩SDR/P3时保持五列槽宽，不能补位拉大两个色彩选项。
        var sparseColors=0
        if model.videoCodecOptions.contains(.h264),model.supportsVideoCodec(.h264) {
            model.videoCodec = .h264
            try await wait("H264就绪"){camera.ready && !camera.videoConfiguring}
            host.rootView=PresetToolbarHost(model:model,width:window.bounds.width)
            model.toggleToolbarPanel(.videoColor)
            try await Task.sleep(for:.milliseconds(250))
            let presetCell=try frame("timeLapsePreset.people",model)
            sparseColors=model.videoColorSpaceOptions.count
            XCTAssertLessThanOrEqual(sparseColors,2)
            for space in model.videoColorSpaceOptions {
                XCTAssertEqual(try frame("videoColor.\(space.rawValue)",model).width,presetCell.width,accuracy:0.5)
            }
            _=shot(window,"Timelapse-H264-two-colors-five-preset-slots",test)
            model.closePopups()
        }
        model.toggleToolbarPanel(.videoColor)
        let color=model.videoColorSpace
        for preset in TimeLapsePreset.allCases {
            model.selectTimeLapsePreset(preset)
            XCTAssertEqual(model.selectedTimeLapsePreset,preset)
            XCTAssertEqual(model.timeLapseInterval,preset.recommendedInterval)
            XCTAssertEqual(model.timeLapseFrameCount,preset.recommendedFrameCount)
            XCTAssertEqual(model.videoColorSpace,color);XCTAssertEqual(model.toolbarPanel,.videoColor)
            try await Task.sleep(for:.milliseconds(120))
        }
        model.selectTimeLapsePreset(.nightSky);XCTAssertNil(model.selectedTimeLapsePreset)
        for _ in 0..<10 {model.toggleToolbarPanel(.videoColor);model.toggleToolbarPanel(.videoColor)}
        _=shot(window,"Timelapse-five-fixed-preset-cells",test)
        model.setCameraActive(false);await Task.yield();XCTAssertNil(model.toolbarPanel)
        model.setCameraActive(true);try await wait("返回"){camera.ready}
        XCTAssertNil(model.toolbarPanel)
        print("PRESET-TOOLBAR-TIMELAPSE layouts=\(layouts) presetChanges=5 snapshots=\(draw.count) drawMS=\(draw) openClosePairs=10 colorPreserved=true sparseColorCount=\(sparseColors) notFPS=true noPhotosWrites=true")
        #endif
    }
}

final class PresetToolbarPhysicalTests:XCTestCase {
    @MainActor func testSlowPresetAndDurationColorsDependOnlyOnPresetSelection() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.closePopups(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        try await PresetToolbarChecks.wait("camera") { camera.ready }
        if !model.slowShutterEnabled { model.toggleSlowShutterMode() }
        try await PresetToolbarChecks.wait("slow shutter") { !model.isPreparingSubmode && camera.ready }
        if let preset = model.selectedSlowShutterPreset { model.selectSlowShutterPreset(preset) }
        model.closePopups()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PresetTitleColorHost(model:model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        let context = CIContext(), format = UIGraphicsImageRendererFormat(); format.scale = 1
        var times = [Double](), samples = 0
        func check(selected: Bool) async throws {
            try await Task.sleep(for:.milliseconds(120))
            let rect = try PresetToolbarChecks.frame("toolbar.slowShutterPresetDuration",model)
            let began = CACurrentMediaTime()
            let shot = UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            times.append((CACurrentMediaTime()-began)*1000)
            let image = try XCTUnwrap(CIImage(image:shot))
            let bounds = CGRect(x:floor(rect.minX),y:floor(window.bounds.height-rect.maxY),width:ceil(rect.width),height:ceil(rect.height))
            let width = Int(bounds.width), height = Int(bounds.height)
            var rgba = [UInt8](repeating:0,count:width*height*4), orange = [0,0], white = [0,0]
            context.render(image,toBitmap:&rgba,rowBytes:width*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            for pixel in 0..<(width*height) {
                let i = pixel*4, row = pixel/width >= height/2 ? 0 : 1
                let r = Int(rgba[i]), g = Int(rgba[i+1]), b = Int(rgba[i+2])
                if r>120 && r-g>40 && g-b>25 { orange[row] += 1 }
                if min(r,g,b)>110 && max(r,g,b)-min(r,g,b)<20 { white[row] += 1 }
            }
            for row in 0..<2 {
                if selected { XCTAssertGreaterThan(orange[row],3,"row=\(row) preset=\(String(describing:model.selectedSlowShutterPreset))") }
                else { XCTAssertEqual(orange[row],0); XCTAssertGreaterThan(white[row],3,"white row=\(row)") }
            }
            samples += 1
        }
        for width: CGFloat in [320,window.bounds.width] {
            host.rootView = PresetTitleColorHost(model:model,width:width)
            for duration in SlowShutterDuration.allCases {
                model.selectSlowShutterDuration(duration)
                for open in [false,true] {
                    model.closePopups()
                    if open { model.toggleToolbarPanel(.slowShutterDuration) }
                    try await check(selected:false)
                }
            }
            for preset in SlowShutterPreset.allCases {
                model.selectSlowShutterPreset(preset)
                for open in [false,true] {
                    model.closePopups()
                    if open { model.toggleToolbarPanel(.slowShutterDuration) }
                    try await check(selected:true)
                }
                model.closePopups(); model.selectSlowShutterPreset(preset)
                try await check(selected:false)
            }
        }
        for _ in 0..<20 {
            model.selectSlowShutterPreset(.silkyWater); model.selectSlowShutterPreset(.silkyWater)
            model.toggleToolbarPanel(.slowShutterDuration); model.closePopups()
        }
        try await check(selected:false)
        times.sort()
        print("SLOW_PRESET_BOTH_COLORS samples=\(samples) durations=\(SlowShutterDuration.allCases.count) presets=5 widths=2 rapidPairs=20 snapshotMedianMS=\(times[times.count/2]) snapshotMaxMS=\(times.last!) separateRows=true notFPS=true")
    }

    @MainActor func testSettingsBitrateDefaultWhiteAndOtherPresetsOrange() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let original = model.preferences.videoBitratePreset
        defer { model.preferences.videoBitratePreset = original }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:SettingsBitrateColorHost(model:model,width:scene.screen.bounds.width))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        let context = CIContext(), format = UIGraphicsImageRendererFormat(); format.scale = 1
        var times = [Double](), samples = 0
        func check(_ preset: VideoBitratePreset) async throws {
            try await Task.sleep(for:.milliseconds(220))
            let rect = try PresetToolbarChecks.frame("settings.videoBitrate",model)
            XCTAssertGreaterThan(rect.width,10); XCTAssertGreaterThan(rect.height,10)
            let began = CACurrentMediaTime()
            let shot = UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            times.append((CACurrentMediaTime()-began)*1000)
            let bounds = CGRect(x:floor(rect.minX),y:floor(window.bounds.height-rect.maxY),width:ceil(rect.width),height:ceil(rect.height))
            let width = Int(bounds.width), height = Int(bounds.height)
            var rgba = [UInt8](repeating:0,count:width*height*4), orange = 0, white = 0
            context.render(try XCTUnwrap(CIImage(image:shot)),toBitmap:&rgba,rowBytes:width*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            for pixel in 0..<(width*height) {
                let i = pixel*4, r = Int(rgba[i]), g = Int(rgba[i+1]), b = Int(rgba[i+2])
                if r>120 && r-g>40 && g-b>25 { orange += 1 }
                if min(r,g,b)>110 && max(r,g,b)-min(r,g,b)<20 { white += 1 }
            }
            if preset == .systemDefault { XCTAssertEqual(orange,0); XCTAssertGreaterThan(white,3) }
            else { XCTAssertGreaterThan(orange,3) }
            samples += 1
            if samples <= 4 {
                let attachment = XCTAttachment(image:shot); attachment.name = "Settings-bitrate-\(preset.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for width: CGFloat in [320,scene.screen.bounds.width] {
            host.rootView = SettingsBitrateColorHost(model:model,width:width)
            for _ in 0..<3 { for preset in VideoBitratePreset.allCases {
                model.preferences.videoBitratePreset = preset
                try await check(preset)
            } }
        }
        for _ in 0..<20 { model.preferences.videoBitratePreset = .high; model.preferences.videoBitratePreset = .systemDefault }
        try await check(.systemDefault)
        window.isHidden = true
        host.rootView = SettingsBitrateColorHost(model:model,width:scene.screen.bounds.width)
        window.makeKeyAndVisible(); try await check(.systemDefault)
        times.sort()
        print("SETTINGS_BITRATE_COLORS samples=\(samples) choices=4 widths=2 rapidPairs=20 reopen=true snapshotMedianMS=\(times[times.count/2]) snapshotMaxMS=\(times.last!) notFPS=true")
    }

    @MainActor func testVideoStandbyDefaultsToFocalsAndWheelHidesAfterIdle() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        model.setCameraActive(true)
        defer {model.closePopups();model.setCameraActive(false)}
        try await PresetToolbarChecks.wait("相机"){camera.ready}
        model.setCaptureKind(.video)
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"待机变焦",timeout:20)
        XCTAssertFalse(model.zoomDialVisible)
        let (window,_,prior)=try PresetToolbarChecks.makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        try await Task.sleep(for:.milliseconds(150))
        let before=try PresetToolbarChecks.frame("lenses",model)
        for _ in 0..<10 {model.openZoomDial();model.finishZoomDrag();model.endZoomDial()}
        model.openZoomDial();model.finishZoomDrag()
        XCTAssertTrue(model.zoomDialVisible);XCTAssertTrue(model.hidesFocalStripForZoomDial)
        let start=CACurrentMediaTime()
        try await Task.sleep(for:.milliseconds(2500));XCTAssertTrue(model.zoomDialVisible)
        try await PresetToolbarChecks.wait("待机4秒收起"){!model.zoomDialVisible}
        let elapsed=CACurrentMediaTime()-start
        XCTAssertGreaterThanOrEqual(elapsed,3.9);XCTAssertLessThan(elapsed,4.8)
        XCTAssertFalse(model.hidesFocalStripForZoomDial)
        XCTAssertEqual(try PresetToolbarChecks.frame("lenses",model),before)
        print("VIDEO_STANDBY_ZOOM hideSeconds=\(elapsed) rapidPairs=10 defaultFocals=true")
    }

    @MainActor func testRecordingZoomButtonsWheelAndFourSecondIdleHide() async throws {
        try await recordingZoom(mode:.auto,front:false,checkTimer:true)
    }
    @MainActor func testManualRecordingZoomChangesHardwareAndKeepsRoute() async throws {
        try await recordingZoom(mode:.manual,front:false,checkTimer:false)
    }
    @MainActor func testFrontRecordingZoomChangesHardwareAndDecodes() async throws {
        try await recordingZoom(mode:.auto,front:true,checkTimer:false)
    }
    @MainActor func testRecordingWheelAndFocalHitAreasAcrossRatiosWidthsAndDirections() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        model.setCameraActive(true)
        defer {camera.setVideoRecordingForTesting(false);model.closePopups();model.setCameraActive(false)}
        try await PresetToolbarChecks.wait("相机"){camera.ready}
        model.setCaptureKind(.video);try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"变焦布局",timeout:20)
        if model.currentPosition != .back {model.flipCamera();try await PresetToolbarChecks.wait("后置"){camera.ready && model.currentPosition == .back}}
        let (window,host,prior)=try PresetToolbarChecks.makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        func descendants(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap(descendants)}
        var cases=0,draw=[Double]()
        for width:CGFloat in [320,402] {for mode:CameraShootingMode in [.auto,.manual] {for ratio in VideoRatio.aspectOptions {for angle in [0.0,90,-90,180] {
            camera.setVideoRecordingForTesting(false);model.setMode(mode);model.videoRatio=ratio
            try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"变焦画幅",timeout:20)
            camera.setVideoRecordingForTesting(true,zoomRange:camera.continuousZoomRange)
            XCTAssertFalse(model.zoomDialVisible)
            model.openZoomDial();model.finishZoomDrag()
            host.rootView=PresetToolbarHost(model:model,width:width,angle:angle)
            try await Task.sleep(for:.milliseconds(240))
            XCTAssertTrue(model.zoomDialVisible);XCTAssertTrue(model.hidesFocalStripForZoomDial)
            let frame=try PresetToolbarChecks.frame("lenses",model)
            XCTAssertGreaterThan(frame.width,0)
            let labels=Set(model.displayedFocalLenses.map(\.accessibilityDescription))
            let hiddenButtons=descendants(window).compactMap{$0 as? UIButton}.filter{$0.isEnabled && labels.contains($0.accessibilityLabel ?? "")}
            XCTAssertFalse(hiddenButtons.isEmpty)
            for button in hiddenButtons {
                XCTAssertFalse(button.point(inside:CGPoint(x:button.bounds.midX,y:button.bounds.midY),with:nil),"隐藏按钮不接受新触摸 \(ratio) \(angle)")
                let zoom=camera.currentZoom
                button.sendActions(for:.touchUpInside)
                XCTAssertEqual(camera.currentZoom,zoom)
                XCTAssertTrue(model.zoomDialVisible,"隐藏按钮不能改变焦段或关闭轮盘")
            }
            let surface=try XCTUnwrap(descendants(window).compactMap{$0 as? CameraZoomTouchView}.first)
            let acceptsWheel=stride(from:surface.region.minY+5,through:surface.region.maxY-5,by:10).contains{y in surface.point(inside:CGPoint(x:surface.region.midX,y:y),with:nil)}
            XCTAssertTrue(acceptsWheel)
            model.endZoomDial();try await Task.sleep(for:.milliseconds(280))
            XCTAssertFalse(model.hidesFocalStripForZoomDial)
            let buttons=descendants(window).compactMap{$0 as? UIButton}.filter{$0.isEnabled && labels.contains($0.accessibilityLabel ?? "")}
            for button in buttons {
                // SwiftUI may retain outgoing host nodes during fades; wait for the
                // visible focal strip to become hittable rather than assuming 280ms.
                func hittable() -> Bool {
                    let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:window)
                    let hit=window.hitTest(point,with:nil)
                    return hit === button || hit?.isDescendant(of:button) == true
                }
                let deadline = CACurrentMediaTime() + 1
                while !hittable() && CACurrentMediaTime() < deadline { try await Task.sleep(for:.milliseconds(20)) }
                XCTAssertTrue(hittable(),"\(ratio) \(angle) \(width) button=\(button.accessibilityLabel ?? "")")
            }
            XCTAssertEqual(try PresetToolbarChecks.frame("lenses",model),frame)
            if angle == 0 {draw.append(PresetToolbarChecks.shot(window,"Recording-layout-\(ratio.rawValue)-\(mode.rawValue)-\(width)",self))}
            cases += 1
        }}}}
        print("RECORDING_ZOOM_LAYOUT cases=\(cases) screenshotMS=\(draw) simulatedRecordingStateOnly=true notFPS=true")
    }

    @MainActor private func recordingZoom(mode:CameraShootingMode,front:Bool,checkTimer:Bool) async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let oldCallback=camera.onVideoRecorded,idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        var result:Result<URL,Error>?
        camera.onVideoRecorded={result=$0}
        defer {camera.stopVideoRecording();model.closePopups();model.setCameraActive(false);camera.onVideoRecorded=oldCallback;UIApplication.shared.isIdleTimerDisabled=idle;if case .success(let url)=result{try? FileManager.default.removeItem(at:url)}}
        model.setCameraActive(true);try await PresetToolbarChecks.wait("相机"){camera.ready && camera.preview != nil}
        model.setCaptureKind(.video);model.videoResolution = .hd1080;model.videoFrameRate = .fps30;model.videoCodec = .hevc;model.videoColorSpace = .sdr
        try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"录像变焦",timeout:20)
        let position:AVCaptureDevice.Position=front ? .front:.back
        if model.currentPosition != position {model.flipCamera();try await PresetToolbarChecks.wait("镜头位置"){camera.ready && model.currentPosition == position}}
        if front && model.frontVideoCenteringRequested {model.toggleFrontVideoCentering()}
        model.setMode(mode);try await FullDeviceRegressionFixture.waitForVideoShutter(model,label:"录像变焦模式",timeout:20)
        let (window,_,prior)=try PresetToolbarChecks.makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        model.toggleVideoRecording();try await PresetToolbarChecks.wait("开始录像"){camera.videoRecording}
        try await Task.sleep(for:.milliseconds(180))
        XCTAssertFalse(model.zoomDialVisible);XCTAssertFalse(model.hidesFocalStripForZoomDial)
        let route=camera.activeCaptureDeviceID,settings=camera.videoSettings
        let range=try XCTUnwrap(camera.videoRecordingZoomRange)
        let before=try PresetToolbarChecks.frame("lenses",model)
        model.endZoomDial();try await Task.sleep(for:.milliseconds(300))
        XCTAssertFalse(model.hidesFocalStripForZoomDial)
        func descendants(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap(descendants)}
        let labels=Set(model.displayedFocalLenses.map(\.accessibilityDescription)+["切换回前置 1 倍","切换前置广角"])
        let enabled=descendants(window).compactMap{$0 as? UIButton}.filter{$0.isEnabled && labels.contains($0.accessibilityLabel ?? "")}
        XCTAssertFalse(enabled.isEmpty,"positions=\(model.currentPosition.rawValue) lenses=\(model.displayedFocalLenses.map(\.title))")
        if let lens=model.displayedFocalLenses.first(where:{abs($0.displayZoom-2)<0.01}),
           let button=enabled.first(where:{$0.accessibilityLabel == lens.accessibilityDescription}) {
            let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:window)
            let hit=window.hitTest(point,with:nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of:button) == true,"轮盘收起后焦段须可点击 hit=\(String(describing:hit)) point=\(point)")
            button.sendActions(for:.touchUpInside)
            let deadline = CACurrentMediaTime() + 3
            var actual: CGFloat = 0
            repeat {
                actual = await withCheckedContinuation { c in camera.zoomStateForTesting { zoom,_,_ in c.resume(returning:zoom) } }
                if abs(actual - 2) <= 0.05 { break }
                try await Task.sleep(for:.milliseconds(20))
            } while CACurrentMediaTime() < deadline
            XCTAssertEqual(actual,2,accuracy:0.05)
            XCTAssertFalse(model.zoomDialVisible,"短按只切换焦段，不打开轮盘")
        }
        let initial:CGFloat=await withCheckedContinuation{c in camera.zoomStateForTesting{zoom,_,_ in c.resume(returning:zoom)}}
        model.beginZoomDial(at:camera.currentZoom)
        XCTAssertTrue(model.zoomDialVisible);XCTAssertTrue(model.hidesFocalStripForZoomDial)
        model.dragZoomDial(translation:-70,width:window.bounds.width)
        try await Task.sleep(for:.milliseconds(150))
        let changed:CGFloat=await withCheckedContinuation{c in camera.zoomStateForTesting{zoom,_,_ in c.resume(returning:zoom)}}
        XCTAssertGreaterThan(changed,initial+0.02)
        var hideSeconds:Double?
        if checkTimer {
            try await Task.sleep(for:.milliseconds(5200));XCTAssertTrue(model.zoomDialVisible,"拖动持有期间不收起")
            model.finishZoomDrag();try await Task.sleep(for:.seconds(2))
            model.beginZoomDial(at:camera.currentZoom);model.dragZoomDial(translation:20,width:window.bounds.width);model.finishZoomDrag()
            let ended=CACurrentMediaTime()
            try await Task.sleep(for:.milliseconds(2500));XCTAssertTrue(model.zoomDialVisible,"重新操作后重置4秒")
            try await PresetToolbarChecks.wait("4秒自动收起"){!model.zoomDialVisible}
            hideSeconds=CACurrentMediaTime()-ended
            XCTAssertGreaterThanOrEqual(hideSeconds ?? 0,3.9);XCTAssertLessThan(hideSeconds ?? 99,4.8)
        }else{model.finishZoomDrag();try await Task.sleep(for:.milliseconds(500));model.endZoomDial()}
        if mode == .manual && !front {
            camera.setContinuousZoom(min(range.upperBound,4.5));try await Task.sleep(for:.milliseconds(160))
            let anchor=try XCTUnwrap(camera.lenses.first{$0.id == camera.selectedLens})
            XCTAssertEqual(anchor.device.uniqueID,route,"固定物理录制不能把按钮状态改成另一颗镜头")
        }
        for n in 0..<20 {camera.setContinuousZoom(n.isMultiple(of:2) ? range.lowerBound : min(range.upperBound,max(range.lowerBound+0.1,2.5)))}
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertEqual(camera.activeCaptureDeviceID,route);XCTAssertEqual(camera.videoSettings,settings);XCTAssertTrue(camera.videoRecording)
        XCTAssertEqual(try PresetToolbarChecks.frame("lenses",model),before)
        _=PresetToolbarChecks.shot(window,"Recording-zoom-\(mode.rawValue)-front-\(front)",self)
        for _ in 0..<10 {model.openZoomDial();model.finishZoomDrag();model.endZoomDial()}
        model.openZoomDial();model.finishZoomDrag()
        model.toggleVideoRecording();try await PresetToolbarChecks.wait("结束录像"){result != nil && !camera.videoBusy}
        XCTAssertFalse(model.zoomDialVisible)
        let url=try XCTUnwrap(result?.get()),asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video),track=try XCTUnwrap(tracks.first)
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);XCTAssertTrue(reader.startReading());var frames=0
        while output.copyNextSampleBuffer() != nil {frames += 1}
        XCTAssertEqual(reader.status,.completed);XCTAssertGreaterThan(frames,20)
        print("RECORDING_ZOOM mode=\(mode.rawValue) front=\(front) initial=\(initial) dragActual=\(changed) range=\(range) stableRoute=true rapid=20 decodedFrames=\(frames) hideSeconds=\(String(describing:hideSeconds))")
    }

    @MainActor func testFrontVideoWideSelectionHasNoBackground() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("前置视频取景规格需真机")
        #else
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let audit=SessionRuntimeErrorAudit(),idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer {model.setCameraActive(false);UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()}
        model.setCameraActive(true);try await PresetToolbarChecks.wait("相机"){camera.ready}
        model.setCaptureKind(.video);try await PresetToolbarChecks.wait("视频"){model.videoShutterEnabled}
        model.flipCamera();try await PresetToolbarChecks.wait("前置"){camera.ready && model.currentPosition == .front && !camera.videoConfiguring}
        let (window,_,prior)=try PresetToolbarChecks.makeWindow(model:model)
        defer {window.isHidden=true;window.rootViewController=nil;prior?.makeKey()}
        func descendants(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap(descendants)}
        var times=[Double]()
        for _ in 0..<3 {for wide in [true,false] {
            let target=try XCTUnwrap(camera.lenses.first{$0.device.position == .front && $0.frontFraming == (wide ? .wide : .standard)})
            if camera.selectedLens != target.id {model.selectFocalLength(target)}
            try await PresetToolbarChecks.wait("前置广角切换"){camera.ready && camera.selectedLens == target.id && !camera.videoConfiguring}
            let began=CACurrentMediaTime();try await Task.sleep(for:.milliseconds(250))
            let label=wide ? "切换回前置 1 倍" : "切换前置广角"
            let button=try XCTUnwrap(descendants(window).compactMap{$0 as? UIButton}.first{$0.accessibilityLabel == label})
            XCTAssertEqual(button.isSelected,wide)
            XCTAssertEqual(button.backgroundColor?.cgColor.alpha ?? -1,0,accuracy:0.001)
            button.isHighlighted=true;button.layoutIfNeeded()
            XCTAssertEqual(button.backgroundColor?.cgColor.alpha ?? -1,0,accuracy:0.001)
            XCTAssertTrue(descendants(button).compactMap{$0 as? UIVisualEffectView}.allSatisfy{$0.effect == nil})
            button.isHighlighted=false
            let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:window)
            let hit=window.hitTest(point,with:nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of:button) == true)
            times.append(CACurrentMediaTime()-began)
            if wide {_=PresetToolbarChecks.shot(window,"Front-video-wide-clear-background",self)}
        }}
        print("FRONT-WIDE-CLEAR states=6 actualRoutes=true selectedAndHighlightedAlpha=0 hitTargets=true observationSeconds=\(times) notSwitchLatency=true noPhotosWrites=true")
        #endif
    }
}
