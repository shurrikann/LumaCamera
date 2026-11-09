import UIKit

/// 相机页共用触感发生器。避免每次点击临时创建后立刻释放，导致首次或高负载时丢反馈。
@MainActor
enum CameraHaptics {
    #if DEBUG
    enum FeedbackKind: Equatable { case selection, impact(UIImpactFeedbackGenerator.FeedbackStyle), success }
    static var recorderForTesting: ((FeedbackKind) -> Void)?
    #endif

    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let successGenerator = UINotificationFeedbackGenerator()

    static func prepare() {
        selectionGenerator.prepare()
        lightGenerator.prepare()
        mediumGenerator.prepare()
        successGenerator.prepare()
    }

    static func selectionChanged() {
        #if DEBUG
        recorderForTesting?(.selection)
        #endif
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if DEBUG
        recorderForTesting?(.impact(style))
        #endif
        switch style {
        case .light, .soft:
            lightGenerator.impactOccurred(intensity: style == .soft ? 0.65 : 1)
            lightGenerator.prepare()
        case .medium, .rigid:
            mediumGenerator.impactOccurred(intensity: style == .rigid ? 0.8 : 1)
            mediumGenerator.prepare()
        case .heavy:
            mediumGenerator.impactOccurred(intensity: 1)
            mediumGenerator.prepare()
        @unknown default:
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        }
    }

    static func success() {
        #if DEBUG
        recorderForTesting?(.success)
        #endif
        successGenerator.notificationOccurred(.success)
        successGenerator.prepare()
    }
}
