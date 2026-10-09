import AppKit

/// 两个进程切换时带上侧栏布局。只同步窗口外框会让分隔线和滚动位置突然跳动。
/// ProxiEngine/UI 中有相同实现，修改时一起更新。
struct SettingsWindowLayout: Codable, Equatable {
    var sidebarWidth: CGFloat
    var scrollY: CGFloat?

    @MainActor
    static func capture(from window: NSWindow) -> SettingsWindowLayout? {
        guard let root = window.contentView,
              let split: NSSplitView = descendant(in: root), split.isVertical,
              let sidebar = split.arrangedSubviews.first else { return nil }
        let scroll: NSScrollView? = descendant(in: sidebar)
        return SettingsWindowLayout(sidebarWidth: sidebar.frame.width, scrollY: scroll?.contentView.bounds.origin.y)
    }

    @MainActor
    func apply(to window: NSWindow) {
        guard sidebarWidth.isFinite, sidebarWidth > 0,
              let root = window.contentView,
              let split: NSSplitView = Self.descendant(in: root), split.isVertical,
              split.arrangedSubviews.count == 2, sidebarWidth < split.bounds.width else { return }
        split.setPosition(sidebarWidth, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        guard let scrollY, scrollY.isFinite,
              let scroll: NSScrollView = Self.descendant(in: split.arrangedSubviews[0]),
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maximum = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        let position = NSPoint(x: clip.bounds.origin.x, y: min(max(scrollY, document.bounds.minY), maximum))
        clip.scroll(to: position)
        scroll.reflectScrolledClipView(clip)
    }

    var notificationInfo: [AnyHashable: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return ["sidebarLayout": data]
    }

    static func decode(_ info: [AnyHashable: Any]?) -> SettingsWindowLayout? {
        guard let data = info?["sidebarLayout"] as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @MainActor
    private static func descendant<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match: T = descendant(in: child) { return match }
        }
        return nil
    }
}
