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

    static func saveSidebarLayout(_ layout: SettingsWindowLayout?) {
        guard let layout, let data = try? JSONEncoder().encode(layout) else { return }
        defaults?.set(data, forKey: "settingsSidebarLayout")
    }

    static func savedSidebarLayout() -> SettingsWindowLayout? {
        guard let data = defaults?.data(forKey: "settingsSidebarLayout") else { return nil }
        return try? JSONDecoder().decode(SettingsWindowLayout.self, from: data)
    }

    /// 要切到另一边（让它打开设置窗口）之前调用。macOS 14 起程序不能自己抢到前台，要由在前台的程序先让出来，
    /// 另一边的窗口出来时才会到前台。
    static func yieldToOther() {
        SettingsWindowController.shared.prepareToHandOff()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: other)
    }

    /// 从这边的设置窗口切到另一边时打开对方用的配置：前台先让给它，但不让系统马上把它切到前台。
    /// 对方保持菜单栏应用身份，准备好窗口后激活；取得焦点并画好首帧再通知这边隐藏。
    static func handOffConfiguration() -> NSWorkspace.OpenConfiguration {
        yieldToOther()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    /// 这边的设置窗口显示出来了：让另一边关掉它的。
    static func announceShown() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: me, userInfo: nil, deliverImmediately: true)
    }

    // 已运行的 Proxi 直接接收页面请求，避免 Launch Services 重新打开事件重置页面。
    nonisolated private static let proxiPageRequest = Notification.Name("com.whrss9527.proxyswitch.proxiSettingsPage")

    static func requestProxiPage(_ page: String) {
        DistributedNotificationCenter.default().postNotificationName(proxiPageRequest, object: page, userInfo: SettingsWindowController.shared.outgoingLayout?.notificationInfo, deliverImmediately: true)
    }

    static func observeProxiPageRequests(_ handler: @escaping @MainActor (String, SettingsWindowLayout?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: proxiPageRequest, object: nil, queue: .main) { note in
            guard let page = note.object as? String else { return }
            MainActor.assumeIsolated { handler(page, SettingsWindowLayout.decode(note.userInfo)) }
        }
    }

    /// Proxi 这边：请代理引擎打开设置窗口的某一页（代理引擎那边 SettingsPage 的 rawValue）。
    static func requestEnginePage(_ page: String) {
        DistributedNotificationCenter.default().postNotificationName(pageRequest, object: page, userInfo: SettingsWindowController.shared.outgoingLayout?.notificationInfo, deliverImmediately: true)
    }

    /// 代理引擎这边：收到打开某一页的请求时调用 handler。
    static func observeEnginePageRequests(_ handler: @escaping @MainActor (String, SettingsWindowLayout?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: pageRequest, object: nil, queue: .main) { note in
            guard let page = note.object as? String else { return }
            MainActor.assumeIsolated { handler(page, SettingsWindowLayout.decode(note.userInfo)) }
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
