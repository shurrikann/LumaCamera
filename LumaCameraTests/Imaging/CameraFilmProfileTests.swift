import XCTest
import CoreImage
@testable import LumaCamera

final class CameraFilmProfileTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func testNewProfilesAreDistinctAndPreserveTransparentImageBounds() {
        let bounds = CGRect(x: 13, y: 17, width: 8, height: 8)
        var signatures = [[UInt8]]()
        for style in [FilmStyle.leicaM9, .fujiNC, .fujiCC] {
            var signature = [UInt8]()
            for rgb: [CGFloat] in [[0.68, 0.43, 0.31], [0.18, 0.48, 0.23], [0.14, 0.31, 0.68], [0.5, 0.5, 0.5]] {
                let source = CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 0.4)).cropped(to: bounds)
                let output = style.apply(to: source, intensity: 1)
                XCTAssertEqual(output.extent, bounds)
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: CGRect(x:13,y:17,width:1,height:1), format:.RGBA8, colorSpace:space) }
                XCTAssertEqual(Int(pixel[3]), 102, accuracy: 1)
                signature += pixel
            }
            signatures.append(signature)
        }
        XCTAssertNotEqual(signatures[0], signatures[1])
        XCTAssertNotEqual(signatures[1], signatures[2])
        XCTAssertNotEqual(signatures[0], signatures[2])
    }
    @MainActor func testImportedCatalogAndFavoritesSurviveReload() throws {
        let suite = "Luma.CameraFilmProfileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let picker = FilterPickerViewModel(defaults:defaults)
        for style in [FilmStyle.leicaM9] {
            XCTAssertTrue(picker.styles.contains(style))
            picker.toggleFavorite(style)
        }
        let restored = FilterPickerViewModel(defaults:defaults)
        restored.category = .favorites
        XCTAssertEqual(restored.styles, [.leicaM9])
        XCTAssertEqual(picker.styles, FilmStyle.availableStyles)
        XCTAssertEqual(picker.styles.count, 46)
    }
}
