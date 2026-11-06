import XCTest
import UIKit
@testable import LumaCamera

final class LivePhotoGestureTests: XCTestCase {
    @MainActor func testLongPressBlocksPagingAndReleaseRestoresSwipeWithoutBlockingPinch() {
        let view = PhotoZoomScrollView()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { _ in UIColor.gray.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400)) }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 650); view.display(image); view.layoutIfNeeded()
        var holding: [Bool] = [], pages: [Int] = []
        view.onLivePress = { holding.append($0) }; view.onSwipe = { pages.append($0) }
        XCTAssertTrue(view.canPlayLive)
        view.beginLivePress(); view.page(1)
        XCTAssertEqual(holding, [true]); XCTAssertTrue(pages.isEmpty)
        view.endLivePress(); view.page(1)
        XCTAssertEqual(holding, [true, false]); XCTAssertEqual(pages, [1])
        view.setZoomScale(2, animated: false)
        XCTAssertFalse(view.canPlayLive); view.beginLivePress()
        XCTAssertEqual(holding, [true, false])
        view.setZoomScale(1, animated: false); view.beginLivePress()
        view.display(UIImage(cgImage: image.cgImage!)); view.layoutIfNeeded()
        XCTAssertEqual(holding, [true, false, true, false])
        XCTAssertEqual(view.zoomScale, 1)
    }
}
