import SwiftUI

extension CameraView {
    /// 自动取景期间只显示候选范围，不拦截触控，也不再要求点“应用倍率”。
    func smartFramingOverlay(_ recommendation: SmartFramingRecommendation) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius:2,style:.continuous)
                .stroke(.white.opacity(0.8),style:StrokeStyle(lineWidth:1.2,dash:[6,4]))
                .frame(width:geometry.size.width*min(1,recommendation.cropScale),
                       height:geometry.size.height*min(1,recommendation.cropScale))
                .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
