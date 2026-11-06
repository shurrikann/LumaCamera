import XCTest
import UIKit
import SwiftUI
import ImageIO
@testable import LumaCamera

@MainActor
final class CameraFocalButtonTests: XCTestCase {
    func testLiveFocalButtonHitAndActualZoom() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: CameraView(model:model).environment(\.scenePhase,.active).environment(\.captureControlAngle,0).frame(width:390,height:760))
        let window = UIWindow(windowScene:scene); window.frame = CGRect(x:0,y:0,width:390,height:760)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false; model.setMode(.auto); model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil && camera.supportsLivePhoto { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready); XCTAssertTrue(camera.supportsLivePhoto)
        let lens = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.001 })
        model.selectFocalLength(lens)
        for _ in 0..<400 { if camera.ready && camera.selectedLens == lens.id && abs(camera.currentZoom-1)<0.02 { break }; try await Task.sleep(for:.milliseconds(20)) }
        camera.setContinuousZoom(1)
        await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
        if !model.livePhotoEnabled { model.toggleLivePhoto() }
        for _ in 0..<400 { if model.capturesLivePhoto && camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.capturesLivePhoto)
        if let image = camera.preview { let a = XCTAttachment(image:image); a.name = "Live-24mm-preview"; a.lifetime = .keepAlways; add(a) }
        func descendants(_ view:UIView)->[UIView] { [view] + view.subviews.flatMap(descendants) }
        for expected in [CGFloat(28.0/24.0), CGFloat(35.0/24.0), 1, CGFloat(28.0/24.0)] {
            try await Task.sleep(for:.milliseconds(250)); host.view.layoutIfNeeded()
            let button = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == lens.accessibilityDescription })
            XCTAssertTrue(button.isEnabled)
            let point = button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:window)
            let hit = window.hitTest(point,with:nil)
            XCTAssertTrue(hit === button || hit?.isDescendant(of:button) == true, "Live时焦段按钮须接收触摸")
            button.sendActions(for:.touchUpInside)
            await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
            var actual:CGFloat = 0
            for _ in 0..<250 {
                actual = await withCheckedContinuation { c in camera.zoomStateForTesting { zoom,_,_ in c.resume(returning:zoom) } }
                if abs(actual-expected)<0.025 { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertEqual(actual,expected,accuracy:0.025); XCTAssertTrue(model.livePhotoEnabled)
            try await Task.sleep(for:.milliseconds(500))
            let settled = await withCheckedContinuation { c in camera.zoomStateForTesting { zoom,_,_ in c.resume(returning:zoom) } }
            XCTAssertEqual(settled,expected,accuracy:0.025,"Live 预览稳定后硬件倍率不应回退")
            if let image = camera.preview { let a = XCTAttachment(image:image); a.name = "Live-preview-\(expected)"; a.lifetime = .keepAlways; add(a) }
        }
    }
    func testHostedFocalStripHitTargetsAfterRepeatedSelections() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        let callback = camera.onCaptureCompleted
        var photos = [CapturedPhoto]()
        camera.onCaptureCompleted = { if let photo = $0 { photos.append(photo) } }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        let host = UIHostingController(rootView:CameraView(model:model).environment(\.scenePhase,.active)
            .environment(\.captureControlAngle,0)
            .frame(width:390,height:760))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene); window.frame = CGRect(x:0,y:0,width:390,height:760)
        let prior = scene.windows.first { $0.isKeyWindow }
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        func descendants(_ view:UIView)->[UIView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
        model.setCameraActive(true); model.setCaptureKind(.photo)
        if model.nightModeEnabled { model.toggleNightMode() }
        if model.portraitModeEnabled { model.togglePortraitMode() }
        if model.slowShutterEnabled { model.toggleSlowShutterMode() }
        if model.virtualApertureEnabled { model.toggleVirtualAperture() }
        if model.burstModeEnabled { model.toggleBurstMode() }
        model.setMode(.auto); model.photoFormat = .jpeg; model.photoResolution = .standard
        model.hdr = false; model.ratio = .standard
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        camera.setContinuousZoom(1)
        try await Task.sleep(for:.milliseconds(300))
        let lenses = camera.lenses.filter { $0.device.position == model.currentPosition }
        XCTAssertFalse(lenses.isEmpty)
        var hits = 0
        for lens in lenses {
            let button = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == lens.accessibilityDescription })
            let point = button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:window)
            let hit = window.hitTest(point,with:nil)
            print("FOCAL-HIT label=\(lens.accessibilityDescription) enabled=\(button.isEnabled) hit=\(String(describing:hit.map { type(of:$0) })) point=\(point)")
            XCTAssertTrue(hit === button || hit?.isDescendant(of:button) == true,"焦段中心触摸必须交给原生按钮")
            if hit === button || hit?.isDescendant(of:button) == true { hits += 1 }
            let visualEffects = descendants(button).compactMap { $0 as? UIVisualEffectView }
                .filter { !$0.isHidden && $0.effect != nil }
            XCTAssertTrue(visualEffects.isEmpty,"共同背景内不能再有选中玻璃")
        }
        func waitReady() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<1000 {
                if camera.ready && !camera.highResolutionPhotoConfiguring { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail("焦段切换未恢复就绪"); throw CancellationError()
        }
        func button(_ lens:CameraLens) throws -> UIButton {
            try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == lens.accessibilityDescription })
        }
        let main = try XCTUnwrap(lenses.first { abs($0.displayZoom-1)<0.001 })
        func captureDimensions(high:Bool) async throws {
            let before = photos.count
            model.ratio = .standard
            let cfg = await withCheckedContinuation { c in camera.photoOutputConfigurationForTesting { c.resume(returning:$0) } }
            print("FOCAL48-PRE high=\(high) modelResolution=\(model.photoResolution.rawValue) options=\(model.photoOptions.resolution.rawValue) mode=\(model.mode.rawValue) cfg=\(cfg)")
            camera.capture(flashMode:.off,options:model.photoOptions)
            for _ in 0..<1500 {
                if photos.count > before && camera.pendingPhotoCount == 0 { break }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTAssertEqual(photos.count,before+1)
            let data = try XCTUnwrap(photos.last?.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            if high { XCTAssertGreaterThan(width*height,40_000_000) }
            else { XCTAssertGreaterThan(width*height,10_000_000); XCTAssertLessThan(width*height,30_000_000) }
            print("FOCAL48-FILE high=\(high) size=\(width)x\(height) noPhotosWrites=true")
        }
        var switchTimes = [Double]()
        model.setMode(.manual)
        try await Task.sleep(for: .milliseconds(1100))
        try await waitReady()
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false; model.ratio = .standard
        for lens in lenses.filter({ $0.id != main.id && camera.highResolutionLensIDs.contains($0.id) }) {
            XCTAssertTrue(model.canSelectPhotoResolution(.high), "M 挡应可切换 48MP")
            model.photoResolution = .high
            try await waitReady(); try await Task.sleep(for:.milliseconds(200))
            XCTAssertEqual(model.photoResolution,.high)
            let mainButton = try button(main)
            XCTAssertTrue(mainButton.isEnabled)
            mainButton.sendActions(for:.touchUpInside)
            try await waitReady()
            XCTAssertEqual(model.photoResolution,.high,"点击当前1×应保留48MP，不切35mm")
            XCTAssertEqual(camera.currentZoom,1,accuracy:0.015)
            if switchTimes.isEmpty { try await captureDimensions(high:true); try await waitReady() }
            let target = try button(lens); XCTAssertTrue(target.isEnabled,"48MP不能禁用整条焦段")
            let began = CACurrentMediaTime()
            target.sendActions(for:.touchUpInside)
            try await waitReady()
            XCTAssertEqual(camera.selectedLens,lens.id)
            XCTAssertEqual(model.photoResolution,.high)
            XCTAssertEqual(camera.currentZoom,lens.displayZoom,accuracy:0.02)
            switchTimes.append(CACurrentMediaTime()-began)
            if switchTimes.count == 1 { try await captureDimensions(high:true); try await waitReady() }
        }
        model.photoResolution = .standard; try await waitReady()
        model.selectFocalLength(main); try await waitReady()
        var layoutHits = 0
        let baselineY = try button(main).convert(CGPoint.zero,to:window).y
        for ratio in FrameRatio.photoOptions { for angle in [0.0,90.0] {
            model.ratio = ratio
            host.rootView = CameraView(model:model).environment(\.scenePhase,.active)
                .environment(\.captureControlAngle,angle).frame(width:390,height:760)
            try await Task.sleep(for:.milliseconds(240)); host.view.layoutIfNeeded()
            for lens in lenses {
                let control = try button(lens)
                let point = control.convert(CGPoint(x:control.bounds.midX,y:control.bounds.midY),to:window)
                let hit = window.hitTest(point,with:nil)
                XCTAssertTrue(hit === control || hit?.isDescendant(of:control) == true)
                XCTAssertEqual(control.convert(CGPoint.zero,to:window).y,baselineY,accuracy:1)
                layoutHits += 1
            }
        } }
        let selected = try button(main); selected.isHighlighted = true
        let renderer = UIGraphicsImageRenderer(bounds:host.view.bounds)
        let image = renderer.image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "FocalStrip-selected-pressed-single-background"; attachment.lifetime = .keepAlways; add(attachment)
        selected.isHighlighted = false
        model.openZoomDial(); model.finishZoomDrag(); model.endZoomDial()
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertFalse(model.zoomDialVisible)
        print("FOCAL-HOST checkedHits=\(hits) layoutHits=\(layoutHits) configurations=\(FrameRatio.photoOptions.count*2) high48SwitchSamples=\(switchTimes.count) switchReadySeconds=\(switchTimes) actualWindowHitTest=true nativeControlActions=true noSyntheticFingerTap=true")
    }
    /// 在有共同玻璃背景的焦段条里反复点选，不应生成第二层选中玻璃；独立按钮保留玻璃。
    func testEnclosingGlassAvoidsNestedSelectionLayerAcrossRepeatedLayouts() throws {
        let start = CACurrentMediaTime()
        for enclosed in [true, false] {
            let component = CameraFocalButton(title: "1", selected: true, enabled: true,
                accessibilityLabel: "1倍", usesEnclosingGlassBackground: enclosed,
                onTap: {}, onLongPress: {}, onDrag: { _, _ in }, onFinish: {})
            let button = component.makeButton(coordinator: component.makeCoordinator())
            for index in 0..<100 {
                button.isSelected = index % 2 == 0
                let side: CGFloat = index % 3 == 0 ? 24 : 40
                button.frame = CGRect(x: 0, y: 0, width: side, height: side)
                button.isHighlighted = index % 4 == 0
                button.setNeedsLayout(); button.layoutIfNeeded()
                let visibleEffects = button.subviews.compactMap { $0 as? UIVisualEffectView }
                    .filter { !$0.isHidden && $0.effect != nil }
                if #available(iOS 26.0, *) {
                    XCTAssertEqual(visibleEffects.count, !enclosed && button.isSelected ? 1 : 0)
                    if let effect = visibleEffects.first?.effect { XCTAssertTrue(effect is UIGlassEffect) }
                }
                if enclosed || !button.isSelected { XCTAssertEqual(button.backgroundColor, .clear) }
                XCTAssertLessThanOrEqual(button.subviews.filter { $0 is UIVisualEffectView }.count, 1,
                    "反复布局不能累积视觉效果视图")
            }
        }
        print("FOCAL-GLASS layouts=200 enclosedAndStandalone=true seconds=\(CACurrentMediaTime()-start); native layout work only, not screen FPS")
    }

    func testRotatedShortAndLongFocalTitlesKeepSquareSpaceWithoutEllipsis() throws {
        for title in ["0.5", "1", "24mm", "28mm", "35mm", "11.7x", "40x"] {
            let component = CameraFocalButton(title: title, selected: true, enabled: true, accessibilityLabel: title,
                onTap: {}, onLongPress: {}, onDrag: { _, _ in }, onFinish: {})
            let button = component.makeButton(coordinator: component.makeCoordinator())
            button.frame = CGRect(x: 0, y: 0, width: 40, height: 40); button.setTitle(title, for: .normal)
            for angle in [0.0, Double.pi / 2, -Double.pi / 2] {
                button.titleLabel?.transform = CGAffineTransform(rotationAngle: angle)
                button.setNeedsLayout(); button.layoutIfNeeded()
                let label = try XCTUnwrap(button.titleLabel)
                XCTAssertEqual(label.bounds.width, 34, accuracy: 0.01)
                XCTAssertEqual(label.bounds.height, 34, accuracy: 0.01)
                XCTAssertTrue(button.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame))
                XCTAssertEqual(label.text, title); XCTAssertEqual(label.lineBreakMode, .byClipping)
            }
        }
    }
    func testNativeButtonHasWorkingTapTargetAndLongPressCancelsTapTracking() {
        var taps = 0
        let component = CameraFocalButton(title: "2x", selected: false, enabled: true, accessibilityLabel: "2x",
            onTap: { taps += 1 }, onLongPress: {}, onDrag: { _, _ in }, onFinish: {})
        let coordinator = component.makeCoordinator()
        let button = component.makeButton(coordinator: coordinator)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 1)
        let recognizer = button.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.minimumPressDuration, 0.4)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, true)
        coordinator.handlePress(.began, x: 50, width: 300)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 1)
        coordinator.handlePress(.ended, x: 50, width: 300)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 2)
    }

    func testHiddenButtonRejectsNewTouchesAndPreservesStartedLongPress() {
        var holds=0,drags=0,finishes=0,taps=0
        let shown=CameraFocalButton(title:"1×",selected:true,enabled:true,accessibilityLabel:"1倍",
            onTap:{taps += 1},onLongPress:{holds += 1},onDrag:{_,_ in drags += 1},onFinish:{finishes += 1})
        let coordinator=shown.makeCoordinator()
        let button=shown.makeButton(coordinator:coordinator);button.frame=CGRect(x:0,y:0,width:44,height:44)
        XCTAssertTrue(button.point(inside:CGPoint(x:22,y:22),with:nil))
        coordinator.handlePress(.began,x:50,width:300)
        var hidden=shown;hidden.acceptsNewTouches={false}
        coordinator.parent=hidden
        let hiddenButton=hidden.makeButton(coordinator:coordinator);hiddenButton.frame=button.frame
        XCTAssertFalse(hiddenButton.point(inside:CGPoint(x:22,y:22),with:nil))
        coordinator.handlePress(.changed,x:30,width:300)
        coordinator.handlePress(.ended,x:30,width:300)
        coordinator.tap();coordinator.handlePress(.began,x:50,width:300)
        XCTAssertEqual(holds,1);XCTAssertEqual(drags,1);XCTAssertEqual(finishes,1);XCTAssertEqual(taps,0)
        coordinator.parent=shown;coordinator.tap();XCTAssertEqual(taps,1)
    }

    func testShortTapSelectsWithoutOpeningDial() {
        var taps = 0, holds = 0
        let button = CameraFocalButton(title: "2×", selected: false, enabled: true, accessibilityLabel: "2倍",
            onTap: { taps += 1 }, onLongPress: { holds += 1 }, onDrag: { _, _ in }, onFinish: {})
        let coordinator = button.makeCoordinator()
        coordinator.handlePress(.possible, x: 50, width: 300)
        coordinator.handlePress(.failed, x: 50, width: 300)
        coordinator.tap()
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(holds, 0)
    }

    func testLongPressDragsAndFinishesWithoutSelectingFocalLength() {
        var taps = 0, holds = 0, finishes = 0
        var translation: CGFloat = 0
        let button = CameraFocalButton(title: "2×", selected: false, enabled: true, accessibilityLabel: "2倍",
            onTap: { taps += 1 }, onLongPress: { holds += 1 },
            onDrag: { translation = $0; XCTAssertEqual($1, 300) }, onFinish: { finishes += 1 })
        let coordinator = button.makeCoordinator()
        coordinator.handlePress(.began, x: 50, width: 300)
        coordinator.tap() // A long press cannot invoke the normal tap action.
        coordinator.handlePress(.changed, x: 30, width: 300)
        coordinator.handlePress(.ended, x: 30, width: 300)
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(translation, -20)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(taps, 0)
        coordinator.tap()
        XCTAssertEqual(taps, 1) // The following short tap remains available.
    }

    func testCancellationAndDisabledButtonDoNotSelect() {
        var calls = 0, finishes = 0
        var button = CameraFocalButton(title: "1×", selected: true, enabled: true, accessibilityLabel: "1倍",
            onTap: { calls += 1 }, onLongPress: {}, onDrag: { _, _ in }, onFinish: { finishes += 1 })
        let coordinator = button.makeCoordinator()
        coordinator.handlePress(.began, x: 50, width: 300)
        coordinator.handlePress(.cancelled, x: 50, width: 300)
        coordinator.finish()
        XCTAssertEqual(finishes, 1)
        button = CameraFocalButton(title: "1×", selected: true, enabled: false, accessibilityLabel: "1倍",
            onTap: { calls += 1 }, onLongPress: { calls += 1 }, onDrag: { _, _ in }, onFinish: {})
        coordinator.parent = button
        coordinator.tap()
        coordinator.handlePress(.began, x: 50, width: 300)
        XCTAssertEqual(calls, 0)
    }
}
