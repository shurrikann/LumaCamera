import XCTest
import CoreLocation
import CoreImage
import UIKit
import ImageIO
@testable import LumaCamera

final class PhotoLocationTests: XCTestCase {
    func testFreshFixPolicyRejectsInvalidStaleAndUncertainReadings() {
        let now = Date()
        func fix(_ seconds: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 34.25, longitude: 108.95), altitude: 410,
                       horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: now.addingTimeInterval(seconds))
        }
        XCTAssertNotNil(PhotoLocation.recent(fix(-5), now: now))
        XCTAssertNil(PhotoLocation.recent(fix(-61), now: now))
        XCTAssertNil(PhotoLocation.recent(fix(100), now: now))
        XCTAssertNil(PhotoLocation.recent(fix(0, accuracy: -1), now: now))
        XCTAssertFalse(PhotoLocation(latitude: .nan, longitude: 1).isValid)
        XCTAssertFalse(PhotoLocation(latitude: 91, longitude: 1).isValid)
        XCTAssertTrue(PhotoLocation(latitude: 0, longitude: 0).isValid)
        XCTAssertNotNil(PhotoLocation.recorded(fix(-100000))) // Historical asset locations do not expire.
    }

    func testGPSAndJSONRoundTripPreserveSouthernWesternCoordinates() throws {
        let location = PhotoLocation(latitude: -33.86, longitude: -151.2, altitude: -8)
        let decoded = try XCTUnwrap(PhotoLocation.fromGPS([kCGImagePropertyGPSDictionary: location.gpsMetadata], date: location.timestamp))
        XCTAssertEqual(decoded.latitude, location.latitude)
        XCTAssertEqual(decoded.longitude, location.longitude)
        XCTAssertEqual(decoded.altitude, -8)
        XCTAssertEqual(try JSONDecoder().decode(PhotoLocation.self, from: JSONEncoder().encode(location)), location)
        XCTAssertNil(PhotoLocation.fromGPS([:]))
    }

    func testEncodedFilesKeepGPSAcrossFormatsAndAllRatiosWithoutChangingRawBytes() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 160))
        let context = CIContext()
        let location = PhotoLocation(latitude: 34.25, longitude: 108.95)
        for format in [PhotoFileFormat.jpeg, .heif, .tiff] {
            for ratio in FrameRatio.allCases {
                let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(ratio: ratio), options: PhotoOptions(format: format), context: context, location: location)
                let image = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
                let gps = try XCTUnwrap(PhotoLocation.fromGPS(props))
                XCTAssertEqual(gps.latitude, 34.25, accuracy: 0.00001)
                XCTAssertEqual(gps.longitude, 108.95, accuracy: 0.00001)
            }
        }
        let raw = Data([1,2,3,4])
        let photo = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(), options: PhotoOptions(format: .raw), context: context, location: location)
        XCTAssertEqual(photo.resources[0].data, raw)
        XCTAssertEqual(photo.location, location)
        let plain = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(), options: PhotoOptions(), context: context)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(plain.resources[0].data as CFData, nil))
        XCTAssertNil(PhotoLocation.fromGPS(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]))
    }

    func testGPSIsKeptInHDRHEIFAndRawJPEGCompanion() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 160))
        let location = PhotoLocation(latitude: 34.25, longitude: 108.95)
        let raw = Data([1,2,3])
        for options in [PhotoOptions(format: .heifPro, hdr: true), PhotoOptions(format: .rawJPEG)] {
            let photo = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(), options: options, context: CIContext(), location: location)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertNotNil(PhotoLocation.fromGPS(properties))
            if options.format == .rawJPEG { XCTAssertEqual(photo.resources[1].data, raw) }
        }
    }

    func testInfoPresentationHidesRequestedPixelsAndSaveStatusButKeepsCaptureValues() {
        let details = PhotoDetails(rows: [.init(title: "保存状态", value: "已保存"), .init(title: "像素设置", value: "48 MP"),
            .init(title: "输出尺寸", value: "6048 × 8064"), .init(title: "文件大小", value: "2.8 MB"),
            .init(title: "文件名称", value: "IMG.heic"), .init(title: "快门时主镜头", value: "长焦")])
        let info = PhotoInfoPresentation(details: details)
        XCTAssertEqual(info.filename, "IMG.heic")
        XCTAssertEqual(info.dimensionsAndSize, "6048 × 8064 · 2.8 MB")
        XCTAssertEqual(info.parameterItems.count, 7)
        XCTAssertEqual(info.parameterItems.last?.title, "拍摄类型")
        XCTAssertEqual(info.parameterItems.last?.value, "—", "Legacy photos have no trustworthy capture-type record")
        XCTAssertEqual(info.additionalRows.map(\.title), ["快门时主镜头"])
        var parameters = PhotoCaptureParameters(); parameters.requestedMegapixels = 48
        XCTAssertFalse(parameters.rows.contains { $0.title == "像素设置" })
        XCTAssertEqual(parameters.requestedMegapixels, 48)
    }

    func testPhotoInfoPresentsExposureFieldsAndRecordedShootingType() {
        var parameters = PhotoCaptureParameters()
        parameters.exposureSeconds = 0.5
        parameters.iso = 400
        parameters.exifExposureBiasEV = 0.3
        parameters.equivalentFocalLengthMM = 35
        parameters.aperture = 1.78
        parameters.shootingType = "光轨"
        let details = PhotoDetails(rows: PhotoCaptureDiagnostics(parameters: parameters).detailRows,
                                  captureParameters: parameters)
        let items = PhotoInfoPresentation(details: details).parameterItems

        XCTAssertEqual(items.map(\.title), ["快门", "ISO", "EV", "焦距", "光圈", "格式", "拍摄类型"])
        XCTAssertEqual(items.map(\.value), ["1/2", "ISO 400", "EV +0.3", "35MM", "f1.78", "—", "光轨"])
        XCTAssertFalse(PhotoInfoPresentation(details: details).additionalRows.contains { $0.title == "拍摄类型" })
    }
    @MainActor
    func testCaptureSaveRetryAndEditKeepLocationAndShutterTime() {
        let service = LocationSaveStub()
        let model = PhotoLibraryViewModel(service: service)
        let location = PhotoLocation(latitude: 34.25, longitude: 108.95)
        var parameters = PhotoCaptureParameters(); parameters.capturedAt = Date(timeIntervalSince1970: 1000)
        parameters.location = location
        let raw = PhotoResource(data: Data([1,2,3]), filename: "photo.dng")
        let photo = CapturedPhoto(preview: UIImage(), resources: [raw], diagnostics: PhotoCaptureDiagnostics(parameters: parameters), location: location)
        model.acceptCapture(photo, automaticallySave: true)
        XCTAssertEqual(service.saved?.location, location)
        XCTAssertEqual(model.lastPhotoDate, parameters.capturedAt)
        service.complete?(.failure(PhotoLibraryError.writeDenied))
        XCTAssertEqual(model.captureLocation, location)
        model.replaceUnsavedPhoto(PhotoEditResult(preview: UIImage(), resource: PhotoResource(data: Data([4]), filename: "edited.jpg")))
        XCTAssertEqual(model.captureLocation, location)
        XCTAssertEqual(model.lastPhotoDate, parameters.capturedAt)
        model.savePhoto(showSuccessMessage: false)
        XCTAssertEqual(service.saved?.location, location)
        XCTAssertTrue(service.saved?.resources.contains { $0.filename == "photo.dng" && $0.data == raw.data } == true)
    }

}


private final class LocationSaveStub: PhotoLibraryService {
    var saved: CapturedPhoto?
    var complete: ((Result<String, Error>) -> Void)?
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { complete = completion }
    func saveCapture(_ photo: CapturedPhoto, completion: @escaping (Result<String, Error>) -> Void) { saved = photo; complete = completion }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
