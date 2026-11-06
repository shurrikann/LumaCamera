import XCTest
import CoreImage
import ImageIO
@testable import LumaCamera

final class CameraZoomTests: XCTestCase {
    func testNativeTwoTimesCropAndFourTimesTelephotoAreSelected() throws {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 10, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 4, minimum: 1, maximum: 10, nativeFactors: [2])
        let two = try XCTUnwrap(CameraZoomPolicy.select(2, from: [wide, tele]))
        XCTAssertEqual(two.id, "wide")
        XCTAssertEqual(two.factor, 2)
        XCTAssertTrue(two.native)
        let four = try XCTUnwrap(CameraZoomPolicy.select(4, from: [wide, tele]))
        XCTAssertEqual(four.id, "tele")
        XCTAssertEqual(four.factor, 1)
        XCTAssertTrue(four.native)
    }

    func testFourTimesUsesThreeTimesTelephotoWhenNativeFourIsUnavailable() throws {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 10, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 3, minimum: 1, maximum: 10, nativeFactors: [])
        let four = try XCTUnwrap(CameraZoomPolicy.select(4, from: [wide, tele]))
        XCTAssertEqual(four.id, "tele")
        XCTAssertEqual(four.factor, 4.0 / 3, accuracy: 0.0001)
        XCTAssertFalse(four.native)
    }

    func testFiveTimesCameraCannotBeUsedToZoomOutToFour() throws {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 10, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 5, minimum: 1, maximum: 10, nativeFactors: [])
        let four = try XCTUnwrap(CameraZoomPolicy.select(4, from: [wide, tele]))
        XCTAssertEqual(four.id, "wide")
        XCTAssertEqual(four.factor, 4)
        XCTAssertFalse(four.native)
    }

    func testUnsupportedMagnificationIsNotOffered() {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 2, nativeFactors: [2])
        XCTAssertNil(CameraZoomPolicy.select(4, from: [wide]))
        XCTAssertNil(CameraZoomPolicy.select(0.5, from: [wide]))
    }

    func testEightTimesUsesNativeTelephotoCropAndRejectsDigitalFallback() throws {
        let wide = LensZoomCapabilities(id: "wide", baseZoom: 1, minimum: 1, maximum: 20, nativeFactors: [2])
        let tele = LensZoomCapabilities(id: "tele", baseZoom: 4, minimum: 1, maximum: 10, nativeFactors: [2])
        let eight = try XCTUnwrap(CameraZoomPolicy.select(8, from: [wide, tele], nativeOnly: true))
        XCTAssertEqual(eight.id, "tele")
        XCTAssertEqual(eight.factor, 2)
        XCTAssertTrue(eight.native)
        XCTAssertNil(CameraZoomPolicy.select(8, from: [wide], nativeOnly: true))
        let five = LensZoomCapabilities(id: "five", baseZoom: 5, minimum: 1, maximum: 10, nativeFactors: [2])
        XCTAssertNil(CameraZoomPolicy.select(8, from: [wide, five], nativeOnly: true))
    }

    func testPreviewQuarterTurnsSwapDimensionsAndMapFocusToOriginal() {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 12, height: 16))
        for turn in 0..<4 {
            let image = PreviewRotation.image(source, quarterTurns: turn)
            XCTAssertEqual(image.extent.width, turn % 2 == 0 ? 12 : 16)
            XCTAssertEqual(image.extent.height, turn % 2 == 0 ? 16 : 12)
        }
        XCTAssertEqual(PreviewRotation.image(source, quarterTurns: 4).extent, source.extent)
        let point = CGPoint(x: 0.2, y: 0.7)
        let expected = [point, CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.3, y: 0.2)]
        for turn in 0..<4 {
            let actual = PreviewRotation.sourcePoint(point, quarterTurns: turn)
            XCTAssertEqual(actual.x, expected[turn].x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, expected[turn].y, accuracy: 0.00001)
        }
    }

    @MainActor
    func testPreviewRotationCyclesWithoutSwitchingLensOrChangingFilter() {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.style = .amber
        let selected = model.camera.selectedLens
        for turn in 1...4 {
            model.rotatePreview()
            XCTAssertEqual(model.previewQuarterTurns, turn % 4)
            XCTAssertEqual(model.camera.selectedLens, selected)
            XCTAssertEqual(model.style, .amber)
        }
    }

    func testUnrotatedLandscapeBufferBecomesPortraitWithoutLosingPixels() {
        let landscape = CIImage(color: .white).cropped(to: CGRect(x: 20, y: 30, width: 12, height: 8))
        let result = CaptureOrientation.portraitFrame(landscape)
        XCTAssertEqual(result.extent.width, 8)
        XCTAssertEqual(result.extent.height, 12)
        XCTAssertEqual(result.extent.width * result.extent.height, landscape.extent.width * landscape.extent.height)
    }

    func testPortraitFrameIsNotRotatedAgain() {
        let portrait = CIImage(color: .white).cropped(to: CGRect(x: 20, y: 30, width: 8, height: 12))
        XCTAssertEqual(CaptureOrientation.portraitFrame(portrait).extent, portrait.extent)
    }
    func testSelfieMirroringHappensAfterPortraitOrientation() throws {
        let extent = CGRect(x: 0, y: 0, width: 4, height: 8)
        let black = CIImage(color: .black).cropped(to: extent)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 8))
        let input = white.composited(over: black)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func leftPixel(_ image: CIImage) -> UInt8 {
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 0, y: 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            return rgba[0]
        }
        XCTAssertEqual(leftPixel(CaptureOrientation.portraitFrame(input)), 255)
        XCTAssertEqual(leftPixel(CaptureOrientation.portraitFrame(input, mirrored: true)), 0)
        XCTAssertEqual(CaptureOrientation.portraitFrame(input, mirrored: true).extent, extent)
    }

    func testAlreadyUprightFrontPixelsRemainUprightForEveryOutputRatio() throws {
        let extent=CGRect(x:0,y:0,width:128,height:192)
        let bottom=CIImage(color:.blue).cropped(to:extent)
        let top=CIImage(color:.red).cropped(to:CGRect(x:0,y:96,width:128,height:96))
        let image=top.composited(over:bottom).settingProperties([
            kCGImagePropertyOrientation as String:6,
            kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFOrientation as String:6],
            kCGImagePropertyExifDictionary as String:[kCGImagePropertyExifFocalLenIn35mmFilm as String:31]
        ])
        let upright=CaptureOrientation.normalizedPhotoMetadata(image), context=CIContext()
        func pixel(_ source:CIImage,_ y:CGFloat) -> [UInt8] {
            var bytes=[UInt8](repeating:0,count:4)
            context.render(source,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:source.extent.midX,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return bytes
        }
        // Open Gate is a video-only uncropped output, so it is not a photo crop ratio.
        for ratio in FrameRatio.photoOptions {
            var look=CaptureLook();look.ratio=ratio
            let photo=try PhotoEncoder.encode(source:upright,raw:nil,look:look,options:PhotoOptions(),context:context)
            let data=try XCTUnwrap(photo.resources.first?.data)
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let metadata=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            XCTAssertEqual((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,1)
            let decoded=try XCTUnwrap(CIImage(data:data,options:[.applyOrientationProperty:true]))
            XCTAssertEqual(decoded.extent.width/decoded.extent.height,ratio.portraitRatio,accuracy:0.01)
            let red=pixel(decoded,decoded.extent.maxY-3),blue=pixel(decoded,decoded.extent.minY+3)
            XCTAssertGreaterThan(red[0],200);XCTAssertLessThan(red[2],30)
            XCTAssertGreaterThan(blue[2],200);XCTAssertLessThan(blue[0],30)
            let exif=try XCTUnwrap(metadata[kCGImagePropertyExifDictionary] as? [CFString:Any])
            XCTAssertEqual((exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue,31)
        }
    }

}
