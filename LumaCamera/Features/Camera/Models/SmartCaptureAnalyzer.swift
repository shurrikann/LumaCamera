import UIKit
import Vision
import CoreGraphics

enum SmartCaptureSuggestionKind: String, Equatable {
    case backlit, night, portrait
}

struct SmartCompositionGuide: Equatable {
    enum Stage: String, Equatable { case align, compose }
    enum Direction: String, Equatable { case left, right, up, down, closer, farther, align }
    let stage: Stage
    let direction: Direction
    let subject: CGPoint
    let target: CGPoint
    let text: String
    var subjectRect: CGRect = .zero
    enum SubjectKind: Equatable { case face, person, group, salient }
    var subjectKind: SubjectKind = .salient
    var subjectID: UUID?
    var imageAspect: CGFloat = 1
    /// 短暂丢失时可保留显示，但不能用预测/旧位置触发自动取景或对焦。
    var trackingVerified = true
    var preserveSceneContext = false
    static let alignmentRadius: CGFloat = 0.05 // 圈直径为预览短边10%，此值是半径。
    var alignmentDistance: CGFloat {
        let aspect = max(0.01,imageAspect)
        return hypot((subject.x-target.x)*aspect,subject.y-target.y)/min(1,aspect)
    }

    var icon: String {
        switch direction {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .closer: return "plus.magnifyingglass"
        case .farther: return "minus.magnifyingglass"
        case .align: return "scope"
        }
    }
}

struct SmartCaptureParameters: Equatable {
    var mode: PhotoSubmode?
    var portraitBlur: Double?
    var evDelta: Double?
    var hdr: Bool?
}

struct SmartCaptureSuggestion: Equatable {
    let kind: SmartCaptureSuggestionKind
    let title: String
    let actionTitle: String?
    let parameters: SmartCaptureParameters

    var icon: String {
        switch kind {
        case .backlit: return "sun.max.trianglebadge.exclamationmark"
        case .night: return "moon.stars.fill"
        case .portrait: return "person.crop.rectangle"
        }
    }
}

struct SmartCaptureResult: Equatable {
    let suggestion: SmartCaptureSuggestion?
    let composition: SmartCompositionGuide?
    let hasPerson: Bool
    var candidates: [SmartCompositionGuide] = []
}

/// 只由camera.smart-capture串行队列读取/修改；不放在MainActor模型上跨隔离访问。
final class SmartSceneAnalysisState: @unchecked Sendable {
    var context = ""
    var timestamp = -Double.infinity
    var result: SmartCaptureResult?
}

/// Lightweight on-device scene and composition hints. These are rules over
/// Vision/observed luminance, not an aesthetic model.
enum SmartCaptureAnalyzer {
    struct Metrics: Equatable {
        let mean: Double
        let highlights: Double
        let shadows: Double
    }

