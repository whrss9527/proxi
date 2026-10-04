import AppKit
import Combine

/// 可选扩展「代理引擎」在这台 Mac 上的状态，存在本机状态里（state.json，不跟 iCloud 同步）。
struct ExtensionState: Codable, Equatable {
    /// 用户开启了扩展。
    var enabled = false
    /// 同意的说明是哪一版（ExtensionManager.disclaimerVersion）；说明改了要重新同意。
    var acceptedVersion: Int?
    var acceptedAt: Date?
    /// 配置列表里「代理引擎」那条配置（id、名字、颜色、生效范围），开启扩展时加回来、关闭时去掉。
    var profile: Profile?
    /// 以前开着的就是代理引擎：用户开启扩展、代理引擎运行起来后重新开启它（那时代理关着才开）。
    var restoreActive = false
    /// 已经检查过以前版本的数据（只在第一次启动新版本时检查一次）。
    var migrationChecked = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, acceptedVersion, acceptedAt, profile, restoreActive, migrationChecked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        acceptedVersion = try? container.decodeIfPresent(Int.self, forKey: .acceptedVersion)
        acceptedAt = try? container.decodeIfPresent(Date.self, forKey: .acceptedAt)
        profile = try? container.decodeIfPresent(Profile.self, forKey: .profile)
        restoreActive = (try? container.decodeIfPresent(Bool.self, forKey: .restoreActive)) ?? false
        migrationChecked = (try? container.decodeIfPresent(Bool.self, forKey: .migrationChecked)) ?? false
    }
}

/// 代理引擎写的状态文件（它的数据目录里的 status.json）。格式和代理引擎那边的 EngineStatusFile 一样，改的时候一起改。
struct ExtensionStatus: Codable, Equatable {
    var version: String
    var pid: Int32
    var mixedPort: Int
    var coreRunning: Bool
    var coreReady: Bool
    var summary: String
    var updatedAt: Date

    static func decode(_ data: Data) -> ExtensionStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExtensionStatus.self, from: data)
    }

    /// 进程还在、最近更新过（代理引擎每 10 秒重写一次）。
    func isAlive(now: Date = Date(), processExists: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        pid > 0 && processExists(pid) && now.timeIntervalSince(updatedAt) < 45
    }
}

enum ExtensionError: LocalizedError, Equatable {
    case notEnabled
    case notAccepted
    case missingAsset(String)
    case notInstalled
    case notRunning(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: return L("扩展没有开启")
        case .notAccepted: return L("还没有同意扩展的说明")
        case .missingAsset(let name): return L("这个版本的发布里没有 %@", name)
        case .notInstalled: return L("代理引擎还没有安装")
        case .notRunning(let text): return L("代理引擎没有运行起来：%@", text)
        }
    }
}

