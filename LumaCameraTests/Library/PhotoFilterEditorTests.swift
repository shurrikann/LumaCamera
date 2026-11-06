import XCTest
import Combine
import CoreImage
import UIKit
import SwiftUI
@testable import LumaCamera

final class PhotoFilterEditorTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testPhotoFilterEditorAcrossAllRatiosAndTabs() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        for ratio in FrameRatio.allCases {
            let input = source.transformed(by: CGAffineTransform(scaleX: 500 / source.extent.width, y: (500 / ratio.portraitRatio) / source.extent.height))
            let session = PhotoEditSession(source: input) { _, _ in }
            let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: FilterEditLibraryStub()))
            model.selectFilter(.leicaM9); model.tool = .adjustments
            host.rootView = AnyView(PhotoEditorView(model: model).id(session.id))
            for _ in 0..<150 { if model.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNotNil(model.preview)
            for tab in FilterEditorTab.allCases {
                model.filterTab = tab
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(model.filterTab.parameters.contains(model.selectedParameter))
                for scroll in scrolls(window) { XCTAssertLessThanOrEqual(scroll.bounds.width, window.bounds.width + 1) }
                let name = "Photo-Filter-" + ratio.rawValue.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "p") + "-" + String(describing: tab)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
            for tool in [PhotoEditorTool.crop, .filters] {
                model.tool = tool
                if tool == .crop { model.setCropAspect(.square) }
                try await Task.sleep(for: .milliseconds(250))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "Photo-Tool-" + ratio.rawValue + "-" + tool.rawValue; attachment.lifetime = .keepAlways; add(attachment)
                if tool == .filters { XCTAssertTrue(scrolls(window).contains { $0.contentSize.width > $0.bounds.width }, "Filter list must scroll horizontally") }
            }
            model.cancelPreview()
        }
    }
    @MainActor private func scrolls(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) } }
    #endif
    private var source: CIImage { CIImage(image: DemoImageFactory.make())! }
    private func pixels(_ image: UIImage) -> Data { image.pngData()! }
    @MainActor func testSwitchingFiltersRestoresLocalRecipesAndResetRejectsLateSliderWrites() throws {
        let library = PhotoLibraryViewModel(service: FilterEditLibraryStub())
        var saved: PhotoAdjustments?
        let session = PhotoEditSession(source: source) { recipe, completion in saved = recipe; completion(.failure(PhotoDetailError.editingUnsupported)) }
        let model = PhotoEditorViewModel(session: session, library: library)
        XCTAssertEqual(model.style, .original); XCTAssertEqual(model.parameterText(.strength), "—")
        model.selectFilter(.leicaM9)
        model.parameterBinding(.temperature).wrappedValue = 23.5
        model.parameterBinding(.strength).wrappedValue = 42
        model.selectFilter(.original)
        model.parameterBinding(.saturation).wrappedValue = -30
        model.selectFilter(.leicaM9)
        XCTAssertEqual(model.parameterBinding(.temperature).wrappedValue, 23.5)
        XCTAssertEqual(model.parameterBinding(.strength).wrappedValue, 42)
        let old = model.parameterBinding(.temperature)
        model.presentReset(); old.wrappedValue = 99
        XCTAssertEqual(model.parameterBinding(.temperature).wrappedValue, 23.5)
        model.dismissReset(); model.rotate(); model.presentReset(); model.resetCurrentFilter(); old.wrappedValue = 60
        XCTAssertTrue(model.adjustments.filterAdjustments.isNeutral)
        XCTAssertEqual(model.adjustments.quarterTurns, 1)
        model.selectFilter(.original)
        XCTAssertEqual(model.parameterBinding(.saturation).wrappedValue, -30)
        model.save { _ in }
        XCTAssertEqual(saved, model.adjustments); XCTAssertFalse(library.editing)
        model.cancelPreview()
    }
    @MainActor func testSaveChoicesPreserveRecipeRouteAndRejectRepeatedSave() throws {
        let library = PhotoLibraryViewModel(service: FilterEditLibraryStub())
        var copies = 0, replacements = 0
        var pending: ((Result<PhotoEditResult, Error>) -> Void)?
        var received: PhotoAdjustments?
        let session = PhotoEditSession(source: source, copy: { recipe, done in copies += 1; received = recipe; pending = done }) { recipe, done in replacements += 1; received = recipe; pending = done }
        let model = PhotoEditorViewModel(session: session, library: library)
        model.selectFilter(.fujiNC); model.adjustments.straightenAngle = 8
        model.parameterBinding(.tint).wrappedValue = 19
        let recipe = model.adjustments
        model.presentSaveOptions(); XCTAssertTrue(model.saveOptionsVisible)
        model.dismissSaveOptions(); XCTAssertEqual(model.adjustments, recipe); XCTAssertFalse(library.editing)
        model.presentSaveOptions(); model.save(asCopy: true) { _ in }
        XCTAssertEqual(copies,1); XCTAssertEqual(replacements,0); XCTAssertEqual(received,recipe)
        XCTAssertTrue(model.saving); XCTAssertTrue(library.editing); XCTAssertFalse(model.saveOptionsVisible)
        model.save(asCopy: false) { _ in }; XCTAssertEqual(replacements,0)
        pending?(.failure(PhotoDetailError.unavailable)); XCTAssertFalse(model.saving); XCTAssertFalse(library.editing)
        model.save(asCopy: false) { _ in }
        XCTAssertEqual(replacements,1); XCTAssertEqual(received,recipe)
        pending?(.failure(PhotoDetailError.unavailable)); model.cancelPreview()
    }
    func testSavedFilterRecipeRoundTripsAndOldPhotoEditsRemainDecodable() throws {
        var recipe = PhotoAdjustments(); recipe.filterID = FilmStyle.leicaM9.rawValue; recipe.filterIntensity = 0.37
        recipe.filterAdjustments[.temperature] = 24; recipe.filterAdjustments[.aberration] = 80
        let restored = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(restored, recipe)
        let legacy = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{\"exposure\":1,\"contrast\":1.2,\"saturation\":0.8,\"quarterTurns\":1}".utf8))
        XCTAssertEqual(legacy.filterID, "original"); XCTAssertTrue(legacy.filterAdjustments.isNeutral)
        XCTAssertEqual(legacy.exposure, 1); XCTAssertEqual(legacy.quarterTurns, 1)
    }
    @MainActor func testContinuousPhotoEditingPublishesThenSettlesAtExactSavedRecipeWithoutAccumulation() async throws {
        let input = source
        let library = PhotoLibraryViewModel(service: FilterEditLibraryStub())
        let session = PhotoEditSession(source: input) { _, _ in }
        let model = PhotoEditorViewModel(session: session, library: library)
        model.selectFilter(.leicaM9)
        var frames = 0
        let token = model.$preview.dropFirst().sink { if $0 != nil { frames += 1 } }; defer { token.cancel(); model.cancelPreview() }
        model.setParameterEditing(true)
        for i in 0..<180 {
            model.parameterBinding(.temperature).wrappedValue = Double(i % 101) - 50
            model.parameterBinding(.aberration).wrappedValue = Double(i % 101)
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertGreaterThan(frames, 5)
        model.setParameterEditing(false)
        let recipe = model.adjustments
        let expected = try XCTUnwrap(PhotoEditRenderer.preview(source: input, adjustments: recipe, context: CIContext(options: [.cacheIntermediates: false])))
        for _ in 0..<150 { if let preview = model.preview, pixels(preview) == pixels(expected) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview)), pixels(expected))
        for _ in 0..<20 { model.selectFilter(.original); model.selectFilter(.leicaM9) }
        XCTAssertEqual(model.adjustments, recipe)
        let encoded = try PhotoEditRenderer.render(source: input, adjustments: recipe)
        XCTAssertEqual(pixels(encoded.preview), pixels(expected))
        let reopened = PhotoEditorViewModel(session: PhotoEditSession(source: input, initialAdjustments: recipe) { _, _ in }, library: library)
        XCTAssertEqual(reopened.adjustments, recipe)
        reopened.cancelPreview()
    }
}
private final class FilterEditLibraryStub: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("asset")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}
