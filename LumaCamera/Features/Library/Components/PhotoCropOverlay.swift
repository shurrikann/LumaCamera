import SwiftUI

struct PhotoCropOverlay: View {
    @Binding var crop: PhotoCropRectangle
    @State private var dragOrigin: PhotoCropRectangle?
    @State private var resizeOrigin: PhotoCropRectangle?
    @State private var scaleOrigin: PhotoCropRectangle?
    var body: some View {
        GeometryReader { geometry in
            let value = crop.clamped
            let rect = CGRect(x: value.x*geometry.size.width, y: value.y*geometry.size.height, width: value.width*geometry.size.width, height: value.height*geometry.size.height)
            ZStack(alignment: .topLeading) {
                Path { path in path.addRect(CGRect(origin: .zero, size: geometry.size)); path.addRect(rect) }
                    .fill(.black.opacity(0.48), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).overlay(Rectangle().stroke(.white, lineWidth: 1.5))
                    .overlay {
                        Path { path in
                            for index in 1...2 {
                                let x = rect.width*CGFloat(index)/3, y = rect.height*CGFloat(index)/3
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
                            }
                        }.stroke(.white.opacity(0.45), lineWidth: 0.5).allowsHitTesting(false)
                    }
                    .frame(width: rect.width, height: rect.height).contentShape(Rectangle())
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        if dragOrigin == nil { dragOrigin = value }
                        crop = (dragOrigin ?? value).moved(CGSize(width: drag.translation.width/max(1,geometry.size.width), height: drag.translation.height/max(1,geometry.size.height)))
                    }.onEnded { _ in dragOrigin = nil })
                ForEach(0..<4, id: \.self) { corner in
                    Circle().fill(AppTheme.accent).frame(width: 12, height: 12).frame(width: 36, height: 36).contentShape(Rectangle())
                        .position(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
                        .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            if resizeOrigin == nil { resizeOrigin = value }
                            crop = (resizeOrigin ?? value).resized(corner: corner, delta: CGSize(width: drag.translation.width/max(1,geometry.size.width), height: drag.translation.height/max(1,geometry.size.height)))
                        }.onEnded { _ in resizeOrigin = nil })
                }
            }.simultaneousGesture(MagnifyGesture().onChanged { gesture in
                if scaleOrigin == nil { scaleOrigin = value }
                crop = (scaleOrigin ?? value).scaled(gesture.magnification)
            }.onEnded { _ in scaleOrigin = nil })
        }.accessibilityLabel("裁剪选区，拖动边角调整范围")
    }
}
