import SwiftUI
import UIKit
import XCTest
@testable import LumaCamera

final class ProResOptionsLayoutTests: XCTestCase {
    @MainActor func testRAWRemainsUnselectableAndRepeatedPanelChangesFitNarrowScreens() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.installVideoCapabilitiesForTesting(ordinary: [VideoCaptureSettings()], cinematic: [])
        model.setCaptureKind(.video)
        for codec in [VideoCodec.hevc, .h264] {
            model.videoCodec = codec
            let previous = model.proResSpecification
            for spec in ProResSpecification.allCases { model.selectProResSpecification(spec) }
            XCTAssertEqual(model.proResSpecification, previous)
        }
        model.videoCodec = .proRes
        let began = CACurrentMediaTime()
        for _ in 0..<30 {
            for spec in ProResSpecification.allCases {
                let previous = model.proResSpecification
                let allowed = model.canSelectProRes(spec)
                model.selectProResSpecification(spec)
                XCTAssertEqual(model.proResSpecification, allowed ? spec : previous)
                model.toggleToolbarPanel(.videoCodec)
                model.closePopups()
            }
        }
        XCTAssertNil(model.toolbarPanel)
        XCTAssertFalse(model.camera.videoBusy)
        print("PRORES-OPTIONS 240 selection/open/close cycles seconds=\(CACurrentMediaTime()-began)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.toolbarPanel = .videoCodec
        for width in [CGFloat(304), window.bounds.width - 16] {
            for angle in [0.0, 90, -90, 180] {
                host.rootView = AnyView(VStack {
                    CameraView(model: model).toolbarOptionsPanel(availableWidth: width)
                    Spacer()
                }.environment(\.captureControlAngle, angle).preferredColorScheme(.dark).background(Color.black))
                try await Task.sleep(for: .milliseconds(250))
                let fitted = host.sizeThatFits(in: CGSize(width: window.bounds.width, height: window.bounds.height))
                XCTAssertLessThanOrEqual(fitted.width, window.bounds.width + 1)
                if angle == 0 {
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "ProRes-Compatible-Options-\(Int(width))"; attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        model.videoCodec = .hevc
        let previousSpecification = model.proResSpecification
        model.selectProResSpecification(.proxy)
        XCTAssertEqual(model.proResSpecification, previousSpecification, "Changing codec must disable specification selection and preserve it")
    }
}
