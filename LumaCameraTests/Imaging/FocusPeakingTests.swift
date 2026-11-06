import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class FocusPeakingTests: XCTestCase {
    private let context = CIContext()
    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
    private var source: CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 80, y: 80, width: 160, height: 240))
            .composited(over: CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: bounds))
    }
    private func bytes(_ image: CIImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 320 * 400 * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        return pixels
    }
    func testSharpEdgesAreMarkedFlatAreasStayCleanAndDefocusReducesPeaks() throws {
        let sharp = FocusPeakingRenderer.apply(to: source, analysis: source)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: bounds)
        let soft = FocusPeakingRenderer.apply(to: blurred, analysis: blurred)
        func marked(_ data: [UInt8]) -> Int { stride(from: 0, to: data.count, by: 4).filter { data[$0] > 180 && data[$0+1] < 150 && data[$0+2] < 150 }.count }
        XCTAssertGreaterThan(marked(bytes(sharp)), 400)
        XCTAssertLessThan(marked(bytes(soft)), marked(bytes(sharp)) / 2)
        let before = bytes(source), after = bytes(sharp)
        for point in [(10, 10), (160, 200)] { let offset = (point.1 * 320 + point.0) * 4; XCTAssertEqual(Array(before[offset..<offset+4]), Array(after[offset..<offset+4])) }
        for (name, image) in [("Sharp", sharp), ("Defocused", soft)] {
            let cg = try XCTUnwrap(context.createCGImage(image, from: bounds))
            let a = XCTAttachment(image: UIImage(cgImage: cg)); a.name = "Focus-Peaking-" + name; a.lifetime = .keepAlways; add(a)
        }
    }
    #if targetEnvironment(simulator)
    @MainActor func testPeakingToggleChangesPreviewButNeverCapturedPhotoAndFinalOffRecovers() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.start(); defer { model.camera.stop() }
        for _ in 0..<200 { if model.camera.ready && model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let clean = try XCTUnwrap(model.camera.preview).pngData()
        model.focusPeaking = true
        for _ in 0..<150 { if model.camera.preview?.pngData() != clean { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(model.camera.preview?.pngData(), clean)
        model.photoFormat = .tiff; model.takePhoto()
        for _ in 0..<200 { if model.library.lastPhoto != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let rawSource = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        let expected = try XCTUnwrap(Imaging.render(rawSource, look: model.effectiveCaptureLook, context: context))
        XCTAssertEqual(model.library.lastPhoto?.pngData(), expected.pngData(), "Focus assistance must not be baked into photos")
        for i in 0..<100 { model.focusPeaking = i % 2 == 0 }
        model.focusPeaking = false
        for _ in 0..<150 { if model.camera.preview?.pngData() == clean { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.camera.preview?.pngData(), clean)
    }
    #endif
}
