import AppKit
import Combine
import SwiftUI

/// 菜单栏图标：左键打开面板（或按设置直接开关），右键弹出简洁菜单。面板是一个无边框的毛玻璃浮动窗口。
@MainActor
final class StatusItemController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private var imageCache = StatusImageCache<NSImage>()
    private var appearanceObserver: NSKeyValueObservation?
    private var panel: PanelWindow?
    private var hostingView: NSHostingView<PanelView>?
    private var keyObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateSpeedLabel() }
            }
        }
        // 更新条出现、进度变化时面板高度会变，跟着调整窗口。
        state.updater.$phase
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.resizePanelIfVisible() } }
            .store(in: &cancellables)
        state.speed.onUpdate = { [weak self] in self?.updateSpeedLabel() }
        state.$config
            .map { SpeedLabelSettings(side: $0.speedSide, colorFollowsStatus: $0.speedColorFollowsStatus) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.updateSpeedLabel() } }
            .store(in: &cancellables)
        updateSpeedLabel()
    }

    // MARK: - 图标与网速

    /// 图标右边两行小字：上行、下行。和开关合成一张图，两行文字以开关的中线对齐。
    private func updateSpeedLabel() {
        guard let button = statusItem.button else { return }
        let meter = state.speed
        let iconState = self.iconState
        let layout = SpeedLayout.resolve(side: state.config.speedSide, state: iconState)
        var textColor = labelColor(for: button)
        if state.config.speedColorFollowsStatus, let accent = StatusIcon.speedTextColor(for: iconState, darkMenuBar: isDark(button)) {
            textColor = accent.cgColor
        }
        let key = StatusImageKey(state: iconState,
                                 upload: meter.mode == .none ? nil : SpeedFormatter.compact(bytesPerSecond: meter.upload),
                                 download: meter.mode == .none ? nil : SpeedFormatter.compact(bytesPerSecond: meter.download),
                                 layout: layout, textColor: textColor, appearance: button.effectiveAppearance.name.rawValue)
        let image = imageCache.image(for: key) {
            if let upload = key.upload, let download = key.download {
                return StatusIcon.image(for: iconState, upload: upload, download: download, textColor: textColor, layout: layout)
            }
            return StatusIcon.image(for: iconState)
        }
        if button.image !== image { button.image = image }
        button.imagePosition = .imageOnly
        // 提示里的网速跟着图标一起更新。
        button.toolTip = tooltip + (meter.mode == .none ? "" : "\n↑ \(SpeedFormatter.full(bytesPerSecond: meter.upload))  ↓ \(SpeedFormatter.full(bytesPerSecond: meter.download))")
    }

    /// 菜单栏现在是不是深色（深色模式，或者浅色模式下被桌面衬成深色）。
    private func isDark(_ button: NSStatusBarButton) -> Bool {
        let match = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return match == .darkAqua || match == .vibrantDark
    }

    /// 菜单栏当前外观（深色 / 浅色）下的文字颜色。
    private func labelColor(for button: NSStatusBarButton) -> CGColor {
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        return color
    }

    private var iconState: StatusIconState {
        switch state.status {
        case .on(let profile):
            let color = NSColor(hex: profile.color)
            return state.health == .down ? .warning(color) : .on(color)
        case .external:
            return .external
        case .off:
            return .off
        }
    }

    func updateIcon() {
        updateSpeedLabel()
        if let panel, panel.isVisible {
            resizePanel()
        }
    }

    private var tooltip: String {
        switch state.status {
        case .on(let profile):
            return state.health == .down ? L("Proxi\n已开启：%@\n代理服务器连不上", profile.name) : L("Proxi\n已开启：%@\n%@", profile.name, profile.summary)
        case .external(let description):
            return L("Proxi\n系统代理由其他程序设置\n%@", description)
        case .off(let next):
            if let next {
                return L("Proxi\n已关闭，下次开启：%@", next.name)
            }
            return L("Proxi\n还没有代理配置")
        }
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showContextMenu()
            return
        }
        switch state.config.clickAction {
        case .toggle:
            closePanel()
            state.toggle()
        case .panel:
            togglePanel()
        }
    }

    func perform(_ command: URLCommand) {
        switch command {
        // 开关和切换也经控制接口：和命令行一样受「自动化」里的权限限制，名字也一样可以只写一部分。
        case .turnOn:
            runTool("turn_on", [:])
        case .turnOff:
            runTool("turn_off", [:])
        case .toggle:
            runTool("toggle", [:])
        case .use(let name):
            runTool("use_profile", ["profile": name])
        case .settings(let page):
            SettingsWindowController.shared.show(page: page)
        case .panel:
            openPanel()
        case .update:
            SettingsWindowController.shared.show(page: .about)
            Task { await state.updater.checkAndInstall() }
        case .tool(let name, let params):
            guard ControlCatalog.tool(named: name) != nil else {
                state.notify(title: L("没有这个命令"), body: name, problem: true)
                return
            }
            runTool(name, params)
        }
    }

    /// 经本机控制接口执行（和命令行、AI 助手一样受权限限制）。
    private func runTool(_ name: String, _ params: [String: Any]) {
        Task { @MainActor in
            do {
                let result = try await state.control.call(name, params: params, client: "url")
                if let text = result["text"] as? String {
                    Log.info("URL 命令 \(name)：\(text)")
                }
            } catch {
                state.notify(title: L("命令没有执行"), body: error.localizedDescription, problem: true)
            }
            updateIcon()
        }
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch state.status {
        case .on(let profile):
            menu.addItem(header(L("代理已开启：%@", profile.name)))
            menu.addItem(item(L("关闭代理"), action: #selector(menuTurnOff), key: ""))
        case .external(let description):
            menu.addItem(header(L("系统代理由其他程序设置：%@", description)))
            menu.addItem(item(L("关闭系统代理"), action: #selector(menuTurnOff), key: ""))
            menu.addItem(item(L("保存为配置"), action: #selector(menuSaveExternal), key: ""))
        case .off(let next):
            menu.addItem(header(L("代理已关闭")))
            if next != nil {
                menu.addItem(item(L("开启代理"), action: #selector(menuTurnOn), key: ""))
            }
        }
        if !state.config.profiles.isEmpty {
            menu.addItem(.separator())
            for profile in state.config.profiles {
                let menuItem = item(profile.name, action: #selector(menuUseProfile(_:)), key: "")
                menuItem.representedObject = profile.id.uuidString
                menuItem.image = StatusIcon.dotImage(color: NSColor(hex: profile.color))
                if case .on(let current) = state.status, current.id == profile.id {
                    menuItem.state = .on
                }
                menu.addItem(menuItem)
            }
        }
        menu.addItem(.separator())
        let updater = state.updater
        if let release = updater.release, updater.isInstalling {
            menu.addItem(header(L("正在更新到 %@…", release.version)))
        } else if let release = updater.release {
            menu.addItem(item(L("更新到 %@…", release.version), action: #selector(menuInstallUpdate), key: ""))
        } else {
            menu.addItem(item(L("检查更新…"), action: #selector(menuCheckUpdates), key: ""))
        }
        // 扩展「代理引擎」没有自己的菜单栏图标，它的设置从这里打开。
        if state.persisted.extensionState.enabled {
            menu.addItem(item(L("代理引擎设置…"), action: #selector(menuEngineSettings), key: ""))
        }
        menu.addItem(item(L("设置…"), action: #selector(menuSettings), key: ","))
        menu.addItem(item(L("退出 Proxi"), action: #selector(menuQuit), key: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func header(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func menuTurnOn() {
        if case .off(let next) = state.status, let next { state.turnOn(next) }
    }

    @objc private func menuTurnOff() { state.turnOff() }
    @objc private func menuSaveExternal() { state.saveExternalAsProfile() }
    @objc private func menuSettings() { SettingsWindowController.shared.show(page: nil) }
    @objc private func menuEngineSettings() { state.extensions.showSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuCheckUpdates() {
        SettingsWindowController.shared.show(page: .about)
        Task { await state.updater.check(manual: true) }
    }

    @objc private func menuInstallUpdate() {
        SettingsWindowController.shared.show(page: .about)
        state.updater.install()
    }

    @objc private func menuUseProfile(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let profile = state.config.profile(id: id) else { return }
        state.use(profile)
    }

    // MARK: - 面板

    private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        if panel == nil {
            let view = PanelView(state: state, actions: PanelActions(
                openSettings: { [weak self] page in
                    MainActor.assumeIsolated {
                        self?.closePanel()
                        SettingsWindowController.shared.show(page: page)
                    }
                },
                openEngineSettings: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.closePanel()
                        self?.state.extensions.showSettings()
                    }
                },
                close: { [weak self] in
                    MainActor.assumeIsolated { self?.closePanel() }
                },
                quit: {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                },
                layoutChanged: { [weak self] in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.resizePanelIfVisible() }
                    }
                },
                sizeChanged: { [weak self] size in
                    MainActor.assumeIsolated { self?.resizePanel(to: size) }
                }
            ))
            let hosting = NSHostingView(rootView: view)
            hostingView = hosting
            let panel = PanelWindow(contentView: hosting)
            panel.onClose = { [weak self] in
                MainActor.assumeIsolated { self?.closePanel() }
            }
            self.panel = panel
        }
        guard let panel else { return }
        resizePanel()
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func resizePanelIfVisible() {
        if let panel, panel.isVisible {
            resizePanel()
        }
    }

    private func resizePanel() {
        guard let hostingView else { return }
        resizePanel(to: hostingView.fittingSize)
    }

    /// 顶边不动，按内容尺寸调整窗口。
    private func resizePanel(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let rounded = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded != panel.frame.size else { return }
        let origin = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - rounded.height)
        panel.setFrame(NSRect(origin: origin, size: rounded), display: true)
    }

    private func position(_ panel: PanelWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 6)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }
}

/// 无边框、不激活程序的浮动面板：点到别处或按 Esc 时关闭。
final class PanelWindow: NSPanel {
    var onClose: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

extension StatusIcon {
    /// 菜单里配置的颜色圆点。
    static func dotImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        return image
    }
}

/// 影响网速文字怎么画的设置，变了就重画。
private struct SpeedLabelSettings: Equatable {
    var side: SpeedSide
    var colorFollowsStatus: Bool
}
