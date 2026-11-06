import SwiftUI

/// 真实时间累积的预览关键帧交叉淡化；只影响预览画面，不拦截按钮。
struct SlowShutterAccumulationView:View {
    let state:SlowShutterAccumulationPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage:state.image).resizable().scaledToFill()
                    .frame(width:geometry.size.width,height:geometry.size.height).clipped()
                    .id(state.revision).transition(.opacity)
            }.clipped()
                .animation(.easeInOut(duration:reduceMotion ? 0.08:0.22),value:state.revision)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
