import CoreImage

/// Preview-only quarter turns. Captured photo orientation remains unchanged.
enum PreviewRotation {
    static func image(_ source: CIImage, quarterTurns: Int) -> CIImage {
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return source.oriented(.right)
        case 2: return source.oriented(.down)
        case 3: return source.oriented(.left)
        default: return source
        }
    }
    /// Inverse rotation in top-left normalized display coordinates.
    static func sourcePoint(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return CGPoint(x: point.y, y: 1 - point.x)
        case 2: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return CGPoint(x: 1 - point.y, y: point.x)
        default: return point
        }
    }
}
