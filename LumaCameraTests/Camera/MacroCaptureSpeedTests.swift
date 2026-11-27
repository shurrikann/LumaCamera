import XCTest
import ImageIO
@testable import LumaCamera

@MainActor
final class MacroCaptureSpeedTests: XCTestCase {
    func testRecentMacroRequestsTwoConstituentsAndDeliversSDRAndHDR() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires virtual multicamera photo delivery")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let previous = camera.onCaptureCompleted
        defer {
            camera.onCaptureCompleted = previous; camera.onPhotoConstituentCountForTesting = nil
            camera.setMacroActiveForTesting(false); model.setCameraActive(false)
        }
        model.setCameraActive(true); model.setMode(.auto); model.photoFormat = .heif; model.photoResolution = .standard
        for _ in 0..<400 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        for hdr in [false, true] {
            model.hdr = hdr
            await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
            let enabled = await withCheckedContinuation { c in camera.prepareConstituentDeliveryForTesting { c.resume(returning: $0) } }
            guard enabled else { throw XCTSkip("Current format does not support constituent delivery") }
            var requested = -1
            camera.onPhotoConstituentCountForTesting = { requested = $0 }
            camera.noteRecentMacroCaptureForTesting()
            let done = expectation(description: "Macro constituent delivery HDR=\(hdr)")
            var photo: CapturedPhoto?
            camera.onCaptureCompleted = { photo = $0; done.fulfill() }
            camera.capture(flashMode: .off, options: model.photoOptions)
            await fulfillment(of: [done], timeout: 40)
            XCTAssertEqual(requested, 2)
            XCTAssertNotNil(photo); XCTAssertNil(camera.message)
            XCTAssertFalse(photo?.resources.isEmpty ?? true)
            let data = try XCTUnwrap(photo?.resources.first(where: { !$0.alternate && !$0.pairedVideo })?.data)
            let file = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            let focal = try XCTUnwrap((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue)
            XCTAssertGreaterThan(focal, 0)
            XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings as String])
            XCTAssertGreaterThan(try XCTUnwrap((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue), 0)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.heic")
            attachment.name = "Macro-Constituent-HDR-\(hdr)"; attachment.lifetime = .keepAlways; add(attachment)
            print("MACRO-CONSTITUENT hdr=\(hdr) requested=\(requested) delivered=\(photo != nil) fileFocalMM=\(focal) PhotosWrites=0")
        }
        #endif
    }
    func testMacroSDRCaptureSpeed() async throws {
        let model = try await FullDeviceRegressionFixture.makeIsolatedModel(), camera = model.camera
        model.setCameraActive(true)
        defer { model.setCameraActive(false); model.hdr = false }
        for _ in 0..<300 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.setCaptureKind(.photo); model.photoFormat = .heif; model.hdr = false
        var captured: CapturedPhoto?
        let done = expectation(description: "sdr")
        let old = camera.onCaptureCompleted
        camera.onCaptureCompleted = { captured = $0; done.fulfill() }
        defer { camera.onCaptureCompleted = old }
        let start = CACurrentMediaTime()
        camera.capture(flashMode: .off, options: model.photoOptions)
        await fulfillment(of: [done], timeout: 45)
        print("MACRO-SPEED sdr seconds=\(CACurrentMediaTime()-start) photo=\(captured != nil)")
        XCTAssertNotNil(captured)
    }
}
