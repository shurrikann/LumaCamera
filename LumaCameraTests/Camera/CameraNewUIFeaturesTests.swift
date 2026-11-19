import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor
final class CameraNewUIFeaturesTests: XCTestCase {
    private func host(_ model: CameraViewModel, width: CGFloat = 390, angle: Double = 0, scenePhase: ScenePhase = .active) throws -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: CameraView(model: model)
            .environment(\.scenePhase, scenePhase)
            .environment(\.captureControlAngle, angle))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 760)
        window.rootViewController = host
        window.isHidden = false
        return (host, window)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func testFixedOrangeThemeAcrossLightDarkAndGlass() async throws {
        var light = EnvironmentValues(), dark = EnvironmentValues()
        light.colorScheme = .light
        dark.colorScheme = .dark
        let onLight = AppTheme.accent.resolve(in: light)
        let onDark = AppTheme.accent.resolve(in: dark)
        XCTAssertEqual(onLight.red, 201.0 / 255, accuracy: 0.01)
        XCTAssertEqual(onLight.green, 101.0 / 255, accuracy: 0.01)
        XCTAssertEqual(onLight.blue, 28.0 / 255, accuracy: 0.01)
        XCTAssertEqual(onLight, onDark)
        XCTAssertEqual(AppTheme.accentForeground.resolve(in: light), AppTheme.accentForeground.resolve(in: dark))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.clear))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        var snapshots = [Double]()
        for _ in 0..<4 {
            for backdrop in [Color.black, .white] {
                host.rootView = AnyView(ZStack {
                    backdrop.ignoresSafeArea()
                    Text("HEIF Pro").font(.system(size: 13, weight: .semibold))
                        .frame(width: 72, height: 20)
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 120, height: 46)
                        .modifier(GlassSurface(radius: 23))
                })
                try await Task.sleep(for: .milliseconds(85))
                let start = CACurrentMediaTime()
                let bounds = CGRect(x: 0, y: 0, width: 120, height: 46)
                let crop = UIGraphicsImageRenderer(size: bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds.offsetBy(dx: bounds.midX - window.bounds.midX,
                        dy: bounds.midY - window.bounds.midY), afterScreenUpdates: true)
                }
                snapshots.append((CACurrentMediaTime() - start) * 1000)
                let image = try XCTUnwrap(crop.cgImage)
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let ink = try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    let rgba = buffer.bindMemory(to: UInt8.self)
                    return stride(from: 0, to: rgba.count, by: 4).filter {
                        let red = Int(rgba[$0]), green = Int(rgba[$0 + 1]), blue = Int(rgba[$0 + 2])
                        return red >= 150 && red - green > 36 && green - blue > 21
                    }.count
                }
                XCTAssertGreaterThan(ink, 35)
                if snapshots.count <= 2 {
                    let attachment = XCTAttachment(image: crop)
                    attachment.name = "Fixed orange on \(snapshots.count == 1 ? "dark" : "light") glass"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        print("FIXED-ORANGE-GLASS backdropSwitches=\(snapshots.count) snapshotMS=\(snapshots) PhotosWrites=0")
    }

    func testTopToolbarDefaultWhiteSurvivesDisabledStateAcrossPhotoVideoAndAstro() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        model.setCameraActive(true)
        defer { model.closePopups(); model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        let deadline = CACurrentMediaTime()+15
        while !model.camera.ready && CACurrentMediaTime()<deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.camera.ready)
        model.flashMode = .off
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:AnyView(Color.black))
        host.safeAreaRegions = [] // Keep the specimen independent of the status-bar inset.
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func whites(_ image: UIImage) throws -> Int {
            let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
            var bytes = [UInt8](repeating:0,count:w*h*4)
            let context = try XCTUnwrap(CGContext(data:&bytes,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
            return stride(from:0,to:bytes.count,by:4).filter { bytes[$0]>240 && bytes[$0+1]>240 && bytes[$0+2]>240 }.count
        }
        var drawCosts = [Double](), pairs = 0
        for kind in [CameraViewModel.CaptureKind.photo,.video] {
            model.requestCaptureKind(kind)
            let limit = CACurrentMediaTime()+15
            while (model.captureKind != kind || model.captureKindSwitching || model.camera.videoConfiguring), CACurrentMediaTime()<limit {
                try await Task.sleep(for:.milliseconds(20))
            }
            model.toolbarPanel = nil
            for width: CGFloat in [320,390,430] {
                for angle in [0.0,90.0] {
                    var counts = [Int]()
                    for disabled in [false,true] {
                        window.frame = CGRect(x:0,y:0,width:width,height:760)
                        // Page-style TabView requires a full-height UIKit host. Crop only
                        // the toolbar when recording; a 70pt UIWindow clips its page child.
                        host.rootView = AnyView(VStack(spacing:0) {
                            Color.clear.frame(height:120)
                            CameraView(model:model).toolStrip
                                .environment(\.captureControlAngle,angle).disabled(disabled)
                                .frame(width:width,height:70)
                            Spacer(minLength:0)
                        }.frame(width:width,height:760).background(.black))
                        host.view.frame = window.bounds
                        // Rotation uses a 0.22s animation; compare only settled glyphs.
                        try await Task.sleep(for:.milliseconds(320)); host.view.layoutIfNeeded()
                        let start = CACurrentMediaTime()
                        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                        let image = UIGraphicsImageRenderer(size:CGSize(width:width,height:70),format:format).image { _ in
                            window.drawHierarchy(in:CGRect(x:0,y:-120,width:width,height:760),afterScreenUpdates:true)
                        }
                        drawCosts.append((CACurrentMediaTime()-start)*1000)
                        counts.append(try whites(image))
                        let a = XCTAttachment(image:image)
                        a.name = "Toolbar-\(kind)-w\(Int(width))-a\(Int(angle))-disabled-\(disabled)"
                        a.lifetime = .keepAlways; add(a)
                    }
                    print("TOOLBAR-WHITE pair kind=\(kind) width=\(width) angle=\(angle) brightPixels=\(counts)")
                    XCTAssertGreaterThan(counts[0],100)
                    XCTAssertGreaterThanOrEqual(Double(counts[1]),Double(counts[0])*0.95,"Disabling must not gray white toolbar glyphs: \(kind) width=\(width) angle=\(angle)")
                    pairs += 1
                }
            }
        }
        window.isHidden = true
        host.rootView = AnyView(Color.black)
        window.rootViewController = nil
        try await Task.sleep(for:.milliseconds(150))
        model.selectTopLevelMode(.astro)
        for _ in 0..<750 { if model.topLevelMode == .astro && model.modeHandoffTarget == nil && AstroModeDiagnostics.previewReady { break }; try await Task.sleep(for:.milliseconds(20)) }
        for mode in [AstroCaptureMode.photo,.trails,.timelapse,.photo] {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await Task.sleep(for:.milliseconds(500))
            let actual = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
            let image = UIGraphicsImageRenderer(bounds:actual.bounds).image { _ in actual.drawHierarchy(in:actual.bounds,afterScreenUpdates:true) }
            let a = XCTAttachment(image:image); a.name = "Astro-White-Toolbar-\(mode.rawValue)"; a.lifetime = .keepAlways; add(a)
        }
        model.selectTopLevelMode(.photo)
        let returnLimit = CACurrentMediaTime()+15
        while (model.topLevelMode != .photo || model.modeHandoffTarget != nil || !model.camera.ready), CACurrentMediaTime()<returnLimit {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(model.topLevelMode,.photo)
        XCTAssertNil(model.modeHandoffTarget)
        XCTAssertTrue(model.camera.ready)
        print("TOOLBAR-WHITE enabledDisabledPairs=\(pairs) realDrawSamples=\(drawCosts.count) draw_ms=\(drawCosts) astroSubmodes=4 PhotosWrites=0; draw cost is not FPS")
    }

    func testManualReadoutsKeepEditorAndButtonGeometryAcrossPhotoVideoRatios() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.setCameraActive(true)
        defer { model.closePopups(); model.setCameraActive(false) }
        for _ in 0..<300 { if model.camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        var costs = [Double]()
        model.setCaptureKind(.photo)
        model.setMode(.auto)
        for _ in 0..<100 {
            if model.captureButtonFramesForTesting["autoEVGlass"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let autoEVGlass = try XCTUnwrap(model.captureButtonFramesForTesting["autoEVGlass"])
        for kind in [CameraViewModel.CaptureKind.photo, .video] {
            model.setCaptureKind(kind); model.setMode(.manual)
            for _ in 0..<300 {
                if model.mode == .manual && !model.captureKindSwitching && !model.camera.videoConfiguring { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertEqual(model.captureKind,kind); XCTAssertEqual(model.mode,.manual)
            XCTAssertTrue(model.displayedManualParameters.contains(.shutter))
            XCTAssertEqual(model.displayedManualParameters.map(\.readoutLabel), ["S","ISO","EV","AF","WEB","T"])
            let originalEV = model.ev
            model.ev = 1.2
            XCTAssertEqual(model.parameterReadout(.ev), "+1.2")
            model.ev = originalEV
            var reference: CGRect?
            let ratios = kind == .photo ? FrameRatio.allCases : VideoRatio.aspectOptions.map(\.frameRatio)
            for ratio in ratios {
                if kind == .photo { model.ratio = ratio }
                else { model.videoRatio = try XCTUnwrap(VideoRatio.aspectOptions.first { $0.frameRatio == ratio }) }
                try await Task.sleep(for:.milliseconds(300))
                let frame = try XCTUnwrap(model.captureButtonFramesForTesting["parameter.S"])
                XCTAssertGreaterThan(frame.width,35); XCTAssertGreaterThan(frame.height,35)
                if let reference { XCTAssertEqual(frame,reference) } else { reference = frame }
                let row = try XCTUnwrap(model.captureButtonFramesForTesting["parameters"])
                let glass = try XCTUnwrap(model.captureButtonFramesForTesting["manualParameterGlass"])
                XCTAssertEqual(glass.midY, row.midY, accuracy: 0.5)
                XCTAssertEqual(glass.midX, row.midX, accuracy: 0.5)
                XCTAssertEqual(glass.height, 46, accuracy: 0.5)
                XCTAssertEqual(glass.minX, autoEVGlass.minX, accuracy: 0.5)
                XCTAssertEqual(glass.maxX, autoEVGlass.maxX, accuracy: 0.5)
                let buttons = try model.displayedManualParameters.map { parameter in
                    try XCTUnwrap(model.captureButtonFramesForTesting["parameter." + parameter.rawValue])
                }
                let slotWidth = glass.width / CGFloat(buttons.count)
                for (index, button) in buttons.enumerated() {
                    XCTAssertEqual(button.width, slotWidth, accuracy: 0.5)
                    XCTAssertEqual(button.minX, glass.minX + CGFloat(index) * slotWidth, accuracy: 0.5)
                    XCTAssertEqual(button.midY, frame.midY, accuracy: 0.5)
                }
                XCTAssertEqual(try XCTUnwrap(buttons.last).maxX, glass.maxX, accuracy: 0.5)
                for _ in 0..<2 {
                    model.openParameter(.shutter)
                    XCTAssertEqual(model.parameter,.shutter); XCTAssertEqual(model.panel,.manual)
                    model.closePopups(); XCTAssertNil(model.panel)
                }
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                    window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                }
                costs.append((CACurrentMediaTime()-start)*1000)
                if ratio == .wide {
                    let attachment = XCTAttachment(image:shot)
                    attachment.name = "Manual-Readout-\(kind)"; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        #if !targetEnvironment(simulator)
        model.toggleCinematicVideoMode()
        for _ in 0..<350 {
            if model.cinematicVideoEnabled && !model.isPreparingSubmode && !model.camera.videoConfiguring { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.cinematicVideoEnabled)
        XCTAssertEqual(model.displayedManualParameters, [.ev, .wb, .tint])
        let cinematicGlass = try XCTUnwrap(model.captureButtonFramesForTesting["manualParameterGlass"])
        XCTAssertEqual(cinematicGlass, autoEVGlass)
        let cinematicSlotWidth = cinematicGlass.width / 3
        for (index, item) in model.displayedManualParameters.enumerated() {
            let button = try XCTUnwrap(model.captureButtonFramesForTesting["parameter." + item.rawValue])
            XCTAssertEqual(button.minX, cinematicGlass.minX + CGFloat(index) * cinematicSlotWidth, accuracy: 0.5)
            XCTAssertEqual(button.width, cinematicSlotWidth, accuracy: 0.5)
        }
        model.toggleCinematicVideoMode()
        #endif
        print("MANUAL-READOUT kinds=photo,video photoRatios=8 videoRatios=5 snapshots=\(costs.count) openClose=\(costs.count*2) snapshotMilliseconds=\(costs); snapshot drawing, not display FPS; PhotosWrites=0")
    }

    func testFilterPickerInsetsContainCategoriesAndFooterAcrossWidthsAndLog() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.setCameraActive(true)
        defer { model.closePopups(); model.setCameraActive(false) }
        for _ in 0..<300 { if model.camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        let (_, window) = try host(model,angle:90)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.style = .leicaM9
        var costs = [Double](), checked = 0
        func check(log:Bool) throws {
            let card = try XCTUnwrap(model.captureButtonFramesForTesting["filter.card"])
            let bar = try XCTUnwrap(model.captureButtonFramesForTesting[log ? "filter.logCategories" : "filter.categories"])
            XCTAssertGreaterThan(card.width,200)
            XCTAssertGreaterThanOrEqual(card.height,200)
            XCTAssertEqual(bar.minX,card.minX,accuracy:0.5)
            XCTAssertEqual(bar.maxX,card.maxX,accuracy:0.5)
            XCTAssertGreaterThanOrEqual(bar.minY,card.minY+19)
            XCTAssertLessThanOrEqual(bar.maxY,card.maxY)
            if !log {
                let favorite = try XCTUnwrap(model.captureButtonFramesForTesting["filter.favorite"])
                let edit = try XCTUnwrap(model.captureButtonFramesForTesting["filter.edit"])
                XCTAssertGreaterThanOrEqual(favorite.minX-card.minX,23.5)
                XCTAssertGreaterThanOrEqual(card.maxX-edit.maxX,23.5)
                XCTAssertEqual(favorite.width,44,accuracy:0.5); XCTAssertEqual(edit.width,44,accuracy:0.5)
            }
        }
        for log in [false,true] {
            model.setCaptureKind(log ? .video : .photo)
            if log { model.videoColorSpace = .appleLog }
            model.filters.showStrength = false; model.panel = .film
            try await Task.sleep(for:.milliseconds(450))
            XCTAssertEqual(model.logVideoLUTControlsEnabled,log)
            for width in [320.0,390,440] {
                window.frame.size.width = width
                for index in 0..<(log ? LogLUTCategory.allCases.count : FilterCategory.allCases.count) {
                    if log {
                        model.videoRatio = VideoRatio.aspectOptions[index % VideoRatio.aspectOptions.count]
                        model.selectLogLUTCategory(LogLUTCategory.allCases[index])
                    } else {
                        model.ratio = FrameRatio.allCases[index % FrameRatio.allCases.count]
                        model.selectFilterCategory(FilterCategory.allCases[index])
                    }
                    try await Task.sleep(for:.milliseconds(130))
                    try check(log:log); checked += 1
                    let start = CACurrentMediaTime()
                    let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                    }
                    costs.append((CACurrentMediaTime()-start)*1000)
                    if index == 0 || index == (log ? LogLUTCategory.allCases.count : FilterCategory.allCases.count)-1 {
                        let attachment = XCTAttachment(image:shot)
                        attachment.name = "Filter-Picker-Inset-\(log ? "Log" : "Photo")-\(Int(width))-\(index)"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
                model.closePopups(); try await Task.sleep(for:.milliseconds(80))
                model.panel = .film; try await Task.sleep(for:.milliseconds(250))
                try check(log:log)
            }
        }
        print("FILTER-PICKER-INSET checks=\(checked) widths=320,390,440 photoCategories=9 logCategories=10 photoRatios=8 videoRatios=5 closeReopen=6 hostAngle=90 popupAngle=0 snapshotMilliseconds=\(costs); snapshot drawing, not FPS; PhotosWrites=0")
        // Drain this isolated camera before the next UI test starts another one.
        model.closePopups(); model.setCameraActive(false)
        await withCheckedContinuation { continuation in
            model.camera.afterPendingSessionTasks { continuation.resume() }
        }
        let running = await withCheckedContinuation { continuation in
            model.camera.actualSessionRunningForTesting { continuation.resume(returning:$0) }
        }
        XCTAssertFalse(running)
    }

    func testWatermarkStylesPanelRepeatedSwitchesAndCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.preferences.watermark.showsLocation = false
        model.setCameraActive(true)
        defer { model.closePopups(); model.setCameraActive(false) }
        for _ in 0..<300 { if model.camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        var samples = [Double]()
        for width: CGFloat in [320,390,440] {
            let (_, window) = try host(model,width:width,angle:90)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for:.milliseconds(500))
            model.setCameraActive(true)
            for ratio in FrameRatio.allCases {
                model.ratio = ratio
                try await Task.sleep(for:.milliseconds(80))
                model.openWatermarkPanel()
                try await Task.sleep(for:.milliseconds(250))
                print("WATERMARK-UI-CHECK width=\(width) ratio=\(ratio) visible=\(model.watermarkPanelVisible)")
                let frame = try XCTUnwrap(model.captureButtonFramesForTesting["watermark.panel"])
                XCTAssertGreaterThanOrEqual(frame.minX,0)
                XCTAssertLessThanOrEqual(frame.maxX,width)
                var preceding: CGRect?
                for style in PhotoWatermarkStyle.allCases {
                    let option = try XCTUnwrap(model.captureButtonFramesForTesting["watermark.style."+style.rawValue])
                    XCTAssertEqual(option.height,54,accuracy:0.5)
                    XCTAssertGreaterThanOrEqual(option.minX,frame.minX)
                    XCTAssertLessThanOrEqual(option.maxX,frame.maxX)
                    if let preceding { XCTAssertGreaterThanOrEqual(option.minX,preceding.maxX+7) }
                    preceding = option
                    model.border = false
                    model.selectWatermarkStyle(style)
                    XCTAssertTrue(model.border)
                    XCTAssertEqual(model.preferences.watermark.style,style)
                    model.selectWatermarkStyle(style)
                    XCTAssertFalse(model.border)
                    model.selectWatermarkStyle(style)
                    XCTAssertTrue(model.border)
                }
                if ratio == .standard { try await Task.sleep(for:.milliseconds(300)) }
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                    window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                }
                samples.append((CACurrentMediaTime()-start)*1000)
                if ratio == .standard {
                    let attachment = XCTAttachment(image:shot); attachment.name = "Watermark-Panel-\(width)"
                    attachment.lifetime = .keepAlways; add(attachment)
                    model.border = false
                    try await Task.sleep(for:.milliseconds(250))
                    let defaultShot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                    }
                    let defaultAttachment = XCTAttachment(image:defaultShot)
                    defaultAttachment.name = "Watermark-Thumbnails-White-\(width)"
                    defaultAttachment.lifetime = .keepAlways; add(defaultAttachment)
                }
                model.closePopups(); XCTAssertFalse(model.watermarkPanelVisible)
                try await Task.sleep(for:.milliseconds(300))
            }
        }
        for _ in 0..<20 { model.openWatermarkPanel(); model.selectWatermarkStyle(.glassStrip); model.closePopups() }
        model.openWatermarkPanel(); model.setCameraActive(false)
        XCTAssertFalse(model.watermarkPanelVisible)
        await withCheckedContinuation { continuation in model.camera.afterPendingSessionTasks { continuation.resume() } }
        print("WATERMARK-UI widths=3 ratios=8 styleTaps=288 rapidOpenClose=20 backgroundDismiss=true snapshotMilliseconds=\(samples); not FPS; PhotosWrites=0")
    }

    func test48MPPillIsDisabledInAutoAndEnabledInManual() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<300 { if camera.ready && camera.availableResolutions.contains(.high) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setMode(.auto); model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(400))
        let autoFrame = try XCTUnwrap(model.captureButtonFramesForTesting["format.resolution.48"])
        XCTAssertFalse(autoFrame.isEmpty)
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 按钮必须禁用")
        model.setMode(.manual)
        for _ in 0..<200 { if camera.ready && model.mode == .manual { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.toolbarPanel = .format
        try await Task.sleep(for: .milliseconds(700))
        let manualFrame = try XCTUnwrap(model.captureButtonFramesForTesting["format.resolution.48"])
        XCTAssertFalse(manualFrame.isEmpty)
        XCTAssertTrue(model.canSelectPhotoResolution(.high), "M 挡 48MP 按钮应可用")
        model.photoResolution = .high
        model.setMode(.auto)
        for _ in 0..<200 { if model.mode == .auto && model.photoResolution == .standard { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.photoResolution, .standard, "M 48MP 切回 A 必须回退 12MP")
    }

    func testPhotoFilterEditorOpensWithDialPadByDefault() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.closePopups() }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.style = .leicaM9
        model.panel = .film
        model.filters.showStrength = true
        XCTAssertFalse(model.preferences.videoFilterDialPad)
        for _ in 0..<100 { if model.filterDialPadFrameForTesting.height > 200 { break }; try await Task.sleep(for: .milliseconds(30)) }
        let frame = model.filterDialPadFrameForTesting
        XCTAssertGreaterThan(frame.width, 250)
        XCTAssertGreaterThan(frame.height, 200)
        XCTAssertFalse(frame.isEmpty)
        print("DIAL-GEOMETRY panel=\(model.popupFrameForTesting) dial=\(frame) window=\(window.bounds)")
        XCTAssertLessThanOrEqual(model.popupFrameForTesting.maxY, window.bounds.maxY + 1, "测试宿主应遵循真实安全区，不把底部滑条截掉")
        let recipe = model.filterAdjustments
        let originalHeight = model.popupFrameForTesting.height
        for tab in FilterEditorTab.allCases {
            model.filterEditorTab = tab
            try await Task.sleep(for: .milliseconds(250))
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: shot)
            attachment.name = "Filter-Dial-" + tab.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(model.popupFrameForTesting.height, originalHeight, accuracy: 1, "三类弹窗高度必须固定")
        }
        // 重复切换、离开/返回编辑，不改写配方；横拿仍维持竖屏弹窗。
        for _ in 0..<5 {
            for tab in FilterEditorTab.allCases { model.filterEditorTab = tab; await Task.yield() }
        }
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.closePopups()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.filterDialPadFrameForTesting, .zero)
        model.panel = .film
        model.filters.showStrength = true
        for _ in 0..<100 {
            if model.filterDialPadFrameForTesting.height > 200 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(model.filterDialPadFrameForTesting.height, 200)
        XCTAssertEqual(model.filterAdjustments, recipe)
    }

    func testCompactDialFitsSupportedWidthsAndRotatedControlsForEveryPhotoRatio() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        defer { model.setCameraActive(false); model.closePopups() }
        var samples = 0
        for width: CGFloat in [390, 430] {
            for angle in [0.0, 90.0] {
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let controller = UIHostingController(rootView: CompactDialPanelHost(model: model, angle: angle))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 760)
                window.rootViewController = controller; window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                _ = controller.view
                model.style = .leicaM9
                model.panel = .film; model.filters.showStrength = true
                try await Task.sleep(for: .milliseconds(250))
                let height = model.popupFrameForTesting.height
                for ratio in FrameRatio.photoOptions {
                    model.ratio = ratio
                    for tab in FilterEditorTab.allCases {
                        model.filterEditorTab = tab
                        try await Task.sleep(for: .milliseconds(70))
                        // 宿主直接测量整个真实弹窗，不使用旧子视图退出时会清零的共享调试值。
                        let frame = model.popupFrameForTesting
                        XCTAssertGreaterThan(frame.height, 200)
                        XCTAssertGreaterThanOrEqual(frame.minX, -1)
                        XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                        XCTAssertLessThanOrEqual(frame.maxY, window.bounds.maxY + 1)
                        XCTAssertEqual(model.popupFrameForTesting.height, height, accuracy: 1)
                        if tab != .effects {
                            let plane = try XCTUnwrap(model.captureButtonFramesForTesting["filter.dial.plane"])
                            let track = try XCTUnwrap(model.captureButtonFramesForTesting["filter.dial.horizontalTrack"])
                            XCTAssertEqual(track.minX, plane.minX, accuracy: 1)
                            XCTAssertEqual(track.maxX, plane.maxX, accuracy: 1)
                            XCTAssertEqual(track.width, plane.width, accuracy: 1)
                        }
                        samples += 1
                    }
                }
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: shot)
                attachment.name = "Compact-Dial-width-\(Int(width))-angle-\(Int(angle))"
                attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden = true; window.rootViewController = nil
            }
        }
        print("DIAL-LAYOUT samples=\(samples) widths=390/430 controlAngles=0/90 ratios=7 tabs=3; hosted UI layout, no FPS claim")
    }

    func testNumericDialogDraftRestoreConfirmCancelAndKeyboardLayout() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.setCameraActive(true)
        defer { model.closePopups(); model.setCameraActive(false) }
        for _ in 0..<300 { if model.camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (controller, window) = try host(model)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        model.style = .leicaM9
        model.panel = .film; model.filters.showStrength = true
        model.filterEditorTab = .light
        try await Task.sleep(for: .milliseconds(300))
        let panel = model.popupFrameForTesting
        model.presentFilterNumericInput(.brightness)
        model.filterNumericDraft = "32.5"
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(descendants(controller.view).contains { ($0 as? UITextField)?.isFirstResponder == true }, "输入框必须真实获得键盘焦点")
        XCTAssertEqual(model.filterNumericValue, 32.5)
        XCTAssertEqual(model.filterAdjustments[.brightness], 0, "编辑草稿不能提前改变图像")
        XCTAssertEqual(model.popupFrameForTesting.minY, panel.minY, accuracy: 1, "键盘不能抬升底层滤镜面板")
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: shot); attachment.name = "Filter-Numeric-Input"
        attachment.lifetime = .keepAlways; add(attachment)
        model.confirmFilterNumericInput()
        XCTAssertEqual(model.filterAdjustments[.brightness], 32.5)
        XCTAssertNil(model.filterNumericParameter)
        model.presentFilterNumericInput(.brightness)
        model.restoreFilterNumericDraft()
        XCTAssertEqual(model.filterNumericValue, 0)
        model.dismissFilterNumericInput()
        XCTAssertEqual(model.filterAdjustments[.brightness], 32.5, "还原后取消仍应保留原值")
        model.presentFilterNumericInput(.brightness); model.restoreFilterNumericDraft(); model.confirmFilterNumericInput()
        XCTAssertEqual(model.filterAdjustments[.brightness], 0)
        model.presentFilterNumericInput(.exposure); model.filterNumericDraft = "-1.25"; model.confirmFilterNumericInput()
        XCTAssertEqual(model.filterAdjustments[.exposure], -1.25)
        model.presentFilterNumericInput(.exposure); model.filterNumericDraft = "99"; model.confirmFilterNumericInput()
        XCTAssertNotNil(model.filterNumericParameter)
        XCTAssertEqual(model.filterAdjustments[.exposure], -1.25)
        model.closePopups()
        XCTAssertNil(model.filterNumericParameter)
        _ = controller
    }

    func testStrengthFadeKeepsSamePreviewDynamicRange() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.intensity = 0.8; model.style = .original }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.hdr = false
        model.style = .leicaM9; model.intensity = 1
        try await Task.sleep(for: .milliseconds(700))
        for value in [1.0, 0.8, 0.5, 0.2, 0.05, 0.0] {
            model.intensity = value
            try await Task.sleep(for: .milliseconds(250))
            let bits = camera.preview?.cgImage?.bitsPerComponent ?? -1
            let headroom = camera.preview?.cgImage?.contentHeadroom ?? -1
            print("STRENGTH-FADE value=\(value) bits=\(bits) headroom=\(headroom) hdrActive=\(camera.hdrPreviewActive)")
        }
    }

    func testJPEGDisablesHDRAndManualHDRRestoresFilter() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.photoFormat = .jpeg; model.style = .original; model.setMode(.auto) }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.style = .leicaM9; model.intensity = 0.8
        model.setMode(.manual)
        model.hdr = true
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.effectiveCaptureLook.style, .original, "M挡HDR也应临时回原片")
        model.hdr = false
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9, "关闭HDR恢复M挡滤镜")
        model.photoFormat = .jpeg
        XCTAssertFalse(model.hdr, "JPG没有HDR，切换后应关闭")
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9)
    }

    func testDialPadStrengthUsesUniformLinearStrength() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.style = .leicaM9
        let binding = model.filterParameterBinding(.strength)
        binding.wrappedValue = 80
        XCTAssertEqual(model.intensity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 1, accuracy: 0.0001)
        binding.wrappedValue = 100
        XCTAssertEqual(model.intensity, 1, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 1.3, accuracy: 0.0001)
        binding.wrappedValue = 0
        XCTAssertEqual(model.intensity, 0, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: model.intensity), 0, accuracy: 0.0001)
    }

    func testHEIFProHDRKeepsProToneButDisablesFilters() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.setCaptureKind(.photo)
        model.photoFormat = .heifPro
        model.style = .leicaM9
        model.intensity = 0.8
        model.filterAdjustments[.contrast] = 20
        model.tone = .cinematic
        model.hdr = true
        let look = model.effectiveCaptureLook
        XCTAssertEqual(look.tone, .cinematic, "HEIF Pro HDR应保留Pro影调")
        XCTAssertEqual(look.style, .original, "HDR仍禁用滤镜")
        XCTAssertEqual(look.intensity, 0)
        XCTAssertTrue(look.adjustments.isNeutral)
        XCTAssertTrue(look.requiresImageProcessing, "影调必须进入HDR图像处理路径")
        model.photoFormat = .heif
        XCTAssertEqual(model.effectiveCaptureLook.tone, .natural, "非HEIF Pro不保留影调")
    }

    func testHDRSuppressesFilterTemporarilyAndRestoresIt() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false; model.style = .original; model.intensity = 0.8 }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (_, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo); model.photoFormat = .heif
        model.style = .leicaM9; model.intensity = 0.8
        model.hdr = true
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.style, .leicaM9, "HDR不应清空已选滤镜")
        XCTAssertEqual(model.effectiveCaptureLook.style, .original, "HDR拍摄临时使用原片")
        XCTAssertFalse(model.filtersEnabled, "HDR开启后滤镜入口禁用")
        XCTAssertEqual(model.style.filterButtonName, FilmStyle.leicaM9.filterButtonName, "HDR不应改滤镜按钮文字")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(camera.preview?.cgImage?.bitsPerComponent, 8, "HDR预览应为SDR")
        XCTAssertEqual(camera.preview?.cgImage?.contentHeadroom ?? -1, 1, accuracy: 0.01)
        model.hdr = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.filtersEnabled)
        XCTAssertEqual(model.style, .leicaM9)
        XCTAssertEqual(model.effectiveCaptureLook.style, .leicaM9, "关闭HDR后恢复原滤镜")
        XCTAssertEqual(model.effectiveCaptureLook.intensity, 0.8, accuracy: 0.001)
    }

    func testBurstCountOccupiesLiveToolbarSlot() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let (controller, window) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setCaptureKind(.photo)
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        if model.virtualApertureEnabled { model.toggleVirtualAperture() }
        if model.burstModeEnabled { model.toggleBurstMode() }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        model.ratio = .standard; model.setMode(.auto)
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        model.closePopups()
        for _ in 0..<300 { if camera.ready && !model.captureKindSwitching && !model.isPreparingSubmode && !camera.videoBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<300 { if camera.ready && camera.preview != nil && !model.isPreparingSubmode { break }; try await Task.sleep(for: .milliseconds(20)) }
        if !model.burstModeEnabled { model.toggleBurstMode() }
        for _ in 0..<300 { if model.burstModeEnabled { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.burstModeEnabled)
        try await Task.sleep(for: .milliseconds(700))
        _ = controller
        XCTAssertNotNil(model.captureButtonFramesForTesting["toolbar.burstCount"])
        XCTAssertNil(model.captureButtonFramesForTesting["toolbar.live"])
        if model.burstModeEnabled { model.toggleBurstMode() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(model.captureButtonFramesForTesting["toolbar.live"])
    }
}

/// 调色盘参数与手势回归：不启动相机、不创建系统相册资产。
@MainActor
final class CompactFilterDialTests: XCTestCase {
    func testAllParametersStayReachableAndVideoRetainsSavedEditorStyle() throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertFalse(CapturePreferences().videoFilterDialPad)
        XCTAssertTrue(model.usesFilterDialPad)
        model.setCaptureKind(.video)
        XCTAssertFalse(model.usesFilterDialPad)
        let legacyData = Data(#"{"filterDialPad":true}"#.utf8)
        model.preferences = try JSONDecoder().decode(CapturePreferences.self, from: legacyData)
        XCTAssertTrue(model.usesFilterDialPad)
        model.setCaptureKind(.photo)
        XCTAssertTrue(model.usesFilterDialPad)
        for tab in FilterEditorTab.allCases {
            let layout = FilterDialLayout.layout(for: tab)
            XCTAssertEqual(Set(layout.parameters), Set(tab.parameters))
            XCTAssertEqual(layout.parameters.count, Set(layout.parameters).count, "同页不能重复放置参数")
        }
        XCTAssertTrue(FilterDialLayout.layout(for: .effects).bottom.isEmpty)
        XCTAssertEqual(FilterDialLayout.layout(for: .effects).vertical,
                       [.detail, .softness, .halation, .grainSize, .grainSaturation, .aberration, .vignette])
    }

    func testPairCommitsOncePreservesIndependentValuesAndRejectsStaleGestures() throws {
        let suite = "Luma.Dial." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilterSettingsStore(defaults: defaults)
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: store)
        model.filterEditorTab = .effects
        model.style = .leicaM9
        model.intensity = 0.8
        model.filterParameterBinding(.softness).wrappedValue = 20
        model.filterParameterBinding(.halation).wrappedValue = 60
        let pair = model.filterParameterPairBinding(.softness, .halation)
        XCTAssertEqual(pair.wrappedValue, CGPoint(x: 20, y: 60))
        var publications = 0
        let token = model.$filterAdjustments.dropFirst().sink { _ in publications += 1 }
        defer { token.cancel() }
        var times: [Double] = []
        for index in 0..<300 {
            let start = CACurrentMediaTime()
            pair.wrappedValue = CGPoint(x: index % 100, y: (index + 40) % 100)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        XCTAssertEqual(publications, 300, "每次二维输入只发布一次配方")
        XCTAssertEqual(model.intensity, 0.8, "调色盘参数不能反向改写基础滤镜浓度")
        let recipe = model.filterAdjustments
        pair.wrappedValue = CGPoint(x: CGFloat.nan, y: 10)
        XCTAssertEqual(model.filterAdjustments, recipe)
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.filterEditorTab = .light
        pair.wrappedValue = CGPoint(x: 90, y: 90)
        XCTAssertEqual(model.filterAdjustments, recipe, "切页后的旧手势不能污染配方")
        model.filterEditorTab = .effects
        let beforeReset = model.filterParameterPairBinding(.softness, .halation)
        model.presentFilterReset()
        beforeReset.wrappedValue = CGPoint(x: 80, y: 90)
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.dismissFilterReset()
        model.resetCurrentFilter()
        beforeReset.wrappedValue = CGPoint(x: 80, y: 90)
        XCTAssertTrue(model.filterAdjustments.isNeutral)
        times.sort()
        print("DIAL-PAIR samples=300 medianMs=\(times[150]) p95Ms=\(times[285]) publications=\(publications); binding submission only, not frame rate")
    }

    func testTextureRailsStayIndependentAndPanelSnapshotCost() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel()
        model.style = .leicaM9
        model.filterEditorTab = .effects
        let parameters = FilterDialLayout.layout(for: .effects).vertical
        var expected = model.filterAdjustments
        var writes = 0
        for index in 0..<140 {
            let parameter = parameters[index % parameters.count]
            let value = parameter.range.lowerBound + Double(index % 101) / 100 * (parameter.range.upperBound - parameter.range.lowerBound)
            model.filterParameterBinding(parameter).wrappedValue = value
            expected[parameter] = value
            XCTAssertEqual(model.filterAdjustments, expected, "单轨调整不能改写相邻参数")
            writes += 1
        }
        let recipe = model.filterAdjustments
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: CompactDialPanelHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.closePopups() }
        var times: [Double] = []
        for tab in FilterEditorTab.allCases {
            model.filterEditorTab = tab
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<12 {
                let start = CACurrentMediaTime()
                window.layoutIfNeeded()
                _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                times.append((CACurrentMediaTime() - start) * 1000)
            }
        }
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.filterEditorTab = .effects
        let oldBindings = parameters.map { model.filterParameterBinding($0) }
        model.presentFilterReset(); model.dismissFilterReset()
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.resetCurrentFilter()
        for binding in oldBindings { binding.wrappedValue = 95 }
        XCTAssertTrue(model.filterAdjustments.isNeutral, "重置后七条旧手势均应失效")
        times.sort()
        print("TEXTURE-UI independentWrites=\(writes) snapshotSamples=\(times.count) medianMs=\(times[times.count/2]) p95Ms=\(times[Int(Double(times.count)*0.95)]); hosted snapshot cost only, not actual FPS")
    }

    func testNumericInputRangesDefaultsAndRapidCancellation() throws {
        XCTAssertEqual(FilterParameter.brightness.numericDisplayText(32.5), "32.5")
        XCTAssertEqual(FilterParameter.exposure.numericDisplayText(-1.25), "-1.25")
        XCTAssertEqual(FilterParameter.exposure.inputValue(from: "－１.２５"), -1.25)
        XCTAssertEqual(FilterParameter.exposure.inputValue(from: "0,5"), 0.5)
        for parameter in FilterParameter.allCases {
            XCTAssertNotNil(parameter.inputValue(from: String(parameter.range.lowerBound)))
            XCTAssertNotNil(parameter.inputValue(from: String(parameter.range.upperBound)))
            for text in ["", "NaN", "inf", "1.2.3", String(parameter.range.upperBound + 1)] {
                XCTAssertNil(parameter.inputValue(from: text))
            }
            XCTAssertEqual(parameter.defaultValue, parameter == .strength ? 80 : 0)
        }
        let suite = "Luma.Numeric." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: FilterSettingsStore(defaults: defaults))
        model.style = .leicaM9
        model.panel = .film; model.filters.showStrength = true
        let recipe = model.filterAdjustments
        let start = CACurrentMediaTime()
        for _ in 0..<100 {
            model.presentFilterNumericInput(.fade); model.filterNumericDraft = "75"
            model.restoreFilterNumericDraft(); model.dismissFilterNumericInput()
        }
        XCTAssertEqual(model.filterAdjustments, recipe)
        model.intensity = 0.3
        model.presentFilterNumericInput(.strength); model.restoreFilterNumericDraft(); model.confirmFilterNumericInput()
        XCTAssertEqual(model.intensity, 0.8)
        model.presentFilterNumericInput(.fade); model.filterNumericDraft = "80"; model.style = .fujiNC
        model.confirmFilterNumericInput()
        XCTAssertNil(model.filterNumericParameter)
        XCTAssertEqual(model.filterAdjustments[.fade], 0)
        print("FILTER-NUMERIC cycles=100 draftCancelTotalMs=\((CACurrentMediaTime()-start)*1000); state lifecycle only, excludes keyboard and rendering")
    }

    func testTabResetPreservesOtherCategoriesAndPersistsWithoutStaleWrites() throws {
        let suite = "Luma.TabReset." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppDependencies.makeCameraModel(automaticallySave: false, filterSettings: FilterSettingsStore(defaults: defaults))
        model.style = .leicaM9
        var timings: [Double] = []
        for _ in 0..<10 {
            for tab in FilterEditorTab.allCases {
                model.filterEditorTab = tab
                model.intensity = 0.35
                var initial = FilterAdjustments()
                for parameter in FilterParameter.allCases where parameter != .strength {
                    initial[parameter] = parameter == .exposure ? 1.2 : 24
                }
                model.filterAdjustments = initial
                let old = tab.parameters.map { model.filterParameterBinding($0) }
                let start = CACurrentMediaTime()
                model.resetCurrentFilterTab()
                timings.append((CACurrentMediaTime() - start) * 1000)
                for parameter in FilterParameter.allCases where parameter != .strength {
                    XCTAssertEqual(model.filterAdjustments[parameter], tab.parameters.contains(parameter) ? 0 : initial[parameter])
                }
                XCTAssertEqual(model.intensity, tab == .color ? 0.8 : 0.35)
                let result = model.filterAdjustments
                for binding in old { binding.wrappedValue = 90 }
                XCTAssertEqual(model.filterAdjustments, result)
                XCTAssertEqual(model.intensity, tab == .color ? 0.8 : 0.35)
                let saved = FilterSettingsStore(defaults: defaults).settings(for: .leicaM9)
                XCTAssertEqual(saved.adjustments, result)
                XCTAssertEqual(saved.intensity, model.intensity)
            }
        }
        model.filterEditorTab = .light
        model.filterParameterBinding(.brightness).wrappedValue = 12
        model.panel = .film; model.filters.showStrength = true
        model.presentFilterNumericInput(.brightness); model.filterNumericDraft = "70"
        model.resetCurrentFilterTab(); model.confirmFilterNumericInput()
        XCTAssertNil(model.filterNumericParameter)
        XCTAssertEqual(model.filterAdjustments[.brightness], 0)
        model.presentFilterReset()
        let before = model.filterAdjustments
        model.resetCurrentFilterTab()
        XCTAssertEqual(model.filterAdjustments, before)
        model.dismissFilterReset()
        timings.sort()
        print("FILTER-TAB-RESET samples=30 medianMs=\(timings[15]) p95Ms=\(timings[28]); state/save/flush submission, excludes preview rendering")
    }

    func testPadEndpointAndNeutralMappingsMatchVisibleHandle() {
        // 包含描边后的圆形滑块在轨道端部圆帽内，横竖共用相同几何约束。
        let capRadius = FilterDialGeometry.trackThickness / 2
        let thumbRadiusWithStroke = FilterDialGeometry.thumbDiameter / 2 + 0.75
        XCTAssertLessThanOrEqual(abs(FilterDialGeometry.inset - capRadius) + thumbRadiusWithStroke, capRadius)
        for length: CGFloat in [80, 124, 180, 240] {
            for parameter in FilterParameter.allCases {
                let range = parameter.range
                for value in [range.lowerBound, 0, range.upperBound] {
                    let fraction = FilterDialGeometry.fraction(value, in: range)
                    let coordinate = 13 + CGFloat(fraction) * (length - 26)
                    XCTAssertEqual(FilterDialGeometry.value(at: coordinate, length: length, in: range), value, accuracy: 0.00001)
                }
            }
        }
    }
}

/// 独立承载真实参数弹窗，避免测试关闭相机会话时把待检查的弹窗也关闭。
private struct CompactDialPanelHost: View {
    @ObservedObject var model: CameraViewModel
    let angle: Double
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            CameraView(model: model).filterAdjustmentPanel
                .environment(\.captureControlAngle, 0)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.popupFrameForTesting = $0 }
        }
        .environment(\.captureControlAngle, angle)
        .background(Color.black)
    }
}
