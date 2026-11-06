import SwiftUI
import UIKit
import CoreImage
import XCTest
@testable import LumaCamera

@MainActor final class NightPreviewLayoutTests:XCTestCase {
    func testSlowAccumulationTransitionFitsAllPhotoRatiosWithoutReflow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView:AnyView(Color.black))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idle }
        let image = UIGraphicsImageRenderer(size:CGSize(width:90,height:120)).image { c in
            UIColor.darkGray.setFill(); c.fill(CGRect(x:0,y:0,width:90,height:120))
            UIColor.white.setFill(); c.fill(CGRect(x:15,y:50,width:60,height:3))
        }
        var measured = CGRect.zero, samples = [Double]()
        for ratio in FrameRatio.photoOptions { for angle in [0.0,90.0] {
            let rect = CameraPreviewLayout.frame(in:window.bounds.size,ratio:ratio,openGatePortraitRatio:3.0/4,landscape:false)
            let token = UUID()
            for revision in [1,2] {
                let state = SlowShutterAccumulationPreview(id:token,image:image,revision:revision,isFinal:revision == 2)
                host.rootView = AnyView(Color.black.overlay {
                    SlowShutterAccumulationView(state:state).frame(width:rect.width,height:rect.height)
                        .onGeometryChange(for:CGRect.self) { $0.frame(in:.global) } action: { measured = $0 }
                }.environment(\.captureControlAngle,angle).ignoresSafeArea())
                try await Task.sleep(for:.milliseconds(280))
                XCTAssertEqual(measured.width,rect.width,accuracy:1); XCTAssertEqual(measured.height,rect.height,accuracy:1)
                let t = CACurrentMediaTime()
                let snapshot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                samples.append(CACurrentMediaTime()-t)
                if ratio == .standard && angle == 0 && revision == 1 {
                    let a = XCTAttachment(image:snapshot); a.name = "Slow-Accumulation-Layout"; a.lifetime = .keepAlways; add(a)
                }
            }
        } }
        samples.sort(); print("SLOW-ACCUMULATION-LAYOUT cases=14 renderedKeyframes=28 medianSnapshotDraw=\(samples[14]) max=\(samples.last!) notFPS=true reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
    }

    func testGradualRevealAcrossAllPhotoRatiosAndOrientations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView:AnyView(Color.black))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey(); UIApplication.shared.isIdleTimerDisabled = idle }
        func solid(_ value:CGFloat)->UIImage {
            UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).image { c in
                UIColor(white:value,alpha:1).setFill(); c.fill(CGRect(x:0,y:0,width:64,height:64))
            }
        }
        let base = solid(0.15), final = solid(0.35), context = CIContext()
        var durations = [Double](), cases = 0
        for ratio in FrameRatio.photoOptions { for angle in [0.0,90.0] {
            let rect = CameraPreviewLayout.frame(in:window.bounds.size,ratio:ratio,openGatePortraitRatio:3.0/4,landscape:false)
            let id = UUID(); var means = [Double]()
            for progress in [0.0,0.65,1.0] {
                let state = NightPreviewReveal(id:id,image:base,progress:progress,finalImage:progress == 1 ? final:nil)
                host.rootView = AnyView(NightCaptureRevealView(state:state).frame(width:rect.width,height:rect.height)
                    .frame(width:window.bounds.width,height:window.bounds.height).background(Color.black)
                    .environment(\.captureControlAngle,angle).ignoresSafeArea())
                try await Task.sleep(for:.milliseconds(750))
                let t = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                durations.append(CACurrentMediaTime()-t)
                let ci = try XCTUnwrap(CIImage(image:image))
                let center = CGRect(x:ci.extent.midX-8,y:ci.extent.midY-8,width:16,height:16)
                means.append(Imaging.meanLuminance(ci.cropped(to:center),context:context))
                if ratio == .standard && angle == 0 {
                    let a = XCTAttachment(image:image); a.name = "Night-Reveal-Progress-\(progress)"; a.lifetime = .keepAlways; add(a)
                }
            }
            XCTAssertGreaterThan(means[1],means[0]*1.1)
            XCTAssertGreaterThan(means[2],means[1]*1.1)
            cases += 1
        } }
        durations.sort()
        print("NIGHT-REVEAL-LAYOUT cases=\(cases) keyframes=\(durations.count) snapshotDrawMedianSeconds=\(durations[durations.count/2]) maxSeconds=\(durations.last!) notDisplayFPS=true reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
    }
}
