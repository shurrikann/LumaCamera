import XCTest
import UIKit
@testable import LumaCamera

@MainActor final class NativeGlassExportProbeTests: XCTestCase {
    func testNativeGlassHierarchySnapshot() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native Liquid Glass requires iOS 26") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert+1
        let host = UIViewController(); window.rootViewController = host
        host.view.backgroundColor = .black
        let image = UIImageView(image:UIImage(named:"FilterLandscape"))
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        image.frame = window.bounds; host.view.addSubview(image)
        let effect = UIVisualEffectView(effect:UIGlassEffect(style:.clear))
        effect.frame = CGRect(x:14,y:window.bounds.height*0.65,width:window.bounds.width-28,height:90)
        effect.layer.cornerRadius = 22; effect.clipsToBounds = true
        host.view.addSubview(effect)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(500))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var complete = false
        let snapshot = UIGraphicsImageRenderer(size:window.bounds.size,format:format).image { _ in
            complete = window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
        }
        let attachment = XCTAttachment(image:snapshot); attachment.name = "Native-Glass-Onscreen-DrawHierarchy"
        attachment.lifetime = .keepAlways; add(attachment)
        let layer = UIGraphicsImageRenderer(size:window.bounds.size,format:format).image { c in
            window.layer.render(in:c.cgContext)
        }
        let layerAttachment = XCTAttachment(image:layer); layerAttachment.name = "Native-Glass-Layer-Render"
        layerAttachment.lifetime = .keepAlways; add(layerAttachment)
        window.frame.origin.x = -20_000
        try await Task.sleep(for:.milliseconds(350))
        let offscreen = UIGraphicsImageRenderer(size:window.bounds.size,format:format).image { _ in
            _ = window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
        }
        let offscreenAttachment = XCTAttachment(image:offscreen); offscreenAttachment.name = "Native-Glass-Offscreen-Hierarchy"
        offscreenAttachment.lifetime = .keepAlways; add(offscreenAttachment)
        XCTAssertTrue(complete)
        print("NATIVE-GLASS-PROBE visibleWindow=true drawHierarchyComplete=\(complete) style=clear PhotosWrites=0")
    }
}
