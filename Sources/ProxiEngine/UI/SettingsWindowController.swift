import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 这边设置窗口的各页。和 Proxi 的页平铺在同一个侧边栏里（见 SidebarItem）；名字、图标、顺序和 Proxi 那边的 EnginePage 一致，改的时候一起改。
/// 以前单独的「通用」（通知、本机控制接口）并进了「高级」，「关于」并进了「内核」，免得和 Proxi 的「通用」「关于」重复。
enum SettingsPage: String, CaseIterable, Identifiable {
    case nodes
    case rules
    case share
    case connections
    case diagnose
    case advanced
    case core

    var id: String { rawValue }

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

/// Proxi 设置窗口的各页（和 Proxi 那边的 SettingsPage 一致：名字、图标、顺序、rawValue），列在这边的侧边栏里，点了切回 Proxi 的设置窗口。
enum ProxiPage: String, CaseIterable {
    case profiles
    case automation
    case general
    case hotkey
    case sync
    case extensions
    case diagnostics
    case about

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

    /// 在 Proxi 里打开这一页；Proxi 的设置窗口显示出来后，这边的窗口随之关掉（见 SettingsWindowSync）。
    @MainActor
    func open() {
        // 不让系统马上把 Proxi 切到前台：等它的窗口出来，这边关窗口时把前台交过去（不然会落到桌面或者别的程序）。
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.whrss9527.proxyswitch").isEmpty {
            SettingsWindowSync.yieldToOther()
            SettingsWindowSync.requestProxiPage(rawValue)
        } else {
            NSWorkspace.shared.open(URL(string: "proxi://settings?page=\(rawValue)")!, configuration: SettingsWindowSync.handOffConfiguration())
        }
    }
}

/// 侧边栏里的一项。和 Proxi 的设置窗口当成同一个窗口：两边的侧边栏是同一份平铺的列表，这边的页接在 Proxi 的「扩展」后面。
enum SidebarItem: Hashable {
    case proxi(ProxiPage)
    case engine(SettingsPage)

