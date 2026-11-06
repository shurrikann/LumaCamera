import Foundation

/// Keep the active aspect ratio exactly, using even dimensions bounded for live filtering.
enum PreviewBufferConfiguration {
    static func dimensions(width: Int, height: Int, longestEdge: Int = 1280) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, longestEdge >= 2 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b,a % b) }
        let divisor = gcd(width,height), unitWidth = width/divisor, unitHeight = height/divisor
        let units = min(divisor, longestEdge/max(unitWidth,unitHeight))/2*2
        // If an exact even size cannot fit, leave dimensions to AVFoundation.
        guard units >= 2 else { return nil }
        return (unitWidth*units,unitHeight*units)
    }
}
