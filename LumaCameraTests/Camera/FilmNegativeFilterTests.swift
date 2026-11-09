import CoreImage
import XCTest
@testable import LumaCamera

final class FilmNegativeFilterTests: XCTestCase {
    func testBothNegativeStocksAreAvailableAndRenderDistinctly() throws {
        XCTAssertTrue(FilmStyle.availableStyles.contains(.daylightNegative400))
        XCTAssertTrue(FilmStyle.availableStyles.contains(.warmNegative200))
        XCTAssertEqual(FilmStyle.daylightNegative400.title, "日光负片 400")
        XCTAssertEqual(FilmStyle.warmNegative200.title, "暖调负片 200")
        let context = CIContext()
        func rgba(_ style: FilmStyle) -> (Double, Double, Double) {
            let source = CIImage(color: CIColor(red: 0.46, green: 0.48, blue: 0.52)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            let output = style.apply(to: source, intensity: 0.8)
            var pixels = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixels, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (Double(pixels[0]), Double(pixels[1]), Double(pixels[2]))
        }
        let original = rgba(.original)
        let daylight = rgba(.daylightNegative400)
        let warm = rgba(.warmNegative200)
        print("FILM-NEGATIVES original=\(original) daylight=\(daylight) warm=\(warm)")
        XCTAssertGreaterThan(warm.0, warm.2, "暖调负片应明显偏暖")
        XCTAssertLessThan(abs(daylight.0 - daylight.2), abs(warm.0 - warm.2), "日光负片应比暖调负片更中性")
        XCTAssertTrue(abs(daylight.0 - original.0) > 1 || abs(daylight.1 - original.1) > 1 || abs(daylight.2 - original.2) > 1,
                      "日光负片不能是无变化的中性滤镜")
    }
}
