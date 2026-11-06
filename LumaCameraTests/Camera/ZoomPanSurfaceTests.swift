import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

@MainActor final class ZoomPanSurfaceTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testRepeatedGripHitsWheelInsteadOfInvisibleFocalButtonsAcrossEveryRatio() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }
        let model = AppDependencies.makeCameraModel(automaticallySave:false)
        let host = UIHostingController(rootView:CameraView(model:model).preferredColorScheme(.dark))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.setCameraActive(false); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for:.milliseconds(300))
        model.setCameraActive(true)
        for _ in 0..<100 { if model.camera.ready { break }; try await Task.sleep(for:.milliseconds(20)) }
        func surfaces(_ view:UIView) -> [CameraZoomTouchView] {
            (view as? CameraZoomTouchView).map { [$0] } ?? view.subviews.flatMap(surfaces)
        }
        for ratio in FrameRatio.allCases {
            model.ratio = ratio; model.beginZoomDial(at:1); model.finishZoomDrag()
            try await Task.sleep(for:.milliseconds(280)); host.view.layoutIfNeeded()
            let surface = try XCTUnwrap(surfaces(window).first)
            let point = CGPoint(x:surface.region.midX,y:surface.region.minY+25)
            XCTAssertTrue(surface.point(inside:point,with:nil),"Visible arc accepts each new touch at \(ratio)")
            let hit = window.hitTest(surface.convert(point,to:window),with:nil)
            XCTAssertTrue(hit === surface,"Hidden focal controls cannot intercept the wheel at \(ratio): \(String(describing:hit))")
            let oldButtonPoint = CGPoint(x:surface.region.midX,y:surface.excluded[0].midY)
            if surface.region.contains(oldButtonPoint), !surface.excluded.contains(where: { $0.contains(oldButtonPoint) }) {
                XCTAssertTrue(window.hitTest(surface.convert(oldButtonPoint,to:window),with:nil) === surface,
                              "Invisible button row must pass new touches to the wheel at \(ratio)")
            }
            for excluded in surface.excluded {
                XCTAssertFalse(surface.point(inside:CGPoint(x:excluded.midX,y:excluded.midY),with:nil))
            }
            let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? CameraZoomPanSurface.Coordinator)
            for _ in 0..<3 {
                let before = model.camera.currentZoom
                coordinator.handlePan(.began,translation:0)
                coordinator.handlePan(.changed,translation:before<4 ? -25:25)
                coordinator.handlePan(.ended,translation:before<4 ? -25:25)
                XCTAssertNotEqual(model.camera.currentZoom,before)
                XCTAssertTrue(model.zoomDialVisible)
            }
            coordinator.handlePan(.began,translation:0); coordinator.handlePan(.cancelled,translation:0)
            coordinator.handlePan(.began,translation:0); coordinator.handlePan(.ended,translation:-10)
            XCTAssertTrue(model.zoomDialVisible)
            model.endZoomDial()
        }
    }
    #endif
}
