import AVFoundation

struct CameraReadings {
    let iso: Double
    let seconds: Double
    let kelvin: Double
    let focus: Double
    var tint: Double? = nil
    var adjustingFocus = false
    var customExposure = false
    var exposureTargetOffsetEV: Double? = nil
    var sampleHostTime: Double? = nil
    var recommendationFocusPosition: Double? = nil
    var recommendationFocusDeviceID: String? = nil

    var validated: CameraReadings? {
        guard iso.isFinite, iso > 0, seconds.isFinite, seconds > 0,
              focus.isFinite, (0...1).contains(focus) else { return nil }
        return CameraReadings(iso: iso, seconds: seconds, kelvin: kelvin.isFinite && kelvin > 0 ? kelvin : 0, focus: focus, tint: tint.flatMap { $0.isFinite ? $0 : nil }, adjustingFocus: adjustingFocus,
            customExposure:customExposure,exposureTargetOffsetEV:exposureTargetOffsetEV.flatMap { $0.isFinite ? $0:nil },
            sampleHostTime:sampleHostTime.flatMap { $0.isFinite ? $0:nil },
            recommendationFocusPosition:recommendationFocusPosition.flatMap { $0.isFinite && (0...1).contains($0) ? $0:nil },
            recommendationFocusDeviceID:recommendationFocusDeviceID)
    }

    func forDisplay(frameGeneration: UInt64, currentGeneration: UInt64, running: Bool) -> CameraReadings? {
        guard running, frameGeneration == currentGeneration else { return nil }
        return validated
    }
}

enum FrontCameraFraming: Equatable { case standard, wide }

enum FrontCameraFramingPolicy {
    static func target(isLandscape: Bool) -> FrontCameraFraming {
        isLandscape ? .wide : .standard
    }
}

struct CameraLens: Identifiable {
    let device: AVCaptureDevice
    let title: String
    var zoomFactor: CGFloat = 1
    var displayZoom: CGFloat = 1
    var isNative = true
    var frontFraming: FrontCameraFraming? = nil
    var id: String { device.uniqueID + ":" + String(format: "%.4f", Double(zoomFactor)) }
    var accessibilityDescription: String {
        title + (device.position == .front ? "前置镜头" : isNative ? "，原生焦段" : "，系统数字变焦")
    }
}

