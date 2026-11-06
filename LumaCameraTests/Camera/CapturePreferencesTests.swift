import XCTest
import CoreImage
import ImageIO
import UIKit
import AVFoundation
@testable import LumaCamera

final class CapturePreferencesTests: XCTestCase {
    func testDockKitPreviewMappingAccountsForAspectFillCrop() throws {
        let portraitSurface = CGSize(width: 300, height: 600)
        let landscapeSource = CGSize(width: 1920, height: 1080)
        let left = try XCTUnwrap(DockKitPreviewMapping.unitPoint(CGPoint(x: 0, y: 300),
            surfaceSize: portraitSurface, sourceImageSize: landscapeSource))
        let center = try XCTUnwrap(DockKitPreviewMapping.unitPoint(CGPoint(x: 150, y: 300),
            surfaceSize: portraitSurface, sourceImageSize: landscapeSource))
        let right = try XCTUnwrap(DockKitPreviewMapping.unitPoint(CGPoint(x: 300, y: 300),
            surfaceSize: portraitSurface, sourceImageSize: landscapeSource))
        XCTAssertEqual(left.x, 23.0 / 64.0, accuracy: 0.0001)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(right.x, 41.0 / 64.0, accuracy: 0.0001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.0001)

        let selected = try XCTUnwrap(DockKitPreviewMapping.unitRect(
            CGRect(x: 75, y: 150, width: 150, height: 300),
            surfaceSize: portraitSurface, sourceImageSize: landscapeSource))
        XCTAssertEqual(selected, CGRect(x: 55.0 / 128.0, y: 0.25,
                                        width: 18.0 / 128.0, height: 0.5))
    }

