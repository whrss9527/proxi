import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case profiles
    case automation
    case general
    case hotkey
    case sync
    case extensions
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: return L("代理配置")
        case .automation: return L("自动化")
        case .general: return L("通用")
        case .hotkey: return L("快捷键")
        case .sync: return L("iCloud 同步")
        case .extensions: return L("扩展")
        case .diagnostics: return L("诊断")
        case .about: return L("关于")
        }
    }

    var symbol: String {
        switch self {
        case .profiles: return "point.3.connected.trianglepath.dotted"
        case .automation: return "wand.and.stars"
        case .general: return "gearshape"
        case .hotkey: return "keyboard"
        case .sync: return "icloud"
        case .extensions: return "puzzlepiece.extension"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .profiles
    @Published var selectedProfileID: UUID?
}

/// 扩展「代理引擎」设置窗口的各页。扩展开着时和 Proxi 自己的页平铺在同一个侧边栏里，点了切到代理引擎的设置窗口
/// （同一个位置、同样大小，见 SettingsWindowSync）。名字、图标、顺序和代理引擎那边的 SettingsPage 一致，改的时候一起改。
enum EnginePage: String, CaseIterable {
    case nodes
    case rules
    case share
    case connections
    case diagnose
    case advanced
    case core

    var title: String {
        switch self {
        case .nodes: return L("节点与订阅")
        case .rules: return L("分流规则")
        case .share: return L("局域网共享")
        case .connections: return L("连接")
        case .diagnose: return L("网址诊断")
        case .advanced: return L("高级")
        case .core: return L("内核")
        }
    }

    var symbol: String {
        switch self {
        case .nodes: return "antenna.radiowaves.left.and.right"
        case .rules: return "arrow.triangle.branch"
        case .share: return "wifi.router"
        case .connections: return "list.bullet.rectangle"
        case .diagnose: return "stethoscope"
        case .advanced: return "slider.horizontal.3"
        case .core: return "cpu"
        }
    }
}

/// 侧边栏里的一项：Proxi 自己的页，或者扩展开着时代理引擎的页。
enum SidebarItem: Hashable {
    case proxi(SettingsPage)
    case engine(EnginePage)

    /// 扩展开着时代理引擎的页接在「扩展」后面，和其他项平铺；关着时不显示。代理引擎那边的侧边栏是同样的顺序。
    static func all(extensionEnabled: Bool) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for page in SettingsPage.allCases {
            items.append(.proxi(page))
            if page == .extensions, extensionEnabled {
                items += EnginePage.allCases.map { .engine($0) }
            }
        }
        return items
    }

    var title: String {
        switch self {
        case .proxi(let page): return page.title
        case .engine(let page): return page.title
        }
    }

    var symbol: String {
        switch self {
        case .proxi(let page): return page.symbol
        case .engine(let page): return page.symbol
        }
    }
}

