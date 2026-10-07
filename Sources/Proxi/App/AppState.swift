import AppKit
import Combine

/// 当前代理状态：关着（下次会开哪个配置）、由本程序开着某个配置、系统代理被别的程序设置了。
enum ProxyStatus: Equatable {
    case off(next: Profile?)
    case on(Profile)
    case external(String)

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    var profile: Profile? {
        switch self {
        case .on(let profile): return profile
        case .off(let next): return next
        case .external: return nil
        }
    }
}

enum ProxyTargetStatus: String {
    case notApplied, applied, failed, changedExternally

    var title: String {
        switch self {
        case .notApplied: return L("未开启")
        case .applied: return L("已开启")
        case .failed: return L("操作失败")
        case .changedExternally: return L("被其他程序改动")
        }
    }
}

enum Health: Equatable {
    case unknown
    case ok
    case down
}

/// 核心状态：配置、系统代理快照、开关操作，所有界面都观察它。只在主线程上使用。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var config: AppConfig
    @Published private(set) var persisted: PersistedState
    @Published private(set) var targetFailures: [ProxyTarget: String] = [:]
    @Published private(set) var snapshot: ProxySnapshot
    @Published private(set) var health: Health = .unknown
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// 快捷键注册不上（被别的程序占用了）时的说明，快捷键页里显示。
    @Published private(set) var hotkeyProblem: String?
    @Published var testResults: [UUID: TestResult] = [:]
    @Published var loginItemEnabled = false
    /// 以前版本装的后台助手还在（要管理员密码才能删）。
    @Published private(set) var legacyHelperInstalled = false
    let updater = Updater()
    let sync = CloudSync()
    let speed = SpeedMeter()
    /// 本机控制接口（命令行、AI 助手）。
    let control = ControlService()
    /// 按网络自动切换。
    let network = NetworkAutomation()
    /// 可选扩展「代理引擎」（默认关闭，见 ExtensionManager）。
    let extensions = ExtensionManager()
    /// 正在重新启动（一键更新、换界面语言）：退出时什么都不关，新的实例接着用（见 handleExit）。
    var relaunching = false
    /// 一键更新后重新启动：代理引擎接着运行，新版本的 Proxi 下载好同版本的代理引擎、替换时才让它退出
    /// （下载经系统代理走，这时代理引擎还得在；换语言重新启动时让它退出，好按新的语言重新打开）。
    var relaunchingForUpdate = false
    /// 系统要注销、重新启动或关机的时间（NSWorkspace.willPowerOffNotification），退出时用来判断是不是这种情况。
    private var poweringOffAt: Date?
    private var powerOffObserver: NSObjectProtocol?

    private var watcher: SystemWatcher?
    private var refreshTimer: Timer?
    private var healthTimer: Timer?
    private var healthMonitor = ProxyHealthMonitor()
    private var healthCheckRunning = false
    private var healthChecksStarted = false
    private let reachability: (String, Int) async -> Bool
    private let healthClock: () -> Date
    private var cancellables = Set<AnyCancellable>()

    var onStatusChanged: (@MainActor () -> Void)?
    /// 从以前的版本更新过来时要收尾的事（读配置之前看过原始文件）。
    private let legacy: LegacyCleanup.Findings
    /// 改系统代理、终端、git、npm 的地方（测试时换成假的）。
    let backend: ProxyBackend
    /// 配置和本机状态要不要写到磁盘上（测试时不写）。
    private let persists: Bool
    /// 退出时最多等清理多久（见 handleExit）。
    var exitCleanupTimeout: TimeInterval = 10

    private convenience init() {
        // 先看以前版本留下的原始文件，再读配置。
        let legacy = LegacyCleanup.inspect()
        self.init(config: Store.loadConfig() ?? AppConfig(), persisted: Store.loadState(), backend: SystemBackend(), legacy: legacy, persists: true)
    }

    /// 测试时传假的系统后端，persists 为 false 时不写磁盘上的配置和本机状态。
    init(config: AppConfig, persisted: PersistedState, backend: ProxyBackend, legacy: LegacyCleanup.Findings = LegacyCleanup.Findings(), persists: Bool,
         reachability: @escaping (String, Int) async -> Bool = { await ProxyTester.reachable(host: $0, port: $1) },
         healthClock: @escaping () -> Date = Date.init) {
        self.legacy = legacy
        self.config = config
        self.persisted = persisted
        self.backend = backend
        self.persists = persists
        self.reachability = reachability
        self.healthClock = healthClock
        snapshot = backend.currentSystemProxy()
        guard persists else { return }
        $config
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { config in Store.save(config) }
            .store(in: &cancellables)
    }

    /// 启动时调用：开始监听系统变化，注册快捷键。
    func start() {
        watcher = SystemWatcher { [weak self] in self?.refresh() }
        watcher?.start()
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOffAt = Date() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        healthChecksStarted = true
        scheduleHealthCheck()
        loginItemEnabled = LoginItem.isEnabled
        extensions.readState = { [weak self] in self?.persisted.extensionState ?? ExtensionState() }
        extensions.writeState = { [weak self] state in
            guard let self else { return }
            self.persisted.extensionState = state
            self.savePersisted()
        }
        extensions.onChange = { [weak self] in self?.extensionChanged() }
        reconcileEngineProfile()
        finishLegacyMigration()
        extensions.start()
        // 测试用：启动时当作用户在扩展页里点了「关闭并移除」（CI 用，界面上不会出现）。
        if ProcessInfo.processInfo.environment["PROXI_TEST_DISABLE_EXTENSION"] == "1", persisted.extensionState.enabled {
            Log.info("扩展：测试环境变量 PROXI_TEST_DISABLE_EXTENSION=1，关闭并移除")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await self.disableExtension(removeApp: true)
            }
        }
        registerHotkey()
        $config
            .map(\.toggleHotkey)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.registerHotkey() } }
            .store(in: &cancellables)
        refresh()
        if persisted.pendingCleanup != nil {
            // 上次退出时没清理完：先接着清理，不要再把终端的环境变量设回去。
            Task { await resumePendingCleanup() }
        } else {
            restoreEnvironment()
        }
        Task { await checkHealth() }
        updater.notify = { [weak self] title, body in
            self?.notify(title: title, body: body, problem: false, route: "about", category: Notifier.updateCategory)
        }
        // 更新先经系统代理访问 GitHub，失败再直连。
        updater.routesProvider = { url in
            NetworkRoute.routes(for: url, system: SystemProxy.current())
        }
        updater.onRelaunch = { [weak self] in
            self?.relaunching = true
            self?.relaunchingForUpdate = true
            NSApp.terminate(nil)
        }
        updater.startAutomaticChecks { [weak self] in self?.config.autoCheckUpdates ?? true }
        // 同步的配置里不带「代理引擎」那条配置（AppConfig 写文件时就去掉了，这里再去一次，比较时也不算它）。
        sync.currentConfig = { [weak self] in
            var config = self?.config ?? AppConfig()
            config.profiles.removeAll { $0.engine }
            return config
        }
        sync.applyRemote = { [weak self] config in self?.applyRemoteConfig(config) }
        sync.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            self.persisted.syncEnabled = enabled
            self.savePersisted()
        }
        // 和上次同步的比较时也不算「代理引擎」那条配置（它不同步）：不然每次从 iCloud 拿到别的 Mac 的配置、
        // 加回这条以后都会被当成本机改了，又写回 iCloud，可能盖掉别的 Mac 刚改的。
        $config
            .map { config -> AppConfig in
                var synced = config
                synced.profiles.removeAll { $0.engine }
                return synced
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] config in Task { @MainActor in self?.sync.localChanged(config) } }
            .store(in: &cancellables)
        sync.start(enabled: persisted.syncEnabled)
        control.start(state: self)
        network.start(state: self)
        speed.setMode(config.speedDisplay)
        $config
            .map(\.speedDisplay)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in Task { @MainActor in self?.speed.setMode(mode) } }
            .store(in: &cancellables)
    }

    /// launchctl setenv 设的环境变量重启、注销以后就没了，系统代理、git、npm 的设置却还在，Proxi 也还显示开着：
    /// 启动时正在用的配置包括「环境变量」就再设一次（不弹钥匙串的对话框，读不到密码就算了）。
    private func restoreEnvironment() {
        guard !busy, case .on(let profile) = status, profile.targets.contains(.environment), profile.supportsNonSystemTargets else { return }
        let password = savedPassword(for: profile, allowUI: false)
        if profile.needsPassword && password.isEmpty {
            Log.info("启动时没有重新设置「\(profile.name)」的环境变量：钥匙串里读不到密码")
            return
        }
        let url = profile.proxyURL(password: password)
        Task {
            do {
                try await backend.setEnvironment(proxyURL: url, noProxy: profile.noProxy)
                Log.info("启动时重新设置了「\(profile.name)」的环境变量")
            } catch {
                Log.error("启动时重新设置环境变量失败：\(Redact.secrets(error.localizedDescription))")
            }
        }
    }

    // MARK: - 从以前的版本更新过来

    /// 第一次启动新版本时：以前版本的代理引擎数据挪到代理引擎的数据目录（一个都不删）；上次开着的是代理引擎那条配置就先把代理关掉
    /// （不然系统代理指向一个没人监听的本机端口），记下来，等用户在「设置 → 扩展」里开启、代理引擎运行起来后再开回来。
    /// 不弹扩展的说明（只在扩展页里打开开关时显示）；只有以前装过后台助手、又没有代理引擎的数据时提示可以移除。
    private func finishLegacyMigration() {
        legacyHelperInstalled = LegacyCleanup.helperInstalled
        var ext = persisted.extensionState
        let firstLaunch = !ext.migrationChecked
        if firstLaunch {
            ext.migrationChecked = true
            if legacy.needsMigration || legacy.hasEngineData {
                let moved = LegacyCleanup.migrateEngineData()
                Log.info("以前版本的代理引擎数据已放到 \(ExtensionManager.dataDirectory.path)：\(moved.isEmpty ? "没有要挪的" : moved.joined(separator: "、"))，原来的数据都保留")
                if var profile = legacy.builtInProfiles.first {
                    profile.engine = true
                    ext.profile = profile
                }
                if legacy.activeBuiltIn != nil {
                    ext.restoreActive = true
                }
                // 去掉以前版本的设置后写回去（代理引擎的设置已经在它自己的目录里了）。
                Store.save(config)
            }
            if legacy.hasEngineData {
                // 有代理引擎的数据：以后开启扩展还要用以前的后台助手，不弹移除的提示（「设置 → 通用」里照样能移除）。
                persisted.noticeShown = true
            }
            persisted.extensionState = ext
            savePersisted()
        }
        if legacyHelperInstalled {
            Log.info(ext.enabled ? "以前版本的后台助手还在，代理引擎开着，留着" : "以前版本的后台助手还在，扩展没开，等用户确认后移除")
        }
        if config.profile(id: persisted.lastProfileID) == nil, persisted.lastProfileID != nil {
            persisted.lastProfileID = config.profiles.first?.id
            savePersisted()
        }
        if firstLaunch, let active = legacy.activeBuiltIn, !ext.enabled {
            Log.info("上次开着的「\(active.name)」是代理引擎，先关掉代理，用户开启扩展后再开回来")
            busy = true
            let mode = config.offMode
            Task {
                var failures: [String] = []
                for target in ProxyTarget.allCases where active.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@：%@", target.title, error))
                    }
                }
                persisted.enabledByUs = false
                persisted.appliedTargets = []
                persisted.original = nil
                persisted.lastProfileID = config.profiles.first { !$0.engine }?.id
                savePersisted()
                busy = false
                refresh()
                onStatusChanged?()
                if failures.isEmpty {
                    Log.info("已关闭以前版本开着的代理引擎配置")
                } else {
                    let text = failures.joined(separator: L("；"))
                    Log.error("关闭以前版本开着的代理引擎配置失败：\(text)")
                    lastError = text
                }
            }
        }
        guard !persisted.noticeShown, legacyHelperInstalled, !persisted.extensionState.enabled else { return }
        persisted.noticeShown = true
        savePersisted()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NoticeWindowController.shared.showHelperNotice()
        }
        Log.info("已显示后台助手的提示")
    }

    // MARK: - 扩展「代理引擎」

    /// 从以前的版本更新过来时开着的是代理引擎那条配置、现在代理关着：开启扩展、代理引擎运行起来后把它开回来（扩展页的说明里会提到）。
    var willRestoreEngineProfile: Bool {
        guard persisted.extensionState.restoreActive, case .off = status else { return false }
        return true
    }

    /// 用户勾选同意说明并点了开启。
    func enableExtension() {
        extensions.accept()
        reconcileEngineProfile()
        extensions.prepareAndLaunch()
    }

    /// 关闭扩展：正在用「代理引擎」那条配置就先关掉代理（恢复系统设置），再退出代理引擎、去掉那条配置。
    func disableExtension(removeApp: Bool) async {
        if case .on(let current) = status, current.engine {
            turnOff()
            for _ in 0..<100 where busy {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await extensions.disable(removeApp: removeApp)
        reconcileEngineProfile()
    }

    /// 代理引擎开了、停了、换了端口：调整配置列表里的「代理引擎」；从以前的版本过来、以前开着它的，内核起来后开回来
    /// （这时用户已经开着别的配置就不动它）。
    private func extensionChanged() {
        reconcileEngineProfile()
        if persisted.extensionState.enabled, persisted.extensionState.restoreActive, extensions.status?.coreRunning != true {
            Log.info("扩展：等代理引擎的内核起来后开回以前开着的配置")
        }
        guard persisted.extensionState.enabled, persisted.extensionState.restoreActive,
              let engineStatus = extensions.status, engineStatus.coreRunning,
              let profile = config.profiles.first(where: { $0.engine }) else { return }
        // 正在开关代理时这次开启会被忽略：先不动，代理引擎下次更新状态时（最多 10 秒）再来。
        guard !busy else { return }
        persisted.extensionState.restoreActive = false
        savePersisted()
        guard case .off = status else {
            Log.info("代理引擎运行起来了，现在开着别的配置，不开回以前开着的「\(profile.name)」")
            return
        }
        Log.info("代理引擎运行起来了，开回以前开着的「\(profile.name)」")
        turnOn(profile)
    }

    /// 配置列表里的「代理引擎」：扩展开着时在最前面（端口跟着代理引擎），关着时去掉。
    func reconcileEngineProfile() {
        let ext = persisted.extensionState
        guard ext.enabled else {
            if config.profiles.contains(where: { $0.engine }) {
                config.profiles.removeAll { $0.engine }
            }
            if let id = persisted.lastProfileID, ext.profile?.id == id {
                persisted.lastProfileID = config.profiles.first?.id
                savePersisted()
            }
            return
        }
        var profile = ext.profile ?? Profile.engineProfile(port: 7890)
        profile.engine = true
        if let port = extensions.status?.mixedPort {
            profile.port = port
        }
        if ext.profile != profile {
            persisted.extensionState.profile = profile
            savePersisted()
        }
        if let index = config.profiles.firstIndex(where: { $0.engine }) {
            if config.profiles[index] != profile {
                update(profile)
            }
        } else {
            config.profiles.insert(profile, at: 0)
            if config.profiles.count == 1 {
                persisted.lastProfileID = profile.id
                savePersisted()
            }
        }
    }

    /// 删掉以前版本的后台助手（系统会请用户输入管理员密码）。
    func removeLegacyHelper() async {
        do {
            try await LegacyCleanup.removeHelper()
        } catch {
            lastError = (error as? ControlError)?.message ?? error.localizedDescription
        }
        legacyHelperInstalled = LegacyCleanup.helperInstalled
    }

    // MARK: - 状态

    /// 旧版本只有开启标记，首次操作时按当时的配置补齐范围。
    var appliedTargets: [ProxyTarget] {
        persisted.appliedTargets ?? ProxyTarget.allCases.filter { persisted.enabledByUs && selectedProfile?.targets.contains($0) == true }
    }

    var systemProxyChangedExternally: Bool {
        guard appliedTargets.contains(.system), let profile = selectedProfile else { return false }
        return !snapshot.matches(profile)
    }

    var targetStatuses: [ProxyTarget: ProxyTargetStatus] {
        Dictionary(uniqueKeysWithValues: ProxyTarget.allCases.map { target in
            let status: ProxyTargetStatus
            if targetFailures[target] != nil { status = .failed }
            else if appliedTargets.contains(target) {
                status = target == .system && systemProxyChangedExternally ? .changedExternally : .applied
            } else { status = .notApplied }
            return (target, status)
        })
    }

    var isPartiallyApplied: Bool {
        guard case .on(let profile) = status else { return false }
        return !targetFailures.isEmpty || profile.targets.contains { targetStatuses[$0] != .applied }
    }

    var status: ProxyStatus {
        if !appliedTargets.isEmpty, let profile = selectedProfile { return .on(profile) }
        if snapshot.isActive {
            if let profile = matchingProfile() {
                return .on(profile)
            }
            return .external(snapshot.summary)
        }
        let next = selectedProfile
        if let next, persisted.enabledByUs, !next.targets.contains(.system) {
            // 不含系统代理的配置（只设环境变量、git、npm）无法从系统代理判断，按记录的状态算。
            return .on(next)
        }
        return .off(next: next)
    }

    /// 最近使用的配置，没有记录时是第一个。
    var selectedProfile: Profile? {
        config.profile(id: persisted.lastProfileID) ?? config.profiles.first
    }

    private func matchingProfile() -> Profile? {
        if let selected = selectedProfile, snapshot.matches(selected) {
            return selected
        }
        return config.profiles.first { snapshot.matches($0) }
    }

    /// 本机状态写回 state.json（测试时不写）。
    private func savePersisted() {
        if persists {
            Store.save(persisted)
        }
    }

    func refresh() {
        let current = backend.currentSystemProxy()
        // 没变就不赋值：每次赋值都会让所有界面重画（设置窗口里的配置编辑页每次重画都要读一遍钥匙串）。
        guard current != snapshot else { return }
        snapshot = current
        onStatusChanged?()
    }

    // MARK: - 开关

    func toggle(askForPassword: Bool = true) {
        switch status {
        case .on, .external:
            turnOff()
        case .off(let next):
            if let next {
                turnOn(next, askForPassword: askForPassword)
            } else {
                lastError = L("还没有代理配置，请先在设置里添加一个")
                SettingsWindowController.shared.show(page: .profiles)
            }
        }
    }

    /// askForPassword：钥匙串里没有密码时弹窗请用户输入；命令行和 AI 助手调用时不弹窗，直接报错。
    /// replacing：重新应用正在用的配置（在设置里改了、iCloud 同步来了新的）时传改之前的那份。这时系统代理的现状已经对不上
    /// 改过的配置，不能再从 status 推断上一个配置（改前有、改后没有的生效范围要清掉），也不能把自己设的代理当成「开启前的设置」记下来。
    func turnOn(_ profile: Profile, askForPassword: Bool = true, replacing old: Profile? = nil) {
        guard !busy else { return }
        guard !profile.isUnsupported else {
            lastError = profile.validate()
            onStatusChanged?()
            return
        }
        // 要登录的代理：密码从这台 Mac 的钥匙串里取；还没有（比如配置是从别的 Mac 同步来的）就请用户输入一次。
        var password = ""
        if profile.needsPassword {
            if let saved = ProxyKeychain.password(for: profile.id, allowUI: askForPassword) {
                password = saved
            } else if askForPassword, let entered = PasswordPrompt.ask(for: profile), !entered.isEmpty {
                do {
                    try ProxyKeychain.set(entered, for: profile.id)
                } catch {
                    Log.error("保存「\(profile.name)」的密码失败：\(error.localizedDescription)")
                }
                password = entered
            } else {
                lastError = L("没有「%@」的代理密码，没有开启", profile.name)
                Log.error("这台 Mac 的钥匙串里没有「\(profile.name)」的代理密码，没有开启")
                onStatusChanged?()
                return
            }
        }
        busy = true
        lastError = nil
        targetFailures = [:]
        let previous: Profile? = old ?? {
            if case .on(let current) = status { return current }
            return persisted.enabledByUs ? selectedProfile : nil
        }()
        if persisted.original == nil || (old == nil && appliedTargets.isEmpty && !status.isOn) {
            persisted.original = snapshot
        }
        let mode = config.offMode
        Task {
            var failures: [String] = []
            // 代理引擎那条配置：先确认代理引擎在运行（没运行就启动它，等内核起来）。
            if profile.engine {
                do {
                    _ = try await extensions.ensureRunning()
                } catch {
                    finish(action: L("开启 %@", profile.name), failures: [error.localizedDescription], successText: "")
                    return
                }
            }
            // 上一个配置设置过、新配置没有的项先清掉。
            if previous != nil {
                for target in appliedTargets where !profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@（清除）：%@", target.title, error))
                    }
                }
            }
            for target in ProxyTarget.allCases where profile.targets.contains(target) {
                if let error = await set(target: target, profile: profile, password: password) {
                    failures.append(L("%@：%@", target.title, error))
                }
            }
            persisted.lastProfileID = profile.id
            persisted.enabledByUs = !appliedTargets.isEmpty
            // 用户重新开启了代理：上次退出时没清理完的不用再清（这次开启已经重新设过了）。
            persisted.pendingCleanup = nil
            savePersisted()
            finish(action: L("开启 %@", profile.name), failures: failures, successText: profile.summary)
        }
    }

    /// clearing：要关掉的配置已经不在配置列表里了（iCloud 同步来的配置删了它）时传它，按它的生效范围清理。
    func turnOff(clearing removed: Profile? = nil) {
        guard !busy else { return }
        busy = true
        targetFailures = [:]
        let current = removed.map { ProxyStatus.on($0) } ?? status
        let mode = config.offMode
        Task {
            var failures: [String] = []
            let owned = appliedTargets
            let targets: [ProxyTarget]
            if !owned.isEmpty {
                targets = owned
            } else if case .on(let profile) = current {
                targets = ProxyTarget.allCases.filter { profile.targets.contains($0) }
            } else if case .external = current {
                targets = [.system]
            } else {
                targets = []
            }
            var remaining: [ProxyTarget] = []
            for target in ProxyTarget.allCases where targets.contains(target) {
                if let error = await clear(target: target, mode: owned.isEmpty && !current.isOn ? .direct : mode) {
                    remaining.append(target)
                    failures.append(L("%@：%@", target.title, error))
                }
            }
            persisted.appliedTargets = remaining
            persisted.enabledByUs = !remaining.isEmpty
            if remaining.isEmpty {
                persisted.original = nil
                persisted.pendingCleanup = nil
            }
            savePersisted()
            finish(action: L("关闭代理"), failures: failures, successText: mode == .restore ? L("已恢复开启前的设置") : L("已改为直接连接"))
        }
    }

    /// 诊断页的「清除所有代理设置」：不管现在开着什么、是谁设的，系统代理都改成直接连接（不按「恢复开启前的设置」），
    /// 环境变量、git、npm 的代理都清掉。
    func clearAllProxySettings() async {
        guard !busy else { return }
        busy = true
        targetFailures = [:]
        var failures: [String] = []
        for target in ProxyTarget.allCases {
            if let error = await clear(target: target, mode: .direct) {
                failures.append(L("%@：%@", target.title, error))
            }
        }
        persisted.enabledByUs = !appliedTargets.isEmpty
        if appliedTargets.isEmpty {
            persisted.original = nil
            persisted.pendingCleanup = nil
        }
        savePersisted()
        finish(action: L("清除所有代理设置"), failures: failures, successText: L("已改为直接连接"))
    }

    func use(_ profile: Profile) {
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        } else {
            turnOn(profile)
        }
    }

    private func finish(action: String, failures: [String], successText: String) {
        busy = false
        healthMonitor.reset()
        refresh()
        onStatusChanged?()
        if failures.isEmpty {
            Log.info("\(action) 成功")
            lastError = nil
            notify(title: action, body: successText, problem: false)
        } else {
            let text = failures.joined(separator: L("；"))
            Log.error("\(action) 失败：\(text)")
            lastError = text
            notify(title: L("%@时出错", action), body: text, problem: true)
        }
        Task { await checkHealth() }
    }

    private func set(target: ProxyTarget, profile: Profile, password: String) async -> String? {
        let url = profile.proxyURL(password: password)
        do {
            switch target {
            case .system:
                let written = try await backend.applySystemProxy(DesiredProxy(profile: profile, password: password), also: persisted.systemServices)
                persisted.systemServices = written
            case .environment:
                try await backend.setEnvironment(proxyURL: url, noProxy: profile.noProxy)
            case .git:
                try await backend.setGit(proxyURL: url)
            case .npm:
                try backend.setNpm(proxyURL: url, noProxy: profile.noProxy)
            }
            var targets = appliedTargets
            if !targets.contains(target) { targets.append(target) }
            persisted.appliedTargets = targets
            targetFailures[target] = nil
            return nil
        } catch {
            let message = Redact.secrets(error.localizedDescription)
            targetFailures[target] = message
            return message
        }
    }

    /// 已经保存在钥匙串里的密码（没有就是空的）。allowUI 为 false 时不弹系统的钥匙串对话框（命令行、AI 助手调用时）。
    func savedPassword(for profile: Profile, allowUI: Bool = true) -> String {
        profile.needsPassword ? (ProxyKeychain.password(for: profile.id, allowUI: allowUI) ?? "") : ""
    }

    private func clear(target: ProxyTarget, mode: OffMode) async -> String? {
        do {
            switch target {
            case .system:
                // 开启时写过、现在没在用的网络服务也一起写（见 PersistedState.systemServices）。
                _ = try await backend.applySystemProxy(offDesired(mode: mode), also: persisted.systemServices)
                persisted.systemServices = []
            case .environment:
                try await backend.clearEnvironment()
            case .git:
                try await backend.clearGit()
            case .npm:
                try backend.clearNpm()
            }
            persisted.appliedTargets = appliedTargets.filter { $0 != target }
            targetFailures[target] = nil
            return nil
        } catch {
            let message = Redact.secrets(error.localizedDescription)
            targetFailures[target] = message
            return message
        }
    }

    /// 关闭代理时系统代理要写成什么：恢复开启前的设置，或者直接连接（保留例外列表，自动发现恢复成开启前的值）。
    private func offDesired(mode: OffMode) -> DesiredProxy {
        if mode == .restore, let original = persisted.original {
            return DesiredProxy(restoring: original)
        }
        let current = backend.currentSystemProxy()
        return DesiredProxy(offWithAutoDiscovery: persisted.original?.autoDiscovery ?? current.autoDiscovery, bypassDomains: current.exceptions)
    }

    // MARK: - 配置

    func addProfile(_ profile: Profile) {
        config.profiles.append(profile)
        if config.profiles.count == 1 {
            persisted.lastProfileID = profile.id
            savePersisted()
        }
    }

    /// passwordChanged：只改了钥匙串里的密码（配置本身没变）时也要重新应用。
    func update(_ profile: Profile, passwordChanged: Bool = false) {
        guard let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = config.profiles[index]
        // 先看改之前是不是正在用它：改了地址以后，系统代理的现状就对不上新地址了。
        let wasActive: Bool = {
            if case .on(let current) = status { return current.id == profile.id }
            return false
        }()
        config.profiles[index] = profile
        if profile.engine, persisted.extensionState.profile != profile {
            persisted.extensionState.profile = profile
            savePersisted()
        }
        // 正在使用的配置改了地址、生效范围或者密码：立即重新应用（只改名字和颜色不用）。
        if wasActive, !profile.appliesSame(as: previous) || passwordChanged {
            turnOn(profile, replacing: previous)
        }
    }

    func remove(_ profile: Profile) {
        // 「代理引擎」那条配置跟着扩展走，在扩展页里关闭扩展才会去掉。
        guard !profile.engine else { return }
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        }
        config.profiles.removeAll { $0.id == profile.id }
        ProxyKeychain.delete(for: profile.id)
        if persisted.lastProfileID == profile.id {
            persisted.lastProfileID = config.profiles.first?.id
            savePersisted()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        config.profiles.move(fromOffsets: source, toOffset: destination)
    }

    /// 来自 iCloud 的配置：整个换掉。正在使用的配置如果改了地址就重新应用，被删了就关闭代理。
    private func applyRemoteConfig(_ remote: AppConfig) {
        let active: Profile? = {
            if case .on(let profile) = status { return profile }
            return nil
        }()
        config = remote
        reconcileEngineProfile()
        guard let active, !active.engine else { return }
        // 换掉配置以后再算 status 就对不上了：上一个配置明确传进去。
        if let updated = remote.profile(id: active.id) {
            if !updated.appliesSame(as: active) {
                turnOn(updated, replacing: active)
            }
        } else {
            turnOff(clearing: active)
        }
    }

    /// 把别的程序设置的系统代理保存成配置。
    func saveExternalAsProfile() {
        guard var profile = snapshot.asProfile(name: L("系统代理")) else { return }
        var index = 1
        while config.profiles.contains(where: { $0.name == profile.name }) {
            index += 1
            profile.name = L("系统代理 %@", index)
        }
        profile.color = ProfilePalette.color(at: config.profiles.count)
        addProfile(profile)
        persisted.lastProfileID = profile.id
        savePersisted()
        refresh()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            loginItemEnabled = LoginItem.isEnabled
        } catch {
            lastError = L("设置登录时启动失败：%@", error.localizedDescription)
            loginItemEnabled = LoginItem.isEnabled
        }
    }

    // MARK: - 测速与健康

    func test(_ profile: Profile, askForPassword: Bool = true) async {
        let result = await ProxyTester.test(profile: profile, password: savedPassword(for: profile, allowUI: askForPassword), testURL: config.testURL)
        testResults[profile.id] = result
    }

    func testAll() async {
        await withTaskGroup(of: Void.self) { group in
            for profile in config.profiles {
                group.addTask { await self.test(profile) }
            }
        }
    }

    private func scheduleHealthCheck() {
        guard healthChecksStarted else { return }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthMonitor.interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkHealth() }
        }
    }

    func checkHealth() async {
        guard !healthCheckRunning else { return }
        healthCheckRunning = true
        healthTimer?.invalidate()
        defer {
            healthCheckRunning = false
            scheduleHealthCheck()
        }
        guard config.healthCheck, case .on(let profile) = status, profile.kind != .pac else {
            healthMonitor.reset()
            if health != .unknown {
                health = .unknown
                onStatusChanged?()
            }
            return
        }
        let reachable = await reachability(profile.host, profile.port)
        // 请求期间可能换配置、关闭代理或关闭检查；旧响应不能改新状态。
        guard !Task.isCancelled, config.healthCheck, case .on(let current) = status,
              current.id == profile.id, current.host == profile.host, current.port == profile.port else { return }
        let notice = healthMonitor.record(reachable, profile: profile, now: healthClock())
        if health != healthMonitor.health {
            health = healthMonitor.health
            onStatusChanged?()
        }
        switch notice {
        case .failed:
            notify(title: L("连不上代理服务器"), body: L("%@（%@）没有响应，浏览器可能无法上网", profile.name, profile.summary), problem: true)
        case .recovered:
            notify(title: L("代理服务器恢复了"), body: profile.summary, problem: false)
        case nil: break
        }
    }

    // MARK: - 通知与退出

    func notify(title: String, body: String, problem: Bool, route: String? = nil, category: String? = nil) {
        switch config.notifyLevel {
        case .none: return
        case .problems where !problem: return
        default: break
        }
        Notifier.shared.show(title: title, body: body, route: route, category: category)
    }

    /// 退出时按设置关闭代理；代理引擎开着的话也让它退出（它自己停内核）。
    /// 正在用「代理引擎」那条配置时，不管「退出时关闭代理」开没开都关掉：代理引擎跟着退出，不关的话系统代理、终端、git、npm
    /// 都指向一个没人监听的端口，再打开 Proxi 之前上不了网。
    /// 重新启动（一键更新、换语言）时什么都不关，新的实例接着用；注销、重新启动电脑、关机时设了登录时启动的话也一样
    /// （「退出时关闭代理」开着也不关）：登录后 Proxi 会再打开、接着启动代理引擎，代理接着用。
    func handleExit() {
        control.stop()
        if relaunching {
            // 同一个网络上按规则切过的记录交给新的实例：不然它启动时又按规则切一次，把手动改过的改回去。
            network.saveForRelaunch()
        }
        if !relaunchingForUpdate {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: ExtensionManager.bundleIdentifier) {
                app.terminate()
            }
        }
        guard !relaunching, case .on(let profile) = status, config.disableOnExit || profile.engine else { return }
        // 注销、重新启动电脑、关机时设了登录时启动：登录后 Proxi 会再打开（代理引擎也跟着启动），和重新启动一样什么都不关。
        if poweringOffAt.map({ Date().timeIntervalSince($0) < 300 }) == true && LoginItem.isEnabled {
            Log.info("注销或关机：设了登录时启动，登录后会再打开，「\(profile.name)」留着")
            return
        }
        // 各项都清理好了才记下代理已经关了；没清理完的（管理员密码没输完、出错、超时）记下来，下次启动时接着清理，
        // 开启前的设置也留着，到时候还能恢复。
        let targets = ProxyTarget.allCases.filter { (appliedTargets.isEmpty ? profile.targets.contains($0) : appliedTargets.contains($0)) }
        let failures = ExitCleanup.run(targets, systemProxy: offDesired(mode: config.offMode), services: persisted.systemServices,
                                       backend: backend, timeout: exitCleanupTimeout)
        let remaining = targets.filter { failures[$0] != nil }
        persisted.appliedTargets = remaining
        if remaining.isEmpty {
            // 不然只设了终端、git、npm 的配置下次打开时还显示开着，下次开启时也会把这时的设置当成「开启前的设置」。
            persisted.enabledByUs = false
            persisted.original = nil
            persisted.systemServices = []
            persisted.pendingCleanup = nil
            savePersisted()
            Log.info("退出时关闭了「\(profile.name)」")
        } else {
            if !remaining.contains(.system) {
                persisted.systemServices = []
            }
            persisted.pendingCleanup = PendingCleanup(profileName: profile.name, targets: remaining)
            savePersisted()
            let detail = remaining.map { "\($0.rawValue): \(failures[$0] ?? "")" }.joined(separator: "; ")
            Log.error("退出时没清理完「\(profile.name)」（\(detail)），下次启动时接着清理")
        }
    }

    /// 上次退出时没清理完的代理设置（见 handleExit）：启动时接着清理，并告诉用户。
    func resumePendingCleanup() async {
        guard let pending = persisted.pendingCleanup, !busy else { return }
        busy = true
        targetFailures = [:]
        persisted.appliedTargets = pending.targets
        Log.info("接着清理上次退出时没清理完的「\(pending.profileName)」：\(pending.targets.map(\.rawValue).joined(separator: "、"))")
        var remaining: [ProxyTarget] = []
        var problems: [String] = []
        for target in pending.targets {
            if let error = await clear(target: target, mode: config.offMode) {
                remaining.append(target)
                problems.append(L("%@：%@", target.title, error))
            }
        }
        if remaining.isEmpty {
            persisted.enabledByUs = false
            persisted.original = nil
            persisted.pendingCleanup = nil
            savePersisted()
            Log.info("已清理上次退出时没清理完的「\(pending.profileName)」")
            notify(title: L("已清理上次退出时没清理完的代理设置"),
                   body: L("「%@」：%@", pending.profileName, pending.targets.map(\.title).joined(separator: L("、"))), problem: false)
        } else {
            persisted.pendingCleanup?.targets = remaining
            savePersisted()
            let message = problems.joined(separator: "\n")
            lastError = L("上次退出时的代理设置还没清理完：%@", message)
            Log.error("上次退出时没清理完的「\(pending.profileName)」还是没清理好：\(message)")
            notify(title: L("上次退出时的代理设置还没清理完"), body: message, problem: true)
        }
        busy = false
        refresh()
        onStatusChanged?()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.unregister(id: 1)
        hotkeyProblem = nil
        guard let binding = config.toggleHotkey else { return }
        if !HotkeyCenter.shared.register(id: 1, binding: binding, action: { [weak self] in
            Task { @MainActor in self?.toggle() }
        }) {
            let problem = L("快捷键 %@ 已被其他程序占用，请换一个", binding.display)
            hotkeyProblem = problem
            lastError = problem
        }
    }
}
