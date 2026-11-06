import SwiftUI

/// 仅成像显示反馈，不修改保存照片；加亮叠加保留黑位，不使用白色蒙层。
struct NightCaptureRevealView: View {
    let state:NightPreviewReveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                picture(state.image,geometry.size)
                picture(state.image,geometry.size)
                    .opacity(min(0.65,max(0,state.progress)*0.65))
                    .blendMode(.plusLighter)
                if let final = state.finalImage {
                    picture(final,geometry.size).transition(.opacity)
                }
            }
            .compositingGroup().clipped()
            .animation(reduceMotion ? .easeInOut(duration:0.1) : .easeInOut(duration:0.65),value:state.progress)
            .animation(reduceMotion ? .easeInOut(duration:0.1) : .easeInOut(duration:0.3),value:state.finalImage != nil)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func picture(_ image:UIImage,_ size:CGSize)->some View {
        Image(uiImage:image).resizable().scaledToFill().frame(width:size.width,height:size.height).clipped()
    }
}
