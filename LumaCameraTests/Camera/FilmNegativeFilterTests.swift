import CoreImage
import XCTest
@testable import LumaCamera

final class FilmNegativeFilterTests: XCTestCase {
    private let context = CIContext()

    private func rgba(_ style: FilmStyle, red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let source = CIImage(color: CIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue)))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = style.apply(to: source, intensity: 0.8)
        var pixels = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixels, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(pixels[0]), Double(pixels[1]), Double(pixels[2]))
    }

    func testBothNegativeStocksAreAvailableAndRenderDistinctly() throws {
        XCTAssertTrue(FilmStyle.availableStyles.contains(.daylightNegative400))
        XCTAssertTrue(FilmStyle.availableStyles.contains(.warmNegative200))
        XCTAssertEqual(FilmStyle.daylightNegative400.title, "日光负片 400")
        XCTAssertEqual(FilmStyle.warmNegative200.title, "暖调负片 200")
        let original = rgba(.original, red: 0.46, green: 0.48, blue: 0.52)
        let daylight = rgba(.daylightNegative400, red: 0.46, green: 0.48, blue: 0.52)
        let warm = rgba(.warmNegative200, red: 0.46, green: 0.48, blue: 0.52)
        print("FILM-NEGATIVES original=\(original) daylight=\(daylight) warm=\(warm)")
        XCTAssertGreaterThan(warm.0, warm.2, "暖调负片应明显偏暖")
        XCTAssertLessThan(abs(daylight.0 - daylight.2), abs(warm.0 - warm.2), "日光负片应比暖调负片更中性")
        XCTAssertTrue(abs(daylight.0 - original.0) > 1 || abs(daylight.1 - original.1) > 1 || abs(daylight.2 - original.2) > 1,
                      "日光负片不能是无变化的中性滤镜")
    }

    func testDaylightNegativeHasSoftHighlightsWarmMidtonesAndOpenShadows() throws {
        let shadow = rgba(.daylightNegative400, red: 0.08, green: 0.08, blue: 0.08)
        let mid = rgba(.daylightNegative400, red: 0.5, green: 0.5, blue: 0.5)
        let high = rgba(.daylightNegative400, red: 0.92, green: 0.92, blue: 0.92)
        print("FILM-DAYLIGHT-TONES shadow=\(shadow) mid=\(mid) high=\(high)")
        XCTAssertGreaterThan((shadow.0 + shadow.1 + shadow.2) / 3, 0.08 * 255, "暗部应被抬起，避免死黑")
        XCTAssertGreaterThan(mid.0, mid.2, "中间调应偏暖")
        XCTAssertLessThan(high.0, 0.94 * 255, "高光应柔和压缩，不能直接冲白")
        XCTAssertGreaterThan(high.0, 0.78 * 255, "高光仍需保留层次")
    }

    func testUseCaseCategoriesCoverEveryVisibleFilter() {
        let styles = FilmStyle.availableStyles
        let grouped = Dictionary(grouping: styles, by: \.filterCategory)
        print("FILM-CATEGORIES " + grouped.map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " "))
        for category in FilterCategory.allCases where category != .all && category != .favorites {
            XCTAssertFalse(styles.filter { category.includes($0) }.isEmpty, "\(category.rawValue)分类不应为空")
        }
        XCTAssertEqual(styles.filter { FilterCategory.film.includes($0) }.count,
                       grouped[.film]?.count ?? -1)
    }
}
