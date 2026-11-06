import AVFoundation

enum WhiteBalanceSafety {
    static func validated(_ gains: AVCaptureDevice.WhiteBalanceGains, maximum: Float) -> AVCaptureDevice.WhiteBalanceGains? {
        guard maximum.isFinite, maximum >= 1,
              [gains.redGain, gains.greenGain, gains.blueGain].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= maximum }) else { return nil }
        return gains
    }
    static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, maximum: Float) -> AVCaptureDevice.WhiteBalanceGains? {
        guard maximum.isFinite, maximum >= 1,
              [gains.redGain, gains.greenGain, gains.blueGain].allSatisfy(\.isFinite) else { return nil }
        return .init(redGain: min(max(1, gains.redGain), maximum), greenGain: min(max(1, gains.greenGain), maximum), blueGain: min(max(1, gains.blueGain), maximum))
    }
}