    static func analyze(image: UIImage,
                        readings: CameraReadings?,
                        activeSubmode: PhotoSubmode?,
                        nominateComposition: Bool = true) -> SmartCaptureResult {
        guard let cgImage = image.cgImage else {
            return SmartCaptureResult(suggestion: nil, composition: nil, hasPerson: false)
        }
        let faces = detectFaces(cgImage)
        let metrics = luminanceMetrics(cgImage)
        let hasPerson = !faces.isEmpty
        // 人脸用于场景判断；取景优先保留人物完整范围，不能把每个人脸都放大到42%。
        let faceRects = faces.map(\.boundingBox)
        var primaryRect: CGRect?, subjectKind: SmartCompositionGuide.SubjectKind = .salient
        if nominateComposition, let face = faceRects.max(by:{ $0.width*$0.height < $1.width*$1.height }), face.height >= 0.10 {
            let request = VNDetectHumanRectanglesRequest(); request.upperBodyOnly = false
            try? VNImageRequestHandler(cgImage:cgImage,orientation:.up,options:[:]).perform([request])
            let people = (request.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
            let matching = people.filter { person in faceRects.contains { person.contains(CGPoint(x:$0.midX,y:$0.midY)) } }
            if faceRects.count > 1 {
                primaryRect = (matching.isEmpty ? faceRects : matching).reduce(CGRect.null) { $0.union($1) }
                subjectKind = .group
            } else if let person = matching.max(by:{ $0.width*$0.height < $1.width*$1.height }) {
                primaryRect = person; subjectKind = .person
            } else { primaryRect = face; subjectKind = .face }
        }
        var candidates:[SmartCompositionGuide] = []
        if let primary = self.composition(for:primaryRect,kind:subjectKind,aspect:CGFloat(cgImage.width)/CGFloat(cgImage.height)) { candidates.append(primary) }
        for rect in nominateComposition ? detectSalientRects(cgImage) : [] {
            guard let candidate = self.composition(for:rect,kind:.salient,aspect:CGFloat(cgImage.width)/CGFloat(cgImage.height)) else { continue }
            if !candidates.contains(where:{ overlap($0.subjectRect,rect) > 0.55 }) { candidates.append(candidate) }
        }
        candidates = Array(candidates.sorted { hypot($0.subject.x-0.5,$0.subject.y-0.5) < hypot($1.subject.x-0.5,$1.subject.y-0.5) }.prefix(3))
        let composition = candidates.first

        let largestFaceHeight = faces.map(\.boundingBox.height).max() ?? 0
        // Humanistic/street scenes often contain small faces in a wider scene.
        // Only promote portrait mode when a face is prominent enough for bokeh
        // to be useful; otherwise leave the scene to composition/HDR guidance.
        let portraitIsUseful = largestFaceHeight >= 0.12 && faces.count <= 3
        let isBacklit = metrics.map { $0.highlights > 0.10 && $0.mean < 0.48 } ?? false
        if !faces.isEmpty, isBacklit, activeSubmode != .portrait {
            let mode: PhotoSubmode? = portraitIsUseful ? .portrait : nil
            return SmartCaptureResult(
                suggestion: SmartCaptureSuggestion(kind: .backlit,
                                                    title: portraitIsUseful ? "人像 · +0.7 EV" : "曝光 · +0.7 EV",
                                                    actionTitle: "应用",
                                                    parameters: SmartCaptureParameters(mode: mode, evDelta: 0.7)),
                composition: composition,
                hasPerson: true,candidates:candidates)
        }
        if !faces.isEmpty, portraitIsUseful, activeSubmode != .portrait {
            return SmartCaptureResult(
                suggestion: SmartCaptureSuggestion(kind: .portrait, title: "人像 · 虚化 55%", actionTitle: "应用",
                                                     parameters: SmartCaptureParameters(mode: .portrait, portraitBlur: 0.55)),
                composition: composition,
                hasPerson: true,candidates:candidates)
        }
        if faces.isEmpty, isBacklit {
            return SmartCaptureResult(
                suggestion: SmartCaptureSuggestion(kind: .backlit, title: "HDR · 保高光", actionTitle: "应用",
                                                     parameters: SmartCaptureParameters(hdr: true)),
                composition: composition,
                hasPerson: false,candidates:candidates)
        }
        if let metrics, metrics.mean < 0.16, activeSubmode != .night {
            return SmartCaptureResult(
                suggestion: SmartCaptureSuggestion(kind: .night, title: "夜景 · 自动", actionTitle: "应用",
                                                     parameters: SmartCaptureParameters(mode: .night)),
                composition: composition,
                hasPerson: hasPerson,candidates:candidates)
        }
        return SmartCaptureResult(suggestion: nil, composition: composition, hasPerson: hasPerson,candidates:candidates)
    }

    private static func composition(for rect: CGRect?, kind:SmartCompositionGuide.SubjectKind,aspect:CGFloat = 1) -> SmartCompositionGuide? {
        guard let rect, rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite else { return nil }
        let center = CGPoint(x: rect.midX, y: 1 - rect.midY)
        let previewCenter = CGPoint(x: 0.5, y: 0.5)
        let distance = hypot((center.x-0.5)*aspect,center.y-0.5)/min(1,aspect)
        let area = rect.width * rect.height
        let touchesEdge = rect.minX < 0.015 || rect.maxX > 0.985
            || rect.minY < 0.015 || rect.maxY > 0.985
        let reliable = area >= 0.006 && rect.width < 0.85 && rect.height < 0.85 && !touchesEdge
        guard reliable else { return nil }
        let aligned = distance <= SmartCompositionGuide.alignmentRadius
        return SmartCompositionGuide(stage: .align, direction: .align,
                                     subject: center, target: previewCenter,
                                     text: aligned ? "已对准中心" : "先对准中心",
                                     subjectRect: rect, subjectKind:kind,imageAspect:aspect)
    }

    /// 将分析输入限制为实际可见画幅，避免1:1/宽画幅外的主体驱动构图。
    static func visibleImage(_ image:UIImage, aspect:CGFloat) -> UIImage? {
        guard let cg = image.cgImage, aspect.isFinite, aspect > 0 else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let cropW = min(width,height*aspect), cropH = min(height,width/aspect)
        guard let cropped = cg.cropping(to:CGRect(x:(width-cropW)/2,y:(height-cropH)/2,width:cropW,height:cropH)) else { return nil }
        let scale = min(1,768/max(cropW,cropH)), size = CGSize(width:cropW*scale,height:cropH*scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in
            UIImage(cgImage:cropped).draw(in:CGRect(origin:.zero,size:size))
        }
    }

    private static func detectFaces(_ image: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.5 }
    }

    /// 多主体来自Vision真实对象框，不在画面里人为添加“可选目标”。
    private static func detectSalientRects(_ image:CGImage) -> [CGRect] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage:image,orientation:.up,options:[:])
        try? handler.perform([request])
        let boxes = (request.results?.first?.salientObjects ?? []).map(\.boundingBox)
        if boxes.contains(where:{ composition(for:$0,kind:.salient) != nil }) { return boxes }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([attention])
        return (attention.results?.first?.salientObjects ?? []).map(\.boundingBox)
    }
    static func overlap(_ a:CGRect,_ b:CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width*intersection.height/max(0.00001,min(a.width*a.height,b.width*b.height))
    }

    static func luminanceMetrics(_ image: CGImage) -> Metrics? {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0, highlights = 0, shadows = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]) / 255, g = Double(pixels[offset + 1]) / 255,
                b = Double(pixels[offset + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sum += luma
            if luma > 0.88 { highlights += 1 }
            if luma < 0.12 { shadows += 1 }
        }
        let count = Double(width * height)
        return Metrics(mean: sum / count, highlights: Double(highlights) / count,
                       shadows: Double(shadows) / count)
    }
}

