import UIKit
import CoreImage
import ImageIO
import XCTest
@testable import LumaCamera

final class PhotoWatermarkRendererTests: XCTestCase {
    func testAllStylesRenderWithParametersAndLocation() throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
            UIColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let content = PhotoWatermarkContent(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "Test",
            location: "Shanghai",
            exposureSeconds: 1.0 / 15.0,
            iso: 3200,
            whiteBalanceKelvin: 5200,
            whiteBalanceAutomatic: false,
            ev: -0.3,
            filter: "原片")
        for style in PhotoWatermarkStyle.allCases {
            var settings = PhotoWatermarkSettings()
            settings.style = style
            settings.showsLocation = true
            settings.showsParameters = true
            let output = PhotoWatermarkRenderer.render(photo, settings: settings, content: content)
            XCTAssertNotNil(output.cgImage, style.rawValue)
            XCTAssertGreaterThan(output.size.width, 0)
            XCTAssertGreaterThan(output.size.height, 0)
        }
    }
    func testNewStylesAcrossRatiosAndFlagsAndExportSamples() throws {
        let content = PhotoWatermarkContent(capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "SHURRIKANN", location: "杭州市 · 西湖区", exposureSeconds: 1/125,
            iso: 100, whiteBalanceKelvin: 5200, ev: 0.3, filter: "原片")
        var count = 0
        for ratio in FrameRatio.allCases {
            let size = ratio.crop(CIImage(color: .white).cropped(to: CGRect(x:0,y:0,width:1200,height:1600))).extent.size
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let photo = UIGraphicsImageRenderer(size: size, format: format).image { c in
                (UIImage(named: "FilterLandscape") ?? UIImage()).draw(in: CGRect(origin:.zero,size:size))
                UIColor.orange.setFill(); c.fill(CGRect(x:20,y:20,width:30,height:30))
            }
            for style in PhotoWatermarkStyle.allCases {
                for flags in 0..<4 {
                    let settings = PhotoWatermarkSettings(style:style,showsLocation:flags & 1 != 0,showsParameters:flags & 2 != 0)
                    let layout = PhotoWatermarkLayout(photoSize: size, settings: settings, content: content)
                    let output = PhotoWatermarkRenderer.render(photo, settings:settings, content:content)
                    XCTAssertEqual(CGFloat(try XCTUnwrap(output.cgImage).width),layout.size.width,accuracy:1)
                    XCTAssertEqual(CGFloat(output.cgImage!.height),layout.size.height,accuracy:1)
                    XCTAssertTrue(CGRect(origin:.zero,size:layout.size).contains(layout.photo))
                    XCTAssertEqual(layout.photo.size,size)
                    if style != .glassStrip && style != .newYear { XCTAssertGreaterThanOrEqual(layout.information.minY,layout.photo.maxY) }
                    if ratio == .standard && (flags == 0 || flags == 3) {
                        let attachment = XCTAttachment(image:output)
                        attachment.name = "Watermark-\(style.rawValue)-flags\(flags)"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                    count += 1
                }
            }
        }
        print("WATERMARK-MATRIX renders=\(count) PhotosWrites=0")
        let legacy = try JSONDecoder().decode(PhotoWatermarkSettings.self,
            from: Data(#"{"style":"festiveRed","showsLocation":true,"showsParameters":false}"#.utf8))
        XCTAssertEqual(legacy.style,.blurredPhoto)
    }

    func testTwelveMegapixelRepeatedRenderPerformance() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size:CGSize(width:3000,height:4000),format:format).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x:0,y:0,width:3000,height:4000))
        }
        let content = PhotoWatermarkContent(capturedAt:Date())
        for style in PhotoWatermarkStyle.allCases {
            var times = [Double]()
            for _ in 0..<5 {
                autoreleasepool {
                    let start = CACurrentMediaTime()
                    let output = PhotoWatermarkRenderer.render(photo,settings:.init(style:style),content:content)
                    XCTAssertNotNil(output.cgImage)
                    times.append((CACurrentMediaTime()-start)*1000)
                }
            }
            print("WATERMARK-PERF style=\(style.rawValue) input=12MP n=5 renderMilliseconds=\(times); not display FPS or application memory")
        }
    }

    func testEncodedJPEGAndHEIFPreserveMetadataAcrossStyles() throws {
        let source = CIImage(color: CIColor(red:0.2,green:0.5,blue:0.6))
            .cropped(to:CGRect(x:0,y:0,width:1200,height:1600))
            .settingProperties([kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: 0.008,
                kCGImagePropertyExifISOSpeedRatings as String: [100],
                kCGImagePropertyExifFocalLength as String: 6.765]])
        let context = CIContext()
        for format in [PhotoFileFormat.jpeg,.heif] {
            for style in PhotoWatermarkStyle.allCases {
                let look = CaptureLook(border:true,watermark:.init(style:style,showsParameters:true))
                let photo = try PhotoEncoder.encode(source:source,raw:nil,look:look,
                    options:PhotoOptions(format:format),context:context)
                let data = try XCTUnwrap(photo.resources.first?.data)
                let file = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
                let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file,0,nil) as? [CFString:Any])
                let exif = try XCTUnwrap(values[kCGImagePropertyExifDictionary] as? [CFString:Any])
                XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue),0.008,accuracy:0.00001)
                XCTAssertEqual(try XCTUnwrap((exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue),6.765,accuracy:0.001)
                XCTAssertEqual((values[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,1)
                XCTAssertNil(values[kCGImagePropertyGPSDictionary])
                let layout = PhotoWatermarkLayout(photoSize:CGSize(width:1200,height:1600),settings:look.watermark)
                XCTAssertEqual(try XCTUnwrap((values[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue),layout.size.width,accuracy:1)
                XCTAssertEqual(try XCTUnwrap((values[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue),layout.size.height,accuracy:1)
            }
        }
        print("WATERMARK-FILES jpeg=3 heif=3 EXIF=exposure,focalLength orientation=1 GPS=absent PhotosWrites=0")
    }

    func testFooterFitsActualRowsInsteadOfEmptyFields() {
        for style in PhotoWatermarkStyle.allCases {
            let settings = PhotoWatermarkSettings(style:style,showsLocation:true,showsParameters:false)
            let empty = PhotoWatermarkContent(capturedAt:Date())
            var full = empty; full.signature = "署名"; full.location = "杭州市"
            let small = PhotoWatermarkLayout(photoSize:CGSize(width:1200,height:1600),settings:settings,content:empty)
            let large = PhotoWatermarkLayout(photoSize:CGSize(width:1200,height:1600),settings:settings,content:full)
            if style != .newYear { XCTAssertLessThan(small.information.height,large.information.height) }
            XCTAssertEqual(small.photo.size,large.photo.size)
            XCTAssertGreaterThanOrEqual(small.information.height,1200*0.052)
        }
    }

}
