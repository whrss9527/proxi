import AppKit
import SwiftUI

/// 等 SwiftUI 更新到本次请求的页面并完成布局，再允许隐藏窗口显现。
/// 窗口取得焦点或 WindowServer 已经登记窗口，都不能证明旧页面已经换掉。
/// ProxiEngine/UI 中有相同实现，修改时一起更新。
struct SettingsPageReady: NSViewRepresentable {
    let revision: UInt
    let onReady: (UInt) -> Void

    func makeNSView(context: Context) -> SettingsPageReadyView {
        SettingsPageReadyView()
    }

    func updateNSView(_ view: SettingsPageReadyView, context: Context) {
        view.configure(revision: revision, onReady: onReady)
    }
}

@MainActor
final class SettingsPageReadyView: NSView {
    private var revision: UInt?
    private var generation: UInt = 0
    private var reported = false
    private var onReady: ((UInt) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(revision: UInt, onReady: @escaping (UInt) -> Void) {
        self.onReady = onReady
        guard self.revision != revision else { return }
        self.revision = revision
        invalidateReport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateReport()
    }

    private func invalidateReport() {
        generation &+= 1
        reported = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard window != nil, let revision, !reported else { return }
        reported = true
        let expected = generation
        // 离开当前布局栈后通知控制器，避免在 SwiftUI 更新视图的中途显现窗口。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.generation == expected else { return }
            self.onReady?(revision)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
