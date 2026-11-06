import XCTest
import CoreGraphics
import UIKit
import SwiftUI
@testable import LumaCamera

final class SmartCompositionGeometryTests: XCTestCase {
    @MainActor func testEarlyAlignedPointsFadeBeforeFramingAndRetainJitterTolerance() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        defer {
            model.toolbarPanel = nil; model.smartAnalysisOverrideForTesting = false
            model.setSmartCaptureForTesting(false); model.setCameraActive(false)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        model.setCameraActive(true)
        for _ in 0..<750 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        model.smartAnalysisOverrideForTesting = true
        let id = UUID()
        func guide(_ x:CGFloat = 0.5) -> SmartCompositionGuide {
            .init(stage:.align,direction:.align,subject:CGPoint(x:x,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心",subjectID:id)
        }
        var acceptedTimes = [Double](), drawingTimes = [Double]()
        for sample in 0..<3 {
            model.setSmartCaptureForTesting(true)
            let started = CACurrentMediaTime()
            model.injectSmartCompositionForTesting(guide())
            for _ in 0..<6 {
                try await Task.sleep(for:.milliseconds(66)); model.injectSmartCompositionForTesting(guide())
                if model.smartAlignmentLatched { break }
            }
            acceptedTimes.append(CACurrentMediaTime()-started)
            XCTAssertTrue(model.smartAlignmentLatched)
            XCTAssertFalse(model.smartFramingInProgress); XCTAssertFalse(model.smartFramingComplete)
            XCTAssertLessThan(acceptedTimes.last!,0.5,"白点隐藏不能等待0.75秒的自动取景门限")
            // 模型输入已确认隐藏；真机检查所有画幅及两种动态效果下的最终像素。
            if sample == 0 { for reduced in [false,true] { for ratio in FrameRatio.allCases { for landscape in [false,true] {
                let aspect = landscape ? 1/ratio.portraitRatio : ratio.portraitRatio, size = CGSize(width:240,height:240/aspect)
                let host = UIHostingController(rootView:CameraView(model:model).smartCompositionGuideContent(guide(),reducedMotion:reduced).frame(width:size.width,height:size.height).background(.black))
                host.safeAreaRegions = []; parent.addChild(host); parent.view.addSubview(host.view)
                host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:parent)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(for:.milliseconds(120))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let t = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(size:size,format:format).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
                drawingTimes.append(CACurrentMediaTime()-t)
                let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
                var pixels = [UInt8](repeating:0,count:w*h*4)
                let bitmap = try XCTUnwrap(CGContext(data:&pixels,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
                let center = ((h/2)*w+w/2)*4
                XCTAssertLessThan(Int(pixels[center]),30,"对齐确认后白点应已隐藏")
                let ring = ((h/2)*w+w/2+Int(min(size.width,size.height)*0.05))*4
                XCTAssertGreaterThan(Int(pixels[ring]),150,"等待后续处理时中心圈仍固定且可见")
                host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
            } } } }
            model.injectSmartCompositionForTesting(guide(0.56))
            XCTAssertTrue(model.smartAlignmentLatched,"容差内手抖不能重新冒点")
            model.injectSmartCompositionForTesting(guide(0.62))
            XCTAssertFalse(model.smartAlignmentLatched,"超出容差应恢复推荐点")
            model.toolbarPanel = .format; model.injectSmartCompositionForTesting(guide())
            XCTAssertFalse(model.smartAlignmentLatched)
            model.toolbarPanel = nil; model.setSmartCaptureForTesting(false)
        }
        print("SMART-EARLY-HIDE samples=3 visualConfirmationSeconds=\(acceptedTimes) renderSamples=\(drawingTimes.count) maxSnapshotSeconds=\(drawingTimes.max() ?? 0) framingDwellUnchanged=true jitterTolerance=true popupCancel=true endpointPixelsOnly=true notScreenFPS=true")
    }
    func testPortraitDisplayMapsCentreAndCropOffset() {
        let image = CGSize(width: 4000, height: 3000)
        let display = CGSize(width: 300, height: 400)
        let centre = CameraView.displayPoint(CGPoint(x: 0.5, y: 0.5), imageSize: image, displaySize: display)
        XCTAssertEqual(centre.x, 150, accuracy: 0.01)
        XCTAssertEqual(centre.y, 200, accuracy: 0.01)
        let left = CameraView.displayPoint(CGPoint(x: 0.25, y: 0.5), imageSize: image, displaySize: display)
        // Aspect-fill renders 533.3x400, origin x=-116.7, so source x=0.25 maps to ~16.7.
        XCTAssertEqual(left.x, 16.67, accuracy: 0.1)
    }

    func testSquareDisplayMapsFourThreeSourceWithVerticalCrop() {
        let image = CGSize(width: 4000, height: 3000)
        let display = CGSize(width: 300, height: 300)
        let bottom = CameraView.displayPoint(CGPoint(x: 0.5, y: 1.0), imageSize: image, displaySize: display)
        XCTAssertEqual(bottom.x, 150, accuracy: 0.01)
        XCTAssertEqual(bottom.y, 300, accuracy: 0.1)
    }
    @MainActor func testShortPointTransitionEndpointsAcrossRatiosAndReduceMotion() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var samples = [Double]()
        for reduced in [false,true] { for ratio in FrameRatio.allCases { for landscape in [false,true] {
            let aspect = landscape ? 1/ratio.portraitRatio : ratio.portraitRatio
            let size = CGSize(width:240,height:240/aspect), id = UUID()
            func content(_ x:CGFloat) -> AnyView {
                let guide = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:x,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"先对准中心",subjectID:id,imageAspect:aspect)
                return AnyView(CameraView(model:model).smartCompositionGuideContent(guide,reducedMotion:reduced)
                    .frame(width:size.width,height:size.height).background(.black))
            }
            let host = UIHostingController(rootView:content(0.3)); host.safeAreaRegions = []
            parent.addChild(host); parent.view.addSubview(host.view); host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:parent)
            for x:CGFloat in [0.3,0.7] {
                host.rootView = content(x); host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(for:.milliseconds(90))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let started = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(size:size,format:format).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
                samples.append(CACurrentMediaTime()-started)
                let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
                var pixels = [UInt8](repeating:0,count:w*h*4)
                let context = try XCTUnwrap(CGContext(data:&pixels,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
                func red(_ px:CGFloat) -> Int { Int(pixels[((h/2)*w+min(w-1,max(0,Int(CGFloat(w)*px))))*4]) }
                XCTAssertGreaterThan(red(x),220,"过渡后点位必须落到最新坐标")
                XCTAssertLessThan(red(1-x),60,"旧点位不能留下拖影")
                let radius = min(size.width,size.height)*0.05
                XCTAssertGreaterThan(red(0.5+radius/size.width),150,"中心圈不能跟随点位移动")
            }
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        } } }
        let sorted = samples.sorted()
        print("SMART-SHORT-MOTION snapshots=\(samples.count) ratios=8 orientations=2 reduceMotionModes=2 drawingMedianSeconds=\(sorted[sorted.count/2]) drawingMaxSeconds=\(sorted.last ?? 0) endpointChecksOnly=true notScreenFPS=true")
    }
    /// 真机组件渲染：圆圈保持短边10%，描边与候选点放大后仍有清楚窄缝。
    @MainActor func testWhitePointAndThickerRingRendering() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let parent = UIViewController(); parent.view.backgroundColor = .black
        window.rootViewController = parent; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let guide = SmartCompositionGuide(stage:.align,direction:.align,subject:CGPoint(x:0.5,y:0.5),target:CGPoint(x:0.5,y:0.5),text:"已对准中心")
        var times:[Double] = []
        for ratio in FrameRatio.allCases { for landscape in [false,true] {
            let aspect = landscape ? 1/ratio.portraitRatio : ratio.portraitRatio, size = CGSize(width:300,height:300/aspect)
            let host = UIHostingController(rootView:CameraView(model:model).smartCompositionGuideOverlay(guide).frame(width:size.width,height:size.height).background(.black))
            // 只渲染预览组件，移除新建测试宿主的系统安全区；正式预览已有独立坐标区域。
            host.safeAreaRegions = []
            parent.addChild(host); parent.view.addSubview(host.view); host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:parent)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(70))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let t = CACurrentMediaTime()
            let rendered = UIGraphicsImageRenderer(size:size,format:format).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            times.append(CACurrentMediaTime()-t)
            let cg = try XCTUnwrap(rendered.cgImage), width = cg.width, height = cg.height
            var pixels = [UInt8](repeating:0,count:width*height*4)
            let context = try XCTUnwrap(CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
            func value(_ dx:CGFloat) -> Int {
                let x = min(width-1,max(0,Int(CGFloat(width)/2+dx))), y = height/2
                return Int(pixels[(y*width+x)*4])
            }
            let diameter = min(size.width,size.height)*0.10
            XCTAssertGreaterThan(value(0),220,"白点中心必须实心")
            XCTAssertGreaterThan(value(diameter/2),180,"圆圈描边应清晰")
            XCTAssertLessThan(value(diameter/2-2.25),220,"点和圈不能完全糊成一块")
            if ratio == .standard && !landscape {
                let attachment = XCTAttachment(image:rendered); attachment.name = "Smart-white-dot-thick-ring"; attachment.lifetime = .keepAlways; add(attachment)
            }
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        } }
        print("SMART-RING renderSamples=\(times.count) snapshotSeconds=\(times) ringDiameter=10percentShortEdge stroke=3 dotDiameter=ringMinus6; drawing time, not display FPS")
    }

}
