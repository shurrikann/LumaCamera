import XCTest
@testable import LumaCamera

final class CameraPreviewLayoutTests: XCTestCase {
    func testAllRatiosFitAboveShutterWithoutChangingAspectAndLongRatiosIncludeToolbar() {
        for size in [CGSize(width: 386, height: 778), CGSize(width: 304, height: 640), CGSize(width: 414, height: 830)] {
            for ratio in FrameRatio.allCases {
                let rect = CameraPreviewLayout.frame(in: size, ratio: ratio)
                XCTAssertEqual(rect.width / rect.height, ratio.portraitRatio, accuracy: 0.0001)
                XCTAssertLessThanOrEqual(rect.maxY, size.height - CameraControlLayout.shutterBottom - 78 - 12 + 0.01)
                XCTAssertEqual(rect.midX, size.width / 2, accuracy: 0.01)
                let includesToolbarBackdrop = ratio == .standard || ratio == .square
                    || (ratio == .openGate && ratio.portraitRatio > 9.0 / 16.0)
                XCTAssertEqual(rect.minY, includesToolbarBackdrop ? 62 : 0, accuracy: 0.01)
            }
        }
    }

    func testHDRBadgeTopStaysAtFourThreePositionForAllPhotoRatios() {
        for size in [CGSize(width: 386, height: 778), CGSize(width: 304, height: 640), CGSize(width: 414, height: 830)] {
            let fourThree = CameraPreviewLayout.frame(in: size, ratio: .standard)
            let fixedTop = CameraPreviewLayout.hdrBadgeTop(in: size)
            XCTAssertEqual(fixedTop, fourThree.minY + CameraPreviewLayout.hdrBadgeTopInset, accuracy: 0.01)
            XCTAssertGreaterThan(fixedTop, CameraControlLayout.toolbarHeight + CameraControlLayout.toolbarTopInset)

            for ratio in FrameRatio.photoOptions {
                let preview = CameraPreviewLayout.frame(in: size, ratio: ratio)
                XCTAssertEqual(CameraPreviewLayout.hdrBadgeTop(in: size), fixedTop, accuracy: 0.01,
                               "HDR top must not move with \(ratio.rawValue)")
                XCTAssertGreaterThan(preview.maxX - 10, 0, "HDR horizontal anchor must stay inside the preview for \(ratio.rawValue)")
                if ratio == .classic || ratio == .wide {
                    XCTAssertEqual(preview.minY, 0, accuracy: 0.01)
                    XCTAssertGreaterThan(fixedTop, preview.minY + CameraPreviewLayout.hdrBadgeTopInset,
                                         "HDR must move below the toolbar instead of following the long preview top")
                }
            }
        }
    }

    func testLandscapeHDRBadgeTopStillUsesFourThreeAnchor() {
        for size in [CGSize(width: 386, height: 778), CGSize(width: 304, height: 640), CGSize(width: 414, height: 830)] {
            let fourThree = CameraPreviewLayout.frame(in: size, ratio: .standard, landscape: true)
            let fixedTop = CameraPreviewLayout.hdrBadgeTop(in: size, landscape: true)
            XCTAssertEqual(fixedTop, fourThree.minY + CameraPreviewLayout.hdrBadgeTopInset, accuracy: 0.01)
            for ratio in FrameRatio.photoOptions {
                XCTAssertEqual(CameraPreviewLayout.hdrBadgeTop(in: size, landscape: true), fixedTop, accuracy: 0.01)
            }
        }
    }

    func testLandscapeSelfieRatiosStayInsidePreviewAndCenterVertically() {
        for size in [CGSize(width: 386, height: 778), CGSize(width: 304, height: 640), CGSize(width: 414, height: 830)] {
            for ratio in FrameRatio.photoOptions {
                let rect = CameraPreviewLayout.frame(in: size, ratio: ratio, landscape: true)
                XCTAssertEqual(rect.width / rect.height, ratio.landscapeRatio, accuracy: 0.0001)
                XCTAssertLessThanOrEqual(rect.maxY, size.height - CameraControlLayout.shutterBottom - 78 - 12 + 0.01)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertEqual(rect.midX, size.width / 2, accuracy: 0.01)
                let top: CGFloat = ratio == .standard || ratio == .square ? 62 : 0
                let bottom = size.height - CameraControlLayout.shutterBottom - 78 - 12
                XCTAssertEqual(rect.midY, (top + bottom) / 2, accuracy: 0.01)
            }
        }
    }
}
