import XCTest
import UIKit
import SwiftUI
import CoreImage
@testable import LumaCamera

final class PhotoEditorZoomTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testPresentedEditorHasSquareCornersAndDialOutsidePhoto() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let session = PhotoEditSession(source: CIImage(image: DemoImageFactory.make())!) { _, _ in }
        let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: EditorFitLibrary()))
        let host = UIHostingController(rootView: Color.black.sheet(isPresented: .constant(true)) {
            PhotoEditorView(model: model).environment(\.captureControlAngle, 0)
        })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.cancelPreview(); window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        try await Task.sleep(for: .milliseconds(800))
        let presented = try XCTUnwrap(host.presentedViewController)
        let sheet = try XCTUnwrap(presented.presentationController as? UISheetPresentationController)
        XCTAssertEqual(sheet.preferredCornerRadius, 0, "The system sheet must not cut the photo's upper corners")
        for tab in FilterEditorTab.allCases {
            model.tool = .adjustments; model.filterEditorTab = tab
            try await Task.sleep(for: .milliseconds(150))
            let dial = model.filterDialPadFrameForTesting
            XCTAssertGreaterThan(dial.height, 200)
            XCTAssertLessThanOrEqual(dial.maxX, window.bounds.width)
            XCTAssertGreaterThanOrEqual(dial.minY, model.photoViewportFrameForTesting.maxY)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let shot = XCTAttachment(image: image); shot.name = "Presented-editor-" + tab.rawValue; shot.lifetime = .keepAlways; add(shot)
        }
        model.tool = .filters
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(sheet.preferredCornerRadius, 0)
    }
    @MainActor func testEditorFitsEntirePhotoAcrossEveryRatioAndToolChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        func zooms(_ view: UIView) -> [PhotoZoomScrollView] { (view as? PhotoZoomScrollView).map { [$0] } ?? view.subviews.flatMap { zooms($0) } }
        for ratio in FrameRatio.allCases {
            for aspect in [ratio.portraitRatio, 1 / ratio.portraitRatio] {
                let size = CGSize(width: 240, height: 240 / aspect)
                let source = UIGraphicsImageRenderer(size: size).image { c in
                    UIColor.darkGray.setFill(); c.fill(CGRect(origin: .zero, size: size))
                    UIColor.red.setStroke(); c.cgContext.setLineWidth(8); c.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
                }
                let session = PhotoEditSession(source: CIImage(image: source)!) { _, _ in }
                let model = PhotoEditorViewModel(session: session, library: PhotoLibraryViewModel(service: EditorFitLibrary()))
                host.rootView = AnyView(PhotoEditorView(model: model).id(UUID()).environment(\.captureControlAngle, 0))
                defer { model.cancelPreview() }
                for tool in [PhotoEditorTool.filters, .adjustments, .filters] {
                    model.tool = tool
                    for _ in 0..<100 { if model.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
                    try await Task.sleep(for: .milliseconds(250))
                    let zoom = try XCTUnwrap(zooms(window).first)
                    zoom.layoutIfNeeded()
                    let displayed = zoom.photoView.convert(zoom.photoView.bounds, to: zoom)
                    XCTAssertEqual(zoom.zoomScale, 1, accuracy: 0.001)
                    XCTAssertTrue(zoom.bounds.insetBy(dx: -1, dy: -1).contains(displayed), "\(ratio) \(aspect) \(tool) bounds=\(zoom.bounds) image=\(displayed) content=\(zoom.contentSize) inset=\(zoom.contentInset)")
                    if tool == .filters {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                        let attachment = XCTAttachment(image: image); attachment.name = "Editor-fit-\(ratio)-\(aspect)"; attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
    }
    #endif
    @MainActor func testFilterRendersPreserveMagnificationAndPanWhileDetailsStillResetForNextPhoto() {
        func image(_ color: UIColor, size: CGSize = CGSize(width: 100, height: 200)) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { _ in color.setFill(); UIRectFill(CGRect(origin: .zero, size: size)) }
        }
        let view = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.display(image(.blue)); view.layoutIfNeeded()
        view.setZoomScale(3, animated: false)
        view.contentOffset = CGPoint(x: 100, y: 300)
        let offset = view.contentOffset
        for _ in 0..<30 {
            view.display(image(.red), preservingViewport: true); view.layoutIfNeeded()
            XCTAssertEqual(view.zoomScale, 3, accuracy: 0.001)
            XCTAssertEqual(view.contentOffset.x, offset.x, accuracy: 0.5)
            XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.5)
        }
        // Geometry changes should fit the new framing instead of keeping a stale crop.
        view.display(image(.green, size: CGSize(width: 200, height: 100)), preservingViewport: true)
        view.layoutIfNeeded(); XCTAssertEqual(view.zoomScale, 1)
        view.setZoomScale(3, animated: false)
        view.display(image(.yellow, size: CGSize(width: 200, height: 100)))
        view.layoutIfNeeded(); XCTAssertEqual(view.zoomScale, 1, "Gallery paging keeps its existing reset behavior")
    }
}

private final class EditorFitLibrary: PhotoLibraryService {
    func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) { completion(.success("test")) }
    func delete(assetID: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}
