import XCTest
import QuartzCore
@testable import LumaCamera

@MainActor final class AstroToolbarHapticsPhysicalTests: XCTestCase {
    func testEnabledToolbarTapsEmitOnceAndDisabledTapsStaySilent() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        defer {
            CameraHaptics.recorderForTesting = nil
            model.settings = false
            model.selectTopLevelMode(.photo); model.setCameraActive(true)
        }
        model.setCameraActive(true)
        try await wait { model.camera.ready && model.camera.preview != nil }
        model.selectTopLevelMode(.astro)
        try await wait { AstroModeDiagnostics.toolbarTap != nil && AstroModeDiagnostics.previewReady }
        var impacts = 0, times = [Double]()
        CameraHaptics.recorderForTesting = { if case .impact = $0 { impacts += 1 } }
        for mode in AstroCaptureMode.allCases {
            AstroModeDiagnostics.submode?.wrappedValue = mode
            try await Task.sleep(for:.milliseconds(400))
            let tap = try XCTUnwrap(AstroModeDiagnostics.toolbarTap)
            for _ in 0..<10 {
                for item in 0...2 {
                    let before = impacts, start = CACurrentMediaTime()
                    tap(item)
                    times.append((CACurrentMediaTime()-start)*1000)
                    let enabled = item == 2 || (item == 1 ? mode == .photo : mode != .timelapse)
                    XCTAssertEqual(impacts-before,enabled ? 1 : 0,"mode=\(mode) item=\(item)")
                }
                await Task.yield()
            }
        }
        let before = impacts
        try XCTUnwrap(AstroModeDiagnostics.toolbarTap)(3)
        XCTAssertTrue(model.settings)
        XCTAssertEqual(impacts-before,1)
        model.settings = false
        print("ASTRO-TOOLBAR-HAPTICS taps=91 enabledImpacts=\(impacts) handlerMilliseconds=\(times); handler dispatch only, not tactile latency or FPS; PhotosWrites=0")
    }
    private func wait(_ condition:()->Bool) async throws {
        let deadline = CACurrentMediaTime()+20
        while !condition(), CACurrentMediaTime()<deadline { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertTrue(condition())
    }
}
