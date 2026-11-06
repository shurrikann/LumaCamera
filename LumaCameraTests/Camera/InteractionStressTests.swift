import XCTest
import AVFoundation
import CoreImage
import UIKit
import Combine
@testable import LumaCamera

final class InteractionStressTests: XCTestCase {
    func testWhiteBalanceTransientAndMalformedValuesNeverReachConversion() {
        let values: [Float] = [-100, -1, 0, 0.99, 1, 2, 4, 100, .nan, .infinity, -.infinity]
        for _ in 0..<100 {
            for red in values { for green in values {
                let gains = AVCaptureDevice.WhiteBalanceGains(redGain: red, greenGain: green, blueGain: 2)
                let accepted = WhiteBalanceSafety.validated(gains, maximum: 4)
                XCTAssertEqual(accepted != nil, red.isFinite && green.isFinite && red >= 1 && green >= 1 && red <= 4 && green <= 4)
                if let safe = WhiteBalanceSafety.clamped(gains, maximum: 4) {
                    XCTAssertNotNil(WhiteBalanceSafety.validated(safe, maximum: 4))
                }
            } }
        }
        XCTAssertNil(WhiteBalanceSafety.validated(.init(redGain: 1, greenGain: 1, blueGain: 1), maximum: .nan))
    }

    @MainActor
    func testRepeatedPopupSwitchesAlwaysReplacePreviousPanel() async {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        #if targetEnvironment(simulator)
        let ready = expectation(description: "Camera ready")
        let token = model.camera.$ready.filter { $0 }.first().sink { _ in ready.fulfill() }
        model.camera.start(); await fulfillment(of: [ready], timeout: 5)
        defer { token.cancel(); model.camera.stop() }
        #endif
        for _ in 0..<500 {
            model.beginZoomDial(at: 1); model.finishZoomDrag()
            model.toggleToolbarPanel(.ratio)
            XCTAssertFalse(model.zoomDialVisible)
            XCTAssertEqual(model.toolbarPanel, .ratio)
            model.openFunctions(); XCTAssertNil(model.toolbarPanel)
            model.openTools(feedback: false); XCTAssertFalse(model.functions)
            model.openParameter(.iso); XCTAssertFalse(model.tools)
            model.togglePanel(.film); XCTAssertNil(model.toolbarPanel)
            let zoomCanOpen = model.camera.ready && !model.camera.capturing
            model.beginZoomDial(at: 1)
            if zoomCanOpen {
                XCTAssertNil(model.panel)
            } else {
                // Zoom is intentionally unavailable until the camera session is ready.
                XCTAssertEqual(model.panel, .film)
            }
            model.closePopups()
            XCTAssertFalse(model.zoomDialVisible)
            XCTAssertFalse(model.popupVisible)
            XCTAssertNil(model.toolbarPanel)
        }
    }

