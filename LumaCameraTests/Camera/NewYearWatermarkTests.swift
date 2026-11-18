import XCTest
import UIKit
@testable import LumaCamera

final class NewYearWatermarkTests: XCTestCase {
    func testZodiacChangesAtLunarNewYearAndAllTwelveAssetsExist() throws {
        let zone = try XCTUnwrap(TimeZone(identifier:"Asia/Shanghai"))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func index(_ text:String) throws -> Int {
            CaptureZodiac.index(at:try XCTUnwrap(formatter.date(from:text)),timeZone:zone)
        }
        XCTAssertNotNil(UIImage(named:"NewYearCloudCorner"))
        XCTAssertEqual(try index("2026-02-16 23:59:59"),5)
        XCTAssertEqual(try index("2026-02-17 00:00:00"),6)
        XCTAssertEqual(try index("2026-11-17 12:00:00"),6)
        XCTAssertEqual(CaptureZodiac.title(at:try XCTUnwrap(formatter.date(from:"2026-07-01 12:00:00"))),"农历 丙午马年")
        for year in 2020...2031 {
            XCTAssertEqual(try index("\(year)-07-01 12:00:00"),(year-2020)%12)
            XCTAssertNotNil(NewYearWatermarkRenderer.animal(at:(year-2020)%12))
        }
    }
    func testLandscapeNewYearSamplesWithFullAndSparseInformation() {
        let photo = UIImage(named:"FilterLandscape")!
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width:1600,height:900),CGSize(width:1600,height:591),CGSize(width:1200,height:1600)] {
            let image = UIGraphicsImageRenderer(size:size,format:format).image { _ in photo.draw(in:CGRect(origin:.zero,size:size)) }
            for full in [false,true] {
                let content = PhotoWatermarkContent(capturedAt:Date(timeIntervalSince1970:1794916800),signature:"SHURRIKANN",
                    location:"杭州市 · 西湖区",exposureSeconds:1/125,iso:100,whiteBalanceKelvin:5200,ev:0.3,filter:"原片")
                let settings = PhotoWatermarkSettings(style:.newYear,showsLocation:full,showsParameters:full)
                let layout = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
                XCTAssertEqual(layout.photo.size,size)
                XCTAssertEqual(layout.decoration?.minX,layout.photo.maxX)
                XCTAssertEqual(layout.photo.width/layout.size.width,0.75,accuracy:1/layout.size.width)
                XCTAssertLessThan(layout.information.minY-layout.photo.minY,size.height*0.02)
                XCTAssertLessThan(layout.decoration!.maxX-layout.information.maxX,layout.decoration!.width*0.04)
                XCTAssertGreaterThan(layout.photo.minX,0)
                XCTAssertGreaterThan(layout.photo.minY,0)
                XCTAssertGreaterThan(layout.size.height-layout.photo.maxY,0)
                let output = PhotoWatermarkRenderer.render(image,settings:settings,content:content)
                XCTAssertEqual(output.size,layout.size)
                let attachment = XCTAttachment(image:output)
                attachment.name = "NewYear-\(Int(size.width))x\(Int(size.height))-full\(full)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    func testFixedWidthShareAndWrappedTextKeepAnimalAtExactCenter() {
        for size in [CGSize(width:1200,height:1600),CGSize(width:1600,height:1200),CGSize(width:1600,height:900),CGSize(width:1600,height:591)] {
            let content = PhotoWatermarkContent(capturedAt:Date(),
                signature:"一个需要自动换行而且完整保留的摄影者署名 SHURRIKANN",
                location:"浙江省杭州市西湖区一处名称较长且需要多行显示的拍摄地点",
                exposureSeconds:1/125,iso:100,whiteBalanceKelvin:5200,ev:0.3,
                filter:"一款需要完整显示名称的摄影滤镜")
            let settings = PhotoWatermarkSettings(style:.newYear,showsLocation:true,showsParameters:true)
            let frame = PhotoWatermarkLayout(photoSize:size,settings:settings,content:content)
            XCTAssertEqual(frame.photo.width/frame.size.width,0.75,accuracy:1/frame.size.width)
            let panel = frame.decoration!
            let center = CGPoint(x:(frame.photo.maxX+frame.size.width)/2,y:frame.size.height/2)
            let layout = NewYearWatermarkRenderer.informationLayout(in:panel,settings:settings,content:content,illustrationCenter:center)
            XCTAssertEqual(layout.animal.midX,center.x,accuracy:0.001)
            XCTAssertEqual(layout.animal.midY,center.y,accuracy:0.001)
            XCTAssertEqual(layout.animal.width,layout.animal.height)
            XCTAssertGreaterThan(layout.animal.width,0)
            XCTAssertLessThan(layout.upper.maxY,layout.animal.minY)
            XCTAssertLessThan(layout.caption.maxY,layout.lower.minY)
            XCTAssertTrue(panel.contains(layout.upper)); XCTAssertTrue(panel.contains(layout.lower))
            XCTAssertTrue(layout.upperText.contains(content.signature))
            XCTAssertTrue(layout.lowerText.contains(content.filter))
            XCTAssertGreaterThan(layout.upper.height,layout.fontSize*5)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let photo = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                UIImage(named:"FilterLandscape")?.draw(in:CGRect(origin:.zero,size:size))
            }
            let output = PhotoWatermarkRenderer.render(photo,settings:settings,content:content)
            let attachment = XCTAttachment(image:output)
            attachment.name = "NewYear-Wrapped-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

}

@MainActor final class AstroWatermarkSelectionPhysicalTests: XCTestCase {
    func testEachStyleTogglesOffAndSwitchesDirectlyAcrossSubmodes() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let previous = model.preferences.watermark
        defer { model.preferences.watermark = previous; model.selectTopLevelMode(.photo); model.setCameraActive(true) }
        model.settings = false; model.review = false
        model.selectTopLevelMode(.photo); model.setCameraActive(true)
        for _ in 0..<400 { if model.camera.ready && model.modeHandoffTarget == nil { break }; try await Task.sleep(for:.milliseconds(50)) }
        try await Task.sleep(for:.milliseconds(300))
        model.selectTopLevelMode(.astro)
        for _ in 0..<400 { if AstroModeDiagnostics.watermarkTap != nil { break }; try await Task.sleep(for:.milliseconds(50)) }
        for mode in AstroCaptureMode.allCases {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await Task.sleep(for:.milliseconds(300))
            let panel = try XCTUnwrap(AstroModeDiagnostics.watermarkPanel)
            panel.wrappedValue = true
            try await Task.sleep(for:.milliseconds(300))
            let tap = try XCTUnwrap(AstroModeDiagnostics.watermarkTap)
            let enabled = try XCTUnwrap(AstroModeDiagnostics.watermarkEnabled)
            if enabled() { tap(model.preferences.watermark.style) }
            for _ in 0..<5 {
                for style in PhotoWatermarkStyle.allCases {
                    tap(style); XCTAssertTrue(enabled())
                    XCTAssertEqual(model.preferences.watermark.style,style)
                    tap(style); XCTAssertFalse(enabled())
                }
                tap(.whiteFrame); tap(.newYear)
                XCTAssertTrue(enabled()); XCTAssertEqual(model.preferences.watermark.style,.newYear)
                tap(.newYear); XCTAssertFalse(enabled())
            }
            tap(.newYear)
            try await Task.sleep(for:.milliseconds(250))
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow) {
                let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                let attachment = XCTAttachment(image:image); attachment.name = "Astro-Watermark-Thumbnails-\(mode.rawValue)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            tap(.newYear); XCTAssertFalse(enabled())
            panel.wrappedValue = false

        }
        print("ASTRO-WATERMARK modes=3 styles=4 repeatLoops=5 onOffTaps=120 directSwitchTaps=45 PhotosWrites=0")
    }
}
