import XCTest
import SwiftUI
import UIKit
import ImageIO
@testable import LumaCamera

@MainActor final class HighResolutionFixedFocalTests:XCTestCase {
    @MainActor func testHighResolutionFocalSwitchLatency() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setMode(.manual)
        model.photoFormat = .jpeg; model.hdr = false; model.photoResolution = .high
        for _ in 0..<300 { if camera.ready && !camera.highResolutionPhotoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        let lenses = camera.lenses.filter { camera.highResolutionLensIDs.contains($0.id) }
        var times: [Double] = []
        for lens in lenses + lenses.prefix(1) {
            let start = CACurrentMediaTime()
            model.selectFocalLength(lens)
            for _ in 0..<300 {
                if camera.ready && camera.selectedLens == lens.id && !camera.highResolutionPhotoConfiguring { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let elapsed = CACurrentMediaTime() - start
            times.append(elapsed)
            print("HIGH-RES-SWITCH zoom=\(lens.displayZoom) seconds=\(elapsed) ready=\(camera.ready) selected=\(camera.selectedLens == lens.id)")
        }
        print("HIGH-RES-SWITCH-SUMMARY times=\(times)")
    }

    func testHighResolutionRouteBracketCapacityProbe() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        var standard = -1, high = -1
        var standardDims: [String] = [], highDims: [String] = []
        await withCheckedContinuation { c in camera.maxBracketedPhotoCountForTesting { count, dims in
            standard = count; standardDims = dims; c.resume()
        } }
        model.setMode(.manual)
        model.photoResolution = .high
        for _ in 0..<300 { if camera.ready && !camera.highResolutionPhotoConfiguring { break }; try await Task.sleep(for: .milliseconds(20)) }
        await withCheckedContinuation { c in camera.maxBracketedPhotoCountForTesting { count, dims in
            high = count; highDims = dims; c.resume()
        } }
        print("HIGH-RES-BRACKET standard=\(standard) high=\(high) standardDims=\(standardDims) highDims=\(highDims)")
    }

    func testFixed48MPRoutesFilesAndAdaptiveStripAcrossModesAndRatios() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let callback = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        let runtime = SessionRuntimeErrorAudit()
        UIApplication.shared.isIdleTimerDisabled = true
        var photo:CapturedPhoto?
        camera.onCaptureCompleted = { photo = $0 }
        defer {
            camera.onCaptureCompleted = callback; model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle; runtime.finish()
        }
        func wait(_ label:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(label+" "+(camera.message ?? "")); throw CancellationError()
        }
        func settle() async throws {
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await wait("就绪") { camera.ready && !camera.highResolutionPhotoConfiguring && !camera.capturing }
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready && camera.preview != nil }
        model.photoFormat = .jpeg; model.hdr = false; model.smoothPreview = false; model.ratio = .standard
        let rear = camera.lenses.filter { $0.device.position == .back }
        let expected = rear.filter { camera.highResolutionLensIDs.contains($0.id) }
        try XCTSkipIf(camera.demo,"48MP固定物理路由需真机验证")
        XCTAssertEqual(expected.map(\.displayZoom),[0.5,1,4])
        let host = UIHostingController(rootView:CameraView(model:model).environment(\.scenePhase,.active)
            .environment(\.captureControlAngle,0)
            .frame(width:390,height:760))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene); window.frame = CGRect(x:0,y:0,width:390,height:760)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for:.milliseconds(400)); model.setCameraActive(true); try await settle()
        func descendants(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(descendants) }
        func button(_ lens:CameraLens)->UIButton? {
            descendants(host.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == lens.accessibilityDescription }
        }
        let firstLens = try XCTUnwrap(expected.first)
        let baseline = try XCTUnwrap(button(firstLens)).bounds.size
        let originalModeFrame = try XCTUnwrap(model.captureButtonFramesForTesting["mode"])
        let originalToolsFrame = try XCTUnwrap(model.captureButtonFramesForTesting["tools"])
        let ordinaryBar = try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
        var times = [Double](), physicalSwitchTimes = [Double](), fileCount = 0
        model.setMode(.auto); try await settle()
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡 48MP 必须禁用")
        for mode in [CameraShootingMode.manual] {
            model.setMode(mode); try await settle()
            model.photoResolution = .high; try await settle()
            XCTAssertFalse(model.hardwareControlSpecs.contains { $0.id == "A.zoom" })
            model.manualExposure = false
            model.manualWB = true; model.wb = 5200; model.whiteBalanceTint = 0
            model.applyExposure(); model.applyWhiteBalance()
            for lens in expected + expected.reversed() {
                try await Task.sleep(for:.milliseconds(120))
                let control = try XCTUnwrap(button(lens)); XCTAssertTrue(control.isEnabled)
                let physicalChange = camera.activeCaptureDeviceID != lens.device.uniqueID
                let started = CACurrentMediaTime()
                control.sendActions(for:.touchUpInside); try await settle()
                times.append(CACurrentMediaTime()-started)
                if physicalChange { physicalSwitchTimes.append(CACurrentMediaTime()-started) }
                XCTAssertEqual(model.photoResolution,.high)
                XCTAssertEqual(camera.selectedLens,lens.id)
                XCTAssertEqual(camera.activeCaptureDeviceID,lens.device.uniqueID)
                XCTAssertEqual(camera.currentZoom,lens.displayZoom,accuracy:0.01)
                let audit = await withCheckedContinuation { c in camera.photoResolutionAuditForTesting { c.resume(returning:$0) } }
                XCTAssertEqual(audit["virtual"],"false"); XCTAssertEqual(audit["physicalZoom"],"1.0")
                XCTAssertEqual(audit["responsive"],"false")
                let before = camera.currentZoom
                model.openZoomDial(); model.beginZoomDial(at:before); model.dragZoomDial(translation:90,width:390)
                model.updatePreviewPinchZoom(scale:1.8); camera.setContinuousZoom(before*1.5)
                await withCheckedContinuation { c in camera.flushRestoredZoom { c.resume() } }
                XCTAssertFalse(model.zoomDialVisible); XCTAssertEqual(camera.currentZoom,before,accuracy:0.001)
                for crop in rear where !camera.highResolutionLensIDs.contains(crop.id) {
                    XCTAssertFalse(model.canSelectFocalLength(crop))
                    model.selectFocalLength(crop); camera.selectLens(crop)
                }
                XCTAssertEqual(camera.selectedLens,lens.id)
                photo = nil
                var options = model.photoOptions
                // 正反两轮验证不同基础格式，全部使用真正的产品48MP状态。
                options.format = fileCount % 2 == 0 ? .jpeg:.heif
                camera.capture(flashMode:.off,options:options)
                try await wait("48MP成片") { photo != nil && camera.pendingPhotoCount == 0 }
                let resource = try XCTUnwrap(photo?.resources.first)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
                let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                XCTAssertGreaterThan(w*h,40_000_000)
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
                if mode == .manual {
                    XCTAssertFalse(model.manualExposure); XCTAssertEqual(model.wb,5200)
                    XCTAssertEqual((exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue,1)
                }
                print("FIXED48-FILE mode=\(mode.rawValue) focal=\(lens.displayZoom) format=\(options.format.rawValue) size=\(w)x\(h) virtual=false physicalZoom=1 noPhotosWrites=true")
                fileCount += 1; photo = nil
            }
        }
        var hitSamples = 0
        for ratio in FrameRatio.photoOptions { for angle in [0.0,90.0] {
            model.ratio = ratio
            host.rootView = CameraView(model:model).environment(\.scenePhase,.active)
                .environment(\.captureControlAngle,angle)
                .frame(width:390,height:760)
            try await Task.sleep(for:.milliseconds(260)); host.view.layoutIfNeeded()
            XCTAssertEqual(model.displayedFocalLenses.map(\.id),expected.map(\.id))
            for lens in expected {
                let control = try XCTUnwrap(button(lens))
                XCTAssertEqual(control.bounds.size,baseline)
                XCTAssertTrue(control.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
                let point = control.convert(CGPoint(x:control.bounds.midX,y:control.bounds.midY),to:window)
                let hit = window.hitTest(point,with:nil)
                XCTAssertTrue(hit === control || hit?.isDescendant(of:control) == true)
                hitSamples += 1
            }
            for crop in rear where !camera.highResolutionLensIDs.contains(crop.id) { XCTAssertNil(button(crop)) }
            let bar = try XCTUnwrap(model.captureButtonFramesForTesting["focalBarBackground"])
            XCTAssertEqual(bar.width,3*baseline.width+8,accuracy:1)
            XCTAssertLessThan(bar.width,ordinaryBar.width)
            XCTAssertEqual(model.captureButtonFramesForTesting["mode"],originalModeFrame)
            XCTAssertEqual(model.captureButtonFramesForTesting["tools"],originalToolsFrame)
        } }
        let image = UIGraphicsImageRenderer(bounds:host.view.bounds).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "Fixed48-three-focal-strip"; attachment.lifetime = .keepAlways; add(attachment)
        model.ratio = .standard
        try await Task.sleep(for:.milliseconds(250))
        model.photoResolution = .standard; try await settle(); try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(model.displayedFocalLenses.count,rear.count)
        model.openZoomDial(); XCTAssertTrue(model.zoomDialVisible); model.finishZoomDrag(); model.endZoomDial()
        var manualFiles = 0
        for parameter in [CameraParameter.iso,.shutter] {
            model.photoResolution = .high; try await settle()
            XCTAssertFalse(model.manualExposure)
            model.parameter = parameter
            model.editableParameterBinding.wrappedValue = parameter == .iso ? 200:log2(1.0/125)
            try await settle()
            XCTAssertEqual(model.photoResolution,.standard)
            XCTAssertTrue(model.manualExposure)
            photo = nil
            camera.capture(flashMode:.off,options:model.photoOptions)
            try await wait("手动曝光12MP") { photo != nil && camera.pendingPhotoCount == 0 }
            let data = try XCTUnwrap(photo?.resources.first?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
            let pixels = (props[kCGImagePropertyPixelWidth as String] as? Int ?? 0)*(props[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
            XCTAssertGreaterThan(pixels,10_000_000); XCTAssertLessThan(pixels,16_000_000)
            if parameter == .iso {
                let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
                XCTAssertEqual(values?.first?.doubleValue ?? 0,200,accuracy:4)
            } else {
                XCTAssertEqual((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0,1.0/125,accuracy:0.0001)
            }
            manualFiles += 1; photo = nil
        }
        model.photoResolution = .high; model.photoResolution = .standard; try await settle()
        XCTAssertFalse(camera.highResolutionPhotoZoomLocked); XCTAssertFalse(model.zoomDialVisible)
        print("FIXED48-SUMMARY files=\(fileCount) manualExposureFallbackFiles=\(manualFiles) modes=A,M nativeRoutes=3 switchSamples=\(times.count) switchReadySeconds=\(times) physicalSwitchReadySeconds=\(physicalSwitchTimes) layoutHits=\(hitSamples) configs=\(FrameRatio.photoOptions.count*2) buttonSize=\(baseline) ordinaryBarWidth=\(ordinaryBar.width) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) rapidToggleCancel=true noPhotosWrites=true notScreenFPS=true")
    }
}
