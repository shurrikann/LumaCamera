import XCTest
import CoreImage
@testable import LumaCamera

final class Library709Tests: XCTestCase {
    func testImportedLibraryIsDeduplicatedAndClassified() throws {
        XCTAssertEqual(Library709.entries.count, 208)
        XCTAssertEqual(Set(Library709.entries.map(\.style)).count, 208)
        XCTAssertEqual(ImportedFilterCatalog.entries.count, 253)
        XCTAssertEqual(Set(FilmStyle.availableStyles).count, 256)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .street }.count, 74)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .film }.count, 35)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .mono }.count, 5)
        XCTAssertEqual(FilmStyle.availableStyles.filter { $0.filterCategory == .cinema }.count, 74)
        for entry in Library709.entries {
            XCTAssertTrue((16...64).contains(entry.dimension), entry.title)
            XCTAssertTrue(entry.compact, entry.title)
            XCTAssertNotNil(ImportedFilterCatalog.table(entry)?.data, entry.title)
            XCTAssertEqual(entry.style.filterCategory, Library709.categories[entry.style], entry.title)
        }
    }

    func testImported709FilterActuallyTransformsPixels() throws {
        let entry = try XCTUnwrap(Library709.entries.first { $0.title.contains("胶片") || $0.title.contains("冷暖") } ?? Library709.entries.first)
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(color: CIColor(red: 0.3, green: 0.55, blue: 0.25)).cropped(to: CGRect(x:0,y:0,width:4,height:4))
        func pixel(_ image: CIImage) -> [UInt8] { var p=[UInt8](repeating:0,count:4); context.render(image,toBitmap:&p,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)); return p }
        let before=pixel(input), after=pixel(entry.style.apply(to: input, intensity: 1))
        XCTAssertNotEqual(before, after, entry.title)
        XCTAssertEqual(after[3], 255)
    }

    #if !targetEnvironment(simulator)
    @MainActor func testImported709PhotoCaptureKeepsSelectedRecipe() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        let entry = try XCTUnwrap(Library709.entries.first)
        let oldStyle = model.style, oldIntensity = model.intensity, oldAdjustments = model.filterAdjustments
        let oldCallback = camera.onCaptureCompleted
        let idle = UIApplication.shared.isIdleTimerDisabled
        var shots: [CapturedPhoto] = []
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCaptureCompleted = { if let photo = $0 { shots.append(photo) } }
        defer {
            camera.onCaptureCompleted = oldCallback
            model.style = oldStyle; model.intensity = oldIntensity; model.filterAdjustments = oldAdjustments
            model.flushFilterSettings()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        model.setCameraActive(true)
        camera.start()
        for _ in 0..<300 { if camera.ready && camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(camera.ready)
        model.style = entry.style
        model.intensity = 0.8
        var recipe = FilterAdjustments(); recipe[.temperature] = 14; recipe[.vignette] = 30
        model.filterAdjustments = recipe
        await withCheckedContinuation { c in camera.afterPendingSessionTasks { c.resume() } }
        camera.capture(flashMode: .off, options: model.photoOptions)
        for _ in 0..<600 { if camera.pendingPhotoCount == 0 && !shots.isEmpty { break }; try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(shots.count, 1, camera.message ?? "Imported 709 photo capture failed")
        XCTAssertEqual(shots.first?.diagnostics?.parameters?.filterID, entry.style.rawValue)
        XCTAssertEqual(shots.first?.diagnostics?.parameters?.filterAdjustments, recipe)
        print("LIBRARY-709-CAPTURE style=\(entry.style.rawValue) shots=\(shots.count)")
    }
    #endif
}
