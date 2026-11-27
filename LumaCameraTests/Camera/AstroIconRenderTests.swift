import SwiftUI
import CoreImage
import XCTest
@testable import LumaCamera

@MainActor final class AstroIconRenderTests: XCTestCase {
    func testShutterCenterAndInteriorDoNotPassTouchesToBackground() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var frame = CGRect.zero
        var checks = 0
        var hitMilliseconds = [Double]()
        for kind in [CaptureShutterFace.Kind.photo, .video] {
            for center in [CaptureShutterFace.Center.none, .loading, .countdown, .stop] {
                let root = ZStack {
                    ShutterTouchBackground()
                    Button {} label: {
                        CaptureShutterFace(kind: kind, center: center)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                    }.buttonStyle(.plain)
                }
                window.rootViewController = UIHostingController(rootView: root)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(frame.width, 76, accuracy: 1)
                for delta in [CGPoint.zero, CGPoint(x: 15,y: 0), CGPoint(x: -15,y: 0), CGPoint(x: 0,y: 15), CGPoint(x: 0,y: -15)] {
                    let point = CGPoint(x: frame.midX + delta.x, y: frame.midY + delta.y)
                    let began = CACurrentMediaTime()
                    let hit = window.hitTest(point, with: nil)
                    hitMilliseconds.append((CACurrentMediaTime() - began) * 1000)
                    XCTAssertFalse(hit is ShutterTouchBackgroundView, "shutter interior passed through: \(kind) \(center) \(delta)")
                    checks += 1
                }
            }
        }
        print("SHUTTER-HIT-TEST checks=\(checks) kinds=2 centers=4 meanHitMilliseconds=\(hitMilliseconds.reduce(0,+) / Double(hitMilliseconds.count)) maxHitMilliseconds=\(hitMilliseconds.max() ?? 0) PhotosWrites=0; UIKit hit-test cost, not frame rate or finger-to-capture latency")
    }

    func testRecoveryPanelFitsSingleAndMultipleItemsOnDevice() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var timings = [Double]()
        var scrollOperations = 0
        for count in [1, 6] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = AstroRecoveryJournal(root: root), store = AstroRecoveryStore(journal: journal)
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            for _ in 0..<count {
                let options = AstroImageOptions(), id = store.begin(kind: "星轨", options: options)
                let _: URL = try await withCheckedThrowingContinuation { continuation in
                    journal.image(id: id, image: image, options: options, final: true) { continuation.resume(with: $0) }
                }
                store.keep(id)
            }
            let deadline = CACurrentMediaTime() + 3
            while store.items.count != count, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(store.items.count, count)
            for angle in [0.0, 90, -90, 180, 0, 90] {
                window.rootViewController = UIHostingController(rootView:
                    AstroRecoveryPanel(store: store, onClose: {}).environment(\.captureControlAngle, angle)
                        .preferredColorScheme(.dark).background(.black))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(100))
                let start = CACurrentMediaTime()
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                timings.append((CACurrentMediaTime() - start) * 1000)
                XCTAssertNotNil(shot.cgImage)
                let scroll = try XCTUnwrap(horizontalScroll(in: window))
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                let cardWidth = max(64, (window.bounds.width - 96) / 3)
                if count == 6 {
                    XCTAssertEqual(scroll.contentSize.width, cardWidth * 6 + 16 * 5 + 40, accuracy: 2)
                    XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width * 1.5)
                    for _ in 0..<3 {
                        scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
                        try await Task.sleep(for: .milliseconds(20))
                        XCTAssertGreaterThan(scroll.contentOffset.x, scroll.bounds.width * 0.5)
                        scroll.setContentOffset(.zero, animated: false)
                        scrollOperations += 2
                    }
                }
                if angle == 180 {
                    let attachment = XCTAttachment(image: shot)
                    attachment.name = "Astro-Recovery-Panel-\(count)-Items"; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            if count == 6 {
                let removed = try XCTUnwrap(store.items.first).id
                store.discard(removed)
                let deadline = CACurrentMediaTime() + 3
                while store.items.count != 5, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(store.items.count, 5)
                XCTAssertFalse(store.items.contains { $0.id == removed })
            }
        }
        print("ASTRO-RECOVERY-UI samples=12 items=1,6 horizontalScrollOperations=\(scrollOperations) discard=1 renderMilliseconds=\(timings); snapshot drawing cost, not FPS; no Photos writes")
    }

    private func horizontalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.width > 0 { return scroll }
        return view.subviews.lazy.compactMap { self.horizontalScroll(in: $0) }.first
    }

    func testNewIconFamilyAcrossSizesAndAngles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = AstroIconState()
        let host = UIHostingController(rootView: AstroIconHarness(state: state))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var timings = [Double]()
        for angle in [0.0, 90, -90, 180] { for size in [22.0, 26.0] { for selected in [false, true] {
            state.angle = angle; state.size = size; state.selected = selected
            try await Task.sleep(for: .milliseconds(40))
            let start = CACurrentMediaTime()
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            timings.append((CACurrentMediaTime() - start) * 1000)
            XCTAssertNotNil(shot.cgImage)
        } } }
        state.angle = 0; state.size = 26; state.selected = true
        try await Task.sleep(for: .milliseconds(100))
        let crop = try XCTUnwrap(state.bounds).insetBy(dx: -24, dy: -24)
        let shot = UIGraphicsImageRenderer(size: crop.size).image { context in
            context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: shot); attachment.name = "Astro-Icons-New-Family"; attachment.lifetime = .keepAlways; add(attachment)
        print("ASTRO-ICON samples=\(timings.count) renderMilliseconds=\(timings) iconsPerSample=3 sizes=22,26 angles=4; snapshot drawing cost, not display FPS")
    }
}

@MainActor private final class AstroIconState: ObservableObject {
    @Published var angle = 0.0
    @Published var size = 26.0
    @Published var selected = false
    var bounds: CGRect?
}
private struct AstroIconHarness: View {
    @ObservedObject var state: AstroIconState
    var body: some View {
        VStack(spacing: 32) {
            Text("星空子模式").font(.headline).foregroundStyle(.white)
            HStack(spacing: 32) {
                ForEach(AstroCaptureMode.allCases) { mode in
                    VStack(spacing: 14) {
                        AstroSubmodeIcon(mode: mode, size: state.size)
                            .foregroundStyle(state.selected ? AppTheme.accent : .white)
                            .rotationEffect(.degrees(state.angle))
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                        Text(mode.rawValue).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.bounds = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
}

private final class ShutterTouchBackgroundView: UIView {}
private struct ShutterTouchBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> ShutterTouchBackgroundView { ShutterTouchBackgroundView() }
    func updateUIView(_ uiView: ShutterTouchBackgroundView, context: Context) {}
}
