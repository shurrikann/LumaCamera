import XCTest
import UIKit
import ImageIO
@testable import LumaCamera

final class Smart48CompatibilityTests:XCTestCase {
    func testSuggestionsDescribeResolutionAndFormatChanges() {
        let night = SmartCaptureSuggestion(kind:.night,title:"夜景 · 自动",actionTitle:"应用",parameters:.init(mode:.night))
        let high = SmartCaptureSuggestionPolicy.presented(night,format:.jpeg,resolution:.high,available:[.jpeg,.heif])
        XCTAssertEqual(high?.title,"夜景 · 12MP"); XCTAssertEqual(high?.actionTitle,"切换")
        let raw = SmartCaptureSuggestionPolicy.presented(night,format:.raw,resolution:.high,available:[.jpeg,.heif,.raw])
        XCTAssertEqual(raw?.title,"夜景 · HEIF 12MP")
        let hdr = SmartCaptureSuggestion(kind:.backlit,title:"HDR · 保高光",actionTitle:"应用",parameters:.init(hdr:true))
        XCTAssertNil(SmartCaptureSuggestionPolicy.presented(hdr,format:.jpeg,resolution:.high,available:[.jpeg])?.actionTitle)
        XCTAssertEqual(SmartCaptureSuggestionPolicy.presented(hdr,format:.heif,resolution:.high,available:[.heif])?.title,"HDR · 保高光")
    }
    #if !targetEnvironment(simulator)
    @MainActor func test48MPIsManualOnlyAndManualPhotoStillWorks() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel(), camera = model.camera
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var photo: CapturedPhoto?
        let callback = camera.onCaptureCompleted
        camera.onCaptureCompleted = { photo = $0 }
        defer { camera.onCaptureCompleted = callback; model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = idle }
        func wait(_ text:String,_ predicate:()->Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(20)) }
            XCTFail(text+" "+(camera.message ?? "")); throw CancellationError()
        }
        model.setCameraActive(true); try await wait("启动") { camera.ready && camera.preview != nil }
        model.photoFormat = .jpeg; model.hdr = false; model.setMode(.auto)
        try await wait("A挡") { camera.ready && model.mode == .auto && camera.availableResolutions.contains(.high) }
        XCTAssertFalse(model.canSelectPhotoResolution(.high), "A 挡不能选择 48MP")
        model.setMode(.manual)
        try await wait("M挡") { camera.ready && model.mode == .manual }
        XCTAssertTrue(model.canSelectPhotoResolution(.high), "M 挡应支持 48MP")
        model.photoResolution = .high
        try await wait("48MP路由") { camera.ready && !camera.highResolutionPhotoConfiguring && model.photoResolution == .high }
        camera.capture(flashMode: .off, options: model.photoOptions)
        try await wait("48MP出片") { photo != nil && camera.pendingPhotoCount == 0 }
        let resource = try XCTUnwrap(photo?.resources.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        print("SMART48-MANUAL size=\(width)x\(height) mode=\(model.mode.rawValue) AEnabled=false MEnabled=true")
        XCTAssertGreaterThan(width * height, 40_000_000)
    }
    #endif
}
