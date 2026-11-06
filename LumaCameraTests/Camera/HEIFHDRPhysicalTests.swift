import XCTest
import AVFoundation
import CoreImage
import ImageIO
import Combine
@testable import LumaCamera

final class HEIFHDRPhysicalTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testHDRToggleAtOneXKeepsWidePrimary() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldFormat = model.photoFormat, oldHDR = model.hdr, oldMode = model.mode
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.hdr = false; model.photoFormat = oldFormat; model.setMode(oldMode)
            model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(30)) }
        model.setMode(.auto); model.photoFormat = .heif
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1) < 0.01 })
        model.selectFocalLength(wide)
        camera.setContinuousZoom(1)
        for _ in 0..<200 { if camera.ready && abs(camera.currentZoom-1)<0.01 { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(camera.currentZoom, 1, accuracy: 0.01)
        model.hdr = true
        for _ in 0..<200 { if camera.hdrPreviewActive { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(camera.hdrPreviewActive)
        model.hdr = false
        for _ in 0..<250 { if !camera.hdrPreviewActive && !camera.hdrPreviewConfiguring && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(350))
        let actual = await withCheckedContinuation { c in camera.zoomStateForTesting { z,_,_ in c.resume(returning:z) } }
        let behavior = await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { _,b,_,p in c.resume(returning:(b,p)) } }
        print("HDR-1X-AFTER-OFF actual=\(actual) ui=\(camera.currentZoom) selected=\(camera.selectedLens) primary=\(behavior.1 ?? "nil")")
        XCTAssertEqual(actual, 1, accuracy: 0.03, "1× 关 HDR 后硬件倍率必须回到主摄")
    }

    @MainActor func testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel), camera = model.camera
        let oldFormat = model.photoFormat, oldHDR = model.hdr, oldMode = model.mode, oldResolution = model.photoResolution, oldStyle = model.style
        let oldCapture = camera.onCaptureCompleted, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCapture
            model.hdr = false; model.photoFormat = oldFormat; model.photoResolution = oldResolution; model.style = oldStyle
            model.setMode(oldMode); model.hdr = oldHDR; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        // A preceding test can still have its stop queued while published ready
        // is true. Wait for the real new session before using capability snapshots.
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto)
        let wide = try XCTUnwrap(camera.lenses.first { $0.device.position == .back && abs($0.displayZoom-1)<0.01 })
        model.selectFocalLength(wide)
        for _ in 0..<200 { if camera.ready && camera.supportsHEIFHDR { break }; try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertTrue(camera.supportsHEIFHDR)
        model.photoFormat = .heif; model.photoResolution = .standard; model.style = .original; model.hdr = true
        for _ in 0..<200 { if camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 16 { break }; try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertTrue(camera.hdrPreviewActive,camera.message ?? "HLG preview failed")
        XCTAssertEqual(camera.preview?.cgImage?.bitsPerComponent,16)
        let capabilities = await withCheckedContinuation { c in camera.previewHDRCapabilitiesForTesting { c.resume(returning:$0) } }
        print("HEIF-HDR-PREVIEW \(capabilities)")
        let done = expectation(description:"HEIF HDR full-quality still")
        var captured:CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        camera.capture(flashMode:.off,options:model.photoOptions)
        await fulfillment(of:[done],timeout:35)
        let photo = try XCTUnwrap(captured,camera.message ?? "HEIF HDR capture failed")
        let resource = try XCTUnwrap(photo.resources.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        HDRImageAssertions.assertHDR(source, "HEIF HDR")
        XCTAssertEqual(photo.preview.cgImage?.bitsPerComponent,16)
        let decoded = try XCTUnwrap(CIImage(data:resource.data,options:[.expandToHDR:true]))
        print("HEIF-HDR-CAPTURE bits=\(properties[kCGImagePropertyDepth as String] ?? "nil") headroom=\(decoded.contentHeadroom) dimensions=\(decoded.extent)")
        XCTAssertGreaterThanOrEqual(decoded.extent.width*decoded.extent.height,11_000_000)
        for _ in 0..<200 { if camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 16 { break }; try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertTrue(camera.hdrPreviewActive)
        for _ in 0..<4 {
            model.hdr = false
            for _ in 0..<120 { if !camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 8 { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertFalse(camera.hdrPreviewActive)
            XCTAssertTrue(camera.availablePhotoFormats.contains(.heifPro))
            model.hdr = true
            for _ in 0..<120 { if camera.hdrPreviewActive { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertTrue(camera.hdrPreviewActive)
        }
        for mode in [CameraShootingMode.manual, .auto, .manual] {
            model.setMode(mode)
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            for _ in 0..<180 { if camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 16 { break }; try await Task.sleep(for:.milliseconds(25)) }
            print("HEIF-HDR-MODE mode=\(mode) requested=\(model.hdr) supported=\(camera.supportsHEIFHDR) active=\(camera.hdrPreviewActive) format=\(model.photoFormat)")
            XCTAssertTrue(camera.hdrPreviewActive)
            for focal in [0.5,1.0,2.0,4.0,8.0] {
                guard let lens = camera.lenses.first(where: { $0.device.position == .back && abs(Double($0.displayZoom)-focal)<0.01 }) else { continue }
                for _ in 0..<200 { if camera.ready && !camera.capturing { break }; try await Task.sleep(for:.milliseconds(20)) }
                model.selectFocalLength(lens)
                for _ in 0..<150 { if camera.ready && camera.selectedLens == lens.id && camera.hdrPreviewActive { break }; try await Task.sleep(for:.milliseconds(25)) }
                XCTAssertTrue(camera.ready); XCTAssertTrue(camera.hdrPreviewActive,"HDR lens \(focal) mode \(mode)")
                XCTAssertEqual(camera.currentZoom,CGFloat(focal),accuracy:0.02)
            }
        }
        model.photoFormat = .heifPro
        for _ in 0..<150 { if !camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 8 { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(camera.hdrPreviewActive,"HEIF Pro must retain its existing SDR live preview")
        XCTAssertTrue(model.photoOptions.hdr)
        XCTAssertTrue(camera.availablePhotoFormats.contains(.raw))
    }
    @MainActor func testTurningHDRBackOffDoesNotPublishBlackPreviewFrames() async throws {
        let model=try XCTUnwrap(AppDependencies.runningAppCameraModel), camera=model.camera
        let format=model.photoFormat, hdr=model.hdr, mode=model.mode
        let idle=UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled=true
        defer { model.hdr=false; model.photoFormat=format; model.hdr=hdr; model.setMode(mode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled=idle }
        model.setCameraActive(true); model.setMode(.auto)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.photoFormat = .heif; model.hdr=false
        let context=CIContext(options:[.cacheIntermediates:false])
        var luminance:[Double]=[]
        let token=camera.$preview.compactMap { $0 }.sink { image in
            if let source=CIImage(image:image) { luminance.append(Imaging.meanLuminance(source,context:context)) }
        }
        defer { token.cancel() }
        for _ in 0..<3 {
            model.hdr=true
            for _ in 0..<200 { if camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 16 { break }; try await Task.sleep(for:.milliseconds(20)) }
            try await Task.sleep(for:.milliseconds(250))
            luminance.removeAll(); model.hdr=false
            for _ in 0..<200 { if !camera.hdrPreviewActive && camera.preview?.cgImage?.bitsPerComponent == 8 { break }; try await Task.sleep(for:.milliseconds(20)) }
            try await Task.sleep(for:.milliseconds(250))
            XCTAssertFalse(camera.hdrPreviewActive); XCTAssertEqual(camera.preview?.cgImage?.bitsPerComponent,8)
            XCTAssertFalse(luminance.isEmpty)
            if (luminance.last ?? 0)>0.01 {
                XCTAssertGreaterThan(luminance.min() ?? 0,0.0005,"No empty black frame during HDR→SDR")
            }
            print("HDR-OFF-FRAMES count=\(luminance.count) min=\(luminance.min() ?? 0) last=\(luminance.last ?? 0)")
        }
    }
    #endif
}
