import SwiftUI

struct DetailOverflowAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    var disabled = false
    var destructive = false
    let action: () -> Void
}

/// 顶部详情菜单。使用固定内容宽度而不是系统 Menu 的整行最小宽度。
struct DetailOverflowMenu: View {
    let actions: [DetailOverflowAction]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(actions) { item in
                Button(role: item.destructive ? .destructive : nil) {
                    onDismiss()
                    item.action()
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.destructive ? Color.red.opacity(item.disabled ? 0.38 : 1) :
                                         Color.white.opacity(item.disabled ? 0.34 : 0.92))
                        .padding(.horizontal, 10)
                        .frame(minWidth: 142, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.disabled)
            }
        }
        .padding(6)
        .fixedSize(horizontal: true, vertical: true)
        .modifier(PopupSurface(radius: 18, glass: true))
        .accessibilityElement(children: .contain)
    }
}
