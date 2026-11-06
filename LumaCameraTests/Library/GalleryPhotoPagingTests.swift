import XCTest
import UIKit
@testable import LumaCamera

final class GalleryPhotoPagingTests: XCTestCase {
    private let photos = (0..<5).map { LibraryPhoto(id: "photo-\($0)", date: nil) }
    func testDeletionAlwaysUsesOlderPhotoAndNeverWrapsToNewer() {
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.asset(photos[2]), photos: photos, hasCapture: false, captureID: nil), .asset(photos[3]))
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.asset(photos[0]), photos: photos, hasCapture: false, captureID: nil), .asset(photos[1]))
        XCTAssertNil(GalleryPhotoPaging.afterDeleting(.asset(photos[0]), photos: [photos[0]], hasCapture: false, captureID: nil))
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.capture, photos: photos, hasCapture: true, captureID: photos[0].id), .asset(photos[1]))
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.asset(photos[0]), photos: photos, hasCapture: true, captureID: nil), .asset(photos[1]))
        XCTAssertNil(GalleryPhotoPaging.afterDeleting(.asset(photos[4]), photos: photos, hasCapture: false, captureID: nil))
    }
    func testSavedCaptureNotIndexedOrAlreadyClearedStillUsesFirstDisplayedNeighbor() {
        // The camera review is open, but the freshly saved asset was not in the last grid snapshot.
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.capture, photos: photos, hasCapture: false, captureID: "just-saved"), .asset(photos[0]))
        // Clearing the capture cache must not remove the page from its own navigation order.
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.capture, photos: photos, hasCapture: false, captureID: nil), .asset(photos[0]))
        // Once indexed, skip only the deleted capture itself, never its immediate older neighbor.
        XCTAssertEqual(GalleryPhotoPaging.afterDeleting(.capture, photos: photos, hasCapture: false, captureID: photos[0].id), .asset(photos[1]))
        XCTAssertNil(GalleryPhotoPaging.afterDeleting(.capture, photos: [], hasCapture: false, captureID: "just-saved"))
    }
    func testPagesFollowGridOrderWithoutWrappingAtEitherEnd() {
        XCTAssertEqual(GalleryPhotoPaging.neighbor(of: .asset(photos[1]), step: 1, photos: photos, hasCapture: false, captureID: nil), .asset(photos[2]))
        XCTAssertEqual(GalleryPhotoPaging.neighbor(of: .asset(photos[1]), step: -1, photos: photos, hasCapture: false, captureID: nil), .asset(photos[0]))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .asset(photos[0]), step: -1, photos: photos, hasCapture: false, captureID: nil))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .asset(photos[4]), step: 1, photos: photos, hasCapture: false, captureID: nil))
    }
    func testFreshCaptureCanPageToLibraryAndBackWithoutDuplicateAfterIndexing() {
        XCTAssertEqual(GalleryPhotoPaging.neighbor(of: .capture, step: 1, photos: photos, hasCapture: true, captureID: nil), .asset(photos[0]))
        XCTAssertEqual(GalleryPhotoPaging.neighbor(of: .asset(photos[0]), step: -1, photos: photos, hasCapture: true, captureID: nil), .capture)
        XCTAssertEqual(GalleryPhotoPaging.neighbor(of: .capture, step: 1, photos: photos, hasCapture: true, captureID: photos[0].id), .asset(photos[1]))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .capture, step: -1, photos: photos, hasCapture: true, captureID: photos[0].id))
    }
    func testRefreshDeletionLimitedListAndInvalidStepsCannotSelectUnrelatedPhoto() {
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .asset(photos[3]), step: 1, photos: [photos[0]], hasCapture: false, captureID: nil))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .asset(photos[0]), step: 1, photos: [photos[0]], hasCapture: false, captureID: nil))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .capture, step: 1, photos: [], hasCapture: true, captureID: nil))
        XCTAssertNil(GalleryPhotoPaging.neighbor(of: .asset(photos[0]), step: 20, photos: photos, hasCapture: false, captureID: nil))
    }
    func testVideoCanvasPagingUsesHorizontalSwipesOnly() {
        XCTAssertEqual(GalleryPhotoPaging.swipeStep(horizontal: -80, vertical: 12), 1)
        XCTAssertEqual(GalleryPhotoPaging.swipeStep(horizontal: 80, vertical: -10), -1)
        XCTAssertNil(GalleryPhotoPaging.swipeStep(horizontal: 20, vertical: 0))
        XCTAssertNil(GalleryPhotoPaging.swipeStep(horizontal: 90, vertical: 100))
    }

    func testStillAndVideoPagesUseMatchingLeftAndRightTransitionGeometry() {
        for direction in [-1, 1] {
            XCTAssertEqual(GalleryPageTransition.horizontalOffset(direction: direction, extent: 300, progress: 0, incoming: true, reduceMotion: false), CGFloat(direction * 300))
            XCTAssertEqual(GalleryPageTransition.horizontalOffset(direction: direction, extent: 300, progress: 1, incoming: true, reduceMotion: false), 0)
            XCTAssertEqual(GalleryPageTransition.horizontalOffset(direction: direction, extent: 300, progress: 0, incoming: false, reduceMotion: false), 0)
            XCTAssertEqual(GalleryPageTransition.horizontalOffset(direction: direction, extent: 300, progress: 1, incoming: false, reduceMotion: false), CGFloat(-direction * 300))
        }
        XCTAssertEqual(GalleryPageTransition.horizontalOffset(direction: 1, extent: 300, progress: 0.5, incoming: true, reduceMotion: true), 0)
        XCTAssertEqual(GalleryPageTransition.opacity(progress: 0.5, incoming: true, reduceMotion: true), 0.5)
        XCTAssertEqual(GalleryPageTransition.opacity(progress: 0.5, incoming: false, reduceMotion: true), 0.5)
    }

    func testVideoPageDoesNotWaitForPhotoPosterLoading() {
        let still = GalleryRoute.asset(LibraryPhoto(id: "still", date: nil))
        let video = GalleryRoute.asset(LibraryPhoto(id: "video", date: nil, isVideo: true))
        XCTAssertTrue(GalleryPhotoPaging.requiresImagePreload(still))
        XCTAssertFalse(GalleryPhotoPaging.requiresImagePreload(video))
        XCTAssertTrue(GalleryPhotoPaging.requiresImagePreload(.capture))
        XCTAssertFalse(GalleryPhotoPaging.requiresImagePreload(still, afterDeletion: true))
        XCTAssertFalse(GalleryPhotoPaging.requiresImagePreload(video, afterDeletion: true))
        XCTAssertFalse(GalleryPhotoPaging.requiresImagePreload(.capture, afterDeletion: true))
    }
    @MainActor func testPagingDoesNotStealPinchOrEnlargedPhotoPanAndReplacementResetsZoom() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { _ in UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 200)) }
        let view = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.display(image); view.layoutIfNeeded()
        var steps: [Int] = []
        view.onSwipe = { steps.append($0) }
        let swipes = view.gestureRecognizers!.compactMap { $0 as? UISwipeGestureRecognizer }
        XCTAssertEqual(swipes.count, 4)
        XCTAssertEqual(swipes.filter { $0.delegate?.gestureRecognizerShouldBegin?($0) == true }.count, 2,
                       "Only screen-horizontal directions participate; rotated canvases need four local recognizers")
        XCTAssertTrue(swipes.allSatisfy { $0.numberOfTouchesRequired == 1 })
        view.page(1); view.page(-1)
        XCTAssertEqual(steps, [1, -1])
        view.setZoomScale(3, animated: false)
        XCTAssertFalse(view.canPage)
        XCTAssertTrue(swipes.allSatisfy { $0.delegate?.gestureRecognizerShouldBegin?($0) == false })
        view.page(1)
        XCTAssertEqual(steps, [1, -1])
        view.display(UIImage(cgImage: image.cgImage!)); view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertTrue(view.canPage)
        view.onSwipe = nil
        view.page(1)
        XCTAssertEqual(steps, [1, -1])
    }
}
