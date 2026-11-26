import SwiftUI
import XCTest
import UIKit
@testable import LumaCamera

final class CaptureShutterFaceTests: XCTestCase {
    @MainActor func testCaptureColorsAndLoadingStayInsideFixedShutterFrame() throws {
        let start = ContinuousClock.now
        var samples = 0
        for kind in [CaptureShutterFace.Kind.photo, .video] {
            for center in [CaptureShutterFace.Center.none, .stop, .loading, .stop, .none] {
                let renderer = ImageRenderer(content: CaptureShutterFace(kind: kind, center: center))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 76)
                XCTAssertEqual(image.height, 76)
                let base = try pixel(in: image, x: 60, y: 38)
                let square = try pixel(in: image, x: 30, y: 30)
                assertColor(base, red: kind == .video)
                assertColor(square, red: center == .none ? kind == .video : kind == .photo)
                samples += 1
            }
        }
        print("SHUTTER-FACE samples=\(samples) elapsed=\(ContinuousClock.now - start)")
    }

    @MainActor func testGlassShutterStatesOnDarkAndPhotoBackgrounds() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(Color.black))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let centers: [CaptureShutterFace.Center] = [.none, .countdown, .stop, .loading]
        var timings: [Double] = []
        for photoBackground in [false, true] {
            host.rootView = AnyView(ZStack {
                Color.black
                if photoBackground {
                    Image(uiImage: DemoImageFactory.make()).resizable().scaledToFill()
                }
                VStack(spacing: 28) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 12) {
                            ForEach(centers.indices, id: \.self) { column in
                                CaptureShutterFace(kind: row == 1 ? .video : .photo,
                                                   center: centers[column], ready: row != 2)
                                    .frame(width: 76, height: 76)
                            }
                        }
                    }
                }
            }.preferredColorScheme(.dark))
            try await Task.sleep(for: .milliseconds(250))
            for iteration in 0..<3 {
                let begin = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                timings.append((CACurrentMediaTime() - begin) * 1000)
                if iteration == 0 {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Shutter-Glass-PhotoBackdrop-\(photoBackground)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        print("SHUTTER-GLASS states=24 snapshots=\(timings.count) snapshotMs=\(timings)")
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    private func assertColor(_ rgba: [UInt8], red: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(rgba[0], 200, file: file, line: line)
        if red {
            XCTAssertLessThan(rgba[1], 115, file: file, line: line)
            XCTAssertLessThan(rgba[2], 115, file: file, line: line)
        } else {
            XCTAssertGreaterThan(rgba[1], 230, file: file, line: line)
            XCTAssertGreaterThan(rgba[2], 230, file: file, line: line)
        }
    }
}
