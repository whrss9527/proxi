import AppKit

/// 代理引擎：Proxi 的可选扩展，一个单独的程序。由 Proxi 在用户同意说明、开启扩展后下载安装并启动，
/// 平时在后台运行，没有自己的菜单栏图标（菜单栏上只有 Proxi 一个）；它的设置窗口从 Proxi 的菜单、面板和扩展页打开。
/// 系统代理、终端、git 和 npm 仍由 Proxi 的开关设置（Proxi 的配置列表里有一条「代理引擎」）。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Proxi 启动代理引擎并要打开设置时带的参数（已经在运行时 Proxi 发的是「重新打开」，见 applicationShouldHandleReopen）。
    /// 和 Proxi 那边的 ExtensionManager.showSettingsArgument 一样，改的时候一起改。
    static let showSettingsArgument = "--show-settings"
    /// 带在 showSettingsArgument 后面，指定打开哪一页（SettingsPage 的 rawValue）。和 Proxi 那边的 ExtensionManager.settingsPageArgument 一样。
    static let settingsPageArgument = "--settings-page"

    static func main() {
        // 带子命令运行（status、nodes、helper……）时是命令行工具，不启动界面。
        if CommandLineTool.shouldHandle(CommandLine.arguments) {
            exit(CommandLineTool.run(CommandLine.arguments))
        }
        // 同一个用户只运行一个代理引擎。
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !running.isEmpty, Bundle.main.bundleIdentifier == AppInfo.bundleIdentifier {
            running.first?.activate()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 设置窗口打开时也保持后台应用身份，不在 Dock 里显示。
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var signalSources: [DispatchSourceSignal] = []
    private var pageRequestObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        MainMenu.install()
        let state = AppState.shared
        Notifier.shared.start()
        Notifier.shared.onOpen = { _ in
            SettingsWindowController.shared.show(page: nil)
        }
        state.start()
        Log.info("代理引擎已启动，版本 \(UpdateChecker.currentVersion)，数据目录 \(Store.directory.path)")
        // CI 按这一行确认界面语言（sample 是菜单里「设置…」的译文）。
        Log.info("界面语言 english=\(AppLanguage.isEnglish) sample=\"\(L("设置…"))\"")
        // Proxi 的侧边栏里点了这边的某一页：运行中时经分布式通知打开那一页，刚启动时经启动参数。
        pageRequestObserver = SettingsWindowSync.observeEnginePageRequests { page in
            SettingsWindowController.shared.show(page: SettingsPage(rawValue: page))
        }
        if CommandLine.arguments.contains(Self.showSettingsArgument) {
            SettingsWindowController.shared.show(page: Self.requestedPage(CommandLine.arguments))
        } else if ProcessInfo.processInfo.environment["PROXI_ENGINE_SHOW_SETTINGS"] == "1" {
            SettingsWindowController.shared.show(page: .nodes)
        }
    }

    /// 启动参数里 settingsPageArgument 后面的那一页。
    static func requestedPage(_ arguments: [String]) -> SettingsPage? {
        guard let index = arguments.firstIndex(of: settingsPageArgument), index + 1 < arguments.count else { return nil }
        return SettingsPage(rawValue: arguments[index + 1])
    }

    /// 再次打开程序（Proxi 的菜单、面板或扩展页里点「代理引擎设置…」、Finder 里双击）时打开设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(page: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.handleExit()
        Log.info("代理引擎已退出")
        Log.flush()
    }

    /// kill、logout 这类信号也走正常退出：停内核。
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
