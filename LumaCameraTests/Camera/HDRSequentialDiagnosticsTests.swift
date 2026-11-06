import XCTest
import UIKit
import ImageIO
import CoreImage
@testable import LumaCamera

@MainActor
final class HDRSequentialDiagnosticsTests: XCTestCase {
    func testMacroGalleryResumeRouteDiagnostic() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<400 { if camera.ready && camera.macroActive && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard camera.ready && camera.macroActive else { throw XCTSkip("需要稳定近距且系统已选择微距") }
        for index in 0..<3 {
            let before = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            let imageBefore = camera.preview
            model.review = true; model.setCameraActive(false)
            try await Task.sleep(for: .seconds(1))
            let started = CACurrentMediaTime()
            model.review = false; model.setCameraActive(true)
            for _ in 0..<300 { if camera.ready && camera.previewFrameTimeForTesting > started { break }; try await Task.sleep(for: .milliseconds(20)) }
            let after = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            print("MACRO-REVIEW \(index) before=\(before) after=\(after) latency=\(CACurrentMediaTime()-started) macro=\(camera.macroActive)")
            for (name, image) in [("before", imageBefore), ("after", camera.preview)] {
                if let image { let a = XCTAttachment(image:image); a.name="macro-review-\(index)-\(name)"; a.lifetime = .keepAlways; add(a) }
            }
            XCTAssertTrue(camera.ready)
        }
    }
    func testTwoSequentialHDRCapturesKeepSameHDR() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.hdr = true
        try await Task.sleep(for: .milliseconds(800))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        for index in 1...2 {
            let route = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            print("HDR-SEQ-BEFORE \(index) macro=\(camera.macroActive) route=\(route)")
            var captured: CapturedPhoto?
            let done = expectation(description: "capture \(index)")
            let old = camera.onCaptureCompleted
            camera.onCaptureCompleted = { captured = $0; done.fulfill() }
            let start = CACurrentMediaTime()
            camera.capture(flashMode: .off, options: model.photoOptions)
            await fulfillment(of: [done], timeout: 30)
            camera.onCaptureCompleted = old
            let photo = try XCTUnwrap(captured, camera.message ?? "capture \(index) failed")
            let data = try XCTUnwrap(photo.resources.first?.data)
            let hdr = try XCTUnwrap(CIImage(data: data, options: [.expandToHDR: true]))
            func avg(_ image: CIImage) -> [Float] {
                let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])!.outputImage!
                var p=[Float](repeating:0,count:4)
                p.withUnsafeMutableBytes { ctx.render(f, toBitmap:$0.baseAddress!, rowBytes:16, bounds:CGRect(x:0,y:0,width:1,height:1), format:.RGBAf, colorSpace:cs) }
                return p
            }
            let sdr = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let primary = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sdr, 0, nil))
            let pAvg = avg(CIImage(cgImage: primary))
            let hAvg = avg(hdr)
            let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(sdr, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString:Any]
            let gmData = gm?[kCGImageAuxiliaryDataInfoData] as? Data
            let routeAfter = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            print("HDR-SEQ-AFTER \(index) macro=\(camera.macroActive) route=\(routeAfter)")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(camera.macroActive, "临时微距超广角拍摄后仍应显示微距标识")
            print("HDR-SEQ \(index) seconds=\(CACurrentMediaTime()-start) headroom=\(hdr.contentHeadroom) sdr=\(pAvg[0...2]) hdr=\(hAvg[0...2]) gm=\(gmData?.count ?? 0)")
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.heic")
            a.name = "seq-\(index).heic"; a.lifetime = XCTAttachment.Lifetime.keepAlways; add(a)
            if index == 1 { try await Task.sleep(for: .milliseconds(600)) }
        }
        // 模拟相册往返的相机生命周期，随后检查已恢复的实时状态。
        model.review = true; model.setCameraActive(false)
        try await Task.sleep(for: .milliseconds(500))
        model.review = false; model.setCameraActive(true)
        for _ in 0..<250 { if camera.ready && camera.macroActive { break }; try await Task.sleep(for: .milliseconds(20)) }
        print("HDR-MACRO-REVIEW ready=\(camera.ready) macro=\(camera.macroActive)")
        XCTAssertTrue(camera.ready, "相册返回后相机应恢复")
        // 检查临时拍摄路由结束后的系统选择；只记录，不推断画面是否合焦。
        try await Task.sleep(for: .seconds(7))
        let restored = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning: $0) } }
        print("HDR-SEQ-RESTORED macro=\(camera.macroActive) route=\(restored)")
        XCTAssertTrue(restored.contains("virtual=true"), "连续微距拍摄后必须释放临时物理输入：\(restored)")
        let fallback = restored.components(separatedBy: "fallback=").last?.components(separatedBy: " format=").first ?? ""
        XCTAssertTrue(fallback.contains("UltraWideCamera"), "恢复虚拟多摄后不能丢失超广角回退镜头：\(restored)")
    }
}
