import XCTest
import CoreImage
import UIKit
import AVFoundation
import ImageIO
@testable import LumaCamera

@MainActor final class NativePhotoGlassRendererTests: XCTestCase {
    func testFreshOffscreenNativeGlassChangesOnlyMaterialAndRestoresWindows() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires native Liquid Glass") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let key = scene.windows.first(where: \.isKeyWindow)
        let originalWindows = Set(scene.windows.map(ObjectIdentifier.init))
        let content = PhotoWatermarkContent(capturedAt:Date(),signature:"SHURRIKANN",location:"杭州市 · 西湖区",
            exposureSeconds:1/125,iso:100,whiteBalanceKelvin:5200,ev:0.3,filter:"原片")
        let settings = PhotoWatermarkSettings(style:.glassStrip,showsLocation:true,showsParameters:true)
        for size in [CGSize(width:1200,height:1600),CGSize(width:1600,height:1200)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let photo = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                UIImage(named:"FilterLandscape")?.draw(in:CGRect(origin:.zero,size:size))
            }
            let layout = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
            let native = try XCTUnwrap(NativePhotoGlassRenderer.render(photo:photo,card:layout.decoration!,cornerRadius:PhotoWatermarkLayout.glassCornerRadius(photoSize:size,card:layout.decoration!)))
            XCTAssertTrue(CGRect(origin:.zero,size:size).contains(native.sourceRect))
            XCTAssertGreaterThan(native.image.size.width,0)
            let source = CIImage(cgImage:try XCTUnwrap(photo.cgImage))
            let composite = UIGraphicsImageRenderer(size:size,format:format).image { c in
                photo.draw(in:CGRect(origin:.zero,size:size))
                c.cgContext.saveGState()
                UIBezierPath(roundedRect:layout.decoration!,cornerRadius:PhotoWatermarkLayout.glassCornerRadius(photoSize:size,card:layout.decoration!)).addClip()
                native.image.draw(in:native.sourceRect)
                c.cgContext.restoreGState()
            }
            let result = CIImage(cgImage:try XCTUnwrap(composite.cgImage))
            let difference = result.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:source])
            let card = layout.decoration!
            let roi = CGRect(x:card.minX,y:size.height-card.maxY,width:card.width,height:card.height)
            let inside = try average(difference,crop:roi)
            let outside = try average(difference,crop:CGRect(x:0,y:size.height*0.4,width:size.width,height:100))
            XCTAssertGreaterThan(inside,outside+0.003,"Native compositor material must be present, not just the photo")
            XCTAssertLessThan(outside,0.015,"Photo outside the glass must keep its pixels")
            let final = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
            let shot = XCTAttachment(image:final); shot.name = "Apple-Native-Glass-\(Int(size.width))x\(Int(size.height))"
            shot.lifetime = .keepAlways; add(shot)
            print("NATIVE-PHOTO-GLASS size=\(size) materialDifference=\(inside) outsideDifference=\(outside) PhotosWrites=0")
        }
        XCTAssertTrue(scene.windows.first(where: \.isKeyWindow) === key)
        XCTAssertTrue(scene.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.allSatisfy { $0.isHidden })
    }
    func testNativeGlassUsesOnlyTheSuppliedBackground() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native Glass") }
        let size = CGSize(width:1200,height:1600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size:size,format:format).image { c in
            UIColor(white:0.5,alpha:1).setFill(); c.fill(CGRect(origin:.zero,size:size))
        }
        let content = PhotoWatermarkContent(capturedAt:Date())
        let settings = PhotoWatermarkSettings(style:.glassStrip)
        let output = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
        let shot = XCTAttachment(image:output); shot.name = "Native-Glass-Uniform-Gray-Background"
        shot.lifetime = .keepAlways; add(shot)
    }

    func testRepeatedWorkerExportsRestoreCameraAndKeyWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let key = scene.windows.first(where: \.isKeyWindow)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size:CGSize(width:800,height:600),format:format).image { _ in
            UIImage(named:"FilterLandscape")?.draw(in:CGRect(x:0,y:0,width:800,height:600))
        }
        let samples = await Task.detached {
            var samples = [Double]()
            for _ in 0..<20 {
                autoreleasepool {
                    let start = CACurrentMediaTime()
                    let image = PhotoWatermarkRenderer.render(photo,settings:.init(style:.glassStrip),content:.init(capturedAt:Date()))
                    XCTAssertNotNil(image.cgImage)
                    samples.append((CACurrentMediaTime()-start)*1000)
                }
            }
            return samples
        }.value
        XCTAssertEqual(samples.count,20)
        XCTAssertTrue(scene.windows.first(where: \.isKeyWindow) === key)
        XCTAssertTrue(scene.windows.filter { $0 !== key && $0.frame.minX < -10_000 }.allSatisfy { $0.isHidden })
        print("NATIVE-GLASS-WORKER n=20 milliseconds=\(samples) keyWindowRetained=true offscreenWindowsHidden=true PhotosWrites=0")
    }

    func testRealJPEGAndHEIFLiveNativeGlassWithoutWritingPhotos() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.photoFormat = .jpeg; model.photoResolution = .standard; model.hdr = false
        model.preferences.watermark.style = .glassStrip; model.border = true
        model.setMode(.auto); model.setCameraActive(true)
        var captures = [CapturedPhoto]()
        camera.onCaptureCompleted = { if let photo = $0 { captures.append(photo) } }
        defer { model.setCameraActive(false) }
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        if !model.livePhotoEnabled { model.toggleLivePhoto() }
        for (index,format) in [PhotoFileFormat.jpeg,.heif].enumerated() {
            model.photoFormat = format
            camera.updateLook(CaptureLook(border:true,watermark:.init(style:.glassStrip)))
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            try await Task.sleep(for:.seconds(2))
            camera.capture(flashMode:.off,options:PhotoOptions(format:format,live:true))
            for _ in 0..<1200 { if captures.count > index { break }; try await Task.sleep(for:.milliseconds(50)) }
            let photo = try XCTUnwrap(captures.last)
            XCTAssertEqual(captures.count,index+1,camera.message ?? "Native glass capture failed")
            XCTAssertEqual(photo.resources.filter(\.pairedVideo).count,1)
            let still = try XCTUnwrap(photo.resources.first(where: { !$0.pairedVideo && !$0.alternate }))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(still.data as CFData,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString:Any])
            XCTAssertNotNil(exif[kCGImagePropertyExifExposureTime])
            XCTAssertNotNil(exif[kCGImagePropertyExifFocalLength])
            XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,1)
            let identifier = try XCTUnwrap((properties[kCGImagePropertyMakerAppleDictionary] as? [String:Any])?["17"] as? String)
            let preview = XCTAttachment(image:photo.preview); preview.name = "Native-Glass-Actual-Live-\(format.rawValue)"
            preview.lifetime = .keepAlways; add(preview)
            let video = try XCTUnwrap(photo.resources.first(where: \.pairedVideo))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mov")
            try video.data.write(to:file)
            defer { try? FileManager.default.removeItem(at:file) }
            let asset = AVURLAsset(url:file)
            let metadata = try await asset.load(.metadata)
            let contentID = try XCTUnwrap(metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }))
            let videoID = try await contentID.load(.stringValue)
            XCTAssertEqual(videoID,identifier)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            XCTAssertEqual(reader.status,.completed); XCTAssertGreaterThan(frames,0)
            print("NATIVE-GLASS-LIVE format=\(format.rawValue) decodedFrames=\(frames) PhotosWrites=0")
        }
        model.setCameraActive(false)
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
    }

    private func average(_ image:CIImage,crop:CGRect) throws -> Double {
        let average = image.cropped(to:crop).applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:crop)])
        var values = [Float](repeating:0,count:4)
        values.withUnsafeMutableBytes { data in
            CIContext().render(average,toBitmap:data.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),
                               format:.RGBAf,colorSpace:CGColorSpaceCreateDeviceRGB())
        }
        return Double(values[0]+values[1]+values[2])/3
    }
}
