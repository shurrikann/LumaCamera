import XCTest
import SwiftUI
import AVFoundation
import ImageIO
@testable import LumaCamera

private struct VirtualApertureHost: View {
    @ObservedObject var model: CameraViewModel
    let angle: Double
    var body: some View {
        CameraView(model: model)
            .environment(\.captureControlAngle, angle)
            .environment(\.scenePhase, .active)
            .preferredColorScheme(.dark)
    }
}

final class VirtualAperturePhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// 用户真实触摸SwiftUI滑条；观察窗口内没有测试代码写入光圈值。
    @MainActor func testRealFingerToolbarApertureChangesBinding() async throws {
        let model=try await FullDeviceRegressionFixture.makeFreshModel(),camera=model.camera
        let idle=UIApplication.shared.isIdleTimerDisabled,audit=SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled=true
        // 真手势必须作用于用户实际看到的App窗口，不能另建一份共享model的相机树。
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}
            .first{$0.activationState == .foregroundActive})
        let window=try XCTUnwrap(scene.windows.first{$0.isKeyWindow && !$0.isHidden})
        func attachScreen(_ name:String) {
            let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
            let attachment=XCTAttachment(image:image);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        }
        defer {
            attachScreen("Aperture-real-window-end")
            model.dismissDepthControls();model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled=idle;audit.finish()
        }
        func wait(_ label:String,timeout:Double = 20,_ predicate:()->Bool) async throws {
            let deadline=CACurrentMediaTime()+timeout
            while CACurrentMediaTime()<deadline {if predicate(){return};try await Task.sleep(for:.milliseconds(20))}
            XCTFail(label);throw CancellationError()
        }
        model.setCameraActive(true);try await wait("相机"){camera.ready && camera.preview != nil}
        model.setMode(.manual)
        await withCheckedContinuation{c in camera.afterPendingSessionTasks{c.resume()}}
        try await wait("M挡取景"){camera.ready && !camera.macroActive && model.focalTransitionImage == nil}
        model.toggleVirtualAperture()
        try await wait("光圈开启"){camera.ready && model.virtualApertureEnabled && !model.isPreparingSubmode}
        model.toggleVirtualApertureSlider();model.setDepthControlEditing(true)
        try await wait("顶部滑条"){model.depthControlPopupVisible && model.captureButtonFramesForTesting["depthControlPopup"] != nil}
        try await Task.sleep(for:.milliseconds(250))
        var samples=[(Double,Double)]()
        let subscription=model.$virtualAperture.dropFirst().removeDuplicates().sink{value in
            samples.append((CACurrentMediaTime(),VirtualApertureRenderer.position(for:value)))
        }
        defer {subscription.cancel()}
        attachScreen("Aperture-real-window-ready")
        print("APERTURE-GESTURE-READY popup=\(String(describing:model.captureButtonFramesForTesting["depthControlPopup"])) awaitingRealTouch=true")
        try await wait("需要在当前顶部光圈滑条实际左右拖动",timeout:120){
            guard samples.count>=12,let first=samples.first else{return false}
            let values=samples.map{$0.1}
            return (values.max() ?? 0)-(values.min() ?? 0)>0.7 && CACurrentMediaTime()-first.0>2
        }
        let values=samples.map{$0.1}
        print("APERTURE-GESTURE-END realChanges=\(samples.count) range=\(values.min() ?? 0)...\(values.max() ?? 0) observationSeconds=\((samples.last?.0 ?? 0)-(samples.first?.0 ?? 0)) noTestWritesDuringObservation=true")
        let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
        let attachment=XCTAttachment(image:image);attachment.name="Aperture-real-finger-toolbar";attachment.lifetime = .keepAlways;add(attachment)
    }

    /// 验证效果开关及连续调节不会改写系统焦点；不把AF模式正确等同所有主体都能合焦。
    @MainActor func testVirtualAperturePreservesAutoTapAndManualFocus() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let audit = SessionRuntimeErrorAudit(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.preferences.focusAssist = false
        defer { model.setFilterParameterEditing(false); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func state() async -> CameraEngine.ExposureColorState? {
            await withCheckedContinuation { c in camera.exposureColorState { c.resume(returning: $0) } }
        }
        func snapshot() async throws -> CameraEngine.ExposureColorState {
            let value = await state(); return try XCTUnwrap(value)
        }
        func wait(_ label: String, _ condition: () async -> Bool) async throws {
            let deadline = CACurrentMediaTime() + 15
            while CACurrentMediaTime() < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail(label); throw CancellationError()
        }
        model.setCameraActive(true)
        try await wait("启动") { camera.ready && camera.preview != nil }
        model.setMode(.manual)
        try await wait("M挡") { await state()?.engineManual == true && camera.ready }
        let lenses = camera.lenses.filter { $0.device.position == .back &&
            (($0.device.deviceType == .builtInWideAngleCamera && abs($0.displayZoom - 1) < 0.01) || $0.device.deviceType == .builtInTelephotoCamera) }
        XCTAssertGreaterThanOrEqual(lenses.count, 2) // 长焦包含4×与8×两个逻辑倍率。
        for lens in lenses {
            model.selectFocalLength(lens)
            try await wait("切镜") { camera.selectedLens == lens.id && camera.ready }
            for position in [0.25, 0.75] {
                model.manualFocus = true; model.focus = position; camera.setFocus(position: position)
                try await wait("手动焦点") { guard let s = await state() else { return false }; return s.focusMode == .locked && !s.adjustingFocus && abs(Double(s.lensPosition) - position) < 0.01 }
                let before = try await snapshot()
                model.toggleVirtualAperture()
                XCTAssertTrue(model.virtualApertureEnabled)
                model.setFilterParameterEditing(true)
                let start = CACurrentMediaTime()
                for n in 0..<60 { model.virtualAperturePosition = Double(n)/59; try await Task.sleep(for: .milliseconds(16)) }
                model.setFilterParameterEditing(false)
                let after = try await snapshot()
                XCTAssertEqual(after.deviceID, before.deviceID); XCTAssertEqual(after.focusMode, .locked)
                XCTAssertEqual(after.lensPosition, before.lensPosition, accuracy: 0.02)
                XCTAssertEqual(after.focusPoint, before.focusPoint)
                model.toggleVirtualAperture()
                let off = try await snapshot()
                XCTAssertEqual(off.focusMode, .locked); XCTAssertEqual(off.lensPosition, before.lensPosition, accuracy: 0.02)
                print("VIRTUAL-FOCUS-M lens=\(lens.device.deviceType.rawValue) requested=\(position) actual=\(after.lensPosition) wall=\(CACurrentMediaTime()-start)")
            }
            model.manualFocus = false; camera.setFocus(position: nil)
            try await wait("连续AF") { await state()?.focusMode == .continuousAutoFocus }
            for enabled in [false, true] {
                if model.virtualApertureEnabled != enabled { model.toggleVirtualAperture() }
                for target in [CGPoint(x: 90, y: 200), CGPoint(x: 210, y: 200)] {
                    // 从已知焦点释放自动调焦，读取实际镜头位置而非仅验证UI数字。
                    camera.setFocus(position: 0.1)
                    try await wait("自动检查前锁焦") { guard let s = await state() else { return false }; return s.focusMode == .locked && abs(s.lensPosition - 0.1) < 0.03 }
                    let seed = try await snapshot()
                    let began = CACurrentMediaTime()
                    model.focusPreview(at: target, size: CGSize(width: 300, height: 400))
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    let point = try await snapshot()
                    XCTAssertEqual(point.focusMode, .continuousAutoFocus)
                    model.virtualAperture = 4; model.virtualAperture = 16
                    await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
                    let after = try await snapshot()
                    XCTAssertEqual(after.focusMode, .continuousAutoFocus); XCTAssertEqual(after.focusPoint, point.focusPoint)
                    let submitted = CACurrentMediaTime() - began
                    // 固定观察0.8秒，记录AF真实移动；观察窗口不保证最终合焦精度。
                    try await Task.sleep(for: .milliseconds(800))
                    let observed = try await snapshot()
                    XCTAssertEqual(observed.focusMode, .continuousAutoFocus)
                    print("VIRTUAL-FOCUS-OBSERVE enabled=\(enabled) start=\(seed.lensPosition) end=\(observed.lensPosition) adjusting=\(observed.adjustingFocus)")
                    print("VIRTUAL-FOCUS-TAP lens=\(lens.device.deviceType.rawValue) enabled=\(enabled) target=\(target) sensor=\(point.focusPoint) config=\(submitted)")
                }
            }
            model.toggleVirtualAperture()
        }
        model.setMode(.auto)
        try await wait("A挡") { await state()?.engineManual == false && camera.ready }
        for _ in 0..<3 {
            model.toggleVirtualAperture(); XCTAssertTrue(model.virtualApertureEnabled)
            camera.setFocus(position: nil)
            try await wait("A挡AF") { await state()?.focusMode == .continuousAutoFocus }
            let before = try await snapshot()
            model.virtualAperture = 16; model.resetVirtualAperture()
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let after = try await snapshot()
            XCTAssertEqual(after.focusMode, .continuousAutoFocus); XCTAssertEqual(after.focusPoint, before.focusPoint)
            model.toggleVirtualAperture()
        }
    }
    @MainActor func testLensRestrictionsContinuousSliderAndRealPhotoInformation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, callback = camera.onCaptureCompleted, audit = SessionRuntimeErrorAudit()
        let originalFocus = model.preferences.focusAssist
        UIApplication.shared.isIdleTimerDisabled = true; model.preferences.focusAssist = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: VirtualApertureHost(model: model, angle: 0))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { camera.onCaptureCompleted = callback; model.preferences.focusAssist = originalFocus; model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; old?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
            XCTFail(label + " " + (camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("相机") { camera.ready }
        model.toggleVirtualAperture(); try await wait("虚拟光圈") { model.virtualApertureEnabled }
        let unsupported = camera.lenses.filter { $0.device.position == .front || $0.device.deviceType == .builtInUltraWideCamera }
        XCTAssertFalse(unsupported.isEmpty); for lens in unsupported { XCTAssertFalse(model.canSelectFocalLength(lens)) }
        XCTAssertFalse(model.canSelectPhotoFormat(.raw)); XCTAssertFalse(model.canSelectPhotoFormat(.rawJPEG)); XCTAssertFalse(model.canToggleLivePhoto)
        XCTAssertGreaterThanOrEqual(model.zoomRange.lowerBound, 1)
        var sliderTimes: [Double] = []
        for n in 0..<100 {
            let began = CACurrentMediaTime()
            model.virtualAperturePosition = Double(n) / 99
            XCTAssertEqual(model.virtualAperture, VirtualApertureRenderer.value(at: Double(n)/99), accuracy: 0.000001)
            sliderTimes.append(CACurrentMediaTime() - began)
        }
        for value in [1.4, 8.0, 16.0] {
            model.virtualAperture = value; model.resetVirtualAperture()
            XCTAssertEqual(model.virtualAperture, 5.6, accuracy: 0.000001)
            model.resetVirtualAperture(); XCTAssertEqual(model.virtualAperture, 5.6)
        }
        model.virtualAperture = 16
        // 高亮外观必须在控件可交互时验收；近景A挡可能触发系统微距并禁用光圈滑块。
        model.setMode(.manual)
        try await wait("滑块可交互状态") { camera.ready && !camera.macroActive && !camera.videoBusy }
        let closedFocal=try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
        model.toggleVirtualApertureSlider()
        model.setDepthControlEditing(true)
        try await wait("顶部光圈弹窗已打开"){model.depthControlPopupVisible && model.captureButtonFramesForTesting["depthControlPopup"] != nil}
        let openedFocal=try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
        XCTAssertEqual(openedFocal.minX,closedFocal.minX,accuracy:1)
        XCTAssertEqual(openedFocal.minY,closedFocal.minY,accuracy:1,"弹出调节不能移动焦段条")
        func apertureSlider(_ view: UIView) -> UISlider? {
            if let slider = view as? UISlider, slider.accessibilityIdentifier == "camera.virtualAperture.slider" { return slider }
            for child in view.subviews { if let found = apertureSlider(child) { return found } }
            return nil
        }
        // SwiftUI不保证使用UISlider或公开进程内的AX子树；布局/参数性能与真手势分开验收。
        let nativeSlider=apertureSlider(window)
        if let nativeSlider { XCTAssertTrue(nativeSlider.isEnabled) }
        let popup=try XCTUnwrap(model.captureButtonFramesForTesting["depthControlPopup"])
        let point=window.convert(CGPoint(x:popup.midX,y:popup.midY),from:nil)
        XCTAssertNotNil(window.hitTest(point,with:nil))
        XCTAssertTrue(model.depthControlPopupVisible)
        let popupShot=UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let popupAttachment=XCTAttachment(image:popupShot);popupAttachment.name="Aperture-top-toolbar-popup";popupAttachment.lifetime = .keepAlways;add(popupAttachment)
        // 等待开关和上一批参数真正出帧后再测连拖；ready只代表会话，不代表显示已收敛。
        let settled = camera.previewPublicationTimesForTestingSnapshot.last ?? 0
        try await wait("调节前实际新预览") { (camera.previewPublicationTimesForTestingSnapshot.last ?? 0) > settled }
        // 以已发布到主线程的实际预览帧计数，不能用滑块setter耗时替代连拖流畅性。
        // 三轮连续调节覆盖持续更新、松手收敛以及再次开始；不写相册。
        for pass in 0..<3 {
            if let nativeSlider {
                nativeSlider.sendActions(for: .touchDown); nativeSlider.isHighlighted = true
                if pass == 0 {
                    try await Task.sleep(for: .milliseconds(180))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let attachment = XCTAttachment(image: image); attachment.name = "Aperture-slider-highlighted"; attachment.lifetime = .keepAlways; add(attachment)
                }
            } else { model.setFilterParameterEditing(true);model.setDepthControlEditing(true) }
            camera.resetPreviewPublicationTimesForTesting()
            let start = CACurrentMediaTime()
            for n in 0..<90 {
                if let nativeSlider {
                    nativeSlider.setValue(Float(n % 60) / 59, animated: false); nativeSlider.sendActions(for: .valueChanged)
                } else { model.virtualAperturePosition = Double(n % 60) / 59 }
                try await Task.sleep(for: .milliseconds(16))
            }
            let end = CACurrentMediaTime()
            let times = camera.previewPublicationTimesForTestingSnapshot.filter { $0 >= start }
            let gaps = zip([start] + times, times + [end]).map { $1 - $0 }
            XCTAssertGreaterThan(times.count, 12, "连拖期间预览不能饿死")
            XCTAssertLessThan(gaps.max() ?? 99, 0.6, "不能持续冻结")
            if let nativeSlider {
                nativeSlider.isHighlighted = false
                nativeSlider.sendActions(for: pass == 0 ? .touchCancel : pass == 1 ? .touchUpOutside : .touchUpInside)
            } else {
                model.setFilterParameterEditing(false);model.setDepthControlEditing(false)
                if pass<2 {
                    model.dismissDepthControls()
                    XCTAssertFalse(model.depthControlPopupVisible);XCTAssertFalse(model.isAdjustingDepthControl)
                    model.toggleVirtualApertureSlider()
                    try await wait("取消调节后重开"){model.depthControlPopupVisible && model.captureButtonFramesForTesting["depthControlPopup"] != nil}
                }
            }
            let latest = camera.previewPublicationTimesForTestingSnapshot.last ?? 0
            try await wait("松手后最新预览") { (camera.previewPublicationTimesForTestingSnapshot.last ?? 0) > latest }
            print("VIRTUAL-APERTURE-DRAG pass=\(pass) input=\(nativeSlider == nil ? "controlled-binding-updates" : "native-control-events") frames=\(times.count) wall=\(end-start) maxGap=\(gaps.max() ?? 0)")
        }
        var layouts = 0
        model.setDepthControlEditing(true)
        defer { model.setDepthControlEditing(false) }
        for ratio in FrameRatio.photoOptions {
            model.ratio = ratio
            for angle in [0.0, 90.0, -90.0, 180.0] {
                host.rootView = VirtualApertureHost(model: model, angle: angle)
                try await Task.sleep(for: .milliseconds(250))
                let popup = try XCTUnwrap(model.captureButtonFramesForTesting["depthControlPopup"])
                let trigger=try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.depthControl"])
                let toolbar=model.toolbarFrameForTesting
                XCTAssertTrue(model.depthControlPopupVisible)
                XCTAssertEqual(popup.width,190,accuracy:1);XCTAssertEqual(popup.height,32,accuracy:1)
                // 垂直间距/直方图对齐由 DepthToolbarPhysicalTests 的稳定宿主覆盖；
                // 这里只验证虚拟光圈自身的尺寸与横向位置，避免测试宿主环境不同步。
                XCTAssertGreaterThan(popup.minY, toolbar.minY)
                XCTAssertEqual(popup.midX,min(max(trigger.midX,toolbar.minX+109),toolbar.maxX-109),accuracy:1)
                layouts += 1
            }
        }
        model.setDepthControlEditing(false);model.dismissDepthControls()
        model.ratio = .standard; model.setMode(.manual)
        let main = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera && abs($0.displayZoom - 1) < 0.01 })
        let tele = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && $0.device.deviceType == .builtInTelephotoCamera })
        for (index, lens) in [main, tele].enumerated() {
            model.selectFocalLength(lens); try await wait("镜头") { camera.ready && camera.selectedLens == lens.id }
            model.virtualAperture = index == 0 ? 8 : 16
            var photo: CapturedPhoto?
            camera.onCaptureCompleted = { photo = $0 }
            let began = CACurrentMediaTime()
            model.takePhoto(); try await wait("成片") { photo != nil && !camera.capturing }
            let captured = try XCTUnwrap(photo), data = try XCTUnwrap(captured.resources.first?.data)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let physical = try XCTUnwrap((exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue)
            XCTAssertGreaterThan(physical, 0); XCTAssertLessThan(physical, 5)
            XCTAssertEqual(try XCTUnwrap(VirtualApertureRenderer.recordedValue(properties)), model.virtualAperture, accuracy: 0.001)
            XCTAssertEqual(captured.diagnostics?.currentParameters?.virtualAperture, model.virtualAperture)
            XCTAssertTrue(PhotoCaptureDiagnostics.exposureRows(properties: properties).contains { $0.title == "虚拟光圈" })
            print("VIRTUAL-APERTURE-PHOTO lens=\(lens.device.deviceType.rawValue) virtual=\(model.virtualAperture) physical=\(physical) wall=\(CACurrentMediaTime()-began)")
        }
        let current = camera.previewFrameTimeForTesting
        try await wait("星芒预览仍出帧") { camera.previewFrameTimeForTesting > current }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot); attachment.name = "Virtual-aperture-slider"; attachment.lifetime = .keepAlways; add(attachment)
        model.toggleVirtualAperture(); XCTAssertFalse(model.virtualApertureEnabled)
        model.toggleSlowShutterMode(); try await wait("慢门") { model.slowShutterEnabled }
        model.toggleVirtualAperture(); XCTAssertFalse(model.slowShutterEnabled); XCTAssertTrue(model.virtualApertureEnabled)
        model.setCaptureKind(.video); try await wait("视频隔离") { !model.virtualApertureEnabled && camera.ready && !camera.videoConfiguring }
        XCTAssertNil(model.effectiveCaptureLook.virtualAperture)
        print("VIRTUAL-APERTURE-LAYOUT cases=\(layouts) adjustmentSeconds=\(sliderTimes)")
    }
    #endif
}
