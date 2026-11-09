import CoreImage
import XCTest
@testable import LumaCamera

final class FilterTintDirectionTests: XCTestCase {
    func testPositiveTintRendersMagentaAndNegativeRendersGreen() throws {
        let context = CIContext()
        func rgb(tint: Double) throws -> (Double, Double, Double) {
            var adjustments = FilterAdjustments()
            adjustments[.tint] = tint
            let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            let output = FilterAdjustmentRenderer.apply(adjustments, to: source)
            var pixels = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixels, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (Double(pixels[0]), Double(pixels[1]), Double(pixels[2]))
        }
        let magenta = try rgb(tint: 100)
        let green = try rgb(tint: -100)
        print("FILTER-TINT positive=\(magenta) negative=\(green)")
        XCTAssertGreaterThan(magenta.0 + magenta.2, magenta.1 * 2, "正值应偏洋红")
        XCTAssertGreaterThan(green.1 * 2, green.0 + green.2, "负值应偏绿")
    }
}
