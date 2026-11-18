import XCTest
@testable import LumaCamera

final class AstroSharedRawStackPhysicalTests: XCTestCase {
    @MainActor func testSharedSessionRawStackProduces12MP() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实相机")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        // Preceding lens tests can leave an ultra-wide route selected; RAW is
        // only a valid astro baseline on the main wide camera.
        if let wide = camera.lenses.first(where: {
            $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
                && abs($0.displayZoom - 1) < 0.01
        }) {
            model.selectFocalLength(wide)
            for _ in 0..<300 {
                if camera.selectedLens == wide.id && camera.ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertTrue(camera.ready)
        camera.enterAstroRoute()
        try await Task.sleep(for: .milliseconds(500))
        for (count, exposure) in [(10, 1.0), (30, 1.0 / 15.0), (60, 1.0 / 15.0)] {
            camera.beginAstroPhotoStack(frameCount: count, exposureSeconds: exposure)
            for _ in 0..<4000 {
                if !camera.astroPhotoBusy && camera.astroPhotoResult != nil { break }
                if !camera.astroPhotoStatus.isEmpty,
                   camera.astroPhotoStatus.contains("失败") || camera.astroPhotoStatus.contains("不支持") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(camera.astroPhotoBusy, "\(count) frames")
            let image = try XCTUnwrap(camera.astroPhotoResult, "\(count): \(camera.astroPhotoStatus)")
            XCTAssertEqual(image.size.width * image.scale, 4032, accuracy: 1)
            XCTAssertEqual(image.size.height * image.scale, 3024, accuracy: 1)
            print("ASTRO-RAW count=\(count) exposure=\(exposure) result=\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))")
        }
        #endif
    }

    @MainActor func testSharedSessionLightenTrails() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("需要真实相机")
        #else
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let camera = model.camera
        defer { model.setCameraActive(false) }
        model.setCameraActive(true)
        for _ in 0..<400 { if camera.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(camera.ready)
        if let wide = camera.lenses.first(where: {
            $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera
                && abs($0.displayZoom - 1) < 0.01
        }) {
            model.selectFocalLength(wide)
            for _ in 0..<300 {
                if camera.selectedLens == wide.id && camera.ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertTrue(camera.ready)
        camera.enterAstroRoute()
        try await Task.sleep(for: .milliseconds(500))
        camera.beginAstroPhotoStack(frameCount: 5, exposureSeconds: 1.0 / 15.0, blend: .lighten)
        for _ in 0..<1200 {
            if !camera.astroPhotoBusy && camera.astroPhotoResult != nil { break }
            if camera.astroPhotoStatus.contains("失败") || camera.astroPhotoStatus.contains("不支持") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(camera.astroPhotoBusy)
        let image = try XCTUnwrap(camera.astroPhotoResult, camera.astroPhotoStatus)
        XCTAssertEqual(image.size.width * image.scale, 4032, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 3024, accuracy: 1)
        #endif
    }
}
