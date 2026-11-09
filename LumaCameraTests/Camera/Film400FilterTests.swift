import CoreImage
import XCTest
@testable import LumaCamera

final class Film400FilterTests: XCTestCase {
    func testFilm400IsAvailableAndRendersDistinctWarmNegative() throws {
        XCTAssertTrue(FilmStyle.availableStyles.contains(.film400))
        XCTAssertEqual(FilmStyle.film400.title, "胶片 400")
        let context = CIContext()
        func rgba(_ style: FilmStyle) -> (Double, Double, Double) {
            let source = CIImage(color: CIColor(red: 0.46, green: 0.48, blue: 0.52)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            let output = style.apply(to: source, intensity: 0.8)
            var pixels = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixels, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (Double(pixels[0]), Double(pixels[1]), Double(pixels[2]))
        }
        let original = rgba(.original), film = rgba(.film400)
        print("FILM-400 original=\(original) film=\(film)")
        XCTAssertGreaterThan(film.0, film.2, "胶片400应保留暖色趋势")
        XCTAssertTrue(abs(film.0 - original.0) > 1 || abs(film.1 - original.1) > 1 || abs(film.2 - original.2) > 1,
                      "胶片400不能是无变化的中性滤镜")
    }
}
