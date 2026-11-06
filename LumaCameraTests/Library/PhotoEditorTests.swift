import XCTest
import CoreImage
import ImageIO
import UIKit
@testable import LumaCamera

final class PhotoEditorTests: XCTestCase {
    private var source: CIImage { CIImage(color: CIColor(red: 0.3, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 20, y: 40, width: 120, height: 160)) }
    func testRotatedEditBakesOrientationIntoFullResolutionJPEG() throws {
        var adjustments = PhotoAdjustments(); adjustments.quarterTurns = 1
        let image = adjustments.apply(to: source)
        XCTAssertEqual(image.extent.origin, .zero)
        let result = try PhotoEditRenderer.render(source: source, adjustments: adjustments)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(result.resource.data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(cg.width, 160); XCTAssertEqual(cg.height, 120)
        XCTAssertEqual(result.preview.imageOrientation, .up)
    }
    func testExposureChangesImageAndAdjustmentDataCanRoundTrip() throws {
        var adjustments = PhotoAdjustments(); adjustments.exposure = 1; adjustments.saturation = 0.5
        let restored = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        XCTAssertEqual(restored, adjustments)
        let context = CIContext()
        let before = Imaging.meanLuminance(source, context: context)
        let after = Imaging.meanLuminance(adjustments.apply(to: source), context: context)
        XCTAssertGreaterThan(after, before)
    }
    @MainActor
    func testEditorCompletionReleasesGuardEvenAfterEditorIsDismissed() async {
        let library = PhotoLibraryViewModel(service: EditorLibraryStub())
        var callback: ((Result<PhotoEditResult, Error>) -> Void)?
        let session = PhotoEditSession(source: source) { _, completion in callback = completion }
        var editor: PhotoEditorViewModel? = PhotoEditorViewModel(session: session, library: library)
        editor?.save { _ in }
        XCTAssertTrue(library.editing)
        editor = nil
        callback?(.failure(PhotoDetailError.editingUnsupported))
        XCTAssertFalse(library.isBusy)
    }

    @MainActor
    func testEditorFailureReleasesBusyGuardAndAllowsRetry() async {
        let library = PhotoLibraryViewModel(service: EditorLibraryStub())
        let image = UIImage(); library.acceptPhoto(image)
        var callback: ((Result<PhotoEditResult, Error>) -> Void)?
        let session = PhotoEditSession(source: source) { _, completion in callback = completion }
        let editor = PhotoEditorViewModel(session: session, library: library)
        var successCount = 0
        editor.save { _ in successCount += 1 }
        XCTAssertTrue(editor.saving); XCTAssertTrue(library.editing)
        library.acceptPhoto(UIImage())
        XCTAssertTrue(library.lastPhoto === image)
        callback?(.failure(PhotoDetailError.editingUnsupported))
        XCTAssertFalse(editor.saving); XCTAssertFalse(library.isBusy)
        XCTAssertNotNil(editor.message)
        XCTAssertEqual(successCount, 0)
        editor.save { _ in successCount += 1 }
        let result = PhotoEditResult(preview: UIImage(), resource: PhotoResource(data: Data([1]), filename: "edit.jpg"))
        callback?(.success(result))
        XCTAssertFalse(library.isBusy); XCTAssertEqual(successCount, 1)
    }
}
private final class EditorLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("asset")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
