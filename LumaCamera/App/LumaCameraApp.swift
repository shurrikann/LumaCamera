import SwiftUI
import UIKit

@main
struct LumaCameraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controlOrientation = CaptureControlOrientation()
    @StateObject private var cameraModel: CameraViewModel

    init() {
        #if DEBUG
        let isTesting = NSClassFromString("XCTestCase") != nil
        let model = AppDependencies.makeCameraModel(filterSettings: FilterSettingsStore(defaults: isTesting ? nil : .standard),
                                                    preferencesStore: isTesting ? CapturePreferencesStore(defaults: nil) : nil)
        #else
        let model = AppDependencies.makeCameraModel(filterSettings: FilterSettingsStore(defaults: .standard))
        #endif
        _cameraModel = StateObject(wrappedValue: model)
        #if DEBUG
        AppDependencies.runningAppCameraModel = model
        #endif
    }

    var body: some Scene {
        WindowGroup {
            CameraView(model: cameraModel).preferredColorScheme(.dark)
                .environment(\.captureControlAngle, controlOrientation.degrees)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                    if phase != .active { cameraModel.flushFilterSettings() }
                }
        }
    }
}
