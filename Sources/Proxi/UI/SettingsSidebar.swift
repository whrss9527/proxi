import SwiftUI

/// 设置侧栏由两个进程共用外观，选中项不随 NSWindow 失焦变成灰色。
/// 使用显式的行颜色，避开原生 List 由窗口焦点控制的选中高亮。
struct SettingsSidebar<Item: Hashable, Row: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    @ViewBuilder let row: (Item) -> Row
    @State private var hovering: Item?

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(items, id: \.self) { item in
                    Button { selection = item } label: {
                        row(item)
                            .font(.system(size: 13))
                            .foregroundStyle(selection == item ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selection == item ? Color.accentColor : (hovering == item ? Color.primary.opacity(0.06) : Color.clear))
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 ? item : nil }
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                }
            }
            .padding(8)
        }
        .focusable()
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func moveSelection(_ direction: Int) {
        guard !items.isEmpty else { return }
        let current = selection.flatMap { items.firstIndex(of: $0) } ?? (direction > 0 ? -1 : items.count)
        selection = items[min(max(current + direction, 0), items.count - 1)]
    }
}
