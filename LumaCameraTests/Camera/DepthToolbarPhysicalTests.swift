import XCTest
import SwiftUI
import UIKit
import ImageIO
@testable import LumaCamera

@MainActor final class DepthToolbarPhysicalTests: XCTestCase {
    func testDepthSlidersFourSecondIdleResetHoldAndCancellation() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        defer { model.dismissDepthControls(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        var times = [Double]()
        for portrait in [true, false] {
            if portrait { model.togglePortraitMode() } else { model.toggleVirtualAperture() }
            try await PresetToolbarChecks.wait("模式就绪") { camera.ready && !model.isPreparingSubmode }
            func toggle() { if portrait { model.togglePortraitDepthSlider() } else { model.toggleVirtualApertureSlider() } }
            toggle(); model.setDepthControlEditing(true)
            try await Task.sleep(for: .milliseconds(3200))
            XCTAssertTrue(model.depthControlPopupVisible, "拖动持有不收起")
            model.setDepthControlEditing(false)
            try await Task.sleep(for: .seconds(2))
            model.noteSliderInteraction()
            for sample in 0..<3 {
                let start = CACurrentMediaTime()
                try await Task.sleep(for: .milliseconds(2500))
                XCTAssertTrue(model.depthControlPopupVisible, "最后一次操作后重新计时")
                try await PresetToolbarChecks.wait("4秒收起") { !model.depthControlPopupVisible }
                let elapsed = CACurrentMediaTime() - start
                XCTAssertGreaterThanOrEqual(elapsed, 3.9); XCTAssertLessThan(elapsed, 4.8)
                times.append(elapsed)
                if sample < 2 { toggle() }
            }
            for _ in 0..<10 { toggle(); model.dismissDepthControls() }
            toggle(); try await Task.sleep(for: .seconds(2)); model.dismissDepthControls(); toggle()
            try await Task.sleep(for: .milliseconds(1500))
            XCTAssertTrue(model.depthControlPopupVisible, "已取消的旧任务不能关闭新滑条")
            model.closePopups(); XCTAssertFalse(model.depthControlPopupVisible)
        }
        print("DEPTH_IDLE samples=\(times.count) seconds=\(times) rapidPairs=20 holdAndReset=true")
    }

    func testDepthSliderTopSpacingIsTwentyAcrossRatios() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        model.setCameraActive(true)
        defer { model.dismissDepthControls(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        try await PresetToolbarChecks.wait("相机") { camera.ready }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let angleBox = DepthToolbarAngle()
        let host = UIHostingController(rootView: DepthToolbarHost(model:model, angleBox:angleBox))
        let window = UIWindow(windowScene:scene); window.frame = CGRect(x:0,y:0,width:390,height:760)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        for portrait in [true, false] {
            if portrait { model.togglePortraitMode() } else { model.toggleVirtualAperture() }
            try await PresetToolbarChecks.wait("模式就绪") { camera.ready && !model.isPreparingSubmode }
            if portrait { model.togglePortraitDepthSlider() } else { model.toggleVirtualApertureSlider() }
            XCTAssertTrue(model.depthControlPopupVisible)
            model.showHistogram = true
            for ratio in FrameRatio.allCases {
                var portraitMidY: CGFloat?
                for angle in [0.0, 90.0] {
                    model.ratio = ratio
                    angleBox.angle = CGFloat(angle)
                    model.noteSliderInteraction()
                    try await Task.sleep(for: .milliseconds(180))
                    let popup = try XCTUnwrap(model.captureButtonFramesForTesting["depthControlPopup"])
                    if angle == 0 {
                        XCTAssertEqual(popup.midY, model.histogramFrameForTesting.midY, accuracy: 1,
                                       "portrait=\(portrait) ratio=\(ratio) 竖屏中线应对齐直方图")
                        portraitMidY = popup.midY
                    } else {
                        XCTAssertEqual(popup.midY, try XCTUnwrap(portraitMidY), accuracy: 1,
                                       "portrait=\(portrait) ratio=\(ratio) 横屏应沿用竖屏位置")
                    }
                }
            }
            if portrait { model.togglePortraitDepthSlider() } else { model.toggleVirtualApertureSlider() }
        }
        print("DEPTH-SPACING portraitAndAperture ratios=\(FrameRatio.allCases.count) gap=20")
    }

    func testHEIFProToolbarPopupLayoutsLifecycleAndCapture() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled, audit = SessionRuntimeErrorAudit()
        let callback = camera.onCaptureCompleted
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.onCaptureCompleted = callback; model.closePopups(); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle; audit.finish() }
        func wait(_ label:String,_ condition:()->Bool) async throws {
            for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label + (camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("ready") { camera.ready && !model.isPreparingSubmode && !camera.shutterBusy && !camera.highResolutionPhotoConfiguring }
        }
        model.setCameraActive(true); try await wait("start") { camera.ready }
        XCTAssertTrue(model.canSelectPhotoFormat(.heifPro)); model.photoFormat = .heifPro
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let angleBox = DepthToolbarAngle()
        let host = UIHostingController(rootView:DepthToolbarHost(model:model, angleBox:angleBox))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        try await Task.sleep(for:.milliseconds(300)); try await settle()
        var samples = [Double](), layouts = 0
        for portrait in [true,false] {
            if portrait { model.togglePortraitMode() } else { model.toggleVirtualAperture() }
            try await settle()
            XCTAssertEqual(model.photoFormat,.heifPro)
            XCTAssertEqual(model.portraitModeEnabled,portrait); XCTAssertEqual(model.virtualApertureEnabled,!portrait)
            func toggle() { if portrait { model.togglePortraitDepthSlider() } else { model.toggleVirtualApertureSlider() } }
            toggle(); XCTAssertTrue(model.depthControlPopupVisible)
            model.setDepthControlEditing(true)
            try await Task.sleep(for:.milliseconds(5250))
            XCTAssertTrue(model.depthControlPopupVisible,"持续按住滑条不应4秒自动消失 page=\(model.toolPage) slider=\(model.virtualApertureSliderVisible)/\(model.portraitDepthSliderVisible) editing=\(model.isAdjustingDepthControl) mode=\(portrait)")
            model.setDepthControlEditing(false)
            model.showHistogram = true
            for ratio in FrameRatio.allCases {
                var portraitPopupMidY: CGFloat?
                for angle in [0.0,90.0] {
                model.ratio = ratio; angleBox.angle = CGFloat(angle)
                model.noteSliderInteraction()
                try await Task.sleep(for:.milliseconds(230))
                XCTAssertTrue(model.depthControlPopupVisible)
                let bar = model.toolbarFrameForTesting
                let popup = try XCTUnwrap(model.captureButtonFramesForTesting["depthControlPopup"])
                let trigger = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.depthControl"])
                XCTAssertGreaterThan(trigger.width,20,"HEIF Pro不能挡住调节入口")
                let format = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.format"])
                let ratioButton = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.ratio"])
                XCTAssertEqual(format.maxX,ratioButton.minX,accuracy:1)
                for key in ["toolbar.ratio","toolbar.flash","toolbar.depthControl","toolbar.settings"] {
                    let button = try XCTUnwrap(model.captureButtonFramesForTesting[key])
                    XCTAssertEqual(button.width,format.width,accuracy:1)
                    XCTAssertEqual(button.height,format.height,accuracy:1)
                    XCTAssertTrue(bar.insetBy(dx:-1,dy:-1).contains(button))
                }
                if angle == 0 {
                    XCTAssertEqual(popup.midY, model.histogramFrameForTesting.midY, accuracy: 1)
                    portraitPopupMidY = popup.midY
                } else {
                    XCTAssertEqual(popup.midY, try XCTUnwrap(portraitPopupMidY), accuracy: 1)
                }
                XCTAssertEqual(popup.midX,min(max(trigger.midX,bar.minX+109),bar.maxX-109),accuracy:1)
                XCTAssertEqual(popup.width,190,accuracy:1)
                XCTAssertEqual(popup.height,32,accuracy:1)
                if layouts < 20 {
                    let start = CACurrentMediaTime()
                    _ = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                    samples.append((CACurrentMediaTime()-start)*1000)
                }
                layouts += 1
            } }
            let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = portrait ? "Portrait-HEIFPro-RestoredPopup" : "Aperture-HEIFPro-RestoredPopup"; attachment.lifetime = .keepAlways; add(attachment)
            for _ in 0..<10 { toggle(); toggle() }
            model.toggleToolbarPanel(.tone); XCTAssertFalse(model.depthControlPopupVisible)
            XCTAssertEqual(model.toolbarPanel,.tone)
            model.toggleToolbarPanel(.tone); XCTAssertNil(model.toolbarPanel)
            toggle()
            model.toggleToolbarPanel(.format); XCTAssertFalse(model.depthControlPopupVisible)
            toggle(); XCTAssertNil(model.toolbarPanel); XCTAssertTrue(model.depthControlPopupVisible)
            model.openTools(feedback:false); XCTAssertFalse(model.depthControlPopupVisible)
            toggle(); XCTAssertTrue(model.depthControlPopupVisible)
            model.updateToolPageFromPager(1); await Task.yield(); try await Task.sleep(for:.milliseconds(50))
            XCTAssertFalse(model.depthControlPopupVisible)
            model.updateToolPageFromPager(0); try await Task.sleep(for:.milliseconds(50))
            XCTAssertFalse(model.depthControlPopupVisible)
            toggle(); model.setCameraActive(false); await Task.yield()
            XCTAssertFalse(model.depthControlPopupVisible)
            model.setCameraActive(true); try await settle()
            XCTAssertFalse(model.depthControlPopupVisible)
            model.ratio = .standard
            var result:CapturedPhoto?
            camera.onCaptureCompleted = { result = $0 }
            camera.capture(flashMode:.off,options:model.photoOptions)
            try await wait("HEIF Pro capture") { result != nil }
            let photo = try XCTUnwrap(result)
            XCTAssertEqual(model.photoOptions.format,.heifPro)
            XCTAssertTrue(model.photoOptions.usesRAWCapture)
            let data = try XCTUnwrap(photo.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            XCTAssertTrue((CGImageSourceGetType(source) as String? ?? "").contains("heic"))
            let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            XCTAssertNotNil(metadata[kCGImagePropertyExifDictionary as String])
            print("DEPTH-HEIFPRO mode=\(portrait ? "portrait" : "aperture") bytes=\(data.count) actualType=\(CGImageSourceGetType(source)!) noPhotosWrites=true")
            try await settle()
        }
        samples.sort(); print("DEPTH-TOOLBAR layouts=\(layouts) snapshots=\(samples.count) medianMS=\(samples[samples.count/2]) maxMS=\(samples.last!) notDisplayFPS=true")
        model.toggleVirtualAperture(); try await settle()
        XCTAssertFalse(model.depthControlPopupVisible)
        XCTAssertFalse(model.virtualApertureEnabled); XCTAssertFalse(model.portraitModeEnabled)
        for width in [CGFloat(320),window.bounds.width] {
            host.rootView = DepthToolbarHost(model:model, angleBox:angleBox, width:width)
            for _ in 0..<4 {
                model.photoFormat = .heif
                try await Task.sleep(for:.milliseconds(230))
                // 后台原窗口也使用同一model；重新挂载前台host，避免条件按钮几何归属落在后台窗口。
                host.rootView = DepthToolbarHost(model:model, angleBox:angleBox, width:width,generation:UUID())
                try await Task.sleep(for:.milliseconds(230)); model.setCameraActive(true); try await settle()
                let five = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.format"])
                model.photoFormat = .heifPro
                try await Task.sleep(for:.milliseconds(230))
                host.rootView = DepthToolbarHost(model:model, angleBox:angleBox, width:width,generation:UUID())
                try await Task.sleep(for:.milliseconds(230)); model.setCameraActive(true); try await settle()
                let current = try XCTUnwrap(model.captureButtonFramesForTesting["toolbar.format"])
                XCTAssertEqual(five.width,current.width,accuracy:1)
                model.toggleToolbarPanel(.format)
                try await Task.sleep(for:.milliseconds(250))
                let heifPro = try XCTUnwrap(model.captureButtonFramesForTesting["format.heifPro"])
                let tone = try XCTUnwrap(model.captureButtonFramesForTesting["format.proTone"])
                let heif = try XCTUnwrap(model.captureButtonFramesForTesting["format.option.HEIF"])
                XCTAssertEqual(heifPro.maxX+8,tone.minX,accuracy:1)
                XCTAssertEqual(heifPro.width,tone.width,accuracy:1)
                XCTAssertEqual(heifPro.width,heif.width,accuracy:1)
                XCTAssertEqual(tone.height,heif.height,accuracy:1)
                let shot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                if width == 320 {
                    let a = XCTAttachment(image:shot); a.name = "ProTone-InFormatPopup-320"; a.lifetime = .keepAlways; add(a)
                }
                model.toggleToolbarPanel(.tone); XCTAssertEqual(model.toolbarPanel,.tone)
                model.closePopups(); XCTAssertNil(model.toolbarPanel)
            }
        }
    }
}
private final class DepthToolbarAngle: ObservableObject {
    @Published var angle: CGFloat = 0
}
private struct DepthToolbarHost:View {
    @ObservedObject var model:CameraViewModel
    @ObservedObject var angleBox: DepthToolbarAngle
    var width:CGFloat? = nil
    var generation: UUID? = nil
    var body:some View { CameraView(model:model).id(generation).frame(width:width).environment(\.scenePhase,.active).environment(\.captureControlAngle,Double(angleBox.angle)) }
}