    static var all: [SidebarItem] {
        var items: [SidebarItem] = []
        for page in ProxiPage.allCases {
            items.append(.proxi(page))
            if page == .extensions {
                items += SettingsPage.allCases.map { .engine($0) }
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

@MainActor
final class SettingsNavigation: ObservableObject {
    // 跨窗口请求发出后保持用户点击的选中项，避免 List 先弹回原页再切到对方。
    @Published private(set) var requestedSidebarItem: SidebarItem?
    var sidebarItem: SidebarItem { requestedSidebarItem ?? .engine(page) }

    func select(_ item: SidebarItem) {
        switch item {
        case .engine(let page):
            self.page = page
            requestedSidebarItem = nil
        default:
            requestedSidebarItem = item
        }
    }

    func didShow() { requestedSidebarItem = nil }

    @Published var page: SettingsPage = .nodes
    /// 从别处发起的诊断（proxi://diagnose 等），诊断页拿走后清空。
    @Published var diagnoseRequest: DiagnoseRequest?
    /// 要导入的配置（proxi://import、拖进窗口的文件），高级页拿走后打开导入预览。
    @Published var importRequest: String?
}

/// 设置窗口：透明标题栏、全尺寸内容，内容是 SwiftUI。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var otherShownObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?

    override init() {
        super.init()
        // 窗口先成为 key、应用稍后才激活时，也要完成交接。
        becameActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.announceWhenReady() }
        }
        // Proxi 的设置窗口显示出来时关掉这边的：两边当成同一个窗口，同一时间只显示一个。
        otherShownObserver = SettingsWindowSync.observeOtherShown { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            // 对方已经取得焦点并完成绘制，直接隐藏旧窗口，避免关闭动画露出桌面。
            window.orderOut(nil)
        }
    }

    func show(page: SettingsPage?) {
        navigation.didShow()
        if let page {
            navigation.page = page
        }
        if window == nil {
            window = makeWindow()
        }
        // 从 Proxi 的设置窗口切过来时放在同一个位置、同样大小。
        if let window, !window.isVisible, let frame = SettingsWindowSync.savedFrame() {
            window.setFrame(frame, display: false)
        }
        // 设置窗口也保持后台应用身份；切页不再向 Dock 添加、移除应用图标。
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
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(state: AppState.shared, navigation: navigation)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        // 和 Proxi 的设置窗口同一个标题：两边当成同一个窗口。
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

/// 设置窗口的内容：左侧导航，右侧各页；跨窗口切换时底色保持稳定。
struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.all, id: \.self, selection: sidebarSelection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationSplitViewColumnWidth(min: AppLanguage.width(170, english: 190), ideal: AppLanguage.width(190, english: 215), max: 260)
            .safeAreaInset(edge: .top) {
                // 和 Proxi 的设置窗口一样的抬头：两边当成同一个窗口。
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
            // 使用稳定的窗口底色，避免交叠的两个窗口相互参与毛玻璃采样。
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        // 把配置文件拖进窗口就导入（先预览）。
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    navigation.importRequest = url.absoluteString
                    navigation.page = .advanced
                }
            }
            return true
        }
    }

    /// 选中 Proxi 的页时切回 Proxi 的设置窗口（这个窗口随之隐藏），保持用户点击的选中项。
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { navigation.sidebarItem }, set: { item in
            guard let item else { return }
            navigation.select(item)
            switch item {
            case .engine: break
            case .proxi(let page): page.open()
            }
        })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page {
        case .nodes: NodesPage(state: state, engine: state.engine, navigation: navigation)
        case .rules: RulesPage(state: state, engine: state.engine, navigation: navigation)
        case .share: SharePage(state: state, engine: state.engine, sleepGuard: state.sleepGuard)
        case .connections: ConnectionsPage(state: state, engine: state.engine)
        case .diagnose: DiagnosePage(state: state, engine: state.engine, navigation: navigation)
        case .advanced: AdvancedPage(state: state, engine: state.engine, navigation: navigation)
        case .core: CorePage(state: state, core: state.core, engine: state.engine)
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

// MARK: - 通知与本机控制接口

/// 以前单独的「通用」页：通知和本机控制接口，现在放在「高级」页的最后。
struct GeneralSections: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section(L("通知")) {
            Picker(L("通知"), selection: $state.config.notifyLevel) {
                ForEach(NotifyLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
        }
        Section(L("本机控制接口")) {
            Picker(L("权限"), selection: $state.config.automation.permission) {
                ForEach(ControlPermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            Text(L("在终端里直接运行代理引擎程序里的二进制并带上子命令（比如 status、nodes），经这个接口操作正在运行的代理引擎；只有你这个账户能连。完整的用法："))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Shell.shellQuote(AdminCommand.executablePath) + " help")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - 内核

/// 内核页：下载的内核和 GeoIP 数据库，删除，以及代理引擎自己的日志。
struct CorePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var core: CoreDownload
    @ObservedObject var engine: Engine
    @State private var logText = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("内核"), subtitle: L("内核 mihomo 和 GeoIP 数据库不打包在程序里，第一次运行时从上游的发布下载并校验"))
            Form {
                AboutSection()
                Section(L("内核")) {
                    LabeledContent(L("版本"), value: CorePin.version)
                    LabeledContent(L("状态")) { phaseView }
                    LabeledContent(L("位置"), value: CoreDownload.directory.path)
                    HStack {
                        Button(core.isReady ? L("重新下载") : L("下载")) {
                            core.remove()
                            core.install()
                        }
                        .disabled(core.isBusy)
                        Button(L("删除内核"), role: .destructive) {
                            // stopCore 连状态一起清掉：不然还显示在运行，写给 Proxi 的状态也说内核在运行。
                            engine.stopCore()
                            core.remove()
                        }
                        .disabled(core.isBusy || !core.isReady)
                    }
                    Text(L("下载地址：%@；下载后先核对写在程序里的 SHA-256，对不上就不用。删除后代理引擎不能运行，下次打开时重新下载。", CorePin.asset()?.url.absoluteString ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L("内核项目主页")) { NSWorkspace.shared.open(AppInfo.coreProjectURL) }
                        .buttonStyle(.link)
                }
                Section(L("日志")) {
                    ScrollView {
                        Text(logText.isEmpty ? L("还没有日志") : logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    HStack {
                        Button(L("刷新")) { logText = Log.tail(lines: 120) }
                        Button(L("打开数据目录")) { NSWorkspace.shared.open(Store.directory) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task { logText = Log.tail(lines: 120) }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch core.phase {
        case .unknown, .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("正在校验…"))
            }
        case .missing:
            Text(L("还没有下载")).foregroundStyle(.orange)
        case .downloading(let title, let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(L("正在下载%@…", title))
            }
        case .ready:
            Label(L("已下载并校验"), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.trailing)
                Button(L("重试")) { core.install() }
            }
        }
    }
}

// MARK: - 关于

/// 以前单独的「关于」页：代理引擎的版本、说明和许可证，现在是「内核」页的第一节。
struct AboutSection: View {
    var body: some View {
        Section(L("代理引擎")) {
            LabeledContent(L("版本"), value: UpdateChecker.currentVersion)
            Text(L("Proxi 的可选扩展：本机运行的代理引擎，由 Proxi 下载、启动和更新。在 Proxi 的「设置 → 扩展」里可以关闭或移除。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("说明")) { NSWorkspace.shared.open(AppInfo.documentationURL) }
                Text("GPL-3.0 License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