    @MainActor
    func testGalleryEntryTracksCaptureAndReturnsToGridAfterDeletion() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        for _ in 0..<1000 {
            model.library.acceptPhoto(nil)
            model.openLibrary(); XCTAssertFalse(model.reviewCapture)
            model.review = false
            model.library.acceptPhoto(UIImage())
            model.openLibrary(); XCTAssertTrue(model.reviewCapture)
            model.review = false
            for _ in 0..<5 {
                model.openLibrary(); XCTAssertFalse(model.reviewCapture)
                model.review = false
            }
            model.library.deletePhoto()
            model.openLibrary(); XCTAssertFalse(model.reviewCapture)
            model.review = false
        }
    }

    @MainActor
    func testPhotoZoomRepeatedPinchesImageReplacementAndViewportResize() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { _ in UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 200)) }
        let view = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.display(image); view.layoutIfNeeded()
        for index in 0..<1000 {
            view.setZoomScale(CGFloat(index % 6 + 1), animated: false)
            view.contentOffset = CGPoint(x: CGFloat(index % 100), y: CGFloat(index % 80))
            view.layoutIfNeeded()
            XCTAssertTrue(view.contentSize.width.isFinite && view.contentSize.height.isFinite)
            XCTAssertTrue(view.photoView.image === image)
            if index % 50 == 0 {
                view.bounds.size = index % 100 == 0 ? CGSize(width: 600, height: 390) : CGSize(width: 390, height: 600)
                view.setNeedsLayout(); view.layoutIfNeeded()
                XCTAssertEqual(view.zoomScale, 1)
            }
        }
        XCTAssertTrue(view.viewForZooming(in: view) === view.photoView)
    }

    func testRAWPreviewIsBoundedAndOriginalResourcesArePreserved() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 8000))
        let raw = Data([1, 2, 3, 4]) // Resource passthrough; not a hardware DNG decoder test.
        let context = CIContext(options: [.cacheIntermediates: false])
        for ratio in FrameRatio.allCases {
            let capture = try PhotoEncoder.encode(source: source, raw: raw, look: CaptureLook(ratio: ratio), options: PhotoOptions(format: .raw), context: context)
            XCTAssertLessThanOrEqual(max(capture.preview.size.width, capture.preview.size.height), 2400)
            XCTAssertEqual(capture.resources.first?.data, raw)
            XCTAssertEqual(capture.preview.imageOrientation, .up)
        }
        XCTAssertThrowsError(try PhotoEncoder.encode(source: CIImage(color: .white), raw: raw, look: CaptureLook(), options: PhotoOptions(format: .raw), context: context))
    }

    func testRepeatedEncodingAllFormatsPreservesResourcesAndFinitePreview() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 60, height: 80))
        let context = CIContext(options: [.cacheIntermediates: false])
        for index in 0..<120 {
            let format = PhotoFileFormat.allCases[index % PhotoFileFormat.allCases.count]
            let look = CaptureLook(style: FilmStyle.allCases[index % FilmStyle.allCases.count], intensity: Double(index % 11) / 10, ratio: FrameRatio.allCases[index % FrameRatio.allCases.count])
            let photo = try PhotoEncoder.encode(source: source, raw: Data([1, 2, 3]), look: look, options: PhotoOptions(format: format), context: context)
            XCTAssertFalse(photo.resources.isEmpty)
            XCTAssertGreaterThan(photo.preview.size.width, 0)
            XCTAssertTrue(photo.preview.size.height.isFinite)
        }
    }

    @MainActor
    func testCancelledDetailRequestsCannotRestoreOldPhotoUnderRapidNavigation() {
        let service = StressLibraryService()
        let library = PhotoLibraryViewModel(service: service)
        let gallery = GalleryViewModel(browser: service, library: library)
        let detail = PhotoDetailViewModel(photo: LibraryPhoto(id: "test", date: nil), gallery: gallery)
        for _ in 0..<1000 { detail.load(); detail.cancelLoading() }
        for callback in service.imageCallbacks { callback(UIImage(), nil) }
        XCTAssertNil(detail.image)
        XCTAssertEqual(service.cancelCount, 1000)
        detail.load()
        let image = UIImage(); service.imageCallbacks.last?(image, nil)
        XCTAssertTrue(detail.image === image)
    }

    @MainActor
    func testRapidDuplicateSaveDeleteAndRetryOnlySubmitOneOperation() {
        let service = StressLibraryService()
        let library = PhotoLibraryViewModel(service: service)
        for _ in 0..<100 {
            library.acceptPhoto(UIImage())
            let saves = service.saves
            for _ in 0..<20 { library.savePhoto(showSuccessMessage: false); library.deletePhoto() }
            XCTAssertEqual(service.saves, saves + 1)
            service.saveCallback?(.success("asset"))
            let deletes = service.deletes
            for _ in 0..<20 { library.deletePhoto(); library.savePhoto() }
            XCTAssertEqual(service.deletes, deletes + 1)
            service.deleteCallback?(.failure(PhotoLibraryError.inaccessible))
            XCTAssertFalse(library.isBusy)
            XCTAssertNotNil(library.lastPhoto)
            library.deletePhoto(); service.deleteCallback?(.success(()))
            XCTAssertNil(library.lastPhoto)
        }
    }
}

private final class StressLibraryService: PhotoLibraryService, PhotoBrowserService {
    var onLibraryChange: (() -> Void)?
    var imageCallbacks: [(UIImage?, Error?) -> Void] = []
    var cancelCount = 0, saves = 0, deletes = 0
    var saveCallback: ((Result<String, Error>) -> Void)?
    var deleteCallback: ((Result<Void, Error>) -> Void)?
    func authorize(completion: @escaping (PhotoLibraryAccess) -> Void) { completion(.full) }
    func fetchPhotos(offset: Int, limit: Int, completion: @escaping (PhotoPage) -> Void) { completion(PhotoPage(photos: [], hasMore: false)) }
    func requestImage(id: String, size: CGSize, completion: @escaping (UIImage?, Error?) -> Void) -> PhotoImageRequest {
        imageCallbacks.append(completion)
        return PhotoImageRequest { self.cancelCount += 1 }
    }
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { saves += 1; saveCallback = completion }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { deletes += 1; deleteCallback = completion }
}
