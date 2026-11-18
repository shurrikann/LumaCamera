import XCTest
import SwiftUI
@testable import LumaCamera

/// Regression coverage for the positions previously occupied by the capsules.
@MainActor final class ModeCapsuleInteractionTests: XCTestCase {
    func testBothCapsulesKeepButtonBoundsAcrossModesAndOrientations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CapsuleLayoutState(), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CapsuleLayoutHarness(state: state)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var baseline: CGRect?
        for angle in [0.0, 90, -90, 180] {
            for mode in ModeSwipeState.modes {
                for submode in AstroCaptureMode.allCases {
                    state.angle = angle; state.mode = mode; state.submode = submode
                    try await Task.sleep(for: .milliseconds(25))
                    let frame = try XCTUnwrap(state.frame)
                    if let baseline { XCTAssertEqual(frame, baseline) } else { baseline = frame }
                    XCTAssertEqual(frame.size, CGSize(width: 180, height: 52))
                }
            }
        }
        print("MODE-REELS layout samples=36 twoButtons=52x52 group=180x52 angles=4 PhotosWrites=0")
    }
    func testBothMountedReelsCycleBothWaysAndCancel() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CapsuleLayoutState(), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CapsuleLayoutHarness(state: state)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func surfaces(_ view: UIView) -> [UIView] {
            let own = view.gestureRecognizers?.contains { ($0 as? UIPanGestureRecognizer)?.delegate is ModeSwipeTouchSurface.Coordinator } == true
            return (own ? [view] : [])+view.subviews.flatMap(surfaces)
        }
        try await Task.sleep(for: .milliseconds(120))
        let controls = surfaces(window).sorted { $0.convert($0.bounds, to: window).midX < $1.convert($1.bounds, to: window).midX }
        XCTAssertEqual(controls.count, 2)
        for (index, control) in controls.enumerated() {
            let coordinator = try XCTUnwrap(control.gestureRecognizers?.compactMap { ($0 as? UIPanGestureRecognizer)?.delegate as? ModeSwipeTouchSurface.Coordinator }.first)
            for direction in [CGFloat(-1), 1] {
                for step in 1...3 {
                    coordinator.handle(.began, translation: .zero)
                    coordinator.handle(.changed, translation: CGPoint(x: 0, y: direction*44))
                    coordinator.handle(.ended, translation: CGPoint(x: 0, y: direction*44))
                    try await Task.sleep(for: .milliseconds(200))
                    let offset = (direction < 0 ? step : -step)
                    if index == 0 { XCTAssertEqual(state.mode, ModeSwipeState.wrapped(.photo, offset: offset)) }
                    else {
                        XCTAssertEqual(state.submode, CyclicModeSwipeState<AstroCaptureMode>.wrapped(.photo, offset: offset, choices: AstroCaptureMode.allCases))
                    }
                    XCTAssertEqual(control.bounds.size, CGSize(width: 68, height: 68))
                }
            }
            coordinator.handle(.began, translation: .zero)
            coordinator.handle(.changed, translation: CGPoint(x: 0, y: -20))
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: snapshot); attachment.name = "Both-Mode-Reels-Mid-Drag-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
            coordinator.handle(.cancelled, translation: .zero)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(state.mode, .photo); XCTAssertEqual(state.submode, .photo)
        }
        print("MODE-REELS mounted=2 cycleSelections=12 cancel=2 snapshots=2 PhotosWrites=0; recognizer callbacks injected")
    }
}
@MainActor private final class CapsuleLayoutState: ObservableObject {
    @Published var mode = CameraViewModel.TopLevelMode.photo
    @Published var submode = AstroCaptureMode.photo
    @Published var angle = 0.0
    var frame: CGRect?
}
private struct CapsuleLayoutHarness: View {
    @ObservedObject var state: CapsuleLayoutState
    var body: some View {
        HStack {
            ModeSwitchButton(current: state.mode) { state.mode = $0 }
            Spacer()
            AstroSubmodeSwitchButton(current: state.submode) { state.submode = $0 }
        }.frame(width: 180, height: 52)
            .environment(\.captureControlAngle, state.angle)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.frame = $0 }
    }
}
