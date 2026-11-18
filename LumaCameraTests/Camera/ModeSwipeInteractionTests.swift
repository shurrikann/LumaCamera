import XCTest
import SwiftUI
@testable import LumaCamera

@MainActor final class ModeSwipeInteractionTests: XCTestCase {
    func testCyclicOrderHysteresisCancellationAndRepeatedGestures() async throws {
        var feedback = 0, selections = [CameraViewModel.TopLevelMode]()
        let state = ModeSwipeState(feedback: { feedback += 1 }, prepare: {})
        for mode in ModeSwipeState.modes {
            XCTAssertEqual(ModeSwipeState.wrapped(mode, offset: 3), mode)
            XCTAssertEqual(ModeSwipeState.wrapped(mode, offset: -3), mode)
            for offset in -100...100 {
                XCTAssertEqual(ModeSwipeState.wrapped(ModeSwipeState.wrapped(mode, offset: offset), offset: -offset), mode)
            }
        }
        var samples = [Double]()
        for _ in 0..<1000 {
            let start = CACurrentMediaTime()
            state.begin(.photo)
            for step in 1...12 { state.move(CGPoint(x: 0, y: -CGFloat(step)*44)) }
            XCTAssertEqual(state.mode(.photo, offset: state.detent), .photo)
            state.reset(); samples.append((CACurrentMediaTime()-start)*1000)
        }
        let before = feedback
        state.begin(.photo); state.move(CGPoint(x: 0, y: -30))
        for _ in 0..<20 { state.move(CGPoint(x: 0, y: -23)); state.move(CGPoint(x: 0, y: -26)) }
        XCTAssertEqual(feedback-before, 1, "Small detent-boundary jitter must not repeat feedback")
        state.end(nil, reduceMotion: true) { selections.append($0) }
        try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(selections.isEmpty)
        var current = CameraViewModel.TopLevelMode.photo
        for direction in [-1, 1] {
            for _ in 0..<9 {
                state.begin(current)
                state.move(CGPoint(x: 0, y: CGFloat(direction)*44))
                let expected = ModeSwipeState.wrapped(current, offset: -direction)
                state.end(CGPoint(x: 0, y: CGFloat(direction)*44), reduceMotion: true) {
                    XCTAssertEqual(state.mode(current, offset: state.detent), $0, "Reduced motion must keep the settled icon on the selected mode")
                    current = $0; selections.append($0)
                }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(current, expected); state.reset()
            }
        }
        XCTAssertEqual(selections.count, 18); XCTAssertEqual(current, .photo)
        state.begin(.photo); state.move(CGPoint(x: 0, y: -44))
        state.end(CGPoint(x: 0, y: -44), reduceMotion: false) { selections.append($0) }; state.reset()
        try await Task.sleep(for: .milliseconds(200)); XCTAssertEqual(selections.count, 18)
        print("MODE-SWIPE handler n=1000 crossings=12000 medianMs=\(samples.sorted()[500]) p95Ms=\(samples.sorted()[950]); CPU handler cost, not FPS/touch latency; cycles=18 cancel=2")
    }

    func testMountedReelKeepsButtonBoundsAndOnlyCommitsOnRelease() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = SwipeHarnessState(), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SwipeHarness(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func surfaces(_ view: UIView) -> [UIView] {
            let own = view.gestureRecognizers?.contains { ($0 as? UIPanGestureRecognizer)?.delegate is ModeSwipeTouchSurface.Coordinator } == true
            return (own ? [view] : [])+view.subviews.flatMap(surfaces)
        }
        var costs = [Double]()
        for angle in [0.0, 90, -90, 180] {
            state.angle = angle
            for mode in ModeSwipeState.modes {
                state.mode = mode
                try await Task.sleep(for: .milliseconds(60))
                let view = try XCTUnwrap(surfaces(window).first)
                let control = try XCTUnwrap(view.gestureRecognizers?.compactMap { ($0 as? UIPanGestureRecognizer)?.delegate as? ModeSwipeTouchSurface.Coordinator }.first)
                let original = try XCTUnwrap(state.frame)
                XCTAssertEqual(original.size, CGSize(width: 52, height: 52))
                XCTAssertEqual(view.bounds.size, CGSize(width: 68, height: 68))
                XCTAssertFalse(view.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } ?? true)
                control.handle(.began, translation: .zero)
                for y in [CGFloat(-12), -24, -44, -66, -88] { control.handle(.changed, translation: CGPoint(x: 0, y: y)) }
                XCTAssertEqual(state.mode, mode, "Dragging previews icons without rebuilding routes")
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(state.frame, original)
                let begin = CACurrentMediaTime()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                costs.append((CACurrentMediaTime()-begin)*1000)
                if angle == 0 {
                    let attachment = XCTAttachment(image: image); attachment.name = "Mode-Swipe-Reel-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                control.handle(.ended, translation: CGPoint(x: 0, y: -88))
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.mode, ModeSwipeState.wrapped(mode, offset: 2))
                control.handle(.began, translation: .zero)
                control.handle(.changed, translation: CGPoint(x: 0, y: 44))
                control.handle(.cancelled, translation: .zero)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.mode, ModeSwipeState.wrapped(mode, offset: 2))
                XCTAssertEqual(state.frame, original)
                let selected = state.mode
                control.handle(.began, translation: .zero)
                control.handle(.changed, translation: CGPoint(x: 0, y: -44))
                state.enabled = false
                try await Task.sleep(for: .milliseconds(40))
                control.handle(.ended, translation: CGPoint(x: 0, y: -44))
                try await Task.sleep(for: .milliseconds(180))
                XCTAssertEqual(state.mode, selected, "Disabling during capture must cancel the pending release")
                state.enabled = true
            }
        }
        print("MODE-SWIPE mounted layouts=12 selections=12 cancellations=12 disabledDuringDrag=12 snapshot_ms=\(costs); drawHierarchy cost only")
    }
}
@MainActor private final class SwipeHarnessState: ObservableObject {
    @Published var mode = CameraViewModel.TopLevelMode.photo
    @Published var angle = 0.0
    @Published var enabled = true
    var frame: CGRect?
}
private struct SwipeHarness: View {
    @ObservedObject var state: SwipeHarnessState
    var body: some View {
        ModeSwitchButton(current: state.mode) { state.mode = $0 }
            .environment(\.captureControlAngle, state.angle)
            .disabled(!state.enabled)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.frame = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.2))
    }
}
