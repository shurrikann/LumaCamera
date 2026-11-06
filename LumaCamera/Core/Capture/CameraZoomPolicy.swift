import Foundation

struct LensZoomCapabilities {
    let id: String
    let baseZoom: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let nativeFactors: [CGFloat]
}

struct LensZoomSelection {
    let id: String
    let factor: CGFloat
    let native: Bool
}

/// Resolve a displayed magnification to the best physical camera without losing manual controls.
enum CameraZoomPolicy {
    static func selectContinuous(_ zoom: CGFloat, from capabilities: [LensZoomCapabilities], currentID: String?) -> LensZoomSelection? {
        guard let choice = select(zoom, from: capabilities) else { return nil }
        if let current = capabilities.first(where: { $0.id == currentID }),
           let preferred = capabilities.first(where: { $0.id == choice.id }),
           preferred.baseZoom > current.baseZoom, zoom < preferred.baseZoom * 1.06 {
            let factor = zoom / current.baseZoom
            if factor >= current.minimum && factor <= current.maximum {
                return LensZoomSelection(id: current.id, factor: factor, native: ([CGFloat(1)] + current.nativeFactors).contains { abs($0 - factor) < 0.001 })
            }
        }
        return choice
    }

    static func select(_ zoom: CGFloat, from capabilities: [LensZoomCapabilities], nativeOnly: Bool = false) -> LensZoomSelection? {
        let candidates = capabilities.sorted { $0.baseZoom > $1.baseZoom }.compactMap { camera -> LensZoomSelection? in
            guard camera.baseZoom > 0 else { return nil }
            let factor = zoom / camera.baseZoom
            guard factor >= camera.minimum - 0.0001, factor <= camera.maximum else { return nil }
            let native = ([CGFloat(1)] + camera.nativeFactors).contains { abs($0 - factor) < 0.001 }
            return LensZoomSelection(id: camera.id, factor: max(camera.minimum, factor), native: native)
        }
        return candidates.first(where: \.native) ?? (nativeOnly ? nil : candidates.first)
    }
}
