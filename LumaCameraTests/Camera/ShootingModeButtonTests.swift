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
        model.toggleSmartCaptureMode(); XCTAssertEqual(model.shootingModeButtonSymbol,"sparkles")
        model.toggleSmartCaptureMode(); XCTAssertEqual(model.shootingModeButtonSymbol,"camera.fill")
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
    var bounds: CGRect?
}

private struct ModeSymbolRenderHarness: View {
    @ObservedObject var state: ModeSymbolRenderState
    var body: some View {
        ZStack {
            Color.black
            ShootingModeButtonSymbol(symbol:state.symbol).font(.system(size:15)).foregroundStyle(.white)
                .rotationEffect(.degrees(state.angle))
                .frame(width:36,height:36)
                .background(.ultraThinMaterial,in:Circle())
                .onGeometryChange(for:CGRect.self) { $0.frame(in:.global) } action: { state.bounds = $0 }
        }
    }
}
