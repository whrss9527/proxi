import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // 带子命令运行（proxi status、proxi mcp……）时是命令行工具，不启动界面。
        if CommandLineTool.shouldHandle(CommandLine.arguments) {
            exit(CommandLineTool.run(CommandLine.arguments))
        }
        // 改名后第一次启动：先把旧的数据目录挪过来（在写任何日志之前），程序本身还叫 ProxySwitch.app 时改名后重新打开。
        if Store.migrateLegacyDirectory() {
            Log.info("数据目录已从 \(Store.legacyDirectory.path) 挪到 \(Store.directory.path)")
        }
        if BundleRename.renameIfNeeded(loginItemEnabled: { LoginItem.isEnabled }) {
            Log.flush()
            exit(0)
        }
        // 设置里改了界面语言、点「立即重新启动」打开的新实例：先等旧的退出，再建菜单栏图标。
        LanguageSetting.waitForPreviousInstance(arguments: ProcessInfo.processInfo.arguments)
        _ = LanguageSetting.atLaunch
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 只有菜单栏图标，不在 Dock 里显示。
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []
    private var settingsPageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        if UserDefaults.standard.bool(forKey: BundleRename.loginItemKey) {
            UserDefaults.standard.removeObject(forKey: BundleRename.loginItemKey)
            LoginItem.reregister()
        }
        DispatchQueue.global(qos: .utility).async {
            CommandLineInstaller.repairIfPossible()
        }
        MainMenu.install()
        settingsPageObserver = SettingsWindowSync.observeProxiPageRequests { page, layout in
            guard let page = SettingsPage(rawValue: page) else { return }
            SettingsWindowController.shared.show(page: page, layout: layout)
        }
        let state = AppState.shared
        Notifier.shared.start()
        Notifier.shared.onOpen = { route in
            SettingsWindowController.shared.show(page: route == "about" ? SettingsPage.about : SettingsPage.profiles)
        }
        // 通知上的「立即更新」：直接下载安装，进度在关于页和面板里。
        Notifier.shared.onAction = { action in
            guard action == Notifier.installUpdateAction else { return }
            SettingsWindowController.shared.show(page: .about)
            Task { await AppState.shared.updater.checkAndInstall() }
        }
        let controller = StatusItemController(state: state)
        statusController = controller
        state.onStatusChanged = { [weak controller] in controller?.updateIcon() }
        state.start()
        controller.updateIcon()
        Log.info("Proxi 已启动，版本 \(UpdateChecker.currentVersion)")
        // 日志也记录界面语言，便于人工诊断；CI 通过状态接口确认实际语言。
        Log.info("界面语言 english=\(AppLanguage.isEnglish) setting=\(LanguageSetting.current.rawValue) sample=\"\(L("设置…"))\"")
        // 还没有任何配置（第一次打开）时显示新手引导；已经有配置的不显示。
        if state.config.profiles.isEmpty {
            OnboardingWindowController.shared.show(state: state)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let command = URLCommand.parse(url) {
                statusController?.perform(command)
            } else {
                Log.error("不认识的命令：\(url)")
            }
        }
    }

    /// 再次打开程序（Finder 里双击、Dock 里点击）时打开设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(page: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.handleExit()
        Log.info("Proxi 已退出")
    }

    /// kill、logout 这类信号也走正常退出（按设置关代理）。
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