/// 可选扩展「代理引擎」：默认关闭。用户在「设置 → 扩展」里看完说明、勾选同意并开启后，才从这个版本的 GitHub 发布下载
/// Proxi-Engine-<版本>.zip（核对 SHA256SUMS.txt 里的校验和、签名的 Team ID 和 Proxi 一样），装到数据目录的 Extensions/ 里并启动。
/// 没开启时不下载、不检查更新、不访问任何和它有关的地址，界面上除了扩展页什么都不显示。只在主线程上用。
@MainActor
final class ExtensionManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(Double?)
        case verifying
        case installing
        case failed(String)
    }

    /// 说明的版本：改了说明的意思就加一，用户要重新同意。
    nonisolated static let disclaimerVersion = 1
    nonisolated static let bundleIdentifier = "com.whrss9527.proxyswitch.engine"
    nonisolated static let appName = "Proxi Engine.app"
    /// 启动代理引擎时让它打开设置窗口的参数（和代理引擎那边的 AppDelegate.showSettingsArgument 一样，改的时候一起改）。
    nonisolated static let showSettingsArgument = "--show-settings"
    /// 带在 showSettingsArgument 后面，指定打开哪一页（EnginePage 的 rawValue）。
    nonisolated static let settingsPageArgument = "--settings-page"
    /// 测试用：把这个环境变量指向一个 GitHub releases 格式的 JSON（本机的 http:// 或 file://），从那里下载代理引擎。
    nonisolated static let feedVariable = "PROXI_EXTENSION_FEED"
    /// 测试用：设成 1 时启动就当作用户已经同意说明并开启了扩展（CI 用，界面上不会出现）。
    nonisolated static let testAcceptVariable = "PROXI_TEST_ACCEPT_EXTENSION"

    @Published private(set) var phase: Phase = .idle
    /// 代理引擎写的状态；nil 表示没在运行。
    @Published private(set) var status: ExtensionStatus?
    /// 装着的代理引擎的版本；nil 表示没装。
    @Published private(set) var installedVersion: String?

    /// 读写本机状态里的扩展部分（AppState 提供）。
    var readState: () -> ExtensionState = { ExtensionState() }
    var writeState: ((ExtensionState) -> Void)?
    /// 代理引擎开了、停了、换了端口（AppState 据此调整配置列表里的「代理引擎」）。
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var installTask: Task<Void, Never>?
    /// 上次启动代理引擎的时间，和最近几次自动重新启动它的时间（见 keepRunning）。
    private var lastLaunch: Date?
    private var restarts: [Date] = []

    // MARK: - 位置

    /// 下载的代理引擎放在这里（Proxi 自己的数据目录下面，不用管理员密码）。
    nonisolated static var extensionsDirectory: URL { Store.directory.appendingPathComponent("Extensions", isDirectory: true) }
    nonisolated static var appURL: URL { extensionsDirectory.appendingPathComponent(appName, isDirectory: true) }
    /// 代理引擎自己的数据目录（订阅、规则、下载的内核……）。从以前的版本迁移的数据也放这里。
    nonisolated static var dataDirectory: URL { Store.directory.appendingPathComponent("engine", isDirectory: true) }
    nonisolated static var statusURL: URL { dataDirectory.appendingPathComponent("status.json") }

    nonisolated static func archiveName(version: String) -> String { "Proxi-Engine-\(version).zip" }

    /// 这个版本的发布信息：GitHub releases 接口里对应标签的那一个（代理引擎和 Proxi 一起发布、版本号一样）。
    nonisolated static func feedURL(version: String = UpdateChecker.currentVersion) -> URL {
        if let text = ProcessInfo.processInfo.environment[feedVariable], let url = URL(string: text) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/tags/v\(version)")!
    }

    // MARK: - 状态

    var state: ExtensionState { readState() }
    var isEnabled: Bool { state.enabled }
    var needsDisclaimer: Bool { state.acceptedVersion != Self.disclaimerVersion }
    var isInstalled: Bool { installedVersion != nil }
    var isRunning: Bool { status != nil }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// 启动时调用：开着扩展时确认代理引擎装好、和 Proxi 同一个版本，再启动它；没开时什么都不做。
    func start() {
        if ProcessInfo.processInfo.environment[Self.testAcceptVariable] == "1", !state.enabled {
            Log.info("扩展：测试环境变量 \(Self.testAcceptVariable)=1，按已同意说明处理")
            accept()
        }
        refreshInstalled()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        guard state.enabled else {
            Log.info("扩展：代理引擎没有开启")
            return
        }
        Log.info("扩展：代理引擎已开启")
        prepareAndLaunch()
    }

    /// 用户在扩展页里勾选同意说明并开启。
    func accept() {
        var current = state
        current.enabled = true
        current.acceptedVersion = Self.disclaimerVersion
        current.acceptedAt = Date()
        writeState?(current)
        Log.info("扩展：用户同意了说明（第 \(Self.disclaimerVersion) 版），开启代理引擎")
        onChange?()
    }

    /// 开启后（或者启动时开着）：没装或者版本不对就下载安装，然后启动。
    func prepareAndLaunch() {
        guard state.enabled, !isBusy else { return }
        restarts = []
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.installedVersion != UpdateChecker.currentVersion {
                    try await self.install()
                }
                self.launch()
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                let message = error.localizedDescription
                self.phase = .failed(message)
                Log.error("扩展：安装代理引擎失败：\(message)")
                // 下载不了同一个版本（比如更新 Proxi 后连不上 GitHub）时先用装着的旧版本，「代理引擎」那条配置照样能用。
                if self.isInstalled {
                    Log.info("扩展：先用已经装着的代理引擎 \(self.installedVersion ?? "")")
                    self.launch()
                }
            }
        }
    }

    /// 关闭扩展：退出代理引擎；removeApp 时把下载的程序也删掉（它的数据目录不动，以后再开还在）。
    /// 关闭配置、恢复系统设置由 AppState 先做。
    func disable(removeApp: Bool) async {
        installTask?.cancel()
        var current = state
        current.enabled = false
        current.restoreActive = false
        writeState?(current)
        await quit()
        if removeApp {
            try? FileManager.default.removeItem(at: Self.appURL)
            Log.info("扩展：已删除下载的代理引擎")
        }
        refreshInstalled()
        phase = .idle
        Log.info("扩展：代理引擎已关闭")
        onChange?()
    }

    // MARK: - 下载安装

    /// 扩展的网络请求都经这里：没开启时一律不发（CI 按日志里的「扩展网络请求」确认关着时没有请求）。
    private func checkAllowed(_ url: URL) throws {
        guard state.enabled else {
            Log.error("扩展：没开启，拒绝访问 \(url.absoluteString)")
            throw ExtensionError.notEnabled
        }
        guard !needsDisclaimer else { throw ExtensionError.notAccepted }
        Log.info("扩展网络请求 \(url.absoluteString)")
    }

    private func routes(for url: URL) -> [NetworkRoute] {
        NetworkRoute.routes(for: url, system: SystemProxy.current())
    }

    /// 下载这个版本的代理引擎，核对校验和、标识、版本和签名，装进 Extensions/。
    func install() async throws {
        let version = UpdateChecker.currentVersion
        phase = .checking
        let feed = Self.feedURL(version: version)
        try checkAllowed(feed)
        let (archiveURL, archiveSize, checksumsURL) = try await fetchAssets(feed: feed, version: version)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("proxi-extension-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(Self.archiveName(version: version))
        try checkAllowed(archiveURL)
        phase = .downloading(nil)
        var lastError: Error = UpdateError.badResponse
        var downloaded = false
        for route in routes(for: archiveURL) {
            do {
                try await UpdateInstaller.download(archiveURL, expectedSize: archiveSize, to: archive, route: route) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                    }
                }
                downloaded = true
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.info("扩展：经\(route.title)下载失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        guard downloaded else { throw lastError }
        phase = .verifying
        try checkAllowed(checksumsURL)
        try await UpdateInstaller.verify(archive: archive, checksumsURL: checksumsURL, routes: routes(for: checksumsURL))
        let app = try await UpdateInstaller.extract(archive: archive, to: work.appendingPathComponent("unzipped", isDirectory: true))
        try await UpdateInstaller.validate(app: app, expectedVersion: version, expectedIdentifier: Self.bundleIdentifier)
        phase = .installing
        await quit()
        try fm.createDirectory(at: Self.extensionsDirectory, withIntermediateDirectories: true)
        try await UpdateInstaller.install(newApp: app, replacing: Self.appURL)
        refreshInstalled()
        phase = .idle
        Log.info("扩展：代理引擎 \(version) 已安装到 \(Self.appURL.path)")
    }

    /// 从发布信息里找代理引擎的压缩包和校验文件。
    private func fetchAssets(feed: URL, version: String) async throws -> (URL, Int?, URL) {
        var data: Data?
        var lastError: Error = UpdateError.badResponse
        for route in routes(for: feed) {
            do {
                if feed.isFileURL {
                    data = try Data(contentsOf: feed)
                } else {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 15
                    configuration.timeoutIntervalForResource = 30
                    route.apply(to: configuration)
                    let session = URLSession(configuration: configuration)
                    defer { session.finishTasksAndInvalidate() }
                    var request = URLRequest(url: feed)
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
                    let (body, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw UpdateError.server(http.statusCode)
                    }
                    data = body
                }
                break
            } catch {
                Log.info("扩展：经\(route.title)读取发布信息失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        guard let data else { throw lastError }
        guard let assets = Self.assets(in: data, version: version) else {
            throw ExtensionError.missingAsset(Self.archiveName(version: version))
        }
        return assets
    }

    /// 解析 GitHub releases 格式的 JSON：代理引擎的压缩包（地址、大小）和校验文件的地址。
    nonisolated static func assets(in data: Data, version: String) -> (URL, Int?, URL)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String) -> [String: Any]? { assets.first { ($0["name"] as? String) == name } }
        guard let archive = asset(archiveName(version: version)),
              let archiveURL = (archive["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let checksumsURL = (asset(UpdateChecker.checksumsName)?["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        return (archiveURL, archive["size"] as? Int, checksumsURL)
    }

    func refreshInstalled() {
        let plist = Self.appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier else {
            installedVersion = nil
            return
        }
        installedVersion = info["CFBundleShortVersionString"] as? String
    }

    // MARK: - 启动和退出

    /// 启动代理引擎。它没有自己的菜单栏图标，平时在后台启动（不抢焦点、不开窗口）；showWindow 时打开它的设置窗口：
    /// 没在运行就带上参数启动，已经在运行时系统发给它的「重新打开」让它显示设置。界面语言跟 Proxi 一样。
    func launch(showWindow: Bool = false, page: String? = nil, handOff: Bool = false) {
        guard state.enabled, isInstalled else { return }
        // 已经在运行（或者几秒前刚启动、还没出现在运行的程序里）时再打开一次就会弹出它的设置窗口，后台启动时不用再打开。
        if !showWindow {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return }
            if let lastLaunch, Date().timeIntervalSince(lastLaunch) < 5 { return }
        }
        let configuration = handOff ? SettingsWindowSync.handOffConfiguration() : NSWorkspace.OpenConfiguration()
        configuration.activates = showWindow && !handOff
        configuration.addsToRecentItems = false
        var arguments = ["-AppleLanguages", AppLanguage.isEnglish ? "(en)" : "(zh-Hans)"]
        if showWindow {
            arguments.append(Self.showSettingsArgument)
            if let page {
                arguments += [Self.settingsPageArgument, page]
            }
        }
        configuration.arguments = arguments
        lastLaunch = Date()
        NSWorkspace.shared.openApplication(at: Self.appURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    Log.error("扩展：启动代理引擎失败：\(error.localizedDescription)")
                    self.phase = .failed(L("启动代理引擎失败：%@", error.localizedDescription))
                }
            } else {
                Log.info(showWindow ? "扩展：已打开代理引擎的设置" : "扩展：已启动代理引擎")
            }
        }
    }

    /// 打开代理引擎的设置窗口（Proxi 的菜单、面板和扩展页里的「代理引擎设置…」）；还没装好、正在下载安装时打开扩展页看进度。
    /// page：打开哪一页（Proxi 侧边栏里点了代理引擎的某一页时传）。
    func showSettings(page: String? = nil) {
        if isInstalled && !isBusy {
            // 从这边开着的设置窗口切过去时，不让系统马上把代理引擎切到前台：等它的窗口出来，这边关窗口时把前台交过去
            // （见 SettingsWindowSync.handOffConfiguration）。从菜单、面板打开时照旧让系统切到前台。
            let handOff = NSApp.isActive && SettingsWindowController.shared.isShowing
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
                SettingsWindowSync.yieldToOther()
                SettingsWindowSync.requestEnginePage(page ?? "")
            } else {
                launch(showWindow: true, page: page, handOff: handOff)
            }
        } else {
            SettingsWindowController.shared.show(page: .extensions)
        }
    }

    /// 扩展开着、代理引擎却不在运行（崩溃了、被退出了、重新启动 Proxi 时旧的还没退完、新的就跳过了启动）：再启动它。
    /// 不然「代理引擎」那条配置开着时，系统代理一直指向一个没人监听的端口。十分钟里自动启动了 3 次还不行就不再试。
    private func keepRunning() {
        guard state.enabled, isInstalled, !isBusy, status == nil,
              NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else { return }
        let now = Date()
        if let lastLaunch, now.timeIntervalSince(lastLaunch) < 15 { return }
        restarts = restarts.filter { now.timeIntervalSince($0) < 600 }
        guard restarts.count < 3 else {
            if case .failed = phase { return }
            phase = .failed(L("代理引擎多次意外退出，没有再启动它"))
            Log.error("扩展：代理引擎十分钟里意外退出了 3 次，不再自动启动")
            return
        }
        restarts.append(now)
        Log.info("扩展：代理引擎没在运行，重新启动它")
        launch()
    }

    /// 退出正在运行的代理引擎（它退出时自己停掉内核），最多等 10 秒。
    func quit() async {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard !running.isEmpty else { return }
        for app in running {
            app.terminate()
        }
        for _ in 0..<50 {
            if running.allSatisfy(\.isTerminated) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        for app in running where !app.isTerminated {
            app.forceTerminate()
        }
        status = nil
        Log.info("扩展：代理引擎已退出")
        onChange?()
    }

    /// 开启「代理引擎」这条配置之前：确认代理引擎在运行、内核起来了，最多等 30 秒。
    func ensureRunning() async throws -> ExtensionStatus {
        guard state.enabled else { throw ExtensionError.notEnabled }
        poll()
        if let status, status.coreRunning { return status }
        guard isInstalled else { throw ExtensionError.notInstalled }
        if status == nil { launch() }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            poll()
            if let status, status.coreRunning { return status }
        }
        throw ExtensionError.notRunning(status?.summary ?? L("没有响应"))
    }

    /// 读代理引擎的状态文件。
    func poll() {
        guard state.enabled else {
            if status != nil {
                status = nil
                onChange?()
            }
            return
        }
        var current: ExtensionStatus?
        if let data = try? Data(contentsOf: Self.statusURL), let file = ExtensionStatus.decode(data), file.isAlive() {
            current = file
        }
        if current != status {
            let wasRunning = status?.coreRunning ?? false
            status = current
            if (current?.coreRunning ?? false) != wasRunning {
                Log.info(current?.coreRunning == true ? "扩展：代理引擎的内核在运行，端口 \(current?.mixedPort ?? 0)" : "扩展：代理引擎的内核没在运行")
            }
            onChange?()
        }
        keepRunning()
    }
}
