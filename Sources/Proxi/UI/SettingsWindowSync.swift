import AppKit

/// Proxi 和代理引擎的设置窗口当成同一个窗口用：同一时间只显示一个，从一边切到另一边时在同一个位置、同样大小。
/// 一边的设置窗口显示出来就发一个分布式通知，另一边收到后关掉自己的；窗口位置存在两边共用的偏好设置里。
/// 代理引擎那边有一份一样的（Sources/ProxiEngine/UI/SettingsWindowSync.swift），改的时候一起改。
@MainActor
enum SettingsWindowSync {
    nonisolated private static let notification = Notification.Name("com.whrss9527.proxyswitch.settingsWindowShown")
    /// Proxi 侧边栏里点了代理引擎的某一页：请正在运行的代理引擎打开那一页。
    nonisolated private static let pageRequest = Notification.Name("com.whrss9527.proxyswitch.engineSettingsPage")
    private static let defaults = UserDefaults(suiteName: "com.whrss9527.proxyswitch.shared")
    private static let frameKey = "settingsWindowFrame"
    /// 通知里标明是哪一边发的，自己发的不理。
    nonisolated private static let me = "proxi"
    /// 另一边程序的 bundle identifier。
    nonisolated private static let other = "com.whrss9527.proxyswitch.engine"

    /// 上次两边设置窗口的位置和大小；已经不在任何屏幕上（换了显示器）时不用。
    static func savedFrame() -> NSRect? {
        guard let text = defaults?.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(text)
        guard frame.width >= 300, frame.height >= 200,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    static func save(_ frame: NSRect) {
        defaults?.set(NSStringFromRect(frame), forKey: frameKey)
    }

    /// 要切到另一边（让它打开设置窗口）之前调用。macOS 14 起程序不能自己抢到前台，要由在前台的程序先让出来，
    /// 另一边的窗口出来时才会到前台。
    static func yieldToOther() {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: other)
    }

    /// 从这边的设置窗口切到另一边时打开对方用的配置：前台先让给它，但不让系统马上把它切到前台。
    /// 它这时还只在菜单栏，先到前台再变成普通程序（显示窗口时）会把前台丢掉，系统就把前台交给排在后面的程序（桌面、浏览器……）。
    /// 它的窗口出来以后，这边关窗口时再把前台交过去（见 becomeAccessoryAfterHandoff）。
    static func handOffConfiguration() -> NSWorkspace.OpenConfiguration {
        yieldToOther()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    private final class Handoff {
        var observer: NSObjectProtocol?
        var done = false
    }

    /// 这边的设置窗口因为另一边的设置窗口打开了而关掉：退回只有菜单栏图标（不在 Dock 里）。
    /// 还在前台时先把前台交给另一边，等真的让出去了再退。马上退的话系统会把前台交给别的程序（常常是桌面），
    /// 看起来就是闪一下跳到了桌面。
    static func becomeAccessoryAfterHandoff() {
        // 设置窗口已隐藏，但提示窗口等仍在时保持普通应用身份。
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        guard NSApp.isActive else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: other).first {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current, options: [])
        }
        let handoff = Handoff()
        let finish: @MainActor () -> Void = {
            guard !handoff.done else { return }
            handoff.done = true
            if let observer = handoff.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            // 这期间又打开了设置窗口（或者别的窗口）就不退。
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        handoff.observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { finish() }
        }
        // 另一边一直没到前台（比如它刚好退出了）：两秒后照样退。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { finish() }
        }
    }

    /// 这边的设置窗口显示出来了：让另一边关掉它的。
    static func announceShown() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: me, userInfo: nil, deliverImmediately: true)
    }

    /// Proxi 这边：请代理引擎打开设置窗口的某一页（代理引擎那边 SettingsPage 的 rawValue）。
    static func requestEnginePage(_ page: String) {
        DistributedNotificationCenter.default().postNotificationName(pageRequest, object: page, userInfo: nil, deliverImmediately: true)
    }

    /// 代理引擎这边：收到打开某一页的请求时调用 handler。
    static func observeEnginePageRequests(_ handler: @escaping @MainActor (String) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: pageRequest, object: nil, queue: .main) { note in
            guard let page = note.object as? String else { return }
            MainActor.assumeIsolated { handler(page) }
        }
    }

    /// 另一边的设置窗口显示出来时调用 handler。
    static func observeOtherShown(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard let sender = note.object as? String, sender != me else { return }
            MainActor.assumeIsolated { handler() }
        }
    }
}
