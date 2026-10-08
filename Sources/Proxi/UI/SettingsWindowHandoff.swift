import AppKit
import QuartzCore

/// 两个设置窗口交接时，旧窗口保留失焦前的画面，新窗口取得焦点后才显现。
/// SwiftUI 的 appearsActive 不控制原生标题栏、控件和材质的失焦绘制。
/// ProxiEngine/UI 中有相同实现，修改时一起更新。
@MainActor
final class SettingsWindowHandoff {
    private weak var window: NSWindow?
    private var cover: NSView?
    private var timeout: DispatchWorkItem?
    private var generation: UInt = 0
    private var pendingPresentation: UInt?
    private let onTimeout: () -> Void

    init(window: NSWindow, onTimeout: @escaping () -> Void = {}) {
        self.window = window
        self.onTimeout = onTimeout
    }

    /// 在让出激活权之前调用；覆盖整个框架视图，标题栏也不能先变成失焦外观。
    func freeze() {
        cancel()
        guard let window, window.isVisible,
              let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(bitmap)
        let cover = HandoffCover(frame: frameView.bounds, image: image)
        cover.autoresizingMask = [.width, .height]
        frameView.addSubview(cover, positioned: .above, relativeTo: nil)
        cover.displayIfNeeded()
        self.cover = cover
        armTimeout()
    }

    /// 窗口可以先取得键盘焦点，但尚未激活时不把它的非激活外观显示出来。
    @discardableResult
    func beginShowing() -> UInt {
        cancel()
        pendingPresentation = generation
        if let window, !window.isVisible {
            window.alphaValue = 0
        }
        armTimeout()
        return generation
    }

    /// 过期或重复的回调不能把新一轮交接中的窗口显现出来，也不能通知对方隐藏。
    func finishShowing(_ request: UInt, applicationIsActive: Bool) -> Bool {
        guard pendingPresentation == request, let window,
              window.isVisible, window.isKeyWindow, applicationIsActive else { return false }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        window.alphaValue = 1
        pendingPresentation = nil
        timeout?.cancel()
        timeout = nil
        return true
    }

    /// 对方已显示、用户选择本地页面或关闭窗口时清理；失败时不能留下冻结的界面。
    func cancel() {
        generation &+= 1
        pendingPresentation = nil
        timeout?.cancel()
        timeout = nil
        cover?.removeFromSuperview()
        cover = nil
        if let window, window.alphaValue == 0 {
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    private func armTimeout() {
        let expected = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else { return }
                self.cancel()
                self.onTimeout()
            }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// 仅保留过渡画面，不截走鼠标、键盘或无障碍交互。
@MainActor
private final class HandoffCover: NSView {
    private let image: NSImage

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }
}
