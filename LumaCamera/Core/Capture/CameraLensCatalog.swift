import AVFoundation

/// Uses the system virtual-camera thresholds to label its physical constituent cameras accurately.
enum CameraLensCatalog {
    static func preferredVirtualRearCamera() -> AVCaptureDevice? {
        [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            .compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
    }
    static func displayMultiplier(_ device: AVCaptureDevice) -> CGFloat {
        guard device.isVirtualDevice else { return 1 }
        if #available(iOS 18, *) { return device.displayVideoZoomFactorMultiplier }
        let factors = [CGFloat(1)] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        guard let wide = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), factors.indices.contains(wide) else { return 1 }
        return 1 / factors[wide]
    }

    static func rearLenses(_ devices: [AVCaptureDevice]) -> [CameraLens] {
        guard let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return [] }
        var baseZooms: [String: CGFloat] = [:]
        let virtual = [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            .compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
        if let virtual {
            let constituents = virtual.constituentDevices
            let transitions = virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let factors = [CGFloat(1)] + transitions
            if factors.count == constituents.count,
               let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) {
                let multiplier: CGFloat
                if #available(iOS 18, *) { multiplier = virtual.displayVideoZoomFactorMultiplier }
                else { multiplier = 1 / factors[wideIndex] }
                for (index, camera) in constituents.enumerated() { baseZooms[camera.uniqueID] = factors[index] * multiplier }
            }
        }
        let cameras = devices.map { device -> LensZoomCapabilities in
            let base: CGFloat
            if let systemBase = baseZooms[device.uniqueID] { base = systemBase }
            else if device.deviceType == .builtInWideAngleCamera { base = 1 }
            else {
                let wideAngle = Double(wide.activeFormat.videoFieldOfView) * .pi / 360
                let angle = Double(device.activeFormat.videoFieldOfView) * .pi / 360
                base = CGFloat(tan(wideAngle) / tan(angle))
            }
            return LensZoomCapabilities(id: device.uniqueID, baseZoom: base,
                minimum: device.minAvailableVideoZoomFactor, maximum: device.maxAvailableVideoZoomFactor,
                nativeFactors: device.activeFormat.secondaryNativeResolutionZoomFactors)
        }
        var targets: [CGFloat] = [1, 2, 4, 8]
        targets.append(contentsOf: cameras.map(\.baseZoom))
        var result: [CameraLens] = []
        for target in targets.sorted() {
            guard !result.contains(where: { abs($0.displayZoom - target) < 0.05 }),
                  let choice = CameraZoomPolicy.select(target, from: cameras, nativeOnly: false),
                  let device = devices.first(where: { $0.uniqueID == choice.id }) else { continue }
            let number = abs(target - target.rounded()) < 0.05 ? String(Int(target.rounded())) : String(format: "%.1f", Double(target))
            result.append(CameraLens(device: device, title: number + "×", zoomFactor: choice.factor, displayZoom: target, isNative: choice.native))
        }
        return result
    }
}
