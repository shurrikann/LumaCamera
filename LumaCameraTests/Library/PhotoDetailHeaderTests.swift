import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class PhotoDetailHeaderTests: XCTestCase {
    @MainActor func testNavigationHostedLandscapePhotoPreservesUpperAndLowerTexture() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            UIColor.black.setFill()
            for y in stride(from: 0, to: 400, by: 8) {
                for x in stride(from: 0, to: 600, by: 8) where (x/8 + y/8).isMultiple(of: 2) {
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        func zooms(_ view: UIView) -> [PhotoZoomScrollView] {
            (view as? PhotoZoomScrollView).map { [$0] } ?? view.subviews.flatMap { zooms($0) }
        }
        func contrast(_ shot: UIImage, at point: CGPoint) throws -> Double {
            let scale = shot.scale
            let rect = CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64)
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            let crop = try XCTUnwrap(shot.cgImage?.cropping(to: rect))
            var pixels = [UInt8](repeating: 0, count: 64*64)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
            return sqrt(pixels.reduce(0.0) { $0 + pow(Double($1)-mean, 2) } / Double(pixels.count))
        }
        var samples: [String] = []
        for angle in [0.0, 90, -90, 0, 90] {
            host.rootView = AnyView(NavigationStack {
                PhotoViewerLayout(image: image, date: Date(), onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {})
            }.environment(\.libraryMediaAngle, angle))
            try await Task.sleep(for: .milliseconds(350))
            let zoom = try XCTUnwrap(zooms(window).first)
            if #available(iOS 26.0, *) {
                XCTAssertTrue(zoom.topEdgeEffect.isHidden)
                XCTAssertTrue(zoom.bottomEdgeEffect.isHidden)
                XCTAssertTrue(zoom.leftEdgeEffect.isHidden)
                XCTAssertTrue(zoom.rightEdgeEffect.isHidden)
            }
            let rect = zoom.photoView.convert(zoom.photoView.bounds, to: window)
            let began = CACurrentMediaTime()
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let cost = (CACurrentMediaTime()-began)*1000
            let upper = try contrast(shot, at: CGPoint(x: rect.midX, y: rect.minY+rect.height*0.28))
            let lower = try contrast(shot, at: CGPoint(x: rect.midX, y: rect.minY+rect.height*0.72))
            samples.append("angle=\(angle) upper=\(upper) lower=\(lower) snapshotMs=\(cost)")
            XCTAssertGreaterThan(upper, 45)
            XCTAssertGreaterThan(upper, lower*0.85)
            let attachment = XCTAttachment(image: shot); attachment.name = "Photo-Texture-\(Int(angle))"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        print("PHOTO-LANDSCAPE-TEXTURE samples=\(samples); contrast is grayscale standard deviation, not FPS")
    }
    func testAddressFormattingDeduplicatesAndHasFallback() {
        XCTAssertEqual(PhotoAddressPresentation.title(locality: "上海市", sublocality: "浦东新区", street: "世纪大道", number: "100号", name: nil), "上海市 · 浦东新区 · 世纪大道 · 100号")
        XCTAssertEqual(PhotoAddressPresentation.title(locality: "同名", sublocality: "同名", street: nil, number: nil, name: nil), "同名")
        XCTAssertEqual(PhotoAddressPresentation.title(locality: nil, sublocality: nil, street: nil, number: nil, name: "景点"), "景点")
        XCTAssertEqual(PhotoAddressPresentation.title(locality: nil, sublocality: nil, street: nil, number: nil, name: nil), "")
    }
    func testRAWBadgeFitsAllRatiosAndRejectsInvalidDimensions() {
        let viewport = CGSize(width: 390, height: 650)
        for ratio in FrameRatio.allCases {
            let fit = PhotoRAWBadgeLayout.fit(image: CGSize(width: 300, height: 300 / ratio.portraitRatio), viewport: viewport)
            XCTAssertGreaterThan(fit.width, 0); XCTAssertGreaterThan(fit.height, 0)
            XCTAssertLessThanOrEqual(fit.width, viewport.width + 0.01)
            XCTAssertLessThanOrEqual(fit.height, viewport.height + 0.01)
            XCTAssertEqual(fit.width / fit.height, ratio.portraitRatio, accuracy: 0.0001)
        }
        XCTAssertEqual(PhotoRAWBadgeLayout.fit(image: .zero, viewport: viewport), .zero)
        XCTAssertEqual(PhotoRAWBadgeLayout.fit(image: CGSize(width: CGFloat.nan, height: 10), viewport: viewport), .zero)
    }

    @MainActor func testFullscreenPhotoAndFloatingControls() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func zoom(in view: UIView) -> PhotoZoomScrollView? {
            if let photo = view as? PhotoZoomScrollView { return photo }
            return view.subviews.lazy.compactMap { zoom(in: $0) }.first
        }
        var costs: [Double] = []
        for width in [CGFloat(320), scene.screen.bounds.width] {
            for size in [CGSize(width: 300, height: 400), CGSize(width: 400, height: 300), CGSize(width: 300, height: 300)] {
                let source = UIGraphicsImageRenderer(size: size).image { context in
                    DemoImageFactory.make().draw(in: CGRect(origin: .zero, size: size))
                }
                host.rootView = AnyView(PhotoViewerLayout(
                    image: source, date: Date(), hasFilter: true,
                    onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {}
                ).frame(width: width).frame(maxWidth: .infinity).preferredColorScheme(.dark))
                try await Task.sleep(for: .milliseconds(200))
                let scroll = try XCTUnwrap(zoom(in: window))
                scroll.layoutIfNeeded()
                XCTAssertEqual(scroll.bounds.width, width, accuracy: 1)
                XCTAssertGreaterThanOrEqual(scroll.bounds.height, window.bounds.height - 1)
                let displayed = scroll.photoView.convert(scroll.photoView.bounds, to: scroll)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(displayed))
                XCTAssertEqual(displayed.width / displayed.height, size.width / size.height, accuracy: 0.01)
                XCTAssertTrue(abs(displayed.width - scroll.bounds.width) < 1 || abs(displayed.height - scroll.bounds.height) < 1)
                let start = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                costs.append((CACurrentMediaTime() - start) * 1000)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Floating-Photo-\(Int(width))-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        print("FLOATING-PHOTO samples=\(costs.count) snapshotMs=\(costs)")
    }

    @MainActor func testSharePreparationKeepsDetailActionIconsFixed() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let source = DemoImageFactory.make()
        var frames: [String: CGRect] = [:]
        var baseline: [String: CGRect] = [:]
        var times: [Double] = []
        for cycle in 0..<4 {
            for busy in [false, true, false] {
                host.rootView = AnyView(PhotoViewerLayout(
                    image: source, date: nil, busy: busy, shareBusy: busy,
                    onBack: {}, onCamera: {}, onShare: {}, onInfo: {}, onEdit: {}, onDelete: {},
                    onActionFrameForTesting: { frames[$0] = $1 }
                ).environment(\.captureControlAngle, 0).preferredColorScheme(.dark))
                try await Task.sleep(for: .milliseconds(90))
                for name in ["分享", "图片详情", "图片编辑", "删除"] {
                    let frame = try XCTUnwrap(frames[name])
                    XCTAssertGreaterThan(frame.width, 0)
                    if let original = baseline[name] { XCTAssertEqual(frame, original, "状态变化不能移动图标") }
                    else { baseline[name] = frame }
                }
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                times.append((CACurrentMediaTime() - start) * 1000)
                if cycle == 0 {
                    let attachment = XCTAttachment(image: shot)
                    attachment.name = "Detail-Share-Stable-\(busy)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        print("DETAIL-SHARE-STABLE transitions=12 snapshotMs=\(times)")
    }

    @MainActor
    func testPhotoInfoParameterGridLayoutAndRepeatedDrawCost() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Photo detail parameter layout is checked on the physical device")
        #else
        var parameters = PhotoCaptureParameters()
        parameters.exposureSeconds = 1.0 / 125
        parameters.iso = 400
        parameters.exifExposureBiasEV = 0.3
        parameters.equivalentFocalLengthMM = 35
        parameters.aperture = 1.78
        parameters.shootingType = "夜景"
        let rows = PhotoCaptureDiagnostics(parameters: parameters).detailRows + [
            .init(title: "输出尺寸", value: "3024 × 4032"), .init(title: "文件大小", value: "2.4 MB"),
            .init(title: "文件名称", value: "IMG_test.heic"), .init(title: "输出格式", value: "HEIF")
        ]
        let details = PhotoDetails(rows: rows, captureParameters: parameters)
        let presentation = PhotoInfoPresentation(details: details)
        XCTAssertEqual(presentation.parameterItems.count, 7)
        XCTAssertEqual(presentation.parameterItems.last?.title, "拍摄类型")
        XCTAssertEqual(presentation.parameterItems.last?.value, "夜景")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: PhotoInfoContent(details: details))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 0)
        XCTAssertGreaterThan(host.view.bounds.height, 0)

        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            for _ in 0..<6 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(image.cgImage)
            }
            samples.append((CACurrentMediaTime() - start) * 1_000)
        }
        let formatted = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let average = samples.reduce(0, +) / Double(samples.count)
        print("PHOTO-INFO-GRID-DRAW samples-ms=\(formatted) avg-ms-per-6-snapshots=\(String(format: "%.2f", average))")
        let metrics = XCTAttachment(string: "device=iPhone 17 Pro; parameterCards=7; drawSamples=5 groups x 6 snapshots; samples-ms=\(formatted); average-ms-per-6-snapshots=\(String(format: "%.2f", average)); view hierarchy snapshot cost only, not display FPS or touch latency")
        metrics.name = "Photo-Info-Grid-Metrics"
        metrics.lifetime = .keepAlways
        add(metrics)
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Photo-Info-Parameters-With-Titles"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}
