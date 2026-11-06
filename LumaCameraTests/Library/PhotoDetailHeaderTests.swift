import XCTest
import SwiftUI
import UIKit
@testable import LumaCamera

final class PhotoDetailHeaderTests: XCTestCase {
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
