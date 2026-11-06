import Foundation

/// 流水将单帧曝光与采集持续时间分开；亮度由真实测光曝光量决定，虚化由时间采样决定。
struct AdaptiveWaterExposurePlan: Equatable {
    let iso: Double
    let seconds: Double
    let duration: Double
    let maximumFrames: Int
}

enum AdaptiveWaterExposurePolicy {
    static func plan(meteredISO: Double, meteredSeconds: Double, isoRange: ClosedRange<Double>,
                     shutterRange: ClosedRange<Double>, manualISO: Double? = nil,
                     manualSeconds: Double? = nil,
                     preferredMaximumSeconds: Double? = nil) -> AdaptiveWaterExposurePlan? {
        let minimum = pow(2,shutterRange.lowerBound), maximum = min(1,pow(2,shutterRange.upperBound))
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum,
              isoRange.lowerBound.isFinite, isoRange.upperBound.isFinite, isoRange.lowerBound > 0 else { return nil }
        if let manualISO, let manualSeconds {
            guard manualISO.isFinite, manualSeconds.isFinite, isoRange.contains(manualISO),
                  manualSeconds >= minimum, manualSeconds <= maximum else { return nil }
            return .init(iso:manualISO,seconds:manualSeconds,duration:8,maximumFrames:64)
        }
        guard meteredISO.isFinite, meteredSeconds.isFinite, meteredISO > 0, meteredSeconds > 0 else { return nil }
        let exposure = meteredISO * meteredSeconds
        guard exposure.isFinite else { return nil }
        // 原生包围出片实测会归并不规则时长及最低ISO的元数据；使用常见档位，
        // 在约0.2EV内匹配测光曝光量，再偏好较低ISO，不把任意小数当作已精确应用。
        let secondsValues = [64000.0,32000,16000,8000,4000,2000,1000,500,250,125,60,30,15,8,4,2,1]
            .map { 1/$0 }.filter { $0 >= minimum && $0 <= maximum }
        let isoValues = [50.0,64,80,100,125,160,200,250,320,400,500,640,800,1000,1250,1600,2000,2500,3200,4000,5000,6400,8000,10000,12800,16000,20000,25600,32000,40000,51200,64000,128000]
            .filter(isoRange.contains)
        var best: (iso:Double,seconds:Double,score:Double)?
        for seconds in secondsValues {
            for iso in isoValues {
                let error = abs(log2(iso*seconds/exposure))
                guard error <= 0.2 else { continue }
                // 流水默认按手持设计：亮度允许时宁可提高少量 ISO，也优先缩短单帧，
                // 减少光学防抖无法消除的帧内拖影；极暗环境仍可放宽以保证能拍。
                let handheldPenalty = preferredMaximumSeconds.map {
                    max(0, log2(seconds / max(minimum, $0))) * 2
                } ?? 0
                let score = error + log2(iso/isoRange.lowerBound)*0.04 + handheldPenalty
                if score < best?.score ?? .infinity { best = (iso,seconds,score) }
            }
        }
        guard let best else { return nil }
        return .init(iso:best.iso,seconds:best.seconds,duration:8,maximumFrames:64)
    }
}
