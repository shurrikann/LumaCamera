import XCTest
import UIKit
@testable import LumaCamera

final class GlassWatermarkLayoutTests: XCTestCase {
    func testRotatingPhotoKeepsCardHeightInsetsAndTypography() {
        let content = PhotoWatermarkContent(capturedAt:Date(),signature:"SHURRIKANN",location:"杭州市 · 西湖区",
            exposureSeconds:1/125,iso:100,whiteBalanceKelvin:5200,ev:0.3,filter:"原片")
        for flags in 0..<4 {
            let settings = PhotoWatermarkSettings(style:.glassStrip,showsLocation:flags & 1 != 0,showsParameters:flags & 2 != 0)
            var layouts = [PhotoWatermarkLayout](), types = [PhotoFrameInformationLayout]()
            for size in [CGSize(width:1200,height:1600),CGSize(width:1600,height:1200),CGSize(width:1600,height:900)] {
                let layout = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
                let type = PhotoFrameInformationLayout(photoSize:size,settings:settings,content:content,
                    informationWidth:layout.information.width,compact:true)
                XCTAssertEqual(layout.size,size)
                XCTAssertEqual(layout.photo,CGRect(origin:.zero,size:size))
                XCTAssertTrue(CGRect(origin:.zero,size:size).contains(layout.decoration!))
                XCTAssertEqual(layout.decoration!.minX,min(size.width,size.height)*0.018,accuracy:0.001)
                XCTAssertGreaterThanOrEqual(layout.decoration!.height,max(type.left.height,type.right.height))
                layouts.append(layout); types.append(type)
                if flags == 0 || flags == 3 {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let photo = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                        UIImage(named:"FilterLandscape")?.draw(in:CGRect(origin:.zero,size:size))
                    }
                    let output = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
                    let shot = XCTAttachment(image:output)
                    shot.name = "Glass-No-Rim-\(Int(size.width))x\(Int(size.height))-flags\(flags)"
                    shot.lifetime = .keepAlways; add(shot)
                }
            }
            XCTAssertEqual(layouts[0].decoration!.height,layouts[1].decoration!.height,accuracy:1)
            XCTAssertEqual(types[0].left.rows[0].attribute(.font,at:0,effectiveRange:nil) as? UIFont,
                           types[1].left.rows[0].attribute(.font,at:0,effectiveRange:nil) as? UIFont)
        }
    }
    func testGlassKeepsBackgroundVisible() throws {
        let size = CGSize(width:600,height:800)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size:size,format:format).image { c in
            UIColor(white:0.8,alpha:1).setFill(); c.fill(CGRect(origin:.zero,size:size))
        }
        let settings = PhotoWatermarkSettings(style:.glassStrip)
        let content = PhotoWatermarkContent(capturedAt:Date())
        let layout = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
        let output = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
        let cg = try XCTUnwrap(output.cgImage)
        func brightness(at point:CGPoint) throws -> Double {
            let pixel = try XCTUnwrap(cg.cropping(to:CGRect(x:floor(point.x),y:floor(point.y),width:1,height:1)))
            var bytes = [UInt8](repeating:0,count:4)
            try bytes.withUnsafeMutableBytes { data in
                let context = try XCTUnwrap(CGContext(data:data.baseAddress,width:1,height:1,bitsPerComponent:8,
                    bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1))
            }
            return Double(Int(bytes[0])+Int(bytes[1])+Int(bytes[2]))/(255*3)
        }
        let x = size.width/2+min(size.width,size.height)*0.055
        let card = try XCTUnwrap(layout.decoration)
        let center = try brightness(at:CGPoint(x:x,y:card.midY))
        let rim = try brightness(at:CGPoint(x:x,y:card.minY+0.5))
        XCTAssertGreaterThan(center,0.62,"The card must preserve the light photo beneath it")
        if #unavailable(iOS 26.0) {
            XCTAssertLessThan(rim,0.85,"The compatibility renderer must not paint an outline")
        } // Native clear glass has its own optical edge highlight.
        print("GLASS-PIXELS sourceBrightness=0.8 center=\(center) topEdge=\(rim); fixed gray export sample, not perceived contrast or HDR")
    }

}
