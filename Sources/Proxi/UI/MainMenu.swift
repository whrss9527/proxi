import AppKit

/// 主菜单。程序只在菜单栏运行，平时看不到主菜单，但 ⌘C / ⌘V / ⌘A / ⌘Z 这些快捷键要经它分发到文本框；
/// 设置窗口打开期间程序临时切成普通应用，这时菜单栏里也会显示它。
enum MainMenu {
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Proxi")
        appMenu.addItem(withTitle: L("关于 Proxi"), action: #selector(MenuActions.showAbout(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(withTitle: L("检查更新…"), action: #selector(MenuActions.checkForUpdates(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("网络监控…"), action: #selector(MenuActions.showNetworkMonitor(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(withTitle: L("设置…"), action: #selector(MenuActions.showSettings(_:)), keyEquivalent: ",").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 Proxi"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("退出 Proxi"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("删除"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

/// 主菜单里需要目标对象的动作。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(page: nil)
    }

    @objc func showNetworkMonitor(_ sender: Any?) {
        NetworkMonitorWindowController.shared.show()
    }

    @objc func showAbout(_ sender: Any?) {
        SettingsWindowController.shared.show(page: .about)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        SettingsWindowController.shared.show(page: .about)
        Task { await AppState.shared.updater.check(manual: true) }
    }
}
