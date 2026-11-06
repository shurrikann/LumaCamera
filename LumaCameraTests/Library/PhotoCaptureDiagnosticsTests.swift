import XCTest
import CoreImage
import ImageIO
@testable import LumaCamera

final class PhotoCaptureDiagnosticsTests: XCTestCase {
    func testOriginalEXIFProvidesLensAndExposureWithoutInferringLensFromZoom() {
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "back triple camera 16.38mm f/2.8",
                kCGImagePropertyExifFocalLength: 16.38, kCGImagePropertyExifFocalLenIn35mmFilm: 200,
                kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifFNumber: 2.8]]
        let rows = PhotoCaptureDiagnostics.exposureRows(properties: properties)
        XCTAssertEqual(rows.first { $0.title == "实际焦距" }?.value, "16.38 mm")
        XCTAssertEqual(rows.first { $0.title == "35mm 等效焦距" }?.value, "200 mm")
        XCTAssertEqual(rows.first { $0.title == "快门" }?.value, "1/100 s")
        XCTAssertFalse(rows.contains { $0.title == "档位能力匹配" })
    }

    func testMalformedMetadataDoesNotCrashOrInventValues() {
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifFocalLength: Double.nan,
            kCGImagePropertyExifExposureTime: Double.leastNonzeroMagnitude, kCGImagePropertyExifFNumber: -1,
            kCGImagePropertyExifFocalLenIn35mmFilm: Double.infinity]]
        let rows = PhotoCaptureDiagnostics.exposureRows(properties: properties)
        XCTAssertFalse(rows.contains { $0.title == "实际焦距" || $0.title == "光圈" || $0.title == "35mm 等效焦距" })
        XCTAssertEqual(PhotoCaptureDiagnostics.exposureRows(properties: [:]), [])
        XCTAssertEqual(PhotoCaptureDiagnostics.resourceRows([PhotoResource(data: Data([1,2,3]), filename: "unknown.dng")]).count, 2)
    }

    func testOutputDimensionsComeFromEncodedFileAndAllRatios() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 800))
        for ratio in FrameRatio.allCases {
            let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(ratio: ratio), options: PhotoOptions(), context: CIContext())
            let rows = PhotoCaptureDiagnostics.resourceRows(photo.resources)
            let encoded = try XCTUnwrap(CGImageSourceCreateWithData(photo.resources[0].data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
            XCTAssertEqual(rows.first { $0.title == "输出尺寸" }?.value, "\(width) × \(height)")
            XCTAssertEqual(rows.first { $0.title == "输出格式" }?.value, "JPEG")
        }
    }

    func testDiagnosticsSurviveStoreRecreationAndAssetIdentifiersDoNotCollide() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var info = PhotoCaptureDiagnostics(); info.add("拍摄倍率", "8.00×"); info.add("快门时主镜头", "长焦")
        let store = PhotoCaptureDiagnosticsStore(directory: directory)
        XCTAssertTrue(store.save(info, assetID: "asset/A+1/L0/001"))
        let second = PhotoCaptureDiagnostics(rows: [.init(title: "拍摄倍率", value: "2.00×")])
        XCTAssertTrue(store.save(second, assetID: "asset_A+1/L0/001"))
        let reopened = PhotoCaptureDiagnosticsStore(directory: directory)
        XCTAssertEqual(reopened.load(assetID: "asset/A+1/L0/001"), info)
        XCTAssertEqual(reopened.load(assetID: "asset_A+1/L0/001"), second)
        XCTAssertNil(reopened.load(assetID: "missing"))
    }

    func testNightBadgeRequiresActualMultiFrameMergeAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoCaptureDiagnosticsStore(directory: directory)

        XCTAssertFalse(store.isNightComposite(assetID: "night-photo"))
        var merged = PhotoCaptureDiagnostics()
        merged.add("夜景曝光合成", "3 帧对齐融合")
        XCTAssertTrue(merged.isNightComposite)
        XCTAssertTrue(merged.detailRows.contains { $0.title == "夜景曝光合成" && $0.value == "3 帧对齐融合" })
        XCTAssertTrue(store.save(merged, assetID: "night-photo"))
        XCTAssertTrue(store.isNightComposite(assetID: "night-photo"), "Saving diagnostics must invalidate the cached badge state.")

        var partial = PhotoCaptureDiagnostics()
        partial.add("夜景曝光合成", "2 帧对齐融合")
        XCTAssertTrue(partial.isNightComposite)
        XCTAssertTrue(store.save(partial, assetID: "partial-night"))
        XCTAssertTrue(store.isNightComposite(assetID: "partial-night"))

        for count in 2...9 {
            var adaptive = PhotoCaptureDiagnostics()
            adaptive.add("夜景曝光合成", "\(count) 帧对齐融合")
            adaptive.add("夜景计划帧数", "9 帧")
            adaptive.add("夜景实际采集", "9 帧")
            XCTAssertTrue(adaptive.isNightComposite)
            XCTAssertEqual(adaptive.detailRows.filter { $0.title.contains("帧") || $0.title == "夜景曝光合成" }.count, 1)
            XCTAssertTrue(store.save(adaptive, assetID: "adaptive-\(count)"))
            XCTAssertTrue(PhotoCaptureDiagnosticsStore(directory: directory).isNightComposite(assetID: "adaptive-\(count)"))
        }

        var fallback = PhotoCaptureDiagnostics()
        fallback.add("夜景曝光合成", "曝光帧不完整，使用可用单帧")
        XCTAssertFalse(fallback.isNightComposite)
        XCTAssertTrue(store.save(fallback, assetID: "fallback-photo"))
        XCTAssertFalse(PhotoCaptureDiagnosticsStore(directory: directory).isNightComposite(assetID: "fallback-photo"))
    }

    func testFailedOrCorruptedStoreIsNotReportedAsKnownInformation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let store = PhotoCaptureDiagnosticsStore(directory: file)
        XCTAssertFalse(store.save(PhotoCaptureDiagnostics(), assetID: "test"))
        XCTAssertNil(store.load(assetID: "test"))
    }

    func testMergingPreservesActualFileValuesAndDoesNotDuplicateTitles() {
        var info = PhotoCaptureDiagnostics(); info.add("拍摄倍率", "4.00×"); info.add("拍摄倍率", "8.00×")
        let rows = PhotoCaptureDiagnostics.merged([.init(title: "输出尺寸", value: "100 × 200")], with: [.init(title: "输出尺寸", value: "20 × 30")] + info.rows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].value, "100 × 200")
        XCTAssertEqual(rows[1].value, "8.00×")
    }

    @MainActor
    func testCaptureReviewRetainsDiagnosticsAfterEditingAndUsesFileSize() throws {
        let photo = try PhotoEncoder.encode(source: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 160)), raw: nil, look: CaptureLook(), options: PhotoOptions(), context: CIContext())
        let library = AppDependencies.makeCameraModel(automaticallySave: false).library
        var capture = photo
        capture.diagnostics = PhotoCaptureDiagnostics(rows: [.init(title: "快门时主镜头", value: "长焦")])
        library.acceptCapture(capture)
        XCTAssertEqual(library.captureInfoRows.first { $0.title == "快门时主镜头" }?.value, "长焦")
        library.replaceUnsavedPhoto(.init(preview: photo.preview, resource: photo.resources[0]))
        XCTAssertEqual(library.captureInfoRows.first { $0.title == "快门时主镜头" }?.value, "长焦")
        XCTAssertTrue(library.captureInfoRows.contains { $0.title == "输出尺寸" })
        library.acceptCapture(photo)
        XCTAssertFalse(library.captureInfoRows.contains { $0.title == "快门时主镜头" })
    }
    func testNumericParametersPersistWithoutFormattingLossAndRAWDoesNotOverwriteProcessedEXIF() throws {
        var parameters = PhotoCaptureParameters()
        parameters.mode = "M"; parameters.displayedZoom = 8
        parameters.filterID = "test"; parameters.filterIntensity = 0.637
        parameters.requestedExposureBiasEV = -1.3; parameters.ratio = "XPAN"
        parameters.updateEXIF([kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [125], kCGImagePropertyExifExposureTime: 0.003125, kCGImagePropertyExifFocalLength: 16.38]])
        parameters.updateEXIF([kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400]]], overwrite: false)
        XCTAssertEqual(parameters.iso, 125)
        XCTAssertEqual(parameters.exposureSeconds, 0.003125)
        let info = PhotoCaptureDiagnostics(parameters: parameters)
        let decoded = try JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.parameters, parameters)
        XCTAssertEqual(decoded.parameters?.filterIntensity, 0.637)
        XCTAssertEqual(decoded.parameters?.ratio, "XPAN")
    }

    func testOldRecordsRemainReadableAndUnavailableEXIFStaysUnknown() throws {
        let legacy = try JSONEncoder().encode(["rows": [PhotoInfoRow(title: "拍摄倍率", value: "2.00×")]])
        let decoded = try JSONDecoder().decode(PhotoCaptureDiagnostics.self, from: legacy)
        XCTAssertNil(decoded.parameters)
        var parameters = PhotoCaptureParameters()
        parameters.sampledISO = 250
        parameters.updateEXIF([:])
        XCTAssertNil(parameters.iso)
        XCTAssertNil(parameters.aperture)
        XCTAssertEqual(parameters.sampledISO, 250)
    }

}
