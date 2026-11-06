import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class PreviewWorkReuseTests: XCTestCase {
    @MainActor func testConcurrentPickersAndReopenedEditorsShareSameRenderedThumbnails() async throws {
        let before = FilterPickerViewModel.thumbnailRenderPassesForTesting
        let models = (0..<8).map { _ in FilterPickerViewModel() }
        models.forEach { $0.prepareThumbnails() }
        for _ in 0..<500 {
            if models.allSatisfy({ $0.thumbnails.count == FilmStyle.availableStyles.count }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertLessThanOrEqual(FilterPickerViewModel.thumbnailRenderPassesForTesting - before, 1)
        for model in models {
            XCTAssertEqual(model.thumbnails.count, FilmStyle.availableStyles.count)
            for style in FilmStyle.availableStyles {
                XCTAssertTrue(model.thumbnails[style] === models[0].thumbnails[style])
            }
        }
        let reopened = FilterPickerViewModel()
        XCTAssertEqual(reopened.thumbnails.count, FilmStyle.availableStyles.count, "Reopening should immediately have existing images")
        let passes = FilterPickerViewModel.thumbnailRenderPassesForTesting
        reopened.prepareThumbnails()
        XCTAssertEqual(FilterPickerViewModel.thumbnailRenderPassesForTesting, passes)
        models[0].category = .favorites
        XCTAssertEqual(reopened.category, .all, "Only image pixels are shared, not picker state")
        print("THUMBNAIL-REUSE pickers=9 renderPasses=\(passes-before) styles=\(reopened.thumbnails.count)")
    }

    func testRenderedSDRHistogramMatchesGraphAndAvoidsRepeatedFilterWork() throws {
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: 900/source.extent.width, y: 900/source.extent.width))
        var look = CaptureLook(style: .leicaM9, intensity: 1)
        look.adjustments[.softness] = 55; look.adjustments[.halation] = 40
        let displayContext = CIContext(options: [.cacheIntermediates: false])
        let histogramContext = CIContext(options: [.cacheIntermediates: false])
        var times: [[Double]] = [[], []]
        var difference = 0.0
        for cycle in 0..<12 {
            for path in cycle.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                try autoreleasepool {
                    let begin = CACurrentMediaTime()
                    let graph = Imaging.filtered(scaled, look: look)
                    let cg = try XCTUnwrap(displayContext.createCGImage(graph, from: graph.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false))
                    let bins = Imaging.histogram(path == 0 ? graph : CIImage(cgImage: cg), context: histogramContext)
                    if cycle >= 2 { times[path].append(CACurrentMediaTime() - begin) }
                    if cycle == 2 {
                        let reference = Imaging.histogram(graph, context: histogramContext)
                        difference = zip(reference, bins).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(bins.count)
                        XCTAssertLessThan(difference, 0.08, "SDR quantization should not materially change histogram")
                    }
                }
            }
        }
        let averages = times.map { $0.reduce(0, +) / Double($0.count) }
        print("HISTOGRAM-REUSE baselineSeconds=\(averages[0]) reusedSeconds=\(averages[1]) meanBinDifference=\(difference)")
        // Device load varies; do not turn a timing comparison into a flaky pass/fail.
    }
}