    func testDockKitPreviewMappingRejectsInvalidGeometry() {
        XCTAssertNil(DockKitPreviewMapping.unitPoint(.zero, surfaceSize: .zero,
            sourceImageSize: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(DockKitPreviewMapping.unitRect(.zero, surfaceSize: CGSize(width: 300, height: 600),
            sourceImageSize: CGSize(width: 1920, height: 1080)))
    }

    func testPreferencesPersistAndNewInstallDoesNotRecordLocation() throws {
        let name = "Preferences-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let store = CapturePreferencesStore(defaults:defaults)
        XCTAssertFalse(store.load().recordLocation)
        XCTAssertFalse(store.load().silentShutter)
        XCTAssertFalse(store.load().auxiliarySmoothPreview)
        XCTAssertFalse(store.load().dockKitTrackingEnabled)
        XCTAssertFalse(store.load().lockVideoWhiteBalance)
        XCTAssertTrue(store.load().saveCaptureSettings)
        var value = CapturePreferences(); value.silentShutter = true; value.recordLocation = true; value.copyright = "Photo by Lin"; value.focusAssist = true; value.saveUnfilteredOriginal = true; value.saveCaptureSettings = false; value.auxiliarySmoothPreview = true; value.dockKitTrackingEnabled = true; value.lockVideoWhiteBalance = true
        store.save(value); XCTAssertEqual(CapturePreferencesStore(defaults:defaults).load(),value)
        XCTAssertFalse(CapturePreferencesStore(defaults:defaults).load().saveCaptureSettings)
    }
    func testExistingPreferencesMigrateWithoutResettingOtherSettings() throws {
        let data = Data(#"{"recordLocation":true,"copyright":"Lin","focusAssist":true,"saveUnfilteredOriginal":true}"#.utf8)
        let value = try JSONDecoder().decode(CapturePreferences.self, from: data)
        XCTAssertFalse(value.silentShutter)
        XCTAssertTrue(value.recordLocation); XCTAssertEqual(value.copyright,"Lin")
        XCTAssertTrue(value.focusAssist); XCTAssertTrue(value.saveUnfilteredOriginal)
        XCTAssertTrue(value.saveCaptureSettings)
        XCTAssertFalse(value.auxiliarySmoothPreview, "Older preference data must default the new helper to off")
        XCTAssertFalse(value.dockKitTrackingEnabled, "Existing settings default DockKit tracking to off")
        XCTAssertFalse(value.lockVideoWhiteBalance, "Existing settings default recording white-balance lock to off")
    }
    @MainActor func testShutterPreferencePropagatesToEachNewCaptureOptionsSnapshot() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        let previous = model.preferences
        defer { model.preferences = previous }
        model.preferences.silentShutter = true
        let pending = model.photoOptions
        model.preferences.silentShutter = false
        XCTAssertTrue(pending.silentShutter)
        XCTAssertFalse(model.photoOptions.silentShutter)
    }
    @MainActor func testDockKitTrackingPreferenceCanBeChangedWhileCameraIsInactive() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        XCTAssertFalse(model.preferences.dockKitTrackingEnabled)
        model.setDockKitTrackingEnabled(true)
        XCTAssertTrue(model.preferences.dockKitTrackingEnabled)
        for _ in 0..<20 {
            model.setDockKitTrackingEnabled(!model.preferences.dockKitTrackingEnabled)
        }
        XCTAssertTrue(model.preferences.dockKitTrackingEnabled, "Repeated toggles finish in the expected state")
        model.setDockKitTrackingEnabled(false)
        XCTAssertFalse(model.preferences.dockKitTrackingEnabled)
    }
    func testMetadataPreservesCameraFieldsRemovesLocationWhenOffAndAddsCopyright() throws {
        let input = CIImage(color:.green).cropped(to:CGRect(x:0,y:0,width:64,height:96)).settingProperties([kCGImagePropertyGPSDictionary as String:["Latitude":1],kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFModel as String:"Camera"]])
        let output = PhotoMetadata.applying(to:input,location:nil,copyright:"  Lin  ")
        XCTAssertNil(output.properties[kCGImagePropertyGPSDictionary as String])
        let tiff = try XCTUnwrap(output.properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"Lin")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String,"Lin")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String,"Camera")
    }
    func testJPGAndHEIFOriginalCompanionIsUnfilteredAndPreservesCopyright() throws {
        let source = CIImage(color:.green).cropped(to:CGRect(x:0,y:0,width:64,height:96)), context = CIContext()
        for format in [PhotoFileFormat.jpeg,.heif] {
            let photo = try PhotoEncoder.encode(source:source,raw:nil,look:CaptureLook(style:.mono),options:PhotoOptions(format:format,copyright:"Lin",saveUnfilteredOriginal:true),context:context)
            let original = try XCTUnwrap(photo.unfilteredOriginal)
            XCTAssertEqual(photo.resources.count,1); XCTAssertNotEqual(photo.resources[0].filename,original.filename)
            let cgSource = try XCTUnwrap(CGImageSourceCreateWithData(original.data as CFData,nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cgSource,0,nil) as? [String:Any])
            let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"Lin")
            let image = try XCTUnwrap(CIImage(data:original.data))
            var pixel = [UInt8](repeating:0,count:4)
            context.render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:32,y:32,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            XCTAssertGreaterThan(pixel[1],200); XCTAssertLessThan(pixel[0],20)
        }
        let plain = try PhotoEncoder.encode(source:source,raw:nil,look:CaptureLook(),options:PhotoOptions(saveUnfilteredOriginal:true),context:context)
        XCTAssertNil(plain.unfilteredOriginal,"Do not save identical duplicates for an unchanged original look")
    }
    func testHDRPreviewRetainsExtendedHighlightsInsteadOfEightBitClipping() throws {
        let source = CIImage(color:CIColor(red:2,green:0.5,blue:0.2,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)!).cropped(to:CGRect(x:0,y:0,width:64,height:96))
        let context = CIContext(), photo = try PhotoEncoder.encode(source:source,raw:nil,look:CaptureLook(),options:PhotoOptions(format:.heifPro,hdr:true),context:context)
        let cg = try XCTUnwrap(photo.preview.cgImage); XCTAssertEqual(cg.bitsPerComponent,16)
        var pixel = [Float](repeating:0,count:4)
        context.render(CIImage(cgImage:cg),toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:1,y:1,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        XCTAssertGreaterThan(pixel[0],1.5)
    }
    #if !targetEnvironment(simulator)
    @MainActor func testRAWAttributionAndLocationOffUseCaptureMetadataWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldPreferences = model.preferences, oldMode = model.mode, oldFormat = model.photoFormat
        let oldResolution = model.photoResolution, oldHDR = model.hdr, oldLive = model.livePhotoEnabled
        let oldCapture = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCapture
            model.preferences = oldPreferences
            model.photoFormat = oldFormat
            model.photoResolution = oldResolution
            model.hdr = oldHDR
            if model.livePhotoEnabled != oldLive { model.toggleLivePhoto() }
            model.setMode(oldMode)
            model.setCameraActive(false)
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.preferences.recordLocation = false; model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto); model.hdr = false; model.photoFormat = .raw; model.photoResolution = .standard
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        let wide = try XCTUnwrap(camera.lenses.first{$0.device.position == .back && abs($0.displayZoom-1)<0.01})
        let previousFrameTime = camera.previewFrameTimeForTesting
        model.selectFocalLength(wide)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        for _ in 0..<300 {
            if camera.ready && camera.selectedLens == wide.id
                && camera.availablePhotoFormats.contains(.raw)
                && camera.previewFrameTimeForTesting > previousFrameTime { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        guard camera.ready, camera.selectedLens == wide.id, camera.availablePhotoFormats.contains(.raw) else {
            throw XCTSkip("The settled rear 1× route does not advertise RAW photo capture")
        }
        let done = expectation(description:"RAW attribution diagnostic")
        var captured:CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        camera.capture(flashMode:.off,options:PhotoOptions(format:.raw,copyright:"RAW Artist"))
        await fulfillment(of:[done],timeout:30)
        let photo = try XCTUnwrap(captured,camera.message ?? "RAW capture failed")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"RAW Artist")
    }
    @MainActor func testFrontMirrorPreferenceAndRealHDRCaptureMetadataWithoutSaving() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let oldPreferences = model.preferences, oldMode = model.mode, oldLens = camera.selectedLens
        let oldCapture = camera.onCaptureCompleted, oldRatio = model.ratio
        let oldFormat = model.photoFormat, oldResolution = model.photoResolution, oldHDR = model.hdr
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            camera.onCaptureCompleted = oldCapture; model.preferences = oldPreferences; model.ratio = oldRatio
            model.photoFormat = oldFormat; model.photoResolution = oldResolution; model.hdr = oldHDR
            if let old = camera.lenses.first(where:{$0.id==oldLens}) { model.selectFocalLength(old) }
            model.setMode(oldMode); model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for:.milliseconds(30)) }
        model.setMode(.auto)
        let front = try XCTUnwrap(camera.lenses.first{$0.device.position == .front})
        model.selectFocalLength(front)
        for _ in 0..<150 { if camera.ready { break }; try await Task.sleep(for:.milliseconds(30)) }
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        let mirrored = await withCheckedContinuation { c in camera.photoMirroringForTesting { c.resume(returning:$0) } }
        XCTAssertEqual(mirrored, true, "Front photos are always mirrored")
        let previewMirrored = await withCheckedContinuation { c in camera.previewMirroringForTesting { c.resume(returning:$0) } }
        XCTAssertEqual(previewMirrored, true, "Front preview is always mirrored")
        let wide = try XCTUnwrap(camera.lenses.first{$0.device.position == .back && abs($0.displayZoom-1)<0.01})
        let previousFrameTime = camera.previewFrameTimeForTesting
        model.selectFocalLength(wide)
        await withCheckedContinuation { continuation in camera.afterPendingSessionTasks { continuation.resume() } }
        model.photoFormat = .heifPro; model.photoResolution = .standard; model.hdr = true
        for _ in 0..<300 {
            if camera.ready && camera.selectedLens == wide.id
                && camera.availablePhotoFormats.contains(.heifPro)
                && camera.previewFrameTimeForTesting > previousFrameTime { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        guard camera.ready, camera.selectedLens == wide.id, camera.availablePhotoFormats.contains(.heifPro) else {
            throw XCTSkip("The settled rear 1× route does not advertise HEIF Pro capture")
        }
        let done = expectation(description:"HDR temporary diagnostic capture")
        var captured:CapturedPhoto?
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        camera.capture(flashMode:.off,options:PhotoOptions(format:.heifPro,hdr:true,copyright:"Luma Diagnostic"))
        await fulfillment(of:[done],timeout:30)
        let photo = try XCTUnwrap(captured,camera.message ?? "HDR capture failed")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData,nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        HDRImageAssertions.assertHDR(source, "保存原片 HDR")
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"Luma Diagnostic")
        XCTAssertEqual(photo.preview.cgImage?.bitsPerComponent,16)
        let policy = await withCheckedContinuation { c in camera.checkAutomaticLensStabilityForTesting { c.resume(returning:($0,$1,$2,$3)) } }
        XCTAssertTrue(policy.0); XCTAssertEqual(policy.1,AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto.rawValue)

    }
    #endif

}
