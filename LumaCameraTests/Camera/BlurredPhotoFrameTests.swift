import XCTest
import UIKit
import CoreImage
import ImageIO
import Vision
@testable import LumaCamera

final class BlurredPhotoFrameTests: XCTestCase {
    func testPortraitAndLandscapeUseSameTypographyWithSlimBorders() {
        let settings = PhotoWatermarkSettings(style:.blurredPhoto,showsLocation:true,showsParameters:true)
        let content = PhotoWatermarkContent(capturedAt:Date(),signature:"SHURRIKANN",
            location:"浙江省杭州市西湖区一处需要自动换行显示的拍摄地点",exposureSeconds:1/125,
            iso:100,whiteBalanceKelvin:5200,ev:0.3,filter:"原片")
        for size in [CGSize(width:1200,height:1600),CGSize(width:1600,height:1200),CGSize(width:1600,height:900)] {
            let layout = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
            let text = PhotoFrameInformationLayout(photoSize:size,settings:settings,content:content)
            XCTAssertEqual(text.scale,min(size.width,size.height))
            XCTAssertEqual(layout.photo.minX,(min(size.width,size.height)*0.03).rounded(.up))
            XCTAssertEqual(layout.photo.size,size)
            XCTAssertGreaterThanOrEqual(layout.information.height,text.left.height)
            XCTAssertTrue(text.left.rows.contains { $0.string == content.location })
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let photo = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                UIImage(named:"FilterLandscape")?.draw(in:CGRect(origin:.zero,size:size))
            }
            let output = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
            let attachment = XCTAttachment(image:output); attachment.name = "BlurredFrame-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let a = PhotoFrameInformationLayout(photoSize:CGSize(width:1200,height:1600),settings:settings,content:content)
        let b = PhotoFrameInformationLayout(photoSize:CGSize(width:1600,height:1200),settings:settings,content:content)
        XCTAssertEqual(a.scale,b.scale)
        XCTAssertEqual(a.left.rows[0].attribute(.font,at:0,effectiveRange:nil) as? UIFont,
                       b.left.rows[0].attribute(.font,at:0,effectiveRange:nil) as? UIFont)
    }

    func testLocationActuallyAppearsInEncodedPixelsWithoutGPSMetadata() throws {
        let source = CIImage(color:CIColor(red:0.15,green:0.4,blue:0.5)).cropped(to:CGRect(x:0,y:0,width:1800,height:2400))
        let settings = PhotoWatermarkSettings(style:.blurredPhoto,showsLocation:true)
        let place = PhotoLocation(latitude:30.2,longitude:120.1,addressText:"杭州西湖")
        let options = PhotoOptions(format:.jpeg,watermarkLocation:place)
        let look = CaptureLook(border:true,watermark:settings)
        let result = try PhotoEncoder.encode(source:source,raw:nil,look:look,options:options,context:CIContext())
        let data = try XCTUnwrap(result.resources.first?.data)
        let file = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file,0,nil) as? [CFString:Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file,0,nil))
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans","en-US"]
        try VNImageRequestHandler(cgImage:image).perform([request])
        let words = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? ""
        XCTAssertTrue(words.contains("杭州"),words)
        XCTAssertTrue(words.contains("西湖"),words)
        print("BLURRED-FRAME encodedLocationOCR=true GPS=false PhotosWrites=0")
    }
}