/// 设置窗口：透明标题栏、全尺寸内容，内容是 SwiftUI。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var otherShownObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?

    /// 设置窗口正开着。
    var isShowing: Bool { window?.isVisible == true }

    override init() {
        super.init()
        // 窗口先成为 key、应用稍后才激活时，也要完成交接。
        becameActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.announceWhenReady() }
        }
        // 代理引擎的设置窗口显示出来时关掉这边的：两边当成同一个窗口，同一时间只显示一个。
        otherShownObserver = SettingsWindowSync.observeOtherShown { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            // 对方已经取得焦点并完成绘制，直接隐藏旧窗口，避免关闭动画露出桌面。
            window.orderOut(nil)
        }
    }

    func show(page: SettingsPage?) {
        if let page {
            navigation.page = page
        }
        if window == nil {
            window = makeWindow()
        }
        // 从代理引擎的设置窗口切过来时放在同一个位置、同样大小。
        if let window, !window.isVisible, let frame = SettingsWindowSync.savedFrame() {
            window.setFrame(frame, display: false)
        }
        // 设置窗口也保持菜单栏应用身份；切页不再向 Dock 添加、移除应用图标。
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            SettingsWindowSync.save(window.frame)
        }
        announceWhenReady()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        announceWhenReady()
    }

    /// 激活是异步的；仅在窗口真正成为前台窗口且首帧画好后，才让另一边隐藏。
    private func announceWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible, window.isKeyWindow, NSApp.isActive else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            SettingsWindowSync.announceShown()
        }
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame(of: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame(of: notification)
    }

    private func saveFrame(of notification: Notification) {
        if let window = notification.object as? NSWindow, window.isVisible {
            SettingsWindowSync.save(window.frame)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 别的窗口（后台助手的提示）还开着时留在 Dock 和 ⌘Tab 里，等它也关了再回到只有菜单栏图标。
        let others = NSApp.windows.contains { $0.isVisible && $0 !== notification.object as? NSWindow && $0.styleMask.contains(.titled) }
        if !others {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(state: AppState.shared, navigation: navigation)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Proxi 设置")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// 设置窗口的内容：左侧导航，右侧各页；整个窗口透出桌面的毛玻璃。
struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.all(extensionEnabled: state.persisted.extensionState.enabled), id: \.self, selection: sidebarSelection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: AppLanguage.width(170, english: 190), ideal: AppLanguage.width(190, english: 215), max: 260)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("Proxi")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 34)
                .padding(.bottom, 4)
            }
        } detail: {
            // 背景独立于页面分支，切换页面时保留同一个 AppKit 毛玻璃视图。
            ZStack {
                VisualEffectView(material: .underWindowBackground).ignoresSafeArea()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    /// 选中代理引擎的页时切到它的设置窗口（这个窗口随之关掉），选中的仍是这边的页。
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { .proxi(navigation.page) }, set: { item in
            switch item {
            case .proxi(let page): navigation.page = page
            case .engine(let page): state.extensions.showSettings(page: page.rawValue)
            case nil: break
            }
        })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page {
        case .profiles: ProfilesPage(state: state, navigation: navigation)
        case .automation: AutomationPage(state: state, control: state.control, network: state.network)
        case .general: GeneralPage(state: state)
        case .hotkey: HotkeyPage(state: state)
        case .sync: SyncPage(state: state, sync: state.sync)
        case .extensions: ExtensionsPage(state: state, extensions: state.extensions)
        case .diagnostics: DiagnosticsPage(state: state)
        case .about: AboutPage(state: state)
        }
    }
}

/// 页面标题。
struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }
}

// MARK: - 通用

/// 「显示高级设置」：不常用的设置默认收起（关闭代理的方式、连通检查和测速地址、网速的位置和颜色、配置里不经代理的地址）。
/// 只影响这台 Mac 的界面，不同步。
enum AdvancedSettings {
    static let key = "showAdvancedSettings"
}

