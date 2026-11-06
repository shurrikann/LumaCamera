import XCTest
import UIKit
import ImageIO
import CoreImage
@testable import LumaCamera

@MainActor
final class HDRSequentialDiagnosticsTests: XCTestCase {
    func testRepeatedMacroFocusAndPhotoDetail() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<400 { if camera.ready && camera.macroActive { break }; try await Task.sleep(for:.milliseconds(20)) }
        guard camera.macroActive else { throw XCTSkip("需要固定近距纹理主体") }
        model.photoFormat = .heif
        let context = CIContext(options: [.cacheIntermediates:false])
        func detail(_ data: Data) throws -> Double {
            let source = try XCTUnwrap(CIImage(data:data))
            let scale = 512 / source.extent.width
            let image = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let rect = CGRect(x:image.extent.midX-128,y:image.extent.midY-128,width:256,height:256)
            var pixels = [UInt8](repeating:0,count:256*256*4)
            pixels.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:1024,bounds:rect,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) }
            var sum=0.0
            for y in 1..<255 { for x in 1..<255 {
                let p=(y*256+x)*4
                sum += abs(Double(pixels[p])-Double(pixels[p-4])) + abs(Double(pixels[p])-Double(pixels[p-1024]))
            } }
            return sum / (254*254*2)
        }
        var scores=[Double]()
        for index in 0..<6 {
            model.hdr = index >= 3
            try await Task.sleep(for:.milliseconds(500))
            let before = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            var captured: CapturedPhoto?
            let done=expectation(description:"macro-focus-\(index)")
            let prior=camera.onCaptureCompleted
            camera.onCaptureCompleted = { captured=$0; done.fulfill() }
            let started=CACurrentMediaTime()
            camera.capture(flashMode:.off,options:model.photoOptions)
            await fulfillment(of:[done],timeout:30)
            camera.onCaptureCompleted=prior
            let photo=try XCTUnwrap(captured,camera.message ?? "拍摄失败")
            let data=try XCTUnwrap(photo.resources.first?.data)
            let score=try detail(data); scores.append(score)
            let after = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            XCTAssertTrue(before.contains("virtual=true") && after.contains("virtual=true"))
            XCTAssertTrue(after.contains("AF=2"),"连续自动对焦应保留：\(after)")
            let a=XCTAttachment(data:data,uniformTypeIdentifier:"public.heic"); a.name="macro-focus-\(index)"; a.lifetime = .keepAlways; add(a)
            print("MACRO-FOCUS index=\(index) hdr=\(model.hdr) seconds=\(CACurrentMediaTime()-started) detail=\(score) before=\(before) after=\(after)")
        }
        // 同一组内的剧烈细节下降作为回归报警，仍需结合原图确认是否失焦。
        for start in [0,3] { for i in (start+1)...(start+2) { XCTAssertGreaterThan(scores[i],scores[start]*0.6) } }
    }
    func testAutomaticMacroFarSceneAndExplicitUltraWideRoutes() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false) }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let main = try XCTUnwrap(camera.lenses.first { abs($0.displayZoom - 1) < 0.01 })
        let ultra = try XCTUnwrap(camera.lenses.first { abs($0.displayZoom - 0.5) < 0.1 })
        for index in 0..<3 {
            model.selectFocalLength(main)
            try await Task.sleep(for: .seconds(2))
            let far = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            XCTAssertTrue(far.contains("primary=AVCaptureDeviceTypeBuiltInWideAngleCamera"), far)
            XCTAssertFalse(camera.macroActive)
            model.selectFocalLength(ultra)
            try await Task.sleep(for: .seconds(1))
            let explicit = await withCheckedContinuation { c in camera.automaticRouteSnapshotForTesting { c.resume(returning:$0) } }
            XCTAssertTrue(explicit.contains("primary=AVCaptureDeviceTypeBuiltInUltraWideCamera"), explicit)
            XCTAssertFalse(camera.macroActive, "用户选择0.5×不属于自动微距")
            print("MACRO-EXIT cycle=\(index) far=\(far) explicit=\(explicit)")
        }
    }
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
            if let image = camera.preview {
                let a = XCTAttachment(image: image); a.name = "macro-before-\(index)"; a.lifetime = .keepAlways; add(a)
            }
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
            XCTAssertTrue(route.contains("virtual=true"), "拍前应保留虚拟多摄")
            XCTAssertTrue(routeAfter.contains("virtual=true"), "快门不得替换预览输入")
            let properties = CGImageSourceCopyPropertiesAtIndex(sdr, 0, nil) as? [String: Any]
            let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]
            print("MACRO-FILE focal=\(String(describing:exif?[kCGImagePropertyExifFocalLength as String]))")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(camera.macroActive, "保持近距时拍摄后应继续显示微距")
            if let image = camera.preview {
                let a = XCTAttachment(image: image); a.name = "macro-after-\(index)"; a.lifetime = .keepAlways; add(a)
            }
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
