import Foundation

/// 场景建议的能力边界与显示保持一致；需要降规格时先在用户点按的按钮旁写清。
enum SmartCaptureSuggestionPolicy {
    static func presented(_ suggestion:SmartCaptureSuggestion?,format:PhotoFileFormat,resolution:PhotoResolution,
                          available:Set<PhotoFileFormat>) -> SmartCaptureSuggestion? {
        guard let suggestion else { return nil }
        var title = suggestion.title, action = suggestion.actionTitle
        // 夜景拍照功能已取消：任何来源的夜景建议都不能进入横幅。
        if suggestion.kind == .night || suggestion.parameters.mode == .night {
            return nil
        } else if suggestion.parameters.hdr == true && format != .heif && format != .heifPro {
            // 无人物的高反差画面不能仅为替代HDR而盲目加曝光，避免窗外进一步过曝。
            title = "高反差 · 可用 HEIF HDR"; action = nil
        }
        return SmartCaptureSuggestion(kind:suggestion.kind,title:title,actionTitle:action,parameters:suggestion.parameters)
    }
}