struct GeneralPage: View {
    @ObservedObject var state: AppState
    @AppStorage(AdvancedSettings.key) private var showAdvanced = false
    @State private var language = LanguageSetting.current
    @State private var relaunchError: String?
    @State private var removingHelper = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("通用"), subtitle: L("界面语言、菜单栏图标的行为、关闭代理的方式、通知"))
            Form {
                Section {
                    Picker(L("界面语言"), selection: languageBinding) {
                        ForEach(InterfaceLanguage.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if language != LanguageSetting.atLaunch {
                        HStack {
                            Label(L("重新启动 Proxi 后生效"), systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(L("立即重新启动")) {
                                relaunchError = nil
                                LanguageSetting.relaunch { relaunchError = L("重新启动失败：%@", $0) }
                            }
                        }
                        if let relaunchError {
                            Text(relaunchError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(L("跟随系统时，系统语言是中文就显示中文，其他语言都显示英文。重新启动时代理保持开着。只影响这台 Mac，不会同步。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(L("启动")) {
                    Toggle(L("登录时自动启动"), isOn: Binding(get: { state.loginItemEnabled }, set: { state.setLoginItem($0) }))
                    Toggle(L("退出 Proxi 时关闭代理"), isOn: $state.config.disableOnExit)
                    Text(L("一键更新、换界面语言后重新启动时什么都不关；设了登录时启动的，注销、重新启动电脑或关机也不关，登录后接着用。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(L("菜单栏图标")) {
                    Picker(L("左键点击"), selection: $state.config.clickAction) {
                        ForEach(ClickAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Text(L("右键或 Control + 点击总是弹出菜单"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(L("实时网速"), selection: $state.config.speedDisplay) {
                        ForEach(SpeedDisplay.allCases) { display in
                            Text(display.title).tag(display)
                        }
                    }
                    if showAdvanced {
                        Picker(L("网速位置"), selection: $state.config.speedSide) {
                            ForEach(SpeedSide.allCases) { side in
                                Text(side.title).tag(side)
                            }
                        }
                        .disabled(state.config.speedDisplay == .none)
                        Toggle(L("网速文字跟着代理状态变色"), isOn: $state.config.speedColorFollowsStatus)
                            .disabled(state.config.speedDisplay == .none)
                        Text(L("上行在上、下行在下，默认显示在图标左边、开关在右边。「关代理时只显示网速」：代理关着时菜单栏里只有网速，开启后开关出现在网速左边，网速本身的位置不动；点网速和点开关一样。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L("变色：开着代理时网速用开关的颜色，系统代理是别的程序设置的时候是黄色，代理服务器连不上时是红色，关着时是普通的菜单栏文字颜色。颜色会按菜单栏深浅自动调深或调浅，保证看得清。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(L("「系统网络总速度」统计有线和 Wi‑Fi 网卡的全部流量。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if showAdvanced {
                    Section(L("代理")) {
                        Picker(L("关闭代理时"), selection: $state.config.offMode) {
                            ForEach(OffMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Toggle(L("定期检查代理服务器能否连上"), isOn: $state.config.healthCheck)
                        TextField(L("测速地址"), text: $state.config.testURL)
                            .textFieldStyle(.roundedBorder)
                        Text(L("测试连接时经代理访问这个地址。默认是苹果的连通性检测页，也可以换成你自己内网里的地址。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if state.legacyHelperInstalled && !state.persisted.extensionState.enabled {
                    Section(L("以前版本的后台助手")) {
                        Text(L("以前的版本装过一个后台助手，没有开启扩展时用不上它。移除它需要输入一次管理员密码。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(removingHelper ? L("正在移除…") : L("移除后台助手…")) {
                            removingHelper = true
                            Task { @MainActor in
                                await state.removeLegacyHelper()
                                removingHelper = false
                            }
                        }
                        .disabled(removingHelper)
                    }
                }
                Section(L("通知")) {
                    Picker(L("通知"), selection: $state.config.notifyLevel) {
                        ForEach(NotifyLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                }
                Section(L("更新‖标题")) {
                    Toggle(L("自动检查更新"), isOn: $state.config.autoCheckUpdates)
                    Text(L("启动后和之后每 6 小时检查一次 GitHub 上的新版本，有新版本时通知，不会自动安装。「关于」页里可以随时手动检查和一键更新。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle(L("显示高级设置"), isOn: $showAdvanced)
                    Text(L("不常用的设置默认收起：关闭代理的方式、连通检查和测速地址、网速的位置和颜色、代理配置里不经代理的地址。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var languageBinding: Binding<InterfaceLanguage> {
        Binding(
            get: { language },
            set: { value in
                LanguageSetting.set(value)
                language = LanguageSetting.current
            }
        )
    }
}

// MARK: - 快捷键

struct HotkeyPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("快捷键"), subtitle: L("在任何程序里按下它就能开关代理"))
            Form {
                Section(L("开 / 关代理")) {
                    HStack {
                        HotkeyRecorder(binding: $state.config.toggleHotkey)
                            .frame(width: 180, height: 28)
                        Button(L("清除")) { state.config.toggleHotkey = nil }
                            .disabled(state.config.toggleHotkey == nil)
                    }
                    Text(L("点击方框后按下新的组合键，至少包含 ⌃ 或 ⌘（F1~F20 可以单独用）。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = state.hotkeyProblem {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section(L("命令行与快捷指令")) {
                    Text(L("更多的命令、给 AI 助手用的接口和按网络自动切换在「自动化」页。终端里也可以用 open 命令控制："))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(["open proxi://toggle", "open proxi://on", "open proxi://off", L("open \"proxi://use?name=配置名\""), "open proxi://update"], id: \.self) { command in
                        HStack {
                            Text(command)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                TerminalCommands.copy(command)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - 诊断

struct DiagnosticsPage: View {
    @ObservedObject var state: AppState
    @State private var environment: [String: String] = [:]
    @State private var gitProxy = ""
    @State private var npm: [String: String] = [:]
    @State private var services: [NetworkServices.Service] = []
    @State private var logText = ""
    @State private var clearing = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("诊断"), subtitle: L("系统里各处的代理设置，以及运行日志"))
            Form {
                Section(L("系统代理")) {
                    LabeledContent(L("当前生效"), value: state.snapshot.summary)
                    LabeledContent(L("自动发现（WPAD）"), value: state.snapshot.autoDiscovery ? L("开") : L("关"))
                    LabeledContent(L("例外"), value: state.snapshot.exceptions.isEmpty ? L("无") : state.snapshot.exceptions.joined(separator: ", "))
                    LabeledContent(L("网络服务"), value: services.isEmpty ? L("无") : services.map { $0.enabled ? $0.name : L("%@（已停用）", $0.name) }.joined(separator: L("、")))
                    HStack {
                        Button(L("打开系统的代理设置")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                        }
                        Button(clearing ? L("正在清除…") : L("清除所有代理设置")) {
                            clearAll()
                        }
                        .disabled(clearing)
                    }
                }
                Section(L("环境变量（launchd）")) {
                    ForEach(EnvironmentProxy.names, id: \.self) { name in
                        LabeledContent(name, value: environment[name]?.isEmpty == false ? environment[name]! : L("未设置"))
                    }
                    Text(L("新打开的终端和程序会读到这些变量；已经打开的终端请用面板里的「复制终端命令」。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(L("git 与 npm")) {
                    LabeledContent("git http.proxy", value: gitProxy.isEmpty ? L("未设置") : gitProxy)
                    LabeledContent("npm proxy", value: npm["proxy"] ?? L("未设置"))
                    LabeledContent("npm https-proxy", value: npm["https-proxy"] ?? L("未设置"))
                }
                Section(L("文件")) {
                    LabeledContent(L("配置目录"), value: Store.directory.path)
                    HStack {
                        Button(L("打开配置目录")) { NSWorkspace.shared.open(Store.directory) }
                        Button(L("刷新")) { reload() }
                    }
                }
                Section(L("日志")) {
                    ScrollView {
                        Text(logText.isEmpty ? L("还没有日志") : logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task { reload() }
    }

    private func reload() {
        services = NetworkServices.all()
        logText = Log.tail(lines: 120)
        npm = NpmProxy.current()
        Task { @MainActor in
            environment = await EnvironmentProxy.current()
            gitProxy = await GitProxy.current()
        }
    }

    private func clearAll() {
        clearing = true
        Task { @MainActor in
            await state.clearAllProxySettings()
            clearing = false
            reload()
        }
    }
}

// MARK: - 关于

struct AboutPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("关于"), subtitle: "Proxi for Mac")
            // 窗口够宽时赞赏码放在右边，一眼就能看到；窄的时候排到下面。
            // 按实际宽度判断（ViewThatFits 按理想宽度量，更新说明里一行长字就会让它一直选竖排）。
            GeometryReader { geometry in
                ScrollView {
                    if geometry.size.width >= 680 {
                        HStack(alignment: .top, spacing: 20) {
                            aboutCard
                            DonateCard()
                        }
                        .padding(24)
                    } else {
                        VStack(spacing: 20) {
                            aboutCard
                            DonateCard()
                        }
                        .padding(24)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("Proxi")
                .font(.system(size: 20, weight: .bold))
            Text(L("版本 %@", UpdateChecker.currentVersion))
                .foregroundStyle(.secondary)
            Text(L("给开发者用的代理开关：一键把系统代理、终端、git 和 npm 指向你自己的代理服务器。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
                Button(L("反馈问题")) { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
            Divider()
                .padding(.horizontal, 40)
            UpdateSection(updater: state.updater)
            Text("GPL-3.0 License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard(cornerRadius: 20)
    }
}

/// 关于页的「请我喝杯咖啡」：微信赞赏码卡片，点一下放大，方便手机扫。图片不在（开发时直接运行二进制）就不显示。
struct DonateCard: View {
    @MainActor static let image: NSImage? = Bundle.main.url(forResource: "donate-wechat", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    @State private var enlarged = false

    var body: some View {
        if let image = Self.image {
            VStack(spacing: 10) {
                Button {
                    enlarged = true
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 210)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .help(L("点击放大"))
                .accessibilityLabel(L("微信赞赏码：请我喝杯咖啡"))
                .popover(isPresented: $enlarged, arrowEdge: .leading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 420)
                        .padding(14)
                }
                Text(L("觉得好用的话，\n微信扫一扫请我喝杯咖啡"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("点图片可以放大"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 230)
            .padding(.vertical, 8)
        }
    }
}
