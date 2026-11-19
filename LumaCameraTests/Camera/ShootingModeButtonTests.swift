import XCTest
import SwiftUI
@testable import LumaCamera

final class ShootingModeButtonTests: XCTestCase {
    /// 使用真正的按钮图标视图反复切换并旋转，外框尺寸不得因符号不同改变。
    @MainActor func testSymbolsRenderAndKeepFixedBoundsDuringRepeatedSwitches() async throws {
        let names = ["camera.fill", "camera.aperture", PhotoSubmode.slowShutter.symbol, PhotoSubmode.night.symbol,
            PhotoSubmode.portrait.symbol, PhotoSubmode.burst.symbol, "video", VideoSubmode.timeLapse.symbol,
            VideoSubmode.slowMotion.symbol, VideoSubmode.cinematic.symbol]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = ModeSymbolRenderState()
        let host = UIHostingController(rootView: ModeSymbolRenderHarness(state:state))
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var bounds: CGRect?, samples = [Double]()
        for pass in 0..<2 { for (index,name) in names.enumerated() {
            XCTAssertNotNil(UIImage(systemName:name),name)
            state.symbol = name; state.angle = [0.0,90,-90,180][(pass+index)%4]
            try await Task.sleep(for:.milliseconds(250))
            let rect = try XCTUnwrap(state.bounds)
            if let bounds { XCTAssertEqual(rect,bounds) } else { bounds = rect }
            XCTAssertEqual(rect.width,36); XCTAssertEqual(rect.height,36)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let start = CACurrentMediaTime()
            let shot = UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in
                window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
            }
            samples.append(CACurrentMediaTime()-start)
            XCTAssertNotNil(shot.cgImage)
        } }
        // 快速来回切换及回退只改变符号，不重建外层按钮。
        for _ in 0..<100 { for name in names { state.symbol = name } }
        state.symbol = "camera.aperture"
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(state.bounds,bounds)
        print("SUBMODE-ICON-RENDER samples=\(samples.count) snapshotSeconds=\(samples) rapidUpdates=900 bounds=36x36; snapshot drawing cost, not display FPS")
    }

    @MainActor func testPhotoAndVideoSymbolsUseAdaptiveEdgeWhenSwitched() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = ModeSymbolRenderState()
        let host = UIHostingController(rootView: ModeSymbolContrastHarness(state: state)
            .environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        let dark = sample(gray: 0)
        let light = sample(gray: 1)
        let gray = sample(gray: 0.5)
        var timings: [Double] = []
        for (symbol, active, angle) in [
            ("camera.fill", false, 0.0), (PhotoSubmode.night.symbol, true, 90.0),
            ("video", false, -90.0), (VideoSubmode.cinematic.symbol, true, 180.0)
        ] {
            state.symbol = symbol
            state.active = active
            state.angle = angle
            state.sample = dark
            try await Task.sleep(for: .milliseconds(800))
            let frame = try XCTUnwrap(state.bounds)
            let before = try edgePixels(in: window, frame: frame)
            state.sample = active ? gray : light
            let start = CACurrentMediaTime()
            var after = 0
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                after = try edgePixels(in: window, frame: frame)
                if after > before + 6 { break }
            }
            XCTAssertGreaterThan(after, before + 6, symbol)
            XCTAssertEqual(state.bounds, frame, symbol)
            timings.append(CACurrentMediaTime() - start)
        }
        state.sample = dark
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try edgePixels(in: window, frame: XCTUnwrap(state.bounds)), 0)
        print("SUBMODE-EDGE samples=\(timings.count) activationSeconds=\(timings)")
    }

    private func sample(gray: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor(white: gray, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    @MainActor private func edgePixels(in window: UIWindow, frame: CGRect) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let snapshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixels = try XCTUnwrap(snapshot.cgImage?.cropping(to: frame.integral))
        var rgba = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        return try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).count {
                // Ignore the orange foreground and count the neutral edge over the white backdrop.
                bytes[$0] < 247 && bytes[$0] == bytes[$0+1] && bytes[$0+1] == bytes[$0+2]
            }
        }
    }

    #if !targetEnvironment(simulator)
    /// 不拍摄媒体；核对实际开启、关闭及照片/视频往返时的入口图标。
    @MainActor func testActivePhotoAndVideoSubmodesUpdateEntryIcon() async throws {
        let model = try await FullDeviceRegressionFixture.makeFreshModel()
        let audit = SessionRuntimeErrorAudit()
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { model.setCameraActive(false); UIApplication.shared.isIdleTimerDisabled = oldIdle; audit.finish() }
        model.setCameraActive(true)
        func settle(_ symbol: String) async throws {
            await withCheckedContinuation { c in model.camera.afterPendingSessionTasks { c.resume() } }
            let deadline = CACurrentMediaTime()+20
            while CACurrentMediaTime()<deadline {
                if model.camera.ready && !model.isPreparingSubmode && !model.camera.videoConfiguring
                    && model.shootingModeButtonSymbol == symbol { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail("Expected \(symbol), actual \(model.shootingModeButtonSymbol), message=\(model.camera.message ?? "none")")
            throw CancellationError()
        }
        try await settle("camera.fill")
        model.photoFormat = .heif; model.hdr = false
        if model.livePhotoEnabled { model.toggleLivePhoto() }
        let photos: [(String, () -> Void)] = [
            (PhotoSubmode.slowShutter.symbol,{ model.toggleSlowShutterMode() }),
            (PhotoSubmode.portrait.symbol,{ model.togglePortraitMode() }),
            (PhotoSubmode.burst.symbol,{ model.toggleBurstMode() })]
        var latencies = [Double]()
        for (symbol,toggle) in photos {
            let start = CACurrentMediaTime(); toggle(); try await settle(symbol)
            XCTAssertTrue(model.shootingSubmodeEnabled)
            latencies.append(CACurrentMediaTime()-start)
            model.closePopups(); XCTAssertEqual(model.shootingModeButtonSymbol,symbol)
            toggle(); try await settle("camera.fill"); XCTAssertFalse(model.shootingSubmodeEnabled)
        }
        model.setCaptureKind(.video); try await settle("video")
        let videos: [(String, () -> Void)] = [
            (VideoSubmode.timeLapse.symbol,{ model.toggleTimeLapseMode() }),
            (VideoSubmode.slowMotion.symbol,{ model.toggleSlowMotionMode() }),
            (VideoSubmode.cinematic.symbol,{ model.toggleCinematicVideoMode() })]
        for (symbol,toggle) in videos {
            let start = CACurrentMediaTime(); toggle(); try await settle(symbol)
            XCTAssertTrue(model.shootingSubmodeEnabled); latencies.append(CACurrentMediaTime()-start)
            model.closePopups(); XCTAssertEqual(model.shootingModeButtonSymbol,symbol)
            toggle(); try await settle("video"); XCTAssertFalse(model.shootingSubmodeEnabled)
        }
        model.setCaptureKind(.photo); try await settle("camera.fill")
        print("SUBMODE-ICON-ACTIVE samples=7 activationToReadySeconds=\(latencies) mediaCaptures=0")
    }
    #endif
}

@MainActor private final class ModeSymbolRenderState: ObservableObject {
    @Published var symbol = "camera.aperture"
    @Published var angle = 0.0
    @Published var active = false
    @Published var sample: UIImage?
    var bounds: CGRect?
}

private struct ModeSymbolRenderHarness: View {
    @ObservedObject var state: ModeSymbolRenderState
    var body: some View {
        ZStack {
            Color.black
            ShootingModeButtonSymbol(symbol: state.symbol, active: false).font(.system(size: 15))
                .rotationEffect(.degrees(state.angle))
                .frame(width:36,height:36)
                .background(.ultraThinMaterial,in:Circle())
                .onGeometryChange(for:CGRect.self) { $0.frame(in:.global) } action: { state.bounds = $0 }
        }
    }
}


private struct ModeSymbolContrastHarness: View {
    @ObservedObject var state: ModeSymbolRenderState

    var body: some View {
        ZStack {
            Color.white.frame(width: 180, height: 180).previewControlContrastFrame()
            ShootingModeButtonSymbol(symbol: state.symbol, active: state.active)
                .font(.system(size: 15))
                .rotationEffect(.degrees(state.angle))
                .frame(width: 36, height: 36)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.bounds = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .previewControlContrastSource(active: true) { state.sample }
    }
}
