import CoreGraphics

/// Pre-capture framing recommendation: the visible crop frame and the zoom
/// that would make that crop fill the preview. Applying it never captures or
/// post-processes a photo.
struct SmartFramingRecommendation: Equatable {
    let zoom: CGFloat
    let cropScale: CGFloat
    var label: String { String(format: "应用 %.1f×", Double(zoom)) }

    /// A subject should occupy roughly 42% of the preview height. Returns nil
    /// when the current framing is already close enough or the zoom cannot be
    /// meaningfully changed.
    static func make(subjectHeight: CGFloat, currentZoom: CGFloat,
                     maxZoom: CGFloat) -> SmartFramingRecommendation? {
        guard subjectHeight > 0, currentZoom > 0, maxZoom >= currentZoom else { return nil }
        let desired = currentZoom * (0.42 / subjectHeight)
        let zoom = min(max(desired, 1), maxZoom)
        guard desired >= 1.12, zoom - currentZoom >= 0.12 else { return nil }
        return SmartFramingRecommendation(zoom: zoom, cropScale: currentZoom / zoom)
    }
    /// 变焦围绕画面中心进行，主体原有的微小偏移也会放大；焦点需投影到新取景。
    static func focusPoint(for guide:SmartCompositionGuide,from currentZoom:CGFloat,to targetZoom:CGFloat) -> CGPoint {
        let box = guide.subjectRect.intersection(CGRect(x:0,y:0,width:1,height:1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return focusPoint(guide.subject,from:currentZoom,to:targetZoom) }
        // 纹理点靠近检测框边缘时向内部留12%，降低AF窗口同时覆盖前后景的概率。
        let inner = box.insetBy(dx:box.width*0.12,dy:box.height*0.12)
        let safe = CGPoint(x:min(max(guide.subject.x,inner.minX),inner.maxX),
                           y:min(max(guide.subject.y,1-inner.maxY),1-inner.minY))
        return focusPoint(safe,from:currentZoom,to:targetZoom)
    }
    static func focusPoint(_ source:CGPoint,from currentZoom:CGFloat,to targetZoom:CGFloat) -> CGPoint {
        guard currentZoom > 0, currentZoom.isFinite, targetZoom.isFinite else { return CGPoint(x:0.5,y:0.5) }
        let scale = targetZoom/currentZoom
        return CGPoint(x:min(1,max(0,0.5+(source.x-0.5)*scale)),y:min(1,max(0,0.5+(source.y-0.5)*scale)))
    }

}
